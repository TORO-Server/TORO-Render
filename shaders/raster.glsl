#[vertex]
#version 450

// Orthographic raster of baked quads with Dynmap-style shading (port of Dynmap-GPU tile.wgsl).
// Vertices are pulled from storage buffers: 6 vertices per quad, optionally through a sorted quad order.

layout(constant_id = 0) const bool TRANS = false;

layout(set = 0, binding = 0, std140) uniform U {
	vec4 row0;
	vec4 row1;
	vec4 row2;
	vec2 size;
	float z_min;
	float z_max;
	uint scale;
	uint atlas_cols;
	uint p0;
	uint p1;
	uvec4 shadow[4];
} u;

layout(set = 0, binding = 2, std430) readonly buffer VF { float vf[]; };
layout(set = 0, binding = 3, std430) readonly buffer VI { uint vi[]; };
layout(set = 0, binding = 4, std430) readonly buffer Chunks { vec4 chunk_off[]; };   // xyz = map offset, w = first vertex
layout(set = 0, binding = 5, std430) readonly buffer Order { uint order[]; };        // sorted quad indices (translucent pass)

layout(location = 0) out vec2 o_uv;
layout(location = 1) flat out uint o_tf;
layout(location = 2) flat out uint o_color;
layout(location = 3) flat out uint o_light;
layout(location = 4) out vec3 o_local;

const uint CORNER[6] = uint[6](0u, 1u, 2u, 0u, 2u, 3u);

void main() {
	uint qi = uint(gl_VertexIndex) / 6u;
	uint corner = CORNER[uint(gl_VertexIndex) % 6u];
	uint quad = TRANS ? order[qi] : qi;
	uint v = quad * 4u + corner;
	uint fo = v * 8u;
	vec3 p = vec3(vf[fo], vf[fo + 1u], vf[fo + 2u]);
	// chunk of this vertex: last entry whose first vertex <= v
	uint lo = 0u;
	uint hi = u.p0;
	while (hi - lo > 1u) {
		uint mid = (lo + hi) / 2u;
		if (uint(chunk_off[mid].w) <= v) {
			lo = mid;
		} else {
			hi = mid;
		}
	}
	vec3 m = vec3(dot(u.row0.xyz, p), dot(u.row1.xyz, p), dot(u.row2.xyz, p)) + chunk_off[lo].xyz;
	float nx = m.x / (u.size.x * 0.5) - 1.0;
	float ny = m.y / (u.size.y * 0.5) - 1.0;
	float d = (m.z - u.z_min) / (u.z_max - u.z_min);
	gl_Position = vec4(nx, -ny, clamp(d, 0.0001, 0.9999), 1.0);
	o_uv = vec2(vf[fo + 3u], vf[fo + 4u]);
	o_local = vec3(vf[fo + 5u], vf[fo + 6u], vf[fo + 7u]);
	uint io = v * 3u;
	o_tf = vi[io];
	o_color = vi[io + 1u];
	o_light = vi[io + 2u];
}

#[fragment]
#version 450

layout(constant_id = 0) const bool TRANS = false;

layout(set = 0, binding = 0, std140) uniform U {
	vec4 row0;
	vec4 row1;
	vec4 row2;
	vec2 size;
	float z_min;
	float z_max;
	uint scale;
	uint atlas_cols;
	uint p0;
	uint p1;
	uvec4 shadow[4];
} u;

layout(set = 0, binding = 1) uniform sampler2D atlas;

layout(location = 0) in vec2 i_uv;
layout(location = 1) flat in uint i_tf;
layout(location = 2) flat in uint i_color;
layout(location = 3) flat in uint i_light;
layout(location = 4) in vec3 i_local;

layout(location = 0) out vec4 frag;

uint shadow_at(uint i) {
	return u.shadow[i / 4u][i % 4u];
}

uint cscale_for(uint light, uint cls, vec3 local) {
	int s = int(u.scale);
	int mid = s / 2;
	ivec3 sub = clamp(ivec3(floor(local * float(s))), ivec3(0), ivec3(s - 1));
	int c1 = 0;
	int c2 = 0;
	if (cls == 1u) {
		c1 = sub.y;
		c2 = sub.z;
	} else if (cls == 2u) {
		c1 = sub.x;
		c2 = sub.y;
	} else {
		c1 = sub.x;
		c2 = sub.z;
	}
	int lv0 = int(light & 15u);
	int lv1 = int((light >> 8u) & 15u);
	if (c1 < mid) {
		lv1 = int((light >> 4u) & 15u);
	}
	int lv2 = int((light >> 16u) & 15u);
	if (c2 < mid) {
		lv2 = int((light >> 12u) & 15u);
	}
	int w1 = abs(c1 - mid);
	int w2 = abs(c2 - mid);
	int weight = 0;
	if (lv1 < lv0) {
		weight = weight - w1;
	} else if (lv1 > lv0) {
		weight = weight + w1;
	}
	if (lv2 < lv0) {
		weight = weight - w2;
	} else if (lv2 > lv0) {
		weight = weight + w2;
	}
	int base = int(shadow_at(uint(lv0)));
	if (weight == 0) {
		return uint(base);
	}
	if (weight < 0) {
		int w = -weight;
		if (lv0 > 0) {
			return uint((base * (s - w) + int(shadow_at(uint(lv0 - 1))) * w) / s);
		}
		return uint(base);
	}
	if (lv0 < 15) {
		return uint((base * (s - weight) + int(shadow_at(uint(lv0 + 1))) * weight) / s);
	}
	return uint(base);
}

void main() {
	uint tex = i_tf & 0xFFFFu;
	uint cls = (i_tf >> 16u) & 7u;
	uint yeven = (i_tf >> 19u) & 1u;
	int s = int(u.scale);
	int cx = int(tex % u.atlas_cols) * s;
	int cy = int(tex / u.atlas_cols) * s;
	int tx = clamp(int(floor(i_uv.x * float(s))), 0, s - 1);
	int ty = clamp(int(floor(i_uv.y * float(s))), 0, s - 1);
	vec4 t = texelFetch(atlas, ivec2(cx + tx, cy + ty), 0);
	uvec3 rgb = uvec3(roundEven(t.rgb * 255.0));
	uvec3 tint = uvec3((i_color >> 16u) & 255u, (i_color >> 8u) & 255u, i_color & 255u);
	rgb = rgb * tint / 255u;
	uint m = 255u;
	if (cls == 1u) {
		m = 0x99u;
	} else if (cls == 2u) {
		m = 0xCDu;
	} else if (cls == 3u) {
		if (yeven == 1u) {
			m = 0xF3u;
		}
	} else if (cls == 4u) {
		m = 0x80u;
	}
	uint noshade = (i_tf >> 20u) & 1u;
	if (noshade == 1u) {
		m = 255u;
	}
	rgb = rgb * m / 255u;
	uint cs = cscale_for(i_light, cls, i_local);
	if (noshade == 1u) {
		cs = shadow_at(i_light & 15u);
	}
	if (cs < 256u) {
		rgb = (rgb * cs) / 256u;
	}
	uint a = uint(roundEven(t.a * 255.0));
	vec3 col = vec3(rgb) / 255.0;
	if (!TRANS) {
		if (a < 255u) {
			discard;
		}
		frag = vec4(col, 1.0);
	} else {
		if (a == 0u || a == 255u) {
			discard;
		}
		float af = float(a) / 255.0;
		frag = vec4(col * af, af);
	}
}
