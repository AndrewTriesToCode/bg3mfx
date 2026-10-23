#pragma once

// Metal source for bg3mfx's sun shadow mask, which replaces BG3's
// DirLight_Cascaded_PCSS_<N>x<size> (Medium and High shadows) and
// DirLight_Cascaded_PCF_<N>x1024 (Low). Function constants select the cascade
// count, the shadow map size and the filter; ImprovedShadows.mm compiles it at
// runtime.
//
// Per pixel: position = linear depth x the frustum ray; the G-buffer's surface
// normal; the first cascade whose fade weight is nonzero; a normal offset of
// about one shadow-map texel; a golden-angle filter (PCSS: radius from a
// blocker search; PCF: a fixed radius); a blend into the next cascade where
// the first fades; and the vista (distant) shadow maps beyond their distance.
//
// BG3's own pass derives the normal per 2x2 pixel quad from depth derivatives
// and fades the normal offset into a small constant bias where it distrusts
// that normal. Quads across terrain triangle edges then draw diamonds and
// dotted lines, and at low render resolution slopes shadow themselves. The
// G-buffer normal is per pixel and reliable at any resolution, so this shader
// keeps the full offset everywhere and nothing depends on the quad.
static const char BG3MFXImprovedShadowsSource[] = R"METAL(
#include <metal_stdlib>
using namespace metal;

constant int Cascades [[function_constant(0)]];
constant float MapSize [[function_constant(1)]];
constant bool PCSS [[function_constant(2)]];

struct In { float4 position [[position]]; float3 frustumOffset; };
struct PerFrame { float f0, f1, time, timeScale; };
struct PerCamera { float4x4 m0, m1, m2; float nearDepth, depthScale; };
struct PerView { packed_float3 light; float pad0; packed_float3 v1; float pad1; packed_float3 v2; float pad2; float4x4 viewToWorld; };
struct ShadowMaskParams { int materials, vista, vistaSlice; float vistaDistance; float4x4 vistaMatrix, vistaDetailedMatrix; };
struct Object { float4 a, b, c, d; };
struct Lighting {
    float f0, f1, f2, f3, softness, f5, edgeFade;
    float4 depthRange, texelWorld;
    float4x4 cascade[4];
    float4 depthFade, constantBias, minimumRadius;
};

struct Inputs {
    texture2d<float> linearDepth, gbuffer0, gbuffer2, gbuffer3, noise;
    depth2d_array<float> shadow, vista, vistaDetailed;
    sampler shadowSampler, pointSampler;
    device const Object *objects;
    constant ShadowMaskParams *params;
    constant PerView *view;
    constant PerCamera *camera;
    constant PerFrame *frame;
    constant Lighting *lighting;
};

constexpr constant float Golden = 0x1.3331fep+1;

static float cascadeWeight(float4 c, float edgeFade, float depthFade) {
    float2 edge = saturate(edgeFade * (1 - abs(saturate(c.xy) * 2 - 1)));
    return edge.x * edge.y * saturate(depthFade * saturate(c.z));
}

// The surface normal in shadow-map units of cascade i: about one texel.
static float3 normalOffset(constant Lighting &l, int i, float3 normal, bool flip) {
    float3 n = (l.cascade[i] * float4(normal, 0)).xyz;
    if (flip) n = -n;
    float scale = (1.0 / MapSize) / l.texelWorld[i];
    float3 offset = n * scale;
    offset.z += max(0.0, 0x1p-16 - scale / l.depthRange[i]);
    return offset;
}

// BG3's stereographic G-buffer normal, view space, rotated like the lighting pass.
static float3 gbufferNormal(Inputs in, uint2 pixel) {
    float3 m = float3(in.gbuffer0.read(pixel).xy * 0x1.c71758p+1 - 0x1.c71758p+0, 1);
    float m2 = dot(m, m);
    float3 n = m2 > 0x1.29254dp+35 ? float3(0, 0, 1) : float3(m.xy * (2 / m2), 1 - 2 / m2);
    return normalize((in.view->viewToWorld * float4(n, 0)).xyz);
}

// Golden-angle disc of 9 - i comparisons around the offset position.
static float filtered(Inputs in, int i, float3 coord, float3 offset, float radius, float angle) {
    int count = 9 - i;
    float root = sqrt(float(count)), lit = 0;
    float3 texel = offset * MapSize, center = coord + offset;
    for (int j = 0; j < count; ++j) {
        float a = float(j) * Golden + angle;
        float3 s = (texel + float3(cos(a), sin(a), 0)) * (sqrt(float(j) + 0.5) * radius / root) + center;
        lit += in.shadow.sample_compare(in.shadowSampler, s.xy, i, s.z);
    }
    return lit / float(count);
}

// The filter radius in cascade i. PCSS: from the average blocker found by a
// golden-angle search over 7 - i points (wider for receivers far below the
// light); PCF: fixed.
static float filterRadius(Inputs in, int i, float3 coord, float3 offset, float flagBias, float angle) {
    constant Lighting &l = *in.lighting;
    float floorRadius = max(l.minimumRadius[i], flagBias * (1.0 / MapSize));
    if (!PCSS) return max(l.softness * 7 * l.texelWorld[i], floorRadius);
    float z = coord.z;
    float search = max(l.texelWorld[i] * min(0x1.ae147ap-3, l.softness * ((1 - z) * l.depthRange[i])), floorRadius);
    int count = 7 - i;
    float root = sqrt(float(count)), sum = 0, blockers = 0;
    float3 base = offset * MapSize * 0x1.19999ap+0, center = coord + offset;
    for (int j = 0; j < count; ++j) {
        float a = float(j) * Golden + angle;
        float3 s = (base + float3(cos(a), sin(a), 0)) * (sqrt(float(j) + 0.5) * search / root) + center;
        float d = in.shadow.sample(in.pointSampler, s.xy, i, level(0));
        if (d > s.z) { sum += d; blockers += 1; }
    }
    float average = sum / max(blockers, 1.0);
    return max(l.texelWorld[i] * min(0x1.ae147ap-3, l.softness * ((average - z) * l.depthRange[i])), floorRadius);
}

