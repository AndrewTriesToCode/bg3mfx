#pragma once

// Metal source for bg3mfx's replacements of BG3's composition draws, the
// full-screen draws that compose the tone-mapped scene and the UI into the
// drawable: CombineUI_HDR and CombineUINo_UI_HDR (BG3's HDR path, Improved
// HDR) and CombineUI and CombineUI_NoUI (BG3's SDR path, Improved SDR). They
// keep BG3's names (metalfx's Frame Generation recognizes the composition by
// them), its bindings and its DefaultVS stage input. ImprovedDisplay.mm
// compiles it at runtime. All of them write extended-linear BT.2020 for an
// RGBA16Float drawable, where 1.0 is SDR white.
//
// HDR path: BG3's display LUT writes the scene as BT.2020 PQ (absolute nits).
// BG3 then decodes it, blends the UI in at UIPaperWhite nits and encodes PQ
// again. These write the scene at nits / 100 (BG3's SDR reference white; its
// paper-white setting brightens the scene from there) and the UI at SDR white.
// Partly covered pixels use BG3's SDR blend (CombineUI): the scene, encoded as
// sRGB, times (1 - coverage) plus the premultiplied sRGB UI, so translucent UI
// looks as it does in SDR. BG3's HDR blend instead attenuates the scene twice
// in linear light, which turns warm translucent UI grey.
//
// BG3's HDR display LUT compresses the scene's gamut to P3 (in a BT.2020
// container), so a P3 or wider screen shows every color it writes. For a
// screen that can't (sRGB), function constant 0 compresses P3 into sRGB:
// ACES 1.3's reference gamut compression (distance from the achromatic axis,
// threshold 0.8, power 1.2), with limits that put P3's boundary on sRGB's.
//
// SDR path: BG3's SDR display LUT writes sRGB-encoded BT.709, and CombineUI
// blends the UI over it in sRGB and applies the SDR gamma setting, as these
// do. BG3 then writes that to an 8-bit drawable tagged Display P3, so P3
// screens show BT.709 colors stretched to P3 primaries, and the drawable bands.
// These decode the same values as sRGB BT.709 into the float drawable: BG3's
// SDR image, in its own colors, without 8-bit steps.
static const char BG3MFXImprovedDisplaySource[] = R"METAL(
#include <metal_stdlib>
using namespace metal;
struct In { float4 position [[position]]; float2 texCoord; };
struct Combine { float UIPaperWhite, SDRGamma, HDRGamma, HDRPaperWhite; };
constant float SDRWhiteNits = 100.0;
constant bool CompressToSRGB [[function_constant(0)]];
constant bool compressToSRGB = is_function_constant_defined(CompressToSRGB) && CompressToSRGB;
// The headroom (relative to SDR white) the scene's highlights roll off into,
// or 0 (function constant 1): ImprovedDisplay.mm sets it when BG3's LUT can't
// peak at the headroom without its clamp.
constant float Rolloff [[function_constant(1)]];
constant float rolloff = is_function_constant_defined(Rolloff) ? Rolloff : 0.0;
// BG3's HDR LUT draws colors about 1.4x as saturated as its SDR LUT (in
// CIELAB, colors within sRGB, fitted outside the game): its ZCAM viewing
// conditions assume a bright HDR screen and it renders into P3 primaries.
// Improved HDR scales the scene's chroma to SDR's.
constant float HDRSaturation = 0.70;
static float3 pqToNits(float3 e) {
    float3 p = pow(abs(e), 1.0 / 78.84375);
    float3 n = max(p - 0.8359375, 0.0) / (18.8515625 - 18.6875 * p);
    return pow(n, 1.0 / 0.1593017578125) * 10000.0;
}
static float3 sceneLinear(float3 pq) {
    float3 scene = pqToNits(pq) / SDRWhiteNits;
    const float luminance = dot(scene, float3(0.2627, 0.6780, 0.0593));
    scene = luminance + HDRSaturation * (scene - luminance);
    if (rolloff > 0.0) {
        // Above 0.7 x the headroom, the brightest channel approaches the
        // headroom (slope 1 at the knee), keeping its hue.
        const float peak = max(scene.r, max(scene.g, scene.b)), knee = 0.7 * rolloff;
        if (peak > knee) {
            const float x = peak - knee;
            scene *= (knee + x / (1.0 + x / (rolloff - knee))) / peak;
        }
    }
    return scene;
}
constant float3x3 BT709ToBT2020 = float3x3(float3(0.6274040, 0.0690970, 0.0163916),
                                           float3(0.3292820, 0.9195400, 0.0880132),
                                           float3(0.0433136, 0.0113612, 0.8955950));
constant float3x3 BT2020ToBT709 = float3x3(float3(1.660491, -0.124550, -0.018151),
                                           float3(-0.587641, 1.132900, -0.100579),
                                           float3(-0.072850, -0.008349, 1.118730));
