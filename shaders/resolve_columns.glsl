#[compute]
#version 450

// Column resolver: one invocation per block column. Walks the column from the top, reads packed chunk data
// (palette + bit-packed long arrays, light nibbles, biomes) straight from GPU buffers and emits up to 5 layers
// (texture word, tint, Dynmap light word) in the layout flat_tile.glsl consumes.
// Mirrors scripts/world_reader.gd build_columns (the CPU reference used by --verify).

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Grid { int grid[]; };
layout(set = 0, binding = 1, std430) restrict readonly buffer ChunkMeta { int cmeta[]; };   // 4 per chunk
layout(set = 0, binding = 2, std430) restrict readonly buffer SecMeta { int smeta[]; };     // 8 per section
layout(set = 0, binding = 3, std430) restrict readonly buffer Pal { uint pal[]; };
layout(set = 0, binding = 4, std430) restrict readonly buffer Data { uint data[]; };        // big-endian long arrays
layout(set = 0, binding = 5, std430) restrict readonly buffer Bytes { uint bytes[]; };      // sky, block light, biomes
layout(set = 0, binding = 6, std430) restrict readonly buffer BlockInfo { uint binfo[]; };  // 2 per id: info, tint
layout(set = 0, binding = 7, std430) restrict readonly buffer BiomeCol { uint bcol[]; };    // 3 per biome
layout(set = 0, binding = 8, std430) restrict writeonly buffer Cols { uint cols[]; };

layout(push_constant, std430) uniform Params {
    int x0;
    int z0;
    int wb;
    int hb;
    int gx0;
    int gz0;
    int gw;
    int gh;
} p;

const int MAX_LAYERS = 5;
const uint COL_WORDS = 16u;

uint bswap(uint x) {
    return ((x & 0xFFu) << 24) | ((x & 0xFF00u) << 8) | ((x >> 8) & 0xFF00u) | (x >> 24);
}

uint byte_at(uint off) {
    return (bytes[off >> 2] >> ((off & 3u) * 8u)) & 255u;
}

uint kind_of(uint id) { return binfo[id * 2u] & 255u; }

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

uint block_at(int x, int y, int z) {
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

int semi_light(int x, int y, int z) {
    return max(max(light_at(x, y + 1, z), light_at(x - 1, y, z)),
        max(max(light_at(x + 1, y, z), light_at(x, y, z - 1)), light_at(x, y, z + 1)));
}

int sample_light(int x, int y, int z) {
    uint k = kind_of(block_at(x, y, z));
    if (k == 2u) {
        return semi_light(x, y, z);
    }
    if (k == 1u) {
        if (kind_of(block_at(x, y + 1, z)) == 2u) {
            return semi_light(x, y + 1, z);
        }
        return light_at(x, y + 1, z);
    }
    return light_at(x, y, z);
}

uint face_light(int x, int y, int z) {
    return uint(sample_light(x, y, z)) | (uint(sample_light(x - 1, y, z)) << 4) | (uint(sample_light(x + 1, y, z)) << 8)
        | (uint(sample_light(x, y, z - 1)) << 12) | (uint(sample_light(x, y, z + 1)) << 16);
}

uint tint_color(uint id, uint biome) {
    uint t = binfo[id * 2u + 1u];
    if (t == 0u) {
        return 0xFFFFFFu;
    }
    if (t >= 1u && t <= 3u) {
        return bcol[biome * 3u + (t - 1u)];
    }
    return t & 0xFFFFFFu;
}

void main() {
    ivec2 id = ivec2(gl_GlobalInvocationID.xy);
    if (id.x >= p.wb || id.y >= p.hb) {
        return;
    }
    int x = p.x0 + id.x;
    int z = p.z0 + id.y;
    uint base = uint(id.y * p.wb + id.x) * COL_WORDS;
    for (uint i = 0u; i < COL_WORDS; i++) {
        cols[base + i] = 0u;
    }
    int ci = chunk_idx(x, z);
    if (ci < 0) {
        return;
    }
    int lx = x & 15;
    int lz = z & 15;
    int min_y = cmeta[ci * 4 + 1] * 16;
    int y = (cmeta[ci * 4 + 1] + cmeta[ci * 4 + 2]) * 16 - 1;
    int n = 0;
    while (y >= min_y && n < MAX_LAYERS) {
        int s = sec_idx(ci, y);
        if (s < 0 || (smeta[s * 8 + 1] < 0 && kind_of(uint(smeta[s * 8 + 6])) == 0u)) {
            y = ((y >> 4) << 4) - 1;
            continue;
        }
        uint bid = block_in(s, lx, y & 15, lz);
        uint k = kind_of(bid);
        if (k == 0u) {
            y--;
            continue;
        }
        uint info = binfo[bid * 2u];
        uint tex = (info >> 8) & 0xFFFFu;
        uint opaque = (info >> 24) & 1u;
        uint biome = byte_at(uint(smeta[s * 8 + 5] + (((y & 15) >> 2) << 4) + (((z & 15) >> 2) << 2) + ((x & 15) >> 2)));
        uint tint = tint_color(bid, biome);
        uint w0 = tex;
        if ((y & 1) == 0) {
            w0 |= 1u << 19;
        }
        uint light;
        if (k == 2u) {
            w0 |= 1u << 20;
            light = uint(semi_light(x, y, z));
        } else {
            light = face_light(x, y, z);
        }
        cols[base + uint(n) * 3u] = w0;
        cols[base + uint(n) * 3u + 1u] = tint;
        cols[base + uint(n) * 3u + 2u] = light;
        n++;
        if (k == 1u && opaque == 1u) {
            break;
        }
        if (k == 2u) {
            while (y > min_y && kind_of(block_at(x, y - 1, z)) == 2u) {
                y--;
            }
        }
        y--;
    }
    cols[base + 15u] = uint(n);
}
