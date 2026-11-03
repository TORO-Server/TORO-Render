#[compute]
#version 450

// Dynmap "iso_S_90_lowres" (flat, 4 px per block) tile shader.
// One invocation = one output pixel. Per block column the CPU supplies up to 5 layers (top -> bottom);
// the shader composites them like Dynmap's stdtexture renderer: nearest opaque texel as the base,
// translucent texels above it blended bottom-to-top, brightness from Dynmap's smooth lighting.

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, std430) restrict readonly buffer Columns {
    uint cols[];
};
layout(set = 0, binding = 1, std430) restrict readonly buffer Atlas {
    uint texels[];
};
layout(set = 0, binding = 2, std430) restrict writeonly buffer Out {
    uint pixels[];
};

layout(push_constant, std430) uniform Params {
    uint pw;  // output width in pixels
    uint ph;  // output height in pixels
    uint wb;  // columns per row (blocks)
    uint hb;  // rows of columns (blocks)
} p;

const int S = 4;
const int MID = 2;
const uint COL_WORDS = 16u;
const uint SHADOW[16] = uint[16](0u, 4u, 9u, 15u, 21u, 28u, 36u, 45u, 56u, 69u, 85u, 104u, 128u, 158u, 199u, 256u);

uint cscale(uint light, int c1, int c2) {
    int lv0 = int(light & 15u);
    int lv1 = int((light >> 8u) & 15u);
    if (c1 < MID) {
        lv1 = int((light >> 4u) & 15u);
    }
    int lv2 = int((light >> 16u) & 15u);
    if (c2 < MID) {
        lv2 = int((light >> 12u) & 15u);
    }
    int w1 = abs(c1 - MID);
    int w2 = abs(c2 - MID);
    int weight = 0;
    if (lv1 < lv0) {
        weight -= w1;
    } else if (lv1 > lv0) {
        weight += w1;
    }
    if (lv2 < lv0) {
        weight -= w2;
    } else if (lv2 > lv0) {
        weight += w2;
    }
    int base = int(SHADOW[lv0]);
    if (weight == 0) {
        return uint(base);
    }
    if (weight < 0) {
        int w = -weight;
        if (lv0 > 0) {
            return uint((base * (S - w) + int(SHADOW[lv0 - 1]) * w) / S);
        }
        return uint(base);
    }
    if (lv0 < 15) {
        return uint((base * (S - weight) + int(SHADOW[lv0 + 1]) * weight) / S);
    }
    return uint(base);
}

// Returns the shaded texel: rgb 0..255 in xyz, alpha 0..255 in w.
uvec4 shade_layer(uint w0, uint tint, uint light, int u, int v, int c1, int c2) {
    uint tex = w0 & 0xFFFFu;
    uint yeven = (w0 >> 19u) & 1u;
    uint noshade = (w0 >> 20u) & 1u;
    uint t = texels[tex * 16u + uint(v * S + u)];
    uvec3 rgb = uvec3(t & 255u, (t >> 8u) & 255u, (t >> 16u) & 255u);
    uint a = (t >> 24u) & 255u;
    uvec3 tc = uvec3((tint >> 16u) & 255u, (tint >> 8u) & 255u, tint & 255u);
    rgb = rgb * tc / 255u;
    uint m = 255u;
    if (noshade == 0u && yeven == 1u) {
        m = 0xF3u;
    }
    rgb = rgb * m / 255u;
    uint cs = (noshade == 1u) ? SHADOW[light & 15u] : cscale(light, c1, c2);
    if (cs < 256u) {
        rgb = (rgb * cs) / 256u;
    }
    return uvec4(rgb, a);
}

float q8(float x) {
    return floor(clamp(x, 0.0, 1.0) * 255.0 + 0.5) / 255.0;
}

void main() {
    uvec2 id = gl_GlobalInvocationID.xy;
    if (id.x >= p.pw || id.y >= p.ph) {
        return;
    }
    // Dynmap tile rows run north -> south: image row 0 is the smallest z of the rectangle.
    int bx = int(id.x) / S;
    int row = int(id.y) / S;
    int u = int(id.x) % S;
    int v = int(id.y) % S;
    uint base = (uint(row) * p.wb + uint(bx)) * COL_WORDS;
    uint count = cols[base + 15u];

    int base_layer = -1;
    uvec4 base_px = uvec4(0u);
    for (uint i = 0u; i < count; i++) {
        uvec4 s = shade_layer(cols[base + i * 3u], cols[base + i * 3u + 1u], cols[base + i * 3u + 2u], u, v, u, v);
        if (s.w == 255u) {
            base_layer = int(i);
            base_px = s;
            break;
        }
    }

    vec4 dst = vec4(0.0);
    int start = int(count) - 1;
    if (base_layer >= 0) {
        dst = vec4(vec3(base_px.xyz) / 255.0, 1.0);
        start = base_layer - 1;
    }
    for (int i = start; i >= 0; i--) {
        uint b = base + uint(i) * 3u;
        uvec4 s = shade_layer(cols[b], cols[b + 1u], cols[b + 2u], u, v, u, v);
        if (s.w == 0u || s.w == 255u) {
            continue;
        }
        float a = float(s.w) / 255.0;
        vec4 src = vec4(vec3(s.xyz) / 255.0 * a, a);
        dst = src + dst * (1.0 - a);
        dst = vec4(q8(dst.x), q8(dst.y), q8(dst.z), q8(dst.w));
    }

    uvec4 o = uvec4(0u);
    if (dst.w > 0.0) {
        vec3 rgb = dst.xyz / dst.w;
        o = uvec4(uvec3(floor(clamp(rgb, 0.0, 1.0) * 255.0 + 0.5)), uint(floor(dst.w * 255.0 + 0.5)));
    }
    pixels[id.y * p.pw + id.x] = o.x | (o.y << 8u) | (o.z << 16u) | (o.w << 24u);
}
