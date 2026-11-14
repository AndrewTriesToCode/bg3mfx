#pragma once

// Metal source for bg3mfx's replacements of BG3's CombineUI_HDR and
// CombineUINo_UI_HDR, the full-screen draws that compose the tone-mapped scene
// and the UI into the drawable. They keep BG3's names (metalfx's Frame
// Generation recognizes the composition by them), its bindings and its
// DefaultVS stage input. ImprovedDisplay.mm compiles it at runtime.
//
// BG3's display LUT writes the scene as BT.2020 PQ (absolute nits). BG3 then
// decodes it, blends the UI in at UIPaperWhite nits and encodes PQ again. These
// write extended-linear BT.2020 for an RGBA16Float drawable instead, where 1.0
// is SDR white: the scene at nits / 100 (BG3's SDR reference white; its
// paper-white setting brightens the scene from there) and the UI at SDR white.
// BG3's blend attenuates the scene by the UI's coverage twice; that is kept,
// so composition matches BG3's.
//
// BG3's HDR display LUT compresses the scene's gamut to P3 (in a BT.2020
// container), so a P3 or wider screen shows every color it writes. For a
// screen that can't (sRGB), function constant 0 compresses P3 into sRGB:
// ACES 1.3's reference gamut compression (distance from the achromatic axis,
// threshold 0.8, power 1.2), with limits that put P3's boundary on sRGB's.
static const char BG3MFXImprovedDisplaySource[] = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct In { float4 position [[position]]; float2 texCoord; };
struct Combine { float UIPaperWhite, SDRGamma, HDRGamma, HDRPaperWhite; };

constant float SDRWhiteNits = 100.0;
constant bool CompressToSRGB [[function_constant(0)]];
constant bool compressToSRGB = is_function_constant_defined(CompressToSRGB) && CompressToSRGB;

static float3 pqToNits(float3 e) {
    float3 p = pow(abs(e), 1.0 / 78.84375);
    float3 n = max(p - 0.8359375, 0.0) / (18.8515625 - 18.6875 * p);
    return pow(n, 1.0 / 0.1593017578125) * 10000.0;
}
// The UI is sRGB-encoded BT.709; linear BT.2020 at SDR white.
static float3 uiLinear(float3 c) {
    float3 l = select(pow(abs(c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
    const float3x3 toBT2020 = float3x3(float3(0.6274040, 0.0690970, 0.0163916),
                                       float3(0.3292820, 0.9195400, 0.0880132),
                                       float3(0.0433136, 0.0113612, 0.8955950));
    return toBT2020 * l;
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
    const float3x3 toBT709 = float3x3(float3(1.660491, -0.124550, -0.018151),
                                      float3(-0.587641, 1.132900, -0.100579),
                                      float3(-0.072850, -0.008349, 1.118730));
    const float3x3 toBT2020 = float3x3(float3(0.627404, 0.069097, 0.016391),
                                       float3(0.329283, 0.919540, 0.088013),
                                       float3(0.043313, 0.011362, 0.895595));
    float3 c = toBT709 * bt2020;
    const float achromatic = max(c.r, max(c.g, c.b));
    if (achromatic <= 0.0) return float3(0.0);
    float3 d = (achromatic - c) / achromatic;
    d = float3(compressDistance(d.r, P3Limits.r), compressDistance(d.g, P3Limits.g), compressDistance(d.b, P3Limits.b));
    return toBT2020 * max(achromatic - d * achromatic, 0.0);
}

fragment float4 CombineUI_HDR(In in [[stage_in]], texture2d<float> Base [[texture(0)]], texture2d<float> Tex [[texture(1)]],
                              sampler LinearClampSampler [[sampler(0)]], constant Combine &combine [[buffer(0)]]) {
    float4 ui = Tex.sample(LinearClampSampler, in.texCoord);
    if (ui.a == 1.0) return float4(uiLinear(ui.rgb), 1.0);
    float3 scene = pqToNits(Base.read(uint2(in.position.xy)).rgb) / SDRWhiteNits;
    if (ui.a < 0.001) return float4(output(scene), 1.0);
    float keep = 1.0 - ui.a;
    return float4(output(scene * keep * keep + uiLinear(ui.rgb)), 1.0);
}

fragment float4 CombineUINo_UI_HDR(In in [[stage_in]], texture2d<float> Base [[texture(0)]], constant Combine &combine [[buffer(0)]]) {
    return float4(output(pqToNits(Base.read(uint2(in.position.xy)).rgb) / SDRWhiteNits), 1.0);
}
)METAL";

// What the drawable shows at 1.0 in nits, for the tone scale's peak.
inline constexpr float BG3MFXImprovedDisplayWhiteNits = 100.0f;
