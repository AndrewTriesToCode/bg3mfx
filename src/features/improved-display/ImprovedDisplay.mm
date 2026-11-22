#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <mach-o/dyld.h>
#include <objc/runtime.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <mutex>
#include "common/Feature.h"
#import "common/Notice.h"
#include "common/native/CodePatch.h"
#include "common/native/SupportedBuild.h"
#import "features/custom-menu/CustomMenu.h"
#import "features/metal-hooks/MetalHooks.h"
#include "features/improved-display/ImprovedDisplayShader.h"

// improved-display: replaces BG3's Windows-style HDR (PQ in absolute nits, a
// launcher toggle, Max Nits calibration) with macOS-style EDR. BG3 always
// renders its HDR path, whatever the launcher's HDR option says. bg3mfx shows
// it as extended-linear EDR, tone-mapped to the window's screen as it is now.
// That includes screens that aren't sold as HDR but report EDR headroom and
// P3 (Studio Display, MacBook Air).
//
// - LSMTLView is made with HDR requested whatever the launcher says, and its
//   layer is RGBA16Float, extended-linear BT.2020, with EDR on.
// - updateHDRState:, which BG3 calls each frame, keeps that and reports HDR on
//   in Improved HDR, so BG3's renderer takes its HDR path on every screen, and
//   off in Improved SDR, so it takes its own SDR path. It also reads the
//   screen's current EDR headroom (1.0 on an SDR screen).
// - BG3's HDR tone scale (ampas::init_TsParams with hdr set) gets a peak that
//   puts the image's peak at SDR white (100 nits) x that headroom instead of
//   the Max Nits setting.
// - BG3's composition pipelines (CombineUI_HDR, CombineUINo_UI_HDR, CombineUI,
//   CombineUI_NoUI) get bg3mfx's fragment functions, which write extended
//   linear in place of PQ or Display P3-tagged sRGB, and every pipeline drawing
//   to BG3's HDR drawable format (BGR10A2Unorm) draws to RGBA16Float.
// - BG3's HDR calibration skips its peak luminance page.
// - A Display Mode combo in Video options picks the look: Improved SDR (BG3's
//   SDR image in its own BT.709 colors, at SDR white) or Improved HDR (BG3's
//   HDR grading, peaking at the headroom). The choice is saved; until there
//   is one, screens with any potential headroom get Improved HDR and others
//   Improved SDR.
namespace Native = BG3MFXBuild::ImprovedDisplay;