static float shadowMask(Inputs in, float4 position, float3 frustumOffset) {
    constant Lighting &l = *in.lighting;
    uint2 pixel = uint2(position.xy);
    float depth = in.linearDepth.read(pixel).x;
    if (depth == 1) return 1;
    float3 p = depth * frustumOffset;
    float worldDepth = depth * in.camera->depthScale;
    // Per-pixel rotation of the filter discs, animated over time. PCSS also
    // dithers it across each 2x2 quad.
    float noise, dither = 0;
    if (PCSS) {
        noise = in.noise.read(uint2(position.xy * 0.5) & 63).x;
        float sx = (pixel.x & 1) == 0 ? 1.0 : -1.0, sy = (pixel.y & 1) == 0 ? 0.5 : -0.5;
        dither = (sy + sx + 1.5) * 0x1.147ae2p-2;
    } else noise = in.noise.read(pixel & 63).x;
    float angle = (fract(in.frame->time * 0.25) * in.frame->timeScale + dither + noise) * 0x1.921fb6p+2;
    float3 normal = gbufferNormal(in, pixel);

    // Material flags: a wider minimum radius, and two-sided foliage facing
    // away from the sun takes its back face's normal.
    bool back = dot(float3(in.view->light), normal) < 0;
    float flagBias = 0; bool flip = false;
    if (in.params->materials != 0 || back) {
        uint bits = uint(round(in.gbuffer2.read(pixel).w * 255));
        uint type = bits & 7;
        flagBias = in.params->materials == 0 || (bits & 128) == 0 ? 0 : 20;
        if (back && type - 3 < 2) {
            float4 g3 = in.gbuffer3.read(pixel);
            flip = (type != 3 || g3.w != 0) && in.objects[int(g3.x * 255)].c.z != 1;
        }
    }

    float result = 1;
    for (int i = 0; i < Cascades; ++i) {
        float4 c = l.cascade[i] * float4(p, 1);
        float weight = cascadeWeight(c, l.edgeFade, l.depthFade[i]);
        if (weight == 0) continue;
        float3 offset = normalOffset(l, i, normal, flip);
        float radius = filterRadius(in, i, c.xyz, offset, flagBias, angle);
        result = weight * filtered(in, i, c.xyz, offset, radius, angle);
        if (i < Cascades - 1 && weight < 1) {
            // Fading out of this cascade: blend the next one in.
            int next = i + 1;
            float4 c2 = l.cascade[next] * float4(p, 1);
            if (cascadeWeight(c2, l.edgeFade, l.depthFade[next]) > 0) {
                float radius2 = PCSS ? radius * l.texelWorld[next] / l.texelWorld[i] :
                    max(l.softness * 7 * l.texelWorld[next], max(l.minimumRadius[next], flagBias * (1.0 / MapSize)));
                result += (1 - weight) * filtered(in, next, c2.xyz, normalOffset(l, next, normal, flip), radius2, angle + 0x1.921fb6p-1);
            }
        } else result += 1 - weight;
        break;
    }
    result = max(result, 0.0);

    constant ShadowMaskParams &params = *in.params;
    if (params.vista != 0 && worldDepth > params.vistaDistance) {
        float4 v = params.vistaDetailedMatrix * float4(p, 1);
        if (all(abs(v.xy - 0.5) < 0.5) && v.z >= 0) {
            float4 c = l.cascade[Cascades - 1] * float4(p, 1);
            if (cascadeWeight(c, l.edgeFade, l.depthFade[Cascades - 1]) < 1)
                result = min(result, in.vistaDetailed.sample_compare(in.shadowSampler, v.xy, params.vistaSlice, v.z + 0x1.a36e2ep-15, level(0)));
        } else {
            float4 u = params.vistaMatrix * float4(p, 1);
            if (all(abs(u.xy - 0.5) < 0.5) && u.z >= 0)
                result = in.vista.sample_compare(in.shadowSampler, u.xy, params.vistaSlice, u.z + 0x1.6f0068p-11, level(0));
        }
    }
    return result;
}

fragment float BG3MFXImprovedShadows(In in [[stage_in]],
    texture2d<float> linearDepth [[texture(0)]], texture2d<float> gbuffer2 [[texture(1)]],
    depth2d_array<float> vista [[texture(2)]], depth2d_array<float> vistaDetailed [[texture(3)]],
    texture2d<float> noise [[texture(4)]], texture2d<float> gbuffer3 [[texture(5)]],
    depth2d_array<float> shadow [[texture(36)]], texture2d<float> gbuffer0 [[texture(40)]],
    sampler pointSampler [[sampler(0)]], sampler shadowSampler [[sampler(9)]],
    constant ShadowMaskParams &params [[buffer(0)]], constant Lighting &lighting [[buffer(7)]],
    constant PerCamera &camera [[buffer(11)]], constant PerView &view [[buffer(12)]],
    constant PerFrame &frame [[buffer(13)]], device const Object *objects [[buffer(14)]]) {
    Inputs inputs = {linearDepth, gbuffer0, gbuffer2, gbuffer3, noise, shadow, vista, vistaDetailed,
        shadowSampler, pointSampler, objects, &params, &view, &camera, &frame, &lighting};
    return shadowMask(inputs, in.position, in.frustumOffset);
}
)METAL";
