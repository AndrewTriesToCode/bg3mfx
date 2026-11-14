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
// - updateHDRState:, which BG3 calls each frame, keeps that and reports HDR on,
//   so BG3's renderer takes its HDR path on every screen. It also reads the
//   screen's current EDR headroom (1.0 on an SDR screen).
// - BG3's HDR tone scale (ampas::init_TsParams with hdr set) gets a peak of
//   SDR white (100 nits) x that headroom instead of the Max Nits setting.
// - BG3's composition pipelines (CombineUI_HDR, CombineUINo_UI_HDR) get
//   bg3mfx's fragment functions, which write extended linear in place of PQ,
//   and every pipeline drawing to BG3's HDR drawable format (BGR10A2Unorm)
//   draws to RGBA16Float.
// - BG3's HDR calibration skips its peak luminance page.
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

float peakNits() {
    return std::fmin(BG3MFXImprovedDisplayWhiteNits * toneHeadroom.load(std::memory_order_relaxed), 10000.0f);
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
    if (hdr && active.load(std::memory_order_relaxed)) maxNits = peakNits();
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
// EDR off). This keeps bg3mfx's output and always reports HDR on.
BOOL updateHDRStateHook(id self, SEL, BOOL) {
    configure(metalLayer(self));
    NSScreen *screen = [self window].screen;
    if (screen) {
        observeHeadroom((float)screen.maximumExtendedDynamicRangeColorComponentValue);
        compressToSRGB.store(![screen canRepresentDisplayGamut:NSDisplayGamutP3], std::memory_order_relaxed);
    }
    return YES;
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
id<MTLFunction> replacementFunction(id<MTLDevice> device, NSString *name, bool srgb) {
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
    return library ? [library newFunctionWithName:name constantValues:constants error:nullptr] : nil;
}
bool compositionFunction(NSString *name) {
    return [name isEqualToString:@"CombineUI_HDR"] || [name isEqualToString:@"CombineUINo_UI_HDR"];
}
MTLRenderPipelineDescriptor *filterPipeline(id device, MTLRenderPipelineDescriptor *desc) {
    NSString *fragment = desc.fragmentFunction.name;
    bool composition = compositionFunction(fragment), drawable = false;
    for (NSUInteger i = 0; i < 8 && !drawable; ++i) drawable = desc.colorAttachments[i].pixelFormat == MTLPixelFormatBGR10A2Unorm;
    if (!composition && !drawable) return desc;
    MTLRenderPipelineDescriptor *changed = [desc copy];
    for (NSUInteger i = 0; i < 8; ++i)
        if (changed.colorAttachments[i].pixelFormat == MTLPixelFormatBGR10A2Unorm)
            changed.colorAttachments[i].pixelFormat = MTLPixelFormatRGBA16Float;
    if (composition) {
        changed.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
        if (id<MTLFunction> function = replacementFunction(device, fragment, false)) changed.fragmentFunction = function;
    }
    return changed;
}

// Each composition pipeline (already bg3mfx's function, from filterPipeline)
// gets its sRGB variant, bound in its place while the screen needs it.
char srgbVariantKey;
bool claimComposition(id device, MTLRenderPipelineDescriptor *desc, id state, BG3MFXCreateRenderPipeline create) {
    NSString *fragment = desc.fragmentFunction.name;
    if (!compositionFunction(fragment) || desc.fragmentFunction.functionConstantsDictionary.count == 0) return false;
    MTLRenderPipelineDescriptor *variant = [desc copy];
    variant.fragmentFunction = replacementFunction(device, fragment, true);
    NSError *error = nil;
    id pipeline = variant.fragmentFunction ? (__bridge_transfer id)create(device, @selector(newRenderPipelineStateWithDescriptor:error:), variant, &error) : nil;
    if (!pipeline) {
        static std::atomic<bool> reported{false};
        if (!reported.exchange(true))
            BG3MFXFail([@"Improved Display could not build its sRGB composition; sRGB screens clip P3 colors: " stringByAppendingString:error.localizedDescription ?: @"unknown error"],
                       nil, nil);
        return false;
    }
    objc_setAssociatedObject(state, &srgbVariantKey, pipeline, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return true;
}
id substituteComposition(__unsafe_unretained id state) {
    if (!compressToSRGB.load(std::memory_order_relaxed)) return state;
    id variant = objc_getAssociatedObject(state, &srgbVariantKey);
    return variant ?: state;
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
    active.store(true);
    return YES;
}

const char *const requires[] = {"metal-hooks", nullptr};
}
BG3MFX_FEATURE(improvedDisplay, {"improved-display", requires, true, installImprovedDisplay, nullptr});