namespace {
using InitTsParams = void (*)(void *out, int hdr, float minNits, float mid, float maxNits, float a, float b);
using RenderViewUpdate = void (*)(void *view, const void *time);
InitTsParams initTsParams;
RenderViewUpdate renderViewUpdate;

// The screen's EDR headroom the tone scale is built for, and a count of its
// changes. It follows the current headroom (read each frame on the render
// thread) once that differs by more than 1%, at most four times a second:
// macOS animates headroom through a brightness change, which would otherwise
// rebuild BG3's stage settings about 20 times a second.
std::atomic<float> toneHeadroom{1.0f};
std::atomic<unsigned> headroomGeneration{0};
// Whether the window's screen shows less than P3: the composition then binds
// its sRGB-compressing variant.
std::atomic<bool> compressToSRGB{false};
// Set once every part is in place; until then the tone scale is BG3's.
std::atomic<bool> active{false};

// The Display Mode combo's values, the player's saved choice (or none), and
// the look it resolves to. With no choice, the window's screen gets
// Improved HDR where its potential headroom (fixed per screen and preset,
// unlike the current headroom) is above 1: XDR screens, and others that
// report headroom at lower brightness.
enum Mode : int { None = -1, SDR = 0, HDR = 1 };
constexpr uint16_t modeID = 0x7f10, refreshRateID = 0x50, maxNitsID = 0x55;
constexpr float hdrPotentialHeadroom = 1.01f;
NSString *const modePreference = @"BG3MFXDisplayModeChoice";
std::atomic<int> modeChoice{None};
std::atomic<float> potentialHeadroom{1.0f};
std::atomic<bool> hdrLook{false};

// Improved HDR: BG3's HDR tone scale with SDR's mid grey, peaking at the
// screen's headroom.
//
// BG3's HDR display LUT draws 200 x (t(x) / 200)^contrast x paper white / 100,
// clamped at 1.2 x maxNits, where t is the tone scale for (minNits, mid,
// maxNits). BG3 passes mid grey 20, so mid grey and shadows come out about
// twice as bright as SDR. This passes mid = 200 x (8 / 200)^(1 / contrast):
// at contrast 1, mid 8 gives SDR's image from the shadows to mid grey (within
// 3%; BG3's HDR curve is shaped differently from its SDR one, which passes
// 10), and the power keeps mid grey there whatever the contrast, down to a
// mid of 3 nits (contrast about 0.77): below that BG3's tone scale shifts
// hues (yellows toward red, blues toward purple), so lower contrasts keep
// mid 3 and brighten mid grey instead. Paper white
// scales it (100 matches SDR); contrast and the headroom spread shadows and
// highlights around it.
//
// maxNits puts the peak at SDR white x headroom. When no maxNits reaches that
// without the LUT's clamp (a peak below about 236 nits at contrast 1, or high
// contrast or paper white), the LUT peaks within 1.5x the target instead and
// the composition rolls the highlights off into the headroom.
//
// The LUT's peak before its clamp, in nits at paper white 100, for these
// maxNits and contrasts (with the mid grey above; measured on BG3's LUT
// outside the game). Contrast also shapes the tone scale itself (it is
// init_TsParams' last argument), so the table has both.
constexpr int toneCount = 16, contrastCount = 5;
constexpr float toneMax[toneCount] = {50, 75, 100, 150, 200, 300, 400, 600, 800, 1200, 1600, 2400, 3200, 4800, 6400, 10000};
constexpr float toneContrast[contrastCount] = {0.5f, 0.75f, 1.0f, 1.25f, 1.5f};
constexpr float tonePeak[contrastCount][toneCount] = {
    {126.3f, 151.7f, 172.7f, 207.1f, 235.5f, 325.7f, 425.0f, 584.3f, 724.0f, 967.4f, 1179.6f, 1545.8f, 1849.5f, 2331.5f, 2711.6f, 3359.5f},
    {92.6f, 121.9f, 148.1f, 194.4f, 235.7f, 330.6f, 425.3f, 584.3f, 724.0f, 967.4f, 1179.6f, 1545.8f, 1849.5f, 2331.5f, 2711.6f, 3359.5f},
    {67.9f, 98.0f, 126.9f, 182.5f, 235.9f, 337.9f, 435.0f, 609.7f, 765.3f, 1039.3f, 1279.9f, 1698.7f, 2063.1f, 2689.6f, 3206.0f, 4115.7f},
    {49.8f, 78.7f, 108.8f, 171.4f, 236.1f, 370.1f, 508.2f, 789.2f, 1061.8f, 1580.3f, 2070.0f, 2983.3f, 3831.0f, 5273.4f, 6512.6f, 8886.4f},
    {36.5f, 63.3f, 93.3f, 160.9f, 236.4f, 405.3f, 592.9f, 990.6f, 1341.0f, 2031.0f, 2831.2f, 4435.0f, 6025.7f, 9148.0f, 12189.8f, 18776.6f}};
// Interpolated in log maxNits and linear contrast; paper white scales it.
float lutPeak(float maxNits, float contrast, float paperWhite) {
    maxNits = std::fmin(std::fmax(maxNits, toneMax[0]), toneMax[toneCount - 1]);
    int i = 0;
    while (i < toneCount - 2 && maxNits > toneMax[i + 1]) ++i;
    const float u = std::log(maxNits / toneMax[i]) / std::log(toneMax[i + 1] / toneMax[i]);
    contrast = std::fmin(std::fmax(contrast, toneContrast[0]), toneContrast[contrastCount - 1]);
    int j = 0;
    while (j < contrastCount - 2 && contrast > toneContrast[j + 1]) ++j;
    const float v = (contrast - toneContrast[j]) / (toneContrast[j + 1] - toneContrast[j]);
    auto at = [&](int row) { return std::log(tonePeak[row][i]) + u * std::log(tonePeak[row][i + 1] / tonePeak[row][i]); };
    return std::exp(at(j) + v * (at(j + 1) - at(j))) * paperWhite / 100.0f;
}
// BG3's GraphicSettings pointer.
uintptr_t settingsGlobal;
// The headroom the composition rolls highlights off into, or 0.
std::atomic<float> rolloffHeadroom{0.0f};
constexpr float minimumMid = 3.0f;
struct HDRTone { float mid, maxNits; };
HDRTone hdrTone(float contrast) {
    const float g = contrast > 0.1f ? contrast : 1.0f;
    void *settings = settingsGlobal ? *reinterpret_cast<void **>(settingsGlobal) : nullptr;
    float paperWhite = settings ? *reinterpret_cast<const float *>(static_cast<const uint8_t *>(settings) + Native::Layout::SettingsPaperWhite) : 100.0f;
    if (!(paperWhite >= 10.0f && paperWhite <= 1000.0f)) paperWhite = 100.0f;
    const float mid = std::fmax(200.0f * std::pow(8.0f / 200.0f, 1.0f / g), minimumMid);
    const float headroom = toneHeadroom.load(std::memory_order_relaxed);
    const float target = BG3MFXImprovedDisplayWhiteNits * headroom;
    // The LUT's peak rises with maxNits: bisect in log maxNits for the target.
    auto solve = [&](auto above) {
        float lo = std::log(toneMax[0]), hi = std::log(toneMax[toneCount - 1]);
        for (int k = 0; k < 40; ++k) {
            const float m = 0.5f * (lo + hi);
            (above(std::exp(m)) ? hi : lo) = m;
        }
        return std::exp(hi);
    };
    const float maxNits = solve([&](float m) { return lutPeak(m, g, paperWhite) >= target; });
    auto clamped = [&](float m) { return lutPeak(m, g, paperWhite) > 1.2f * m * 0.98f; };
    if (!clamped(maxNits)) {
        rolloffHeadroom.store(0.0f, std::memory_order_relaxed);
        return {mid, maxNits};
    }
    // The highlights roll off into the headroom from the smallest maxNits the
    // clamp leaves alone, if it peaks within 1.5x the target, or else from the
    // clamp at 1.5x the target.
    const float unclamped = solve([&](float m) { return !clamped(m); });
    const bool natural = !clamped(unclamped) && lutPeak(unclamped, g, paperWhite) <= 1.5f * target;
    rolloffHeadroom.store(headroom, std::memory_order_relaxed);
    return {mid, natural ? unclamped : 1.5f * target / 1.2f};
}
// Resolves the look. BG3 switches between its HDR and SDR paths on the next
// frame; a change also rebuilds the display LUT as a headroom change does.
void resolveMode() {
    const int choice = modeChoice.load(std::memory_order_relaxed);
    const bool hdr = choice == None ? potentialHeadroom.load(std::memory_order_relaxed) >= hdrPotentialHeadroom : choice == HDR;
    if (hdrLook.exchange(hdr, std::memory_order_relaxed) != hdr) headroomGeneration.fetch_add(1, std::memory_order_release);
}
void observeHeadroom(float current) {
    if (!(current >= 1.0f)) current = 1.0f;
    const float tone = toneHeadroom.load(std::memory_order_relaxed);
    if (std::fabs(current - tone) <= 0.01f * tone) return;
    static std::chrono::steady_clock::time_point last;
    const auto now = std::chrono::steady_clock::now();
    if (now - last < std::chrono::milliseconds(250)) return;
    last = now;
    toneHeadroom.store(current, std::memory_order_relaxed);
    headroomGeneration.fetch_add(1, std::memory_order_release);
}
// BG3 rebuilds its display LUT only when a render view's stages see a state
// change (settings, level loads). A headroom change sets each render view's
// state-changed flag once, before its Update reads it.
struct ViewGeneration { void *view; unsigned generation; };
ViewGeneration viewGenerations[8];
std::mutex viewLock;
void renderViewUpdateHook(void *view, const void *time) {
    if (active.load(std::memory_order_relaxed)) {
        const unsigned generation = headroomGeneration.load(std::memory_order_acquire);
        std::lock_guard<std::mutex> hold(viewLock);
        ViewGeneration *slot = nullptr;
        for (auto &entry : viewGenerations) if (entry.view == view) { slot = &entry; break; }
        if (!slot) {
            // A view seen for the first time builds its tone scale with the
            // current headroom anyway. Views beyond eight (none seen) refresh
            // only on BG3's own state changes.
            for (auto &entry : viewGenerations) if (!entry.view) { entry = {view, generation}; break; }
        } else if (slot->generation != generation) {
            slot->generation = generation;
            static_cast<uint8_t *>(view)[BG3MFXBuild::ImprovedDisplay::Layout::RenderViewStateChanged] = 1;
        }
    }
    renderViewUpdate(view, time);
}
void initTsParamsHook(void *out, int hdr, float minNits, float mid, float maxNits, float a, float b) {
    if (hdr && active.load(std::memory_order_relaxed)) {
        const HDRTone tone = hdrTone(b);
        mid = tone.mid;
        maxNits = tone.maxNits;
    }
    initTsParams(out, hdr, minNits, mid, maxNits, a, b);
}

CGColorSpaceRef outputSpace() {
    static CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearITUR_2020);
    return space;
}
Ivar metalLayerIvar;
CAMetalLayer *metalLayer(id view) {
    id layer = metalLayerIvar ? object_getIvar(view, metalLayerIvar) : nil;
    return [layer isKindOfClass:CAMetalLayer.class] ? layer : nil;
}
void configure(CAMetalLayer *layer) {
    if (!layer) return;
    if (layer.pixelFormat != MTLPixelFormatRGBA16Float) layer.pixelFormat = MTLPixelFormatRGBA16Float;
    if (!layer.wantsExtendedDynamicRangeContent) layer.wantsExtendedDynamicRangeContent = YES;
    if (layer.colorspace != outputSpace()) layer.colorspace = outputSpace();
}

