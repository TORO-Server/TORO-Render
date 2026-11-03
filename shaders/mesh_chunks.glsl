#[compute]
#version 450

// Chunk mesher on the GPU: one invocation per block column of a target chunk. Walks the column bottom-up and emits the
// baked quads of every block state (culling, Dynmap-style smooth light samples, biome tint, fluids) exactly like
// scripts/mesher.gd (the CPU reference) / Dynmap-GPU mesh.rs. Two passes: emit = 0 only counts quads, emit = 1 writes them.
// Quads of one block are contiguous; the order between blocks is unspecified (atomics), which only matters for
// coincident faces of different blocks (none in practice).

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Grid { int grid[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer ChunkMeta { int cmeta[]; };   // 4 per chunk
layout(set = 0, binding = 2, std430) restrict readonly buffer SecMeta { int smeta[]; };     // 8 per section
layout(set = 0, binding = 3, std430) restrict readonly buffer Pal { uint pal[]; };          // palette -> state id
layout(set = 0, binding = 4, std430) restrict readonly buffer Data { uint data[]; };        // big-endian long arrays
layout(set = 0, binding = 5, std430) restrict readonly buffer Bytes { uint bytes[]; };      // sky, block light, biomes
layout(set = 0, binding = 6, std430) restrict readonly buffer SInfo { uint sinfo[]; };      // 8 per state
layout(set = 0, binding = 7, std430) restrict readonly buffer QD { float qd[]; };           // 20 floats per quad
layout(set = 0, binding = 8, std430) restrict readonly buffer QM { int qm[]; };             // 4 ints per quad
layout(set = 0, binding = 9, std430) restrict readonly buffer BiomeCol { uint bcol[]; };    // 3 per biome
layout(set = 0, binding = 10, std430) restrict readonly buffer Targets { ivec2 targets[]; };
layout(set = 0, binding = 11, std430) restrict readonly buffer TexClass { uint tclass[]; };
layout(set = 0, binding = 12, std430) restrict readonly buffer Offs { vec4 offs[]; };       // per target, .z = map z offset
layout(set = 0, binding = 13, std430) buffer Counters { uint counters[]; };                 // 0 = quads, 1 = translucent
layout(set = 0, binding = 14, std430) restrict writeonly buffer VF { float vf[]; };         // 32 floats per quad
layout(set = 0, binding = 15, std430) restrict writeonly buffer VI { uint vi[]; };          // 12 uints per quad
layout(set = 0, binding = 16, std430) restrict writeonly buffer QChunk { uint qchunk[]; };  // target index per quad
layout(set = 0, binding = 17, std430) restrict writeonly buffer Trans { uint trans[]; };    // (quad, z key bits) pairs

layout(push_constant, std430) uniform Params {
	int n_targets;
	int gx0;
	int gz0;
	int gw;
	int gh;
	int topdown;
	int emit;
	int n_biomes;
	vec4 row2;     // third row of the world->map matrix
	int water_tex;
	int lava_tex;
	int p0;
	int p1;
} p;

const uint F_AIR = 1u;
const uint F_OPAQUE = 2u;
const uint F_SOLID = 4u;

uint bswap(uint x) {
	return ((x & 0xFFu) << 24) | ((x & 0xFF00u) << 8) | ((x >> 8) & 0xFF00u) | (x >> 24);
}

uint byte_at(uint off) {
	return (bytes[off >> 2] >> ((off & 3u) * 8u)) & 255u;
}

bool is_air(uint s) { return (sinfo[s * 8u] & F_AIR) != 0u; }
bool is_opaque(uint s) { return (sinfo[s * 8u] & F_OPAQUE) != 0u; }
bool is_solid(uint s) { return (sinfo[s * 8u] & F_SOLID) != 0u; }
uint fluid_kind(uint s) { return (sinfo[s * 8u] >> 3u) & 3u; }
bool is_waterlogged(uint s) { return ((sinfo[s * 8u] >> 5u) & 1u) != 0u; }
bool cull_same(uint s) { return ((sinfo[s * 8u] >> 6u) & 1u) != 0u; }
uint tint_code(uint s) { return sinfo[s * 8u + 1u]; }
uint block_of(uint s) { return sinfo[s * 8u + 2u]; }
uint level_of(uint s) { return sinfo[s * 8u + 3u]; }
uint fluid_of(uint s) {
	uint f = fluid_kind(s);
	if (f != 0u) {
		return f;
	}
	return is_waterlogged(s) ? 1u : 0u;
}

int chunk_idx(int x, int z) {
	int gx = (x >> 4) - p.gx0;
	int gz = (z >> 4) - p.gz0;
	if (gx < 0 || gz < 0 || gx >= p.gw || gz >= p.gh) {
		return -1;
	}
	return grid[gz * p.gw + gx];
}

int sec_idx(int ci, int y) {
	if (ci < 0) {
		return -1;
	}
	int si = (y >> 4) - cmeta[ci * 4 + 1];
	if (si < 0 || si >= cmeta[ci * 4 + 2]) {
		return -1;
	}
	int s = cmeta[ci * 4] + si;
	return smeta[s * 8 + 7] == 0 ? -1 : s;
}

uint block_in(int s, int lx, int ly, int lz) {
	int data_off = smeta[s * 8 + 1];
	if (data_off < 0) {
		return uint(smeta[s * 8 + 6]);
	}
	int bits = smeta[s * 8 + 2];
	int idx = (ly << 8) | (lz << 4) | lx;
	int per = 64 / bits;
	int li = idx / per;
	int sh = (idx % per) * bits;
	uint hi = bswap(data[data_off + li * 2]);
	uint lo = bswap(data[data_off + li * 2 + 1]);
	uint mask = (1u << uint(bits)) - 1u;
	uint v;
	if (sh >= 32) {
		v = (hi >> uint(sh - 32)) & mask;
	} else if (sh + bits <= 32) {
		v = (lo >> uint(sh)) & mask;
	} else {
		v = ((lo >> uint(sh)) | (hi << uint(32 - sh))) & mask;
	}
	return pal[smeta[s * 8] + int(v)];
}

uint state_at(int x, int y, int z) {
	int s = sec_idx(chunk_idx(x, z), y);
	if (s < 0) {
		return 0u;
	}
	return block_in(s, x & 15, y & 15, z & 15);
}

int nib(int off, int i) {
	uint b = byte_at(uint(off + (i >> 1)));
	return int((i & 1) == 1 ? (b >> 4) : (b & 15u));
}

int light_at(int x, int y, int z) {
	int ci = chunk_idx(x, z);
	if (ci < 0) {
		return 15;
	}
	int s = sec_idx(ci, y);
	if (s < 0) {
		int max_y = (cmeta[ci * 4 + 1] + cmeta[ci * 4 + 2]) * 16;
		return y >= max_y ? 15 : 0;
	}
	int i = ((y & 15) << 8) | ((z & 15) << 4) | (x & 15);
	int sky = 0;
	int sky_off = smeta[s * 8 + 3];
	if (sky_off >= 0) {
		sky = nib(sky_off, i);
	} else if ((y >> 4) >= cmeta[ci * 4 + 3]) {
		sky = 15;
	}
	int bl = 0;
	int blk_off = smeta[s * 8 + 4];
	if (blk_off >= 0) {
		bl = nib(blk_off, i);
	}
	return max(sky, bl);
}

uint biome_at(int x, int y, int z) {
	int ci = chunk_idx(x, z);
	int s = sec_idx(ci, y);
	if (s < 0) {
		return 0u;
	}
	return byte_at(uint(smeta[s * 8 + 5] + (((y & 15) >> 2) << 4) + (((z & 15) >> 2) << 2) + ((x & 15) >> 2)));
}

int semi_light(int x, int y, int z) {
	return max(max(light_at(x, y + 1, z), light_at(x - 1, y, z)),
		max(max(light_at(x + 1, y, z), light_at(x, y, z - 1)), light_at(x, y, z + 1)));
}

// Dynmap's light sample for a block position (mesh.rs sample_light): fluids the brightest neighbour, solid blocks the
// light of the face they were entered through (or of the fluid in front), everything else its own light.
int sample_light(uint s, int x, int y, int z, ivec3 nv) {
	if (fluid_kind(s) != 0u) {
		return semi_light(x, y, z);
	}
	if (!is_air(s) && is_solid(s)) {
		int ex = x + nv.x;
		int ey = y + nv.y;
		int ez = z + nv.z;
		if (fluid_kind(state_at(ex, ey, ez)) != 0u) {
			return semi_light(ex, ey, ez);
		}
		return light_at(ex, ey, ez);
	}
	return light_at(x, y, z);
}

const ivec3 DIRV[6] = ivec3[6](ivec3(0, -1, 0), ivec3(0, 1, 0), ivec3(0, 0, -1), ivec3(0, 0, 1), ivec3(-1, 0, 0), ivec3(1, 0, 0));

// own | axis1- << 4 | axis1+ << 8 | axis2- << 12 | axis2+ << 16 ; own_fluid selects the fluid sample for the block itself
uint face_light(uint sid, bool own_fluid, int x, int y, int z, int n) {
	ivec3 nv = DIRV[n];
	int own = own_fluid ? semi_light(x, y, z) : sample_light(sid, x, y, z, nv);
	ivec3 a1;
	ivec3 a2;
	if (n == 5 || n == 4) {
		a1 = ivec3(0, 1, 0);
		a2 = ivec3(0, 0, 1);
	} else if (n == 2 || n == 3) {
		a1 = ivec3(1, 0, 0);
		a2 = ivec3(0, 1, 0);
	} else {
		a1 = ivec3(1, 0, 0);
		a2 = ivec3(0, 0, 1);
	}
	ivec3 o0 = ivec3(x, y, z) - a1;
	ivec3 o1 = ivec3(x, y, z) + a1;
	ivec3 o2 = ivec3(x, y, z) - a2;
	ivec3 o3 = ivec3(x, y, z) + a2;
	uint r = uint(own);
	r |= uint(sample_light(state_at(o0.x, o0.y, o0.z), o0.x, o0.y, o0.z, nv)) << 4;
	r |= uint(sample_light(state_at(o1.x, o1.y, o1.z), o1.x, o1.y, o1.z, nv)) << 8;
	r |= uint(sample_light(state_at(o2.x, o2.y, o2.z), o2.x, o2.y, o2.z, nv)) << 12;
	r |= uint(sample_light(state_at(o3.x, o3.y, o3.z), o3.x, o3.y, o3.z, nv)) << 16;
	return r;
}

uint shade_class(int d) {
	if (d == 5 || d == 4) {
		return 1u;
	}
	if (d == 2 || d == 3) {
		return 2u;
	}
	if (d == 1) {
		return 3u;
	}
	return 4u;
}

uint tint_color(uint sid, int x, int y, int z) {
	uint t = tint_code(sid);
	if (t == 0u) {
		return 0xFFFFFFu;
	}
	if (t >= 0x1000000u) {
		return t & 0xFFFFFFu;
	}
	uint b = biome_at(x, y, z);
	if (int(b) >= p.n_biomes) {
		return 0xFFFFFFu;
	}
	return bcol[b * 3u + (t - 1u)];
}

// ---------------------------------------------------------------------------------------------------------------------

uint g_target;
vec3 g_off;
uint g_lx;
uint g_lz;
int g_min_y;

void push_vertex(uint q, uint v, vec3 pos, vec2 uv, vec3 local, uint flags, uint color, uint light) {
	uint fo = (q * 4u + v) * 8u;
	vf[fo] = pos.x;
	vf[fo + 1u] = pos.y;
	vf[fo + 2u] = pos.z;
	vf[fo + 3u] = uv.x;
	vf[fo + 4u] = uv.y;
	vf[fo + 5u] = local.x;
	vf[fo + 6u] = local.y;
	vf[fo + 7u] = local.z;
	uint io = (q * 4u + v) * 3u;
	vi[io] = flags;
	vi[io + 1u] = color;
	vi[io + 2u] = light;
}

// Translucent quads are listed for the CPU, which sorts them back to front in double precision like Dynmap-GPU does:
// 16 uints each = quad index, target index, emission order inside the chunk (block y/z/x, quad ordinal), 12 vertex floats.
void note_quad(uint q, uint tex, vec3 p0, vec3 p1, vec3 p2, vec3 p3, int y, uint w) {
	if ((tclass[tex] & 2u) != 0u) {
		uint t = atomicAdd(counters[1], 1u);
		uint o = t * 16u;
		uint within = ((uint(y - g_min_y) << 8u) | (g_lz << 4u) | g_lx) * 64u + min(w, 63u);
		trans[o] = q;
		trans[o + 1u] = g_target;
		trans[o + 2u] = within;
		vec3 pv[4] = vec3[4](p0, p1, p2, p3);
		for (uint k = 0u; k < 4u; k++) {
			trans[o + 3u + k * 3u] = floatBitsToUint(pv[k].x);
			trans[o + 4u + k * 3u] = floatBitsToUint(pv[k].y);
			trans[o + 5u + k * 3u] = floatBitsToUint(pv[k].z);
		}
	}
}

void main() {
	uint gid = gl_GlobalInvocationID.x;
	uint ti = gid >> 8u;
	if (int(ti) >= p.n_targets) {
		return;
	}
	g_target = ti;
	g_off = offs[ti].xyz;
	int lx = int(gid & 15u);
	int lz = int((gid >> 4u) & 15u);
	ivec2 cc = targets[ti];
	int x = cc.x * 16 + lx;
	int z = cc.y * 16 + lz;
	int ci = chunk_idx(x, z);
	if (ci < 0) {
		return;
	}
	int min_y = cmeta[ci * 4 + 1] * 16;
	int max_y = (cmeta[ci * 4 + 1] + cmeta[ci * 4 + 2]) * 16;
	g_lx = uint(lx);
	g_lz = uint(lz);
	g_min_y = min_y;
	int top = -2147483647 - 1;
	if (p.topdown != 0) {
		for (int y = max_y - 1; y >= min_y; y--) {
			int s = sec_idx(ci, y);
			if (s < 0 || (smeta[s * 8 + 1] < 0 && smeta[s * 8 + 6] == 0)) {
				y = ((y >> 4) << 4);
				continue;
			}
			uint id = block_in(s, lx, y & 15, lz);
			if (id != 0u && is_opaque(id)) {
				top = y;
				break;
			}
		}
	}
	for (int y = min_y; y < max_y; y++) {
		int s = sec_idx(ci, y);
		if (s < 0 || (smeta[s * 8 + 1] < 0 && smeta[s * 8 + 6] == 0)) {
			y = ((y >> 4) << 4) + 15;
			continue;
		}
		uint id = block_in(s, lx, y & 15, lz);
		if (id == 0u || y < top || is_air(id)) {
			continue;
		}
		bool opaque = is_opaque(id);
		uint fk = fluid_kind(id);
		if (opaque && fk == 0u) {
			bool enclosed = true;
			for (int d = 0; d < 6; d++) {
				ivec3 o = ivec3(x, y, z) + DIRV[d];
				if (!is_opaque(state_at(o.x, o.y, o.z))) {
					enclosed = false;
					break;
				}
			}
			if (enclosed) {
				continue;
			}
		}
		uint yeven = ((y & 1) == 0) ? 1u : 0u;
		uint qstart = sinfo[id * 8u + 4u];
		uint qcount = sinfo[id * 8u + 5u];
		// --- regular quads: first pass counts the survivors, the second writes them contiguously
		uint nq = 0u;
		uint nt = 0u;
		uint flu = fluid_of(id);
		// fluid faces (counted below once their visibility is known)
		bool top_face = false;
		bool side[4] = bool[4](false, false, false, false);
		float fh = 1.0;
		if (flu != 0u) {
			uint lvl = level_of(id);
			if (fk == 0u) {
				lvl = 0u;
			}
			bool above = fluid_of(state_at(x, y + 1, z)) == flu;
			fh = (above || lvl >= 8u) ? 1.0 : float(8u - min(lvl, 7u)) / 9.0;
			top_face = !above;
			// north, south, west, east
			for (int k = 0; k < 4; k++) {
				ivec3 d = (k == 0) ? ivec3(0, 0, -1) : (k == 1) ? ivec3(0, 0, 1) : (k == 2) ? ivec3(-1, 0, 0) : ivec3(1, 0, 0);
				uint nid = state_at(x + d.x, y, z + d.z);
				side[k] = !(fluid_of(nid) == flu || (is_opaque(nid) && !is_air(nid)));
			}
		}
		for (int pass = 0; pass < 2; pass++) {
			uint base = 0u;
			if (pass == 1) {
				if (nq == 0u) {
					break;
				}
				if (p.emit == 0) {
					atomicAdd(counters[0], nq);
					atomicAdd(counters[1], nt);
					break;
				}
				base = atomicAdd(counters[0], nq);
			}
			uint w = 0u;
			if (fk == 0u) {
				for (uint q = 0u; q < qcount; q++) {
					uint qi = qstart + q;
					int cull = qm[qi * 4u + 2u];
					if (cull >= 0) {
						ivec3 o = ivec3(x, y, z) + DIRV[cull];
						uint nid = state_at(o.x, o.y, o.z);
						if (is_opaque(nid) && !is_air(nid)) {
							continue;
						}
						if (cull_same(id) && block_of(nid) == block_of(id)) {
							continue;
						}
					}
					uint tex = uint(qm[qi * 4u]);
					if ((tclass[tex] & 3u) == 0u) {
						continue;
					}
					if (pass == 0) {
						nq++;
						nt += (tclass[tex] >> 1u) & 1u;
						continue;
					}
					int tintidx = qm[qi * 4u + 1u];
					int normal = qm[qi * 4u + 3u];
					uint color = tintidx >= 0 ? tint_color(id, x, y, z) : 0xFFFFFFu;
					uint light = face_light(id, false, x, y, z, normal);
					uint flags = (tex & 0xFFFFu) | (shade_class(normal) << 16u) | (yeven << 19u);
					uint qo = base + w;
					vec3 pv[4];
					for (uint v = 0u; v < 4u; v++) {
						uint o = qi * 20u + v * 3u;
						vec3 lp = vec3(qd[o], qd[o + 1u], qd[o + 2u]);
						vec2 uv = vec2(qd[qi * 20u + 12u + v * 2u], qd[qi * 20u + 12u + v * 2u + 1u]);
						pv[v] = vec3(float(lx) + lp.x, float(y) + lp.y, float(lz) + lp.z);
						push_vertex(qo, v, pv[v], uv, lp, flags, color, light);
					}
					qchunk[qo] = g_target;
					note_quad(qo, tex, pv[0], pv[1], pv[2], pv[3], y, w);
					w++;
				}
			}
			if (flu != 0u) {
				uint tex = flu == 1u ? uint(p.water_tex) : uint(p.lava_tex);
				bool visible = (tclass[tex] & 3u) != 0u;
				uint color = 0xFFFFFFu;
				if (flu == 1u) {
					uint b = biome_at(x, y, z);
					color = int(b) < p.n_biomes ? bcol[b * 3u + 2u] : 0x3f76e4u;
				}
				for (int face = 0; face < 5; face++) {
					// face 0: top, 1..4: north, south, west, east
					bool vis = face == 0 ? top_face : side[face - 1];
					if (!vis || !visible) {
						continue;
					}
					if (pass == 0) {
						nq++;
						nt += (tclass[tex] >> 1u) & 1u;
						continue;
					}
					int cls = face == 0 ? 3 : (face <= 2 ? 2 : 1);
					vec3 pp[4];
					if (face == 0) {
						pp = vec3[4](vec3(0.0, fh, 0.0), vec3(0.0, fh, 1.0), vec3(1.0, fh, 1.0), vec3(1.0, fh, 0.0));
					} else if (face == 1) {
						pp = vec3[4](vec3(1.0, fh, 0.0), vec3(1.0, 0.0, 0.0), vec3(0.0, 0.0, 0.0), vec3(0.0, fh, 0.0));
					} else if (face == 2) {
						pp = vec3[4](vec3(0.0, fh, 1.0), vec3(0.0, 0.0, 1.0), vec3(1.0, 0.0, 1.0), vec3(1.0, fh, 1.0));
					} else if (face == 3) {
						pp = vec3[4](vec3(0.0, fh, 0.0), vec3(0.0, 0.0, 0.0), vec3(0.0, 0.0, 1.0), vec3(0.0, fh, 1.0));
					} else {
						pp = vec3[4](vec3(1.0, fh, 1.0), vec3(1.0, 0.0, 1.0), vec3(1.0, 0.0, 0.0), vec3(1.0, fh, 0.0));
					}
					// light normal class: East for 1 (x faces), North for 2 (z faces), Up, Down
					int ln = cls == 1 ? 5 : (cls == 2 ? 2 : 1);
					uint light = face_light(id, true, x, y, z, ln);
					uint flags = tex | (uint(cls) << 16u) | (yeven << 19u) | (1u << 20u);
					uint qo = base + w;
					vec2 uvs[4] = vec2[4](vec2(0.0, 0.0), vec2(0.0, 1.0), vec2(1.0, 1.0), vec2(1.0, 0.0));
					vec3 pv[4];
					for (uint v = 0u; v < 4u; v++) {
						pv[v] = vec3(float(lx) + pp[v].x, float(y) + pp[v].y, float(lz) + pp[v].z);
						push_vertex(qo, v, pv[v], uvs[v], pp[v], flags, color, light);
					}
					qchunk[qo] = g_target;
					note_quad(qo, tex, pv[0], pv[1], pv[2], pv[3], y, w);
					w++;
				}
			}
			if (pass == 0 && nq == 0u) {
				break;
			}
		}
	}
}
