#[compute]
#version 450

// Zoom-out parents: each parent tile is the 2x2 mean of its four children, per channel, truncating (Dynmap's
// zoomFile). Child order is 0 = top-right, 1 = bottom-right, 2 = top-left, 3 = bottom-left; a missing child is
// all zero. Pixels are packed RGBA8 words; z of the dispatch selects the parent.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Src { uint px[]; } src;
layout(set = 0, binding = 1, std430) restrict writeonly buffer Dst { uint px[]; } dst;

const uint T = 128u;
const uint H = 64u;

void main() {
	uvec3 g = gl_GlobalInvocationID;
	if (g.x >= T || g.y >= T) {
		return;
	}
	uint left = g.x < H ? 1u : 0u;
	uint bottom = g.y >= H ? 1u : 0u;
	uint child = (left << 1u) | bottom;
	uint sx = (g.x % H) * 2u;
	uint sy = (g.y % H) * 2u;
	uint base = (g.z * 4u + child) * T * T;
	uint p0 = src.px[base + sy * T + sx];
	uint p1 = src.px[base + sy * T + sx + 1u];
	uint p2 = src.px[base + (sy + 1u) * T + sx];
	uint p3 = src.px[base + (sy + 1u) * T + sx + 1u];
	uint o = 0u;
	for (uint c = 0u; c < 4u; c++) {
		uint s = 8u * c;
		uint sum = ((p0 >> s) & 255u) + ((p1 >> s) & 255u) + ((p2 >> s) & 255u) + ((p3 >> s) & 255u);
		o |= (sum >> 2u) << s;
	}
	dst.px[g.z * T * T + g.y * T + g.x] = o;
}