using InitView = id (*)(id, SEL, CGRect, id, int, BOOL, BOOL);
InitView originalInitView;
id initViewHook(id self, SEL cmd, CGRect frame, id device, int display, BOOL, BOOL vsync) {
    id view = originalInitView(self, cmd, frame, device, display, YES, vsync);
    if (view) configure(metalLayer(view));
    return view;
}
// BG3's reads the screen's potential headroom and sets PQ (or Display P3 and
// EDR off). This keeps bg3mfx's output and reports the mode's path.
BOOL updateHDRStateHook(id self, SEL, BOOL) {
    configure(metalLayer(self));
    NSScreen *screen = [self window].screen;
    if (screen) {
        observeHeadroom((float)screen.maximumExtendedDynamicRangeColorComponentValue);
        potentialHeadroom.store((float)screen.maximumPotentialExtendedDynamicRangeColorComponentValue, std::memory_order_relaxed);
        resolveMode();
        compressToSRGB.store(![screen canRepresentDisplayGamut:NSDisplayGamutP3], std::memory_order_relaxed);
    }
    return hdrLook.load(std::memory_order_relaxed);
}

// LSMTLView's own method, with the supported signature.
bool supportedMethod(Class cls, SEL selector, const char *types) {
    unsigned count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    bool found = false;
    for (unsigned i = 0; i < count && !found; ++i)
        found = method_getName(methods[i]) == selector && !strcmp(method_getTypeEncoding(methods[i]), types);
    free(methods);
    return found;
}

