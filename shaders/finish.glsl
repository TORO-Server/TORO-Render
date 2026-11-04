#[compute]
#version 450

// Un-premultiplies the rendered image into packed RGBA8 words.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0) uniform sampler2D img;
layout(set = 0, binding = 1, std430) writeonly buffer Out { uint px[]; };

layout(push_constant, std430) uniform P {
	uint w;
	uint h;
	uint p0;
	uint p1;
} pc;

void main() {
	ivec2 c = ivec2(gl_GlobalInvocationID.xy);
	if (c.x >= int(pc.w) || c.y >= int(pc.h)) {
		return;
	}
	vec4 t = texelFetch(img, c, 0);
	uvec4 b = uvec4(roundEven(t * 255.0));
	uint a = b.a;
	uvec4 o = b;
	if (a == 0u) {
		o = uvec4(0u);
	} else if (a != 255u) {
		o.rgb = min(uvec3(255u), (b.rgb * 255u + a / 2u) / a);
	}
	px[uint(c.y) * pc.w + uint(c.x)] = o.r | (o.g << 8u) | (o.b << 16u) | (o.a << 24u);
}