// sRGB's transfer, extended to negative values and values above 1.
static float3 srgbDecode(float3 c) {
    float3 a = abs(c);
    return sign(c) * select(pow((a + 0.055) / 1.055, 2.4), a / 12.92, a <= 0.04045);
}
static float3 srgbEncode(float3 l) {
    float3 a = abs(l);
    return sign(l) * select(1.055 * pow(a, 1.0 / 2.4) - 0.055, a * 12.92, a <= 0.0031308);
}
// The UI is sRGB-encoded BT.709; linear BT.2020 at SDR white.
static float3 uiLinear(float3 c) {
    return BT709ToBT2020 * srgbDecode(c);
}
// BG3's SDR blend of a premultiplied sRGB UI over the scene, in sRGB.
static float3 blendSDR(float3 scene, float4 ui) {
    float3 encoded = srgbEncode(BT2020ToBT709 * scene) * (1.0 - ui.a) + ui.rgb;
    return BT709ToBT2020 * srgbDecode(encoded);
}
// How far P3's boundary reaches past sRGB's, per channel (cyan, magenta,
// yellow), as a distance from the achromatic axis.
constant float3 P3Limits = float3(1.2159, 1.0343, 1.0983);
static float compressDistance(float d, float limit) {
    const float threshold = 0.8, power = 1.2;
    if (d < threshold) return d;
    const float scale = (limit - threshold) / pow(pow((1.0 - threshold) / (limit - threshold), -power) - 1.0, 1.0 / power);
    const float x = (d - threshold) / scale;
    return threshold + scale * x / pow(1.0 + pow(x, power), 1.0 / power);
}
static float3 output(float3 bt2020) {
    if (!compressToSRGB) return bt2020;
    float3 c = BT2020ToBT709 * bt2020;
    const float achromatic = max(c.r, max(c.g, c.b));
    if (achromatic <= 0.0) return float3(0.0);
    float3 d = (achromatic - c) / achromatic;
    d = float3(compressDistance(d.r, P3Limits.r), compressDistance(d.g, P3Limits.g), compressDistance(d.b, P3Limits.b));
    return BT709ToBT2020 * max(achromatic - d * achromatic, 0.0);
}
fragment float4 CombineUI_HDR(In in [[stage_in]], texture2d<float> Base [[texture(0)]], texture2d<float> Tex [[texture(1)]],
                              sampler LinearClampSampler [[sampler(0)]], constant Combine &combine [[buffer(0)]]) {
    float4 ui = Tex.sample(LinearClampSampler, in.texCoord);
    if (ui.a == 1.0) return float4(uiLinear(ui.rgb), 1.0);
    float3 scene = sceneLinear(Base.read(uint2(in.position.xy)).rgb);
    if (ui.a < 0.001) return float4(output(scene), 1.0);
    return float4(output(blendSDR(scene, ui)), 1.0);
}
fragment float4 CombineUINo_UI_HDR(In in [[stage_in]], texture2d<float> Base [[texture(0)]], constant Combine &combine [[buffer(0)]]) {
    return float4(output(sceneLinear(Base.read(uint2(in.position.xy)).rgb)), 1.0);
}
// BG3's SDR output of an sRGB value (its gamma setting, as CombineUI applies
// it), as linear BT.2020.
static float4 sdrOutput(float3 encoded, float gamma) {
    const float3 c = pow(max(abs(saturate(encoded)), 0.0001), 1.0 / gamma);
    return float4(BT709ToBT2020 * srgbDecode(c), 1.0);
}
fragment float4 CombineUI(In in [[stage_in]], texture2d<float> Base [[texture(0)]], texture2d<float> Tex [[texture(1)]],
                          sampler LinearClampSampler [[sampler(0)]], constant Combine &combine [[buffer(0)]]) {
    float4 ui = Tex.sample(LinearClampSampler, in.texCoord);
    if (ui.a == 1.0) return sdrOutput(ui.rgb, combine.SDRGamma);
    float3 scene = Base.read(uint2(in.position.xy)).rgb;
    if (ui.a < 0.001) return sdrOutput(scene, combine.SDRGamma);
    return sdrOutput(ui.rgb + scene * (1.0 - ui.a), combine.SDRGamma);
}
fragment float4 CombineUI_NoUI(In in [[stage_in]], texture2d<float> Base [[texture(0)]], constant Combine &combine [[buffer(0)]]) {
    return sdrOutput(Base.read(uint2(in.position.xy)).rgb, combine.SDRGamma);
}
)METAL";
// The headroom steps Improved HDR's highlight roll-off variants are built for.
inline constexpr int BG3MFXImprovedDisplayRolloffSteps = 14;
inline constexpr float BG3MFXImprovedDisplayRolloffHeadroom[] = {1.0f, 1.25f, 1.5f, 1.75f, 2.0f, 2.5f, 3.0f, 4.0f, 5.0f, 6.0f, 8.0f, 10.0f, 12.0f, 16.0f};
// What the drawable shows at 1.0 in nits, for the tone scale's peak.
inline constexpr float BG3MFXImprovedDisplayWhiteNits = 100.0f;