// Composition functions, compiled once per device.
std::mutex libraryLock;
id<MTLDevice> libraryDevice;
id<MTLLibrary> library;
bool libraryFailed;
char replacementKey;
id<MTLFunction> replacementFunction(id<MTLDevice> device, NSString *name, bool srgb, float rolloff = 0.0f) {
    std::lock_guard<std::mutex> hold(libraryLock);
    if (device != libraryDevice) {
        libraryDevice = device;
        NSError *error = nil;
        library = [device newLibraryWithSource:@(BG3MFXImprovedDisplaySource) options:nil error:&error];
        if (!library && !libraryFailed) {
            libraryFailed = true;
            BG3MFXFail([@"Improved Display could not compile its composition shader: " stringByAppendingString:error.localizedDescription ?: @"unknown error"],
                       nil, nil);
        }
    }
    MTLFunctionConstantValues *constants = [MTLFunctionConstantValues new];
    [constants setConstantValue:&srgb type:MTLDataTypeBool atIndex:0];
    [constants setConstantValue:&rolloff type:MTLDataTypeFloat atIndex:1];
    id<MTLFunction> function = library ? [library newFunctionWithName:name constantValues:constants error:nullptr] : nil;
    // Marked as bg3mfx's: a specialized function lists no function constants.
    if (function) objc_setAssociatedObject(function, &replacementKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return function;
}
bool hdrComposition(NSString *name) {
    return [name isEqualToString:@"CombineUI_HDR"] || [name isEqualToString:@"CombineUINo_UI_HDR"];
}
bool compositionFunction(NSString *name) {
    return hdrComposition(name) || [name isEqualToString:@"CombineUI"] || [name isEqualToString:@"CombineUI_NoUI"];
}
MTLRenderPipelineDescriptor *filterPipeline(id device, MTLRenderPipelineDescriptor *desc) {
    NSString *fragment = desc.fragmentFunction.name;
    bool drawable = false;
    for (NSUInteger i = 0; i < 8 && !drawable; ++i) drawable = desc.colorAttachments[i].pixelFormat == MTLPixelFormatBGR10A2Unorm;
    // BG3 builds its drawable's pipelines (the compositions and the soft
    // cursor) for BGR10A2Unorm or BGRA8Unorm, whichever path it started on.
    // It also draws CombineUI and CombineUI_HDR into 8-bit offscreen targets
    // (RGBA8Unorm), which keep BG3's pipeline.
    const MTLPixelFormat target = desc.colorAttachments[0].pixelFormat;
    const bool onDrawable = target == MTLPixelFormatBGR10A2Unorm || target == MTLPixelFormatBGRA8Unorm;
    const bool composition = compositionFunction(fragment) && onDrawable;
    const bool cursor = [fragment isEqualToString:@"SoftCursorPS"] && onDrawable;
    if (!composition && !cursor && !drawable) return desc;
    MTLRenderPipelineDescriptor *changed = [desc copy];
    for (NSUInteger i = 0; i < 8; ++i)
        if (changed.colorAttachments[i].pixelFormat == MTLPixelFormatBGR10A2Unorm)
            changed.colorAttachments[i].pixelFormat = MTLPixelFormatRGBA16Float;
    if (composition || cursor) changed.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
    if (composition) {
        if (id<MTLFunction> function = replacementFunction(device, fragment, false)) changed.fragmentFunction = function;
    }
    return changed;
}

// Each HDR composition pipeline (already bg3mfx's function, from
// filterPipeline) gets a variant for every other combination of sRGB
// compression (for screens that can't show P3) and highlight roll-off (at each
// headroom step), bound in its place while the screen and tone scale need it.
// BG3's SDR image is BT.709 already.
char variantsKey;
constexpr int looks = BG3MFXImprovedDisplayRolloffSteps + 1, variantCount = 2 * looks;
int rolloffStep() {
    const float headroom = rolloffHeadroom.load(std::memory_order_relaxed);
    if (!(headroom > 0.0f)) return -1;
    int step = 0;
    while (step + 1 < BG3MFXImprovedDisplayRolloffSteps && BG3MFXImprovedDisplayRolloffHeadroom[step + 1] <= headroom * 1.001f) ++step;
    return step;
}
bool claimComposition(id device, MTLRenderPipelineDescriptor *desc, id state, BG3MFXCreateRenderPipeline create) {
    NSString *fragment = desc.fragmentFunction.name;
    if (!hdrComposition(fragment) || !objc_getAssociatedObject(desc.fragmentFunction, &replacementKey)) return false;
    NSMutableArray *variants = [NSMutableArray arrayWithCapacity:variantCount];
    for (int srgb = 0; srgb < 2; ++srgb)
        for (int look = 0; look < looks; ++look) {
            if (!srgb && !look) {
                [variants addObject:NSNull.null];
                continue;
            }
            MTLRenderPipelineDescriptor *variant = [desc copy];
            const float rolloff = look ? BG3MFXImprovedDisplayRolloffHeadroom[look - 1] : 0.0f;
            variant.fragmentFunction = replacementFunction(device, fragment, srgb, rolloff);
            NSError *error = nil;
            id pipeline = variant.fragmentFunction ? (__bridge_transfer id)create(device, @selector(newRenderPipelineStateWithDescriptor:error:), variant, &error) : nil;
            if (!pipeline) {
                static std::atomic<bool> reported{false};
                if (!reported.exchange(true))
                    BG3MFXFail([@"Improved Display could not build its composition variants; Improved HDR clips highlights at low headroom and P3 colors on sRGB screens: " stringByAppendingString:error.localizedDescription ?: @"unknown error"],
                               nil, nil);
                return false;
            }
            [variants addObject:pipeline];
        }
    objc_setAssociatedObject(state, &variantsKey, variants, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return true;
}
id substituteComposition(__unsafe_unretained id state) {
    const bool srgb = compressToSRGB.load(std::memory_order_relaxed);
    const int step = rolloffStep();
    if (!srgb && step < 0) return state;
    NSArray *variants = objc_getAssociatedObject(state, &variantsKey);
    id variant = variants.count == variantCount ? variants[(srgb ? looks : 0) + step + 1] : nil;
    return variant && variant != NSNull.null ? variant : state;
}

// The Display Mode combo, below Refresh Rate in Video options. It applies on
// selection; BG3's ApplyCombo does not see it.
struct ModeText { const char *handle, *literal; };
void modeChanged(void *, const void *item) {
    if (!item || BG3MFXMenuItemID(const_cast<void *>(item)) != modeID) return;
    const int value = BG3MFXMenuComboSelection(item);
    if (value != SDR && value != HDR) return;
    modeChoice.store(value, std::memory_order_relaxed);
    [NSUserDefaults.standardUserDefaults setInteger:value forKey:modePreference];
    resolveMode();
}
void modeApply(void *manager, const void *item, BG3MFXMenuApply next) {
    if (item && BG3MFXMenuItemID(const_cast<void *>(item)) == modeID) return;
    next(manager, item);
}
bool makeTexts(BG3MFXMenuText &name, BG3MFXMenuText &description, ModeText n, ModeText d) {
    if (BG3MFXMenuMakeText(name, n.handle, n.literal) && BG3MFXMenuMakeText(description, d.handle, d.literal)) return true;
    BG3MFXMenuDestroyText(name); BG3MFXMenuDestroyText(description);
    return false;
}
void menuBuilt(void *manager) {
    // BG3 builds the page for the frame's HDR flag (updateHDRState:): Gamma
    // calibration in SDR, HDR sliders and calibration in HDR. Its Max Nits
    // slider (100 to 4000) has no effect: the tone scale's peak is the headroom.
    if (void *maxNits = BG3MFXMenuFind(manager, -1, maxNitsID)) BG3MFXMenuSetEnabled(maxNits, false);
    BG3MFXMenuText name, description;
    if (!makeTexts(name, description, {"h00000000g0000g0000g0000g00000000f020", "Display Mode"},
                   {"h00000000g0000g0000g0000g00000000f021",
                    "Picks SDR or HDR output. Until you pick, HDR screens use HDR. "
                    "Calibration options update when Options is reopened."})) {
        BG3MFXMenuProblem(@"Could not register the Display Mode text.");
        return;
    }
    void *combo = BG3MFXMenuAddCombo(manager, modeID, name, description, modeChanged);
    BG3MFXMenuDestroyText(name); BG3MFXMenuDestroyText(description);
    if (!combo) {
        BG3MFXMenuProblem(@"Could not add the Display Mode option.");
        return;
    }
    const ModeText items[2][2] = {
        {{"h00000000g0000g0000g0000g00000000f024", "Improved SDR"},
         {"h00000000g0000g0000g0000g00000000f025", "The game's SDR image, with accurate color and smooth gradients."}},
        {{"h00000000g0000g0000g0000g00000000f026", "Improved HDR"},
         {"h00000000g0000g0000g0000g00000000f027", "The game's HDR image, using the screen's full brightness."}}};
    for (int value = SDR; value <= HDR; ++value) {
        if (!makeTexts(name, description, items[value][0], items[value][1])) {
            BG3MFXMenuProblem(@"Could not register the Display Mode text.");
            return;
        }
        BG3MFXMenuAppendComboValue(combo, value, name, description);
        BG3MFXMenuDestroyText(name); BG3MFXMenuDestroyText(description);
    }
    BG3MFXMenuComboItemsChanged(combo);
    BG3MFXMenuShowComboSelection(combo, hdrLook.load(std::memory_order_relaxed) ? HDR : SDR);
    // Right below Refresh Rate (combo 0x50); last if it is missing.
    const size_t count = BG3MFXMenuItemCount(manager);
    if (count && BG3MFXMenuItem(manager, count - 1) == combo)
        for (size_t i = 0; i + 1 < count; ++i)
            if (BG3MFXMenuItemID(BG3MFXMenuItem(manager, i)) == refreshRateID) {
                BG3MFXMenuMoveLast(manager, i + 1);
                break;
            }
}

BOOL installImprovedDisplay(const BG3MFXFeatureContext &context, NSError **error) {
    auto fail = [&](NSString *message) {
        if (error) *error = [NSError errorWithDomain:@"BG3MFXImprovedDisplay" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
        return NO;
    };
    Class view = NSClassFromString(@"LSMTLView");
    metalLayerIvar = view ? class_getInstanceVariable(view, "metalLayer") : nullptr;
    if (!metalLayerIvar || strcmp(ivar_getTypeEncoding(metalLayerIvar), "@\"CAMetalLayer\""))
        return fail(@"BG3's render view has no Metal layer where Improved Display expects it.");
    const SEL initSelector = sel_registerName("initWithFrame:device:display:hdr:vsync:"), stateSelector = sel_registerName("updateHDRState:");
    const char *initTypes = "@68@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16@48i56B60B64", *stateTypes = "B20@0:8B16";
    if (!supportedMethod(view, initSelector, initTypes) || !supportedMethod(view, stateSelector, stateTypes))
        return fail(@"BG3's render view methods are not the supported ones.");
    const intptr_t slide = context.slide;
    settingsGlobal = BG3MFXBuild::Temporal::Settings + slide;
    // The calibration opens on paper white and contrast: its peak luminance
    // page sets a Max Nits the tone scale no longer uses.
    const uintptr_t firstPhase = Native::CalibrationFirstPhase + slide;
    if (*reinterpret_cast<const uint32_t *>(firstPhase) != Native::CalibrationFirstPhaseOriginal)
        return fail(@"BG3's HDR calibration is not the supported one.");
    if (BG3MFXPatchCode({{firstPhase, 4}}, [&] {
            *reinterpret_cast<uint32_t *>(firstPhase) = Native::CalibrationFirstPhasePatched;
        }) == BG3MFXCodePatchResult::NotWritable)
        return fail(@"Could not make BG3's HDR calibration writable.");
    const uintptr_t islands = BG3MFXBuild::HeaderPadding + slide + BG3MFXBuild::Islands::ImprovedDisplay.offset;
    const uintptr_t tsIsland = islands, updateIsland = islands + BG3MFXEntryIslandBytes;
    initTsParams = reinterpret_cast<InitTsParams>(tsIsland + BG3MFXEntryOriginalOffset);
    renderViewUpdate = reinterpret_cast<RenderViewUpdate>(updateIsland + BG3MFXEntryOriginalOffset);
    // The hooks pass BG3's values through until `active`.
    if (const char *failure = BG3MFXHookEntry(Native::InitTsParams + slide, Native::InitTsParamsFirst, tsIsland,
                                              reinterpret_cast<void *>(initTsParamsHook)))
        return fail([NSString stringWithFormat:@"Could not hook BG3's tone scale: %s.", failure]);
    if (const char *failure = BG3MFXHookEntry(Native::RenderViewUpdate + slide, Native::RenderViewUpdateFirst,
                                              updateIsland, reinterpret_cast<void *>(renderViewUpdateHook)))
        return fail([NSString stringWithFormat:@"Could not hook BG3's render view update: %s.", failure]);
    if (!BG3MFXMetalHooksFilterRenderPipeline(filterPipeline) ||
        !BG3MFXMetalHooksSubstitutePipelines({claimComposition, substituteComposition}))
        return fail(@"Could not register Improved Display's pipeline hooks.");
    originalInitView = reinterpret_cast<InitView>(class_replaceMethod(view, initSelector, (IMP)initViewHook, initTypes));
    class_replaceMethod(view, stateSelector, (IMP)updateHDRStateHook, stateTypes);
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:modePreference];
    const int choice = saved ? (int)[saved integerValue] : None;
    modeChoice.store(choice == SDR || choice == HDR ? choice : None);
    BG3MFXMenuOnBuilt(menuBuilt);
    BG3MFXMenuWrapApplyCombo(modeApply);
    active.store(true);
    return YES;
}

const char *const requires[] = {"metal-hooks", "custom-menu", nullptr};
}
BG3MFX_FEATURE(improvedDisplay, {"improved-display", requires, true, installImprovedDisplay, nullptr});
