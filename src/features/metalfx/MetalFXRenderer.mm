#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#include <atomic>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <vector>
#include "common/Feature.h"
#import "common/EventLog.h"
#import "common/Notice.h"
#import "common/gpu/GPUResources.h"
#import "common/gpu/MetalFXPipeline.h"
#import "features/metalfx/MetalFX.h"
#import "features/metalfx/dynamic-resolution/DynamicResolution.h"
#import "features/metalfx/frame-generation/FrameInterpolation.h"
#import "features/metalfx/frame-generation/FrameLog.h"
#import "features/metalfx/spatial-upscaling/SpatialUpscaler.h"
#import "features/metalfx/temporal-upscaling/TemporalUpscaler.h"
#import "features/metal-hooks/MetalHooksInternal.h"

// metalfx's renderer work, as metal-hooks' renderer extension
// (MetalHooksInternal.h): the MetalFX Spatial and Temporal scaler dispatch
// that replaces BG3's FSR, the scene tracking that feeds them, Frame
// Generation's composition and presentation, Dynamic resolution's renderer
// corrections and the FSR_Tonemap skip.

using namespace metalhooks;

namespace {
#ifndef BG3MFX_NO_TRACE
// Events the diagnostic log keeps even when it samples.
void record(NSDictionary *event) {
    NSString *kind = event[@"event"];
    BOOL important = [kind isEqualToString:@"nativeMenuTemporalMismatch"] ||
        [kind isEqualToString:@"temporalValidationProgress"] || [kind isEqualToString:@"temporalScalerCreated"] || [kind hasPrefix:@"frameGeneration"] ||
        [kind isEqualToString:@"upscalingFallback"] ||
        [kind isEqualToString:@"viewportReductionPass"] || [kind hasPrefix:@"dynamicResolution"] || [kind isEqualToString:@"surfaceDebugFragment"] ||
        [kind isEqualToString:@"surfaceGrid"] || [kind isEqualToString:@"subsurfaceScale"] ||
        [kind isEqualToString:@"stencilDump"] || [kind isEqualToString:@"spatialUpscaleError"] ||
        [kind isEqualToString:@"temporalUpscaleError"];
    BG3MFXEventLogWrite(event, important);
}
// Diagnostic settings that hot paths check, read once.
const char *stencilDumpDirectory() { static const char *value = getenv("BG3MFX_STENCIL_DUMP_DIR"); return value; }
bool traceTemporalChain() { static const bool value = getenv("BG3MFX_TRACE_TEMPORAL_CHAIN"); return value; }
#endif
// Pipelines whose draws this renderer inspects (BG3MFXPipelineInfo::kind).
enum PipelineKind : uint8_t {
    PipelineOther, PipelineTAA, PipelineLinearizeDepth, PipelineVelocity,
    PipelinePostColor, PipelineToneMapLUT, PipelineCombineUI, PipelineSceneOverlay,
};
// BG3MFXPipelineInfo::rendererFlags: Dynamic resolution corrections (see
// SurfaceGridDraw and SubsurfaceDraw).
enum : uint8_t { FlagSurfaceGrid = 1, FlagSubsurface = 2 };
// Associated objects this renderer sets on an encoder.
enum : uint16_t {
    AssocTAAInputs = AssocRenderer, AssocFSRInputs = AssocRenderer << 1, AssocComposition = AssocRenderer << 2,
    AssocPostprocess = AssocRenderer << 3, AssocSuppressed = AssocRenderer << 4,
};
// The scene's camera (11), temporal (8) and viewport (9) constants, and the
// composition's vertices and constants (0).
constexpr uint32_t ConstantSlots = 1u << 0 | 1u << 8 | 1u << 9 | 1u << 11;
// Dynamic resolution: the vertex EngineParams (index 21) surface grid draws read.
constexpr NSUInteger SurfaceEngineIndex = 21;
// BG3MFX_SCENE_PROBE=1 (diagnostic runtime): run both scalers once on a
// captured scene without displaying the result.
BOOL sceneProbe;
char bufferScalingModeKey;
char frameGenerationModeKey, compositorSizeKey, frameCompositionKey, generatedPairKey;
thread_local bool encodingFrameGeneration=false;
char deferredPresentKey;
#ifndef BG3MFX_NO_TRACE
std::atomic<unsigned> deferredPresents{0}, pairedPresents{0}, replayedPresents{0};
#endif
// MetalFX reads FSR_Tonemap's input, so with a MetalFX upscaler selected that
// pass only feeds native FSR: skip its draw and recreate its output only on a
// frame that falls back to native FSR (suppressFSRTonemap, restoreSkippedTonemap).
bool skipFSRTonemap;
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
std::atomic<unsigned> fsrTonemapStoresDropped{0};
#endif
void setEncoderMode(id encoder, NSNumber *mode) {
    if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder)) s->mode=mode ? mode.intValue : -1;
}
int encoderScalingMode(__unsafe_unretained id encoder) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    return s && s->mode>=0 ? s->mode : BG3MFXSelectedScalingMode();
}
}
static bool frameGeneration(id buffer) { return [objc_getAssociatedObject(buffer,&frameGenerationModeKey) boolValue]; }
// Scene color, depth, motion and camera are associated with BG3's TAA output and
// followed through post-processing: for MetalFX Spatial and Temporal, and for
// every Upscaling Type while Frame Generation needs them at the composition.
static bool sceneTracked(int mode, id buffer) { return mode == 2 || mode == 3 || (buffer && frameGeneration(buffer)); }
// BG3 composes scene and UI with CombineUI, or CombineUI_HDR when HDR output
// is enabled; both take the same scene, UI, constants and sampler bindings.
static BOOL compositionShader(NSString *fragment) {
    return [fragment isEqualToString:@"CombineUI"] || [fragment isEqualToString:@"CombineUI_HDR"];
}
// BG3's UI model VFX alpha-blend a 3D effect straight onto the final scene image.
static BOOL sceneOverlayShader(NSString *fragment) { return [fragment hasPrefix:@"Shared_UI_VFX_UI_Model_"]; }
// BG3 grades colors in place on the TAA output when bloom is off (the read is the TAA input).
static BOOL colorGradingShader(NSString *fragment) { return [fragment isEqualToString:@"PPColorGradingApplyLUTPS"]; }
// Passes that rewrite a tagged scene image in place, keeping its frame inputs.
static BOOL inPlaceScenePass(NSString *fragment) { return colorGradingShader(fragment) || sceneOverlayShader(fragment); }
static PipelineKind classifyPipeline(NSString *fragment) {
    if ([fragment isEqualToString:@"PPTAA_PS"]) return PipelineTAA;
    if ([fragment isEqualToString:@"LinearizeDepth"]) return PipelineLinearizeDepth;
    if ([fragment isEqualToString:@"VelocityBufferCamera_PS"]) return PipelineVelocity;
    if ([fragment isEqualToString:@"PPToneMap_LUT"]) return PipelineToneMapLUT;
    if (compositionShader(fragment)) return PipelineCombineUI;
    if ([fragment isEqualToString:@"PPBloomUpsampleBlurAndCombine_PS"] || [fragment isEqualToString:@"PPColorGradingApplyLUTPS"] ||
        [fragment isEqualToString:@"EoCOutlineCombinePS"] || [fragment isEqualToString:@"EoCSight"] || [fragment isEqualToString:@"FSR_Tonemap"]) return PipelinePostColor;
    if (sceneOverlayShader(fragment)) return PipelineSceneOverlay;
    return PipelineOther;
}
static NSUInteger sceneProbeAttempts;
static char deviceDepthKey, sceneCaptureFailureKey, sceneCameraKey, taaInputsKey;
static char fsrInputsKey, nativeFallbackKey;
// A frame whose FSR input matches no captured scene (loading, view or size
// transitions) runs BG3's native FSR instead of closing the game. Temporal
// history restarts on the next MetalFX frame.
static std::atomic<bool> temporalResetPending{false};
static void fallBackToNative(id encoder, BOOL temporal, NSString *reason) {
    objc_setAssociatedObject(encoder,&nativeFallbackKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (temporal) temporalResetPending=true;
    static std::atomic<unsigned> fallbacks{0};
    unsigned count=++fallbacks;
    if (count==1 || count%600==0) {
        fprintf(stderr,"MetalFX %s used native FSR for a frame (%u so far): %s\n",
            temporal ? "Temporal" : "Spatial",count,reason.UTF8String);
        fflush(stderr);
    }
    record(@{@"event":@"metalFXNativeFallback",@"temporal":@(temporal),@"reason":reason ?: @"",@"count":@(count)});
}
static char temporalFrameKey, temporalSuppressedKey;
// Only replace AA on exact targets already observed feeding native FSR.
// Auxiliary views (inventory, portraits) must keep AA if they do not upscale.
// Weak identities neither keep obsolete render targets alive nor match a new
// allocation that happens to reuse an old address.
static NSHashTable *upscaledTAATargets() {
    static NSHashTable *targets = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    return targets;
}
static BOOL knownUpscaledTAA(id<MTLTexture> target) {
    std::lock_guard<std::recursive_mutex> lock(guard());
    return target && [upscaledTAATargets() containsObject:target];
}
static void rememberUpscaledTAA(id<MTLTexture> target) {
    if (!target) return;
    std::lock_guard<std::recursive_mutex> lock(guard());
    [upscaledTAATargets() addObject:target];
}
static char temporalPostprocessKey;
static BOOL temporalColorPass(NSString *name) {
    return [name isEqualToString:@"PPBloomUpsampleBlurAndCombine_PS"] ||
        [name isEqualToString:@"PPColorGradingApplyLUTPS"] ||
        [name isEqualToString:@"EoCOutlineCombinePS"] ||
        [name isEqualToString:@"EoCSight"] ||  // stealth/visibility overlay, ping-pongs a variable number of times
        [name isEqualToString:@"FSR_Tonemap"];
}
// Quiet runtime: pipelines keep their fragment name only when the integration reads it.
static BOOL recognizedFragment(NSString *fragment) {
    return [fragment isEqualToString:@"PPTAA_PS"] || [fragment isEqualToString:@"LinearizeDepth"] || [fragment isEqualToString:@"VelocityBufferCamera_PS"] ||
        temporalColorPass(fragment) || compositionShader(fragment) || [fragment isEqualToString:@"PPToneMap_LUT"] || sceneOverlayShader(fragment);
}
#ifndef BG3MFX_NO_TRACE
static char temporalPassHistoryKey;
#endif
static BOOL spatialFailed;
static BOOL temporalFailed;
static void probeScene(id<MTLCommandBuffer> buffer, NSDictionary *inputs);
// A frame whose inputs or composition Frame Generation cannot reproduce turns it
// off without closing the game: the selected upscaler keeps running, and frames
// already rendered into stand-ins are presented unpaired. Clearing the Frame
// Generation checkbox and checking it again retries.
static std::atomic<bool> frameGenerationDeclined{false};
static void declineFrameGeneration(NSString *reason) {
    if(frameGenerationDeclined.exchange(true)) return;
    record(@{@"event":@"frameGenerationDeclined",@"reason":reason ?: @""});
    fprintf(stderr,"MetalFX Frame Generation is off: %s\n",(reason ?: @"").UTF8String); fflush(stderr);
    BG3MFXShowNotice(@"MetalFX Frame Generation is off",[(reason ?: @"") stringByAppendingString:
        @"\n\nThe game continues with the selected Upscaling Type and without Frame Generation. "
        "To retry, turn Frame Generation off and on again in Video options."]);
}
// frameInterpolator, frameConfiguration and previousFrameTime belong to BG3's
// render thread. framePresenter is also read by layerNextDrawable, so it is
// written under the guard.
static BG3MFXFrameInterpolation *frameInterpolator;
static BG3MFXFramePresenter *framePresenter;
static NSString *frameConfiguration;
static double previousFrameTime;
// Menu callbacks run on another thread; the render thread applies their reset
// at its next generated frame instead of touching its objects concurrently.
static std::atomic<bool> frameGenerationResetPending{false};
// Set once BG3 has bound a real velocity target, whose usage the zero-motion
// stand-in copies. Until then a reset frame's stand-in has a guessed usage.
static std::atomic<bool> bg3MotionSeen{false};
// Unchecking Frame Generation frees the interpolator and
// presentation worker instead of leaving an idle effect alive. The worker joins
// its thread after draining queued pairs, so release it off the render thread.
static void releaseFrameGeneration(void) {
    BG3MFXFramePresenter *presenter;
    { std::lock_guard<std::recursive_mutex> lock(guard()); presenter=framePresenter; framePresenter=nil; }
    frameInterpolator=nil; frameConfiguration=nil; previousFrameTime=0;
    if (presenter) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ (void)presenter; });
    record(@{@"event":@"frameGenerationReleased"});
}
static void resetFrameGeneration(void) { frameGenerationResetPending=true; }
static void encodeGeneratedPair(id<MTLCommandBuffer> buffer, NSDictionary *request);

// A failed MetalFX upscaler is off until the player chooses it again: BG3's
// TAA and FSR, which the menu has already set up underneath, render instead
// (see dispatch and suppressTemporalTAA), and the menu selects AMD FSR 1.0.
static void failFeature(BOOL temporal, NSString *reason) {
    { std::lock_guard<std::recursive_mutex> lock(guard());
      if (temporal ? temporalFailed : spatialFailed) return;
      if (temporal) temporalFailed = YES; else spatialFailed = YES; }
    if (temporal) temporalResetPending = true;
    NSString *feature = temporal ? @"Temporal" : @"Spatial";
    if (![reason isKindOfClass:NSString.class] || reason.length == 0)
        reason = @"MetalFX could not initialize or validate the requested frame.";
    NSString *message = [[@"MetalFX " stringByAppendingString:feature] stringByAppendingFormat:@" stopped: %@",reason];
    fprintf(stderr,"%s\n",message.UTF8String); fflush(stderr);
    record(@{@"event":temporal ? @"temporalUpscaleError" : @"spatialUpscaleError",@"error":message});
    BOOL menu = BG3MFXFallBackToFSR();
    record(@{@"event":@"upscalingFallback",@"to":@"AMD FSR 1.0",@"menu":@(menu)});
    BG3MFXShowNotice([NSString stringWithFormat:@"MetalFX %@ is off",feature],[reason stringByAppendingString:menu ?
        [NSString stringWithFormat:@"\n\nUpscaling Type is now AMD FSR 1.0. To retry, choose MetalFX %@ in Video options.",feature] :
        @"\n\nThe game continues with AMD FSR 1.0 upscaling. To retry, choose another Upscaling Type "
        "and then this one again in Video options."]);
}
// The viewport reduction probe reduces only while Temporal can upscale the region;
// BG3's FSR fallback would show the reduced region as is.
extern "C" BOOL BG3MFXTemporalFailed(void) {
    std::lock_guard<std::recursive_mutex> lock(guard());
    return temporalFailed;
}
static void failSpatial(NSString *reason) { failFeature(NO,reason); }
static void failTemporal(NSString *reason) { failFeature(YES,reason); }
// metalfx's options changed the Upscaling Type or Frame Generation.
void BG3MFXMetalFXSelectionChanged(bool upscalingTypeChanged) {
    // Choosing a different Upscaling Type retries a failed MetalFX upscaler.
    if (upscalingTypeChanged) {
        std::lock_guard<std::recursive_mutex> lock(guard());
        spatialFailed = temporalFailed = NO;
    }
    resetFrameGeneration();
    // Changing either way starts the next enabled run with fresh history.
    extern void BG3MFXResetTemporalHistory(void);
    BG3MFXResetTemporalHistory();
}
static NSString *scalerKey(id<MTLDevice> device, NSUInteger iw, NSUInteger ih, NSUInteger ow, NSUInteger oh) {
    return [NSString stringWithFormat:@"%p:%lu:%lu:%lu:%lu",(__bridge void *)device,iw,ih,ow,oh];
}
// Creating a scaler takes tens of milliseconds. Dragging a window edge gives
// every frame a new size, so a size with no scaler runs BG3's native FSR until
// it has held for a moment; the first scaler of the session is created at once.
struct PendingSize { NSString *key; double since; };
static BOOL sizeSettled(NSString *key, NSDictionary *cache, PendingSize &pending) {
    std::lock_guard<std::recursive_mutex> lock(guard());
    if (cache[key] || !cache.count) return YES;
    double now=NSProcessInfo.processInfo.systemUptime;
    if (![key isEqualToString:pending.key]) { pending.key=key; pending.since=now; return NO; }
    return now-pending.since>=0.3;
}
// Spatial scalers are freed normally. Keep only the sizes in use, the current
// one and the one before it (two views of different sizes may alternate):
// keeping every size held each one's scaler and pooled textures for the rest
// of the session, about 7 MB per size even at 384×384 → 768×768.
static constexpr NSUInteger SpatialCachedSizes = 2;
static NSMutableDictionary<NSString *, BG3MFXSpatialUpscaler *> *spatialUpscalerCache() {
    static NSMutableDictionary *value = [NSMutableDictionary dictionary];
    return value;
}
static NSMutableArray<NSString *> *spatialUpscalerOrder() {  // least recently used first
    static NSMutableArray *value = [NSMutableArray array];
    return value;
}
static BOOL spatialSizeSettled(NSString *key) {
    static PendingSize pending;
    return sizeSettled(key,spatialUpscalerCache(),pending);
}
static BOOL upscaleSpatial(id<MTLCommandBuffer> buffer, NSDictionary *inputs) {
    id<MTLTexture> input = inputs[@"input"], destination = inputs[@"destination"];
    if (!input || !destination) return NO;
    // Fetch/store under the tracer guard, but construct MetalFX outside it:
    // synchronous driver initialization can call our hooks on other threads.
    NSString *key = scalerKey(buffer.device,input.width,input.height,destination.width,destination.height);
    BG3MFXSpatialUpscaler *upscaler;
    { std::lock_guard<std::recursive_mutex> lock(guard()); upscaler = spatialUpscalerCache()[key]; }
    NSError *error = nil;
    if (!upscaler) upscaler = [[BG3MFXSpatialUpscaler alloc] initWithDevice:buffer.device inputWidth:input.width
        inputHeight:input.height outputWidth:destination.width outputHeight:destination.height error:&error];
    if (upscaler) {
        // Frames in flight keep an evicted scaler alive until they complete.
        std::lock_guard<std::recursive_mutex> lock(guard());
        NSMutableArray<NSString *> *order = spatialUpscalerOrder();
        [order removeObject:key]; [order addObject:key];
        spatialUpscalerCache()[key] = upscaler;
        while (order.count > SpatialCachedSizes) {
            [spatialUpscalerCache() removeObjectForKey:order.firstObject]; [order removeObjectAtIndex:0];
        }
    }
    BOOL encoded = upscaler && [upscaler encodeHDRColor:input destination:destination commandBuffer:buffer error:&error];
    record(@{@"event": @"spatialUpscaleEncoded", @"success": @(encoded),
        @"input": texture(input), @"destination": texture(destination), @"error": error.description ?: @""});
    if (encoded) [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        record(@{@"event": @"spatialUpscaleCompleted", @"status": @(completed.status),
            @"error": completed.error.description ?: @""});
        if (completed.status != MTLCommandBufferStatusCompleted)
            failSpatial(completed.error.localizedDescription ?: @"Metal could not complete the scaling commands.");
    }];
    if (!encoded) failSpatial(error.localizedDescription ?: @"MetalFX could not encode the spatial frame.");
    return encoded;
}
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
static std::atomic<unsigned> temporalScalersCreated{0};
static std::atomic<unsigned> frameInterpolatorsCreated{0};
#endif
static NSMutableDictionary *temporalUpscalerCache() {
    // Initialized once, thread-safely; temporalSizeSettled reads it before
    // taking the guard.
    static NSMutableDictionary *value = [NSMutableDictionary dictionary];
    return value;
}
// On macOS 27.0.1 a Temporal scaler whose output is 1512 px tall or less is
// never deallocated (Metal 3 and Metal 4 alike): each keeps an
// ANEServicesThread and tens to hundreds of MB. Creating one per frame while a
// window edge was dragged stuttered, corrupted the image and eventually hung
// BG3 inside scaler creation with about a thousand leaked threads, so new
// sizes wait to settle and such scalers stay cached for reuse. Taller ones are
// freed, so they are evicted once another size is rendered.
static constexpr NSUInteger TemporalLeakedOutputHeight = 1512;
static BOOL temporalSizeSettled(NSString *key) {
    static PendingSize pending;
    return sizeSettled(key,temporalUpscalerCache(),pending);
}
void BG3MFXResetTemporalHistory(void) {
    NSArray<BG3MFXTemporalUpscaler *> *upscalers;
    { std::lock_guard<std::recursive_mutex> lock(guard()); upscalers = temporalUpscalerCache().allValues; }
    for (BG3MFXTemporalUpscaler *upscaler in upscalers) [upscaler resetHistory];
}
static BOOL temporalParameters(NSDictionary *inputs, BG3MFXFrameParameters *parameters, NSString **reason) {
    NSData *cameraData = inputs[@"camera"], *temporalData = inputs[@"temporal"];
    if (cameraData.length < 224 || temporalData.length < 224) {
        if (reason) *reason = @"BG3 did not provide the full camera and temporal constants.";
        return NO;
    }
    const float *camera = (const float *)cameraData.bytes;
    const float *temporal = (const float *)temporalData.bytes;
    BG3MFXFrameParameters p = {};
    // BG3's constants describe the sample displacement, not MetalFX's
    // image/projection displacement. Depth registration and the analytic
    // reconstruction regression establish the opposite sign in both axes.
    BG3MFXApplyTemporalJitter(&p, temporal[52], temporal[53]);
    if (NSNumber *width = inputs[@"contentWidth"], *height = inputs[@"contentHeight"]; width && height) {
        // The reduction probe makes BG3 divide its projection jitter by the
        // reduced region, so BG3's value is already in rendered pixels.
        p.contentWidth = width.unsignedIntegerValue; p.contentHeight = height.unsignedIntegerValue;
    }
    // Inspected BG3 camera/object shaders emit current minus previous in
    // framebuffer pixels. MetalFX needs previous minus current displacement.
    p.motionScaleX = p.motionScaleY = -1;
    p.depthReversed = YES; p.reset = [inputs[@"reset"] boolValue];
    float nearPlane = camera[48], farPlane = camera[49];
    float fieldOfView = 2 * std::atan(1/camera[21]) * 180 / M_PI;
    float nearDepth = camera[26] + camera[30]/nearPlane;
    float farDepth = camera[26] + camera[30]/farPlane;
    if (!std::isfinite(nearDepth) || !std::isfinite(farDepth) || std::abs(nearDepth-1) > 0.001 ||
        std::abs(farDepth) > 0.001 || nearPlane <= 0 || farPlane <= nearPlane ||
        !std::isfinite(fieldOfView) || fieldOfView <= 0 || fieldOfView >= 180 ||
        !std::isfinite(p.jitterX) || !std::isfinite(p.jitterY) || std::abs(p.jitterX) > 0.5 || std::abs(p.jitterY) > 0.5) {
        if (reason) *reason = @"BG3 supplied an unsupported camera projection or temporal jitter.";
        return NO;
    }
    *parameters = p;
    return YES;
}
#ifndef BG3MFX_NO_TRACE
static void validateMotionSample(id<MTLCommandBuffer> buffer, id<MTLTexture> motion) {
    static std::atomic<unsigned> attempts{0};
    if (!getenv("BG3MFX_VALIDATE_MOTION") || attempts.fetch_add(1) >= 8) return;
    NSUInteger row = (motion.width*4+255)&~NSUInteger(255);
    id<MTLBuffer> data = [buffer.device newBufferWithLength:row*motion.height options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> encoder = [buffer blitCommandEncoder];
    [encoder copyFromTexture:motion sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(motion.width,motion.height,1) toBuffer:data destinationOffset:0
        destinationBytesPerRow:row destinationBytesPerImage:row*motion.height];
    [encoder endEncoding];
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status != MTLCommandBufferStatusCompleted) return;
        NSUInteger nonfinite=0; float maximum=0;
        for (NSUInteger y=0;y<motion.height;++y) for (NSUInteger x=0;x<motion.width;++x) {
            const __fp16 *p=(const __fp16 *)((const uint8_t *)data.contents+y*row+x*4);
            for (int c=0;c<2;++c) { float v=p[c]; if (!std::isfinite(v)) ++nonfinite; else maximum=std::fmax(maximum,std::abs(v)); }
        }
        record(@{@"event":@"temporalMotionValidation",@"nonfinite":@(nonfinite),@"maximumAbsolute":@(maximum),@"motion":texture(motion)});
    }];
}
#endif
// Dynamic resolution counts our Metal 4 MetalFX submissions as GPU work too.
static void metal4GPUWork(double start, double end) {
    if (BG3MFXDynamicResolutionMeasuring()) BG3MFXDynamicResolutionGPUWork(start,end);
}
static BOOL upscaleTemporal(id<MTLCommandBuffer> buffer, NSDictionary *inputs, id<MTLTexture> destination) {
    id<MTLTexture> color = inputs[@"color"], depth = inputs[@"depth"], motion = inputs[@"motion"];
    if (!color || !depth || !motion || !destination) {
        failTemporal(@"The scene capture did not provide color, depth, motion, and final output textures.");
        return NO;
    }
    BG3MFXFrameParameters parameters = {};
    NSString *reason = nil;
    if (!temporalParameters(inputs,&parameters,&reason)) { failTemporal(reason); return NO; }
    BOOL nativeAAWarmup = [inputs[@"nativeTAAPreserved"] boolValue];
    parameters.reset |= nativeAAWarmup || temporalResetPending.exchange(false);
    NSString *key = scalerKey(buffer.device,color.width,color.height,destination.width,destination.height);
    if (BG3MFXDynamicResolutionSelected()) key = [key stringByAppendingString:@" dynamic"];
    BG3MFXTemporalUpscaler *upscaler;
    { std::lock_guard<std::recursive_mutex> lock(guard()); upscaler = temporalUpscalerCache()[key]; }
    NSError *error = nil;
    if (!upscaler) {
        BOOL dynamicResolution = BG3MFXDynamicResolutionSelected();
        if (dynamicResolution) BG3MFXGPUWorkHook = metal4GPUWork;
        if (dynamicResolution)
            BG3MFXDynamicResolutionSetScaleLimits([MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:buffer.device],
                [MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:buffer.device]);
        upscaler = [[BG3MFXTemporalUpscaler alloc] initWithDevice:buffer.device inputWidth:color.width
            inputHeight:color.height outputWidth:destination.width outputHeight:destination.height
            dynamicResolution:dynamicResolution error:&error];
        if (upscaler) {
            upscaler.gpuFailureHandler=^(NSError *gpuError) {
                failTemporal(gpuError.localizedDescription ?: @"Metal 4 could not complete temporal scaling commands.");
            };
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
            temporalScalersCreated.fetch_add(1);
#endif
            record(@{@"event":@"temporalScalerCreated",@"api":upscaler.usesMetal4 ? @"metal4" : @"metal3"});
            std::lock_guard<std::recursive_mutex> lock(guard());
            // Keep every settled size that leaks: evicting it freed nothing,
            // and a bounded cache once evicted the scaler it had just added,
            // recreating it every frame until the ANE was exhausted.
            temporalUpscalerCache()[key] = upscaler;
        }
    }
    if (upscaler) {
        // When the size changes, the previous size's scaler lets go of what it
        // kept for its next frame (BG3 frees those render targets on resize),
        // and other sizes MetalFX does free are evicted. The current size is
        // never evicted.
        static NSString *activeKey;
        NSMutableArray<BG3MFXTemporalUpscaler *> *idle = [NSMutableArray array];
        { std::lock_guard<std::recursive_mutex> lock(guard());
          if (![key isEqualToString:activeKey]) {
              if (BG3MFXTemporalUpscaler *previous = activeKey ? temporalUpscalerCache()[activeKey] : nil) [idle addObject:previous];
              activeKey = key;
              for (NSString *cached in temporalUpscalerCache().allKeys) {
                  BG3MFXTemporalUpscaler *other = temporalUpscalerCache()[cached];
                  if (![cached isEqualToString:key] && other.outputHeight > TemporalLeakedOutputHeight)
                      [temporalUpscalerCache() removeObjectForKey:cached];
              }
          } }
        for (BG3MFXTemporalUpscaler *previous in idle) [previous releaseIdleResources];
    }
    #ifndef BG3MFX_NO_TRACE
    validateMotionSample(buffer,motion);
#endif
    BOOL encoded = upscaler && [upscaler encodeColor:color deviceDepth:depth motion:motion parameters:parameters
        destination:destination commandBuffer:buffer error:&error];
    if (encoded) {
        if(frameGeneration(buffer)) {
            NSMutableDictionary *frames=objc_getAssociatedObject(buffer,&temporalFrameKey);
            frames[[NSValue valueWithPointer:(__bridge const void *)destination]]=inputs;
        }
        rememberUpscaledTAA(inputs[@"nativeTAA"]);
        // Discovery frames contain native AA. Do not carry that filtered
        // history into the subsequent raw-jittered-color reconstruction.
        if (nativeAAWarmup) [upscaler resetHistory];
    }
    record(@{@"event":@"temporalUpscaleEncoded",@"success":@(encoded),@"input":texture(color),
        @"content":@[@(parameters.contentWidth ?: color.width),@(parameters.contentHeight ?: color.height)],
        @"jitter":@[@(parameters.jitterX),@(parameters.jitterY)],
        @"depth":texture(depth),@"motion":texture(motion),@"destination":texture(destination),@"error":error.description ?: @""});
    if (encoded) [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
#ifndef BG3MFX_NO_TRACE
        static std::atomic<unsigned> frames{0};
        unsigned frame = frames.fetch_add(1);
        if (frame < 3 || frame % 120 == 0)
            record(@{@"event":@"temporalValidationProgress",@"frame":@(frame),@"status":@(completed.status),@"input":texture(color)});
#endif
        record(@{@"event":@"temporalUpscaleCompleted",@"status":@(completed.status),
            @"error":completed.error.localizedDescription ?: @"",@"input":texture(color),@"destination":texture(destination)});
        if (completed.status != MTLCommandBufferStatusCompleted)
            failTemporal(completed.error.localizedDescription ?: @"Metal could not complete temporal scaling commands.");
    }];
    else failTemporal(error.localizedDescription ?: @"MetalFX could not encode the temporal frame.");
    return encoded;
}
static BOOL copyTemporalAAColor(id<MTLCommandBuffer> buffer, NSDictionary *inputs) {
    id<MTLTexture> color = inputs[@"color"], target = inputs[@"taaColor"];
    if (!color || !target || color.width != target.width || color.height != target.height ||
        color.pixelFormat != target.pixelFormat || target.storageMode == MTLStorageModeMemoryless ||
        color.hazardTrackingMode == MTLHazardTrackingModeUntracked || target.hazardTrackingMode == MTLHazardTrackingModeUntracked) {
        failTemporal(@"The native TAA output cannot safely receive the current HDR frame.");
        return NO;
    }
    if (color == target) return YES;
    id<MTLBlitCommandEncoder> encoder = [buffer blitCommandEncoder];
    if (!encoder) { failTemporal(@"Could not create the TAA replacement copy encoder."); return NO; }
    [encoder copyFromTexture:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(color.width,color.height,1) toTexture:target destinationSlice:0 destinationLevel:0
        destinationOrigin:MTLOriginMake(0,0,0)];
    [encoder endEncoding];
    record(@{@"event":@"temporalTAACopy",@"source":texture(color),@"target":texture(target)});
    return YES;
}
#ifndef BG3MFX_NO_TRACE
// BG3MFX_STENCIL_DUMP_DIR: the stencil plane after the decal normal pass (which
// marks decal and surface receivers with 64) and after the fluid surface pass,
// written once with the viewport reduced and once at full size.
static char stencilDepthKey, stencilRoleKey;
static void dumpStencil(id<MTLCommandBuffer> buffer, id<MTLTexture> depth, NSString *role) {
    const char *directory = stencilDumpDirectory();
    // Each switch between reduced and full size starts a new numbered pair.
    static NSMutableSet *written = [NSMutableSet set];
    static bool lastReduced; static unsigned switches;
    bool reduced = BG3MFXDynamicResolutionArea() < 1;
    NSString *name;
    { std::lock_guard<std::recursive_mutex> lock(guard());
      if (reduced != lastReduced) { lastReduced = reduced; ++switches; }
      name = [NSString stringWithFormat:@"stencil-%02u-%@-%@-%lux%lu.bin", switches, reduced ? @"reduced" : @"full", role,
          (unsigned long)depth.width, (unsigned long)depth.height];
      if ([written containsObject:name]) return;
      [written addObject:name]; }
    NSUInteger size = depth.width * depth.height;
    id<MTLBuffer> data = [buffer.device newBufferWithLength:size options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit = [buffer blitCommandEncoder];
    [blit copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(depth.width,depth.height,1)
        toBuffer:data destinationOffset:0 destinationBytesPerRow:depth.width destinationBytesPerImage:size options:MTLBlitOptionStencilFromDepthStencil];
    [blit endEncoding];
    NSString *path = [[NSString stringWithUTF8String:directory] stringByAppendingPathComponent:name];
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        BOOL saved = completed.status == MTLCommandBufferStatusCompleted &&
            [[NSData dataWithBytes:data.contents length:size] writeToFile:path atomically:YES];
        record(@{@"event": @"stencilDump", @"path": path, @"saved": @(saved)});
    }];
}
#endif
// BG3 pairs DeferredFog_* with DefaultVS, whose texCoord spans the render
// viewport, but indexes the volumetric fog in texture UV. Other post passes use
// PPDefaultVS, which maps texCoord through _Viewport (buffer 9, already bound
// for the fog draw). Dynamic resolution shrinks the viewport, so give the fog
// composite that mapping (identical at full size); the output member keeps
// DefaultVS's linkage name. Dynamic resolution installs at library load,
// before BG3 creates its device.
static MTLRenderPipelineDescriptor *viewportFogDescriptor(id<MTLDevice> device, MTLRenderPipelineDescriptor *desc) {
    if (!BG3MFXDynamicResolutionInstalled() || ![desc.vertexFunction.name isEqualToString:@"DefaultVS"] ||
        ![desc.fragmentFunction.name hasPrefix:@"DeferredFog_"]) return desc;
    static id<MTLFunction> vertex;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct In { float2 position [[attribute(0)]]; float2 texCoord [[attribute(1)]]; };\n"
            "struct Out { float4 position [[position]]; float2 texCoord; };\n"
            "struct Viewport { float2 scale; float2 offset; };\n"
            "vertex Out BG3MFXViewportFogVS(In in [[stage_in]], constant Viewport &viewport [[buffer(9)]]) {\n"
            "    return { float4(in.position, 1, 1), in.texCoord * viewport.scale + viewport.offset };\n}\n";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        vertex = [library newFunctionWithName:@"BG3MFXViewportFogVS"];
        record(@{@"event": @"viewportFogVertex", @"success": @(vertex != nil), @"error": error.description ?: @""});
    });
    if (!vertex) return desc;
    MTLRenderPipelineDescriptor *copy = [desc copy];
    copy.vertexFunction = vertex;
    return copy;
}
#ifndef BG3MFX_NO_TRACE
// BG3MFX_SURFACE_DEBUG=1 replaces the fluid surface shader (blood pools) with
// its world reconstruction: depth times the view ray, then the surface grid's
// noise warp and height test. Albedo shows world X and Z as red and blue
// stripes and the height-test error as green (BG3 discards from 0.125).
static MTLRenderPipelineDescriptor *surfaceDebugDescriptor(id<MTLDevice> device, MTLRenderPipelineDescriptor *desc) {
    if (!getenv("BG3MFX_SURFACE_DEBUG") ||
        ![desc.fragmentFunction.name isEqualToString:@"Shared_Surface_VFX_Surface_AlphaBlend_Fluid_ST_DEF_fragmentMain"]) return desc;
    static id<MTLFunction> fragment;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct In { float4 position [[position]]; float3 ViewSpacePosition; };\n"
            "struct Out { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; float4 c2 [[color(2)]]; float4 c3 [[color(3)]]; };\n"
            "template<class T> T at(constant uchar *p, uint offset) { return *(constant T *)(p + offset); }\n"
            "fragment Out BG3MFXSurfaceDebug(In in [[stage_in]], constant uchar *material [[buffer(20)]],\n"
            "    constant uchar *view [[buffer(12)]], constant uchar *camera [[buffer(11)]], constant float4 &rt [[buffer(10)]],\n"
            "    texture2d<float> linearDepth [[texture(30)]], texture2d<float> received [[texture(37)]], texture2d<float> noise [[texture(0)]],\n"
            "    texture2d<float> baseColor [[texture(1)]], texture2d<float> mask [[texture(2)]], texture2d<float> height [[texture(3)]],\n"
            "    sampler pointClamp [[sampler(0)]], sampler linearClamp [[sampler(1)]], sampler pointMirror [[sampler(13)]], sampler wrap [[sampler(15)]]) {\n"
            "    float2 screen = in.position.xy * rt.zw;\n"
            "    float2 normal = received.sample(pointMirror, screen).xy;\n"
            "    float lin = linearDepth.sample(pointClamp, screen).x;\n"
            "    float3 ray = in.ViewSpacePosition * (at<float>(camera, 196) / in.ViewSpacePosition.z) * lin;\n"
            "    float3 world = at<float4>(view, 48).xyz * ray.x + at<float4>(view, 64).xyz * ray.y + at<float4>(view, 80).xyz * ray.z +\n"
            "        float3(at<float>(camera, 208), at<float>(camera, 212), at<float>(camera, 216));\n"
            "    float4 c0 = at<float4>(material, 0), c1 = at<float4>(material, 16);\n"
            "    float2 local = world.xz - c0.xz * c0.w;\n"
            "    float amount = at<float>(material, 48);\n"
            "    float2 warp = noise.sample(wrap, local / at<float>(material, 44)).xy * amount - amount * 0.5;\n"
            "    float alpha = baseColor.sample(wrap, local / at<float>(material, 52)).w;\n"
            "    warp = mix(warp, float2(0.5), saturate(1 - alpha) * 0.25);\n"
            "    float3 warped = world + float3(warp.x, 0, warp.y);\n"
            "    float2 uv = (warped.xz - c0.xz) / (c1.xy * c1.w);\n"
            "    float ground = height.sample(linearClamp, uv).x * 1310.7 + c0.y;\n"
            "    float error = saturate((abs(ground - warped.y) - 0.1) * 40);\n"
            "    float2 cell = float2(uv.x, 1 - uv.y);\n"
            "    float4 layer = floor(float4(c1.z));\n"
            "    float4 first = mask.gather(linearClamp, cell, int2(0), component::x), second = mask.gather(linearClamp, cell, int2(0), component::y);\n"
            "    float4 inFirst = float4(floor(first * 255 + 0.5) == layer), inSecond = float4(floor(second * 255 + 0.5) == layer);\n"
            "    float4 amounts = saturate(mask.gather(linearClamp, cell, int2(0), component::z) * inFirst +\n"
            "        mask.gather(linearClamp, cell, int2(0), component::w) * inSecond);\n"
            "    float2 f = fract(cell * c1.xy - 0.499);\n"
            "    float coverage = mix(mix(amounts.w, amounts.z, f.x), mix(amounts.x, amounts.y, f.x), f.y);\n"
            "    bool noNormal = all(normal == 0), noLayer = !any(inFirst + inSecond > 0), outside = any(uv != saturate(uv));\n"
            "    Out out = {};\n"
            "    out.c1 = noNormal || noLayer || outside || error > 0 ?\n"
            "        float4(noNormal || outside ? 1 : 0, error, noLayer ? 1 : 0, 1) : float4(float3(coverage), 1);\n"
            "    return out;\n}\n";
        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
        fragment = [library newFunctionWithName:@"BG3MFXSurfaceDebug"];
        record(@{@"event": @"surfaceDebugFragment", @"success": @(fragment != nil), @"error": error.description ?: @""});
    });
    if (!fragment) return desc;
    MTLRenderPipelineDescriptor *copy = [desc copy];
    copy.fragmentFunction = fragment;
    return copy;
}
#endif
static void classifyDynamicResolution(BG3MFXPipelineInfo *info, MTLRenderPipelineDescriptor *desc) {
    if (!BG3MFXDynamicResolutionInstalled()) return;
    if ([desc.vertexFunction.name hasPrefix:@"Shared_Surface_VFX_Surface_"]) info->rendererFlags |= FlagSurfaceGrid;
    if ([desc.fragmentFunction.name hasPrefix:@"PPSSSS_"]) info->rendererFlags |= FlagSubsurface;
}
#ifndef BG3MFX_NO_TRACE
// Whether worker drawables reach the display. CAMetalLayer drops a drawable
// superseded within the same refresh (presentedTime == 0).
// GPU time per frame-generation frame: Metal 4 submissions by label, and BG3's
// presenting command buffers (duration and spacing between completions).
static std::mutex gpuTimingLock;
static std::map<std::string,std::pair<double,unsigned>> gpuSubmissionTime;
static double frameGPUTime, frameGPUPeriod, lastFrameGPUEnd; static unsigned frameGPUCount;
static void recordGPUSubmission(NSString *label, double seconds) {
    std::lock_guard<std::mutex> hold(gpuTimingLock);
    auto &entry=gpuSubmissionTime[label.UTF8String ?: "?"]; entry.first+=seconds; ++entry.second;
}
static void recordFrameGPU(id<MTLCommandBuffer> buffer) {
    std::lock_guard<std::mutex> hold(gpuTimingLock);
    frameGPUTime+=buffer.GPUEndTime-buffer.GPUStartTime; ++frameGPUCount;
    if (lastFrameGPUEnd>0) frameGPUPeriod+=buffer.GPUEndTime-lastFrameGPUEnd;
    lastFrameGPUEnd=buffer.GPUEndTime;
}
static NSDictionary *takeGPUTiming() {
    std::lock_guard<std::mutex> hold(gpuTimingLock);
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for (auto &[label,entry]:gpuSubmissionTime)
        result[[@(label.c_str()) stringByAppendingString:@" ms"]]=@(entry.second ? entry.first*1000/entry.second : 0);
    result[@"bg3FrameBufferMs"]=@(frameGPUCount ? frameGPUTime*1000/frameGPUCount : 0);
    result[@"bg3FrameGPUPeriodMs"]=@(frameGPUCount>1 ? frameGPUPeriod*1000/(frameGPUCount-1) : 0);
    gpuSubmissionTime.clear(); frameGPUTime=frameGPUPeriod=0; frameGPUCount=0;
    return result;
}
static void recordDisplayed(BOOL generated, CFTimeInterval time, CFTimeInterval target, double interval) {
    static std::mutex lock; static unsigned shown[2], dropped[2], missing[2], raw;
    static CFTimeInterval last; static BOOL lastGenerated;
    // Gaps are keyed by the frame that ended them: real->generated and
    // generated->real should each be about half the rendered interval.
    static std::vector<double> realToGenerated, generatedToReal, lateness[2], intervals;
    std::lock_guard<std::mutex> hold(lock);
    int kind=generated ? 1 : 0;
    if (time<0) missing[kind]++;
    else if (time==0) dropped[kind]++;
    else {
        shown[kind]++;
        if (last>0 && lastGenerated!=generated) (generated ? realToGenerated : generatedToReal).push_back(time-last);
        last=time; lastGenerated=generated;
        if (target>0) lateness[kind].push_back(time-target);
    }
    intervals.push_back(interval);
    if (raw++<120) record(@{@"event":@"frameGenerationDisplay",@"generated":@(generated),@"shown":@(time),
        @"target":@(target),@"intervalMs":@(interval*1000)});
    unsigned total=shown[0]+shown[1]+dropped[0]+dropped[1]+missing[0]+missing[1];
    if (total%240) return;
    auto ms=[](std::vector<double> v, double p){
        if (v.empty()) return 0.0; std::sort(v.begin(),v.end()); return 1000*v[(size_t)(p*(v.size()-1))]; };
    auto spread=[&](const std::vector<double> &v){ return @[@(ms(v,.1)),@(ms(v,.5)),@(ms(v,.9))]; };
    BG3MFXFramePresenter *presenter;
    { std::lock_guard<std::recursive_mutex> guardLock(guard()); presenter=framePresenter; }
    if (presenter)
        record(@{@"event":@"frameGenerationPresenterTiming",@"timing":[presenter takeTimingSummary],@"gpu":takeGPUTiming()});
    record(@{@"event":@"frameGenerationDisplayed",@"generatedShown":@(shown[1]),@"generatedDropped":@(dropped[1]),
        @"generatedNoDrawable":@(missing[1]),@"realShown":@(shown[0]),@"realDropped":@(dropped[0]),@"realNoDrawable":@(missing[0]),
        @"realToGeneratedMsP10P50P90":spread(realToGenerated),@"generatedToRealMsP10P50P90":spread(generatedToReal),
        @"generatedLateMsP10P50P90":spread(lateness[1]),@"realLateMsP10P50P90":spread(lateness[0]),
        @"renderedIntervalMsP10P50P90":spread(intervals)});
    realToGenerated.clear(); generatedToReal.clear(); lateness[0].clear(); lateness[1].clear(); intervals.clear();
}
#endif
static void encodeGeneratedPair(id<MTLCommandBuffer> buffer, NSDictionary *request) {
    id<MTLTexture> scene=request[@"scene"], ui=request[@"ui"], target=request[@"target"];
    // Only frames composed into a stand-in drawable can be paired. A frame that
    // began on a real drawable (Frame Generation just selected) stays native.
    BG3MFXFramePresenter *presenter;
    { std::lock_guard<std::recursive_mutex> lock(guard()); presenter=framePresenter; }
    if(![presenter ownsTexture:target]) return;
    NSDictionary *inputs=request[@"inputs"];
    // BG3's first frames after launch are resets. Their stand-in motion would
    // configure an interpolator that the first real frame replaces; a reset
    // frame has no history to interpolate from, so present it unpaired.
    if([inputs[@"reset"] boolValue] && !bg3MotionSeen) return;
    id<MTLTexture> depth=inputs[@"depth"], motion=inputs[@"motion"];
    BG3MFXFrameParameters parameters={}; NSString *reason=nil;
    if(!temporalParameters(inputs,&parameters,&reason)) { declineFrameGeneration(reason); return; }
    BOOL dynamicContent=BG3MFXDynamicResolutionSelected();
    NSString *configuration=[NSString stringWithFormat:@"%p:%lu:%lu:%lu:%lu:%d:%lu:%lu/%lu:%lu/%lu:%lu/%lu:%d",(__bridge void *)buffer.device,
        depth.width,depth.height,scene.width,scene.height,[objc_getAssociatedObject(buffer,&bufferScalingModeKey) intValue],target.pixelFormat,
        scene.pixelFormat,scene.usage,depth.pixelFormat,depth.usage,motion.pixelFormat,motion.usage,dynamicContent];
    NSError *error=nil;
    if(![configuration isEqualToString:frameConfiguration]) {
        frameInterpolator=[[BG3MFXFrameInterpolation alloc] initWithDevice:buffer.device scene:scene depth:depth motion:motion
            dynamicContent:dynamicContent error:&error];
        if(!frameInterpolator) {declineFrameGeneration(error.localizedDescription ?: @"Could not initialize frame generation.");return;}
        frameInterpolator.failureHandler=^(NSError *e){declineFrameGeneration(e.localizedDescription ?: @"Metal could not complete frame generation.");};
        frameConfiguration=configuration;previousFrameTime=0;
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
        frameInterpolatorsCreated.fetch_add(1);
#endif
        record(@{@"event":@"frameGenerationCreated",@"api":frameInterpolator.usesMetal4 ? @"metal4" : @"metal3",
            @"input":texture(depth),@"scene":texture(scene),@"direct":@[@(frameInterpolator.directColor),
            @(frameInterpolator.directDepth),@(frameInterpolator.directMotion)]});
    }
    if(frameGenerationResetPending.exchange(false)) { [frameInterpolator resetHistory]; previousFrameTime=0; }
    double now=NSProcessInfo.processInfo.systemUptime;
    double interval=previousFrameTime>0 ? now-previousFrameTime : 1.0/60;
    previousFrameTime=now;
    if(interval<=0 || interval>0.1) {parameters.reset=YES;interval=1.0/60;}
    encodingFrameGeneration=true;
    id<MTLTexture> interpolated=[frameInterpolator encodeScene:scene depth:depth motion:motion camera:inputs[@"camera"]
        parameters:parameters deltaTime:interval commandBuffer:buffer error:&error];
    if(!interpolated) {encodingFrameGeneration=false;declineFrameGeneration(error.localizedDescription ?: @"Could not encode the generated frame.");return;}
    // BG3's own CombineUI already composes the real frame into the stand-in;
    // compose only the generated scene with the same UI, pipeline and constants.
    id<MTLTexture> generated=[presenter generatedTargetLike:target];
    if(!generated){encodingFrameGeneration=false;declineFrameGeneration(@"Could not allocate the frame generation composition output.");return;}
    // Replay BG3's draw exactly: its viewport and scissor, and outside them the
    // real frame's pixels (letterbox bars, or whatever its load action left).
    MTLViewport viewport={0,0,double(target.width),double(target.height),0,1};
    MTLScissorRect scissor={0,0,target.width,target.height};
    NSData *viewportData=request[@"viewport"],*scissorData=request[@"scissor"];
    if(viewportData) memcpy(&viewport,viewportData.bytes,sizeof(viewport));
    if(scissorData) memcpy(&scissor,scissorData.bytes,sizeof(scissor));
    bool partial=viewport.originX>0 || viewport.originY>0 || viewport.originX+viewport.width<target.width ||
        viewport.originY+viewport.height<target.height || scissor.x>0 || scissor.y>0 ||
        scissor.x+scissor.width<target.width || scissor.y+scissor.height<target.height;
    if(partial) {
        auto blit=[buffer blitCommandEncoder];
        [blit copyFromTexture:target toTexture:generated];[blit endEncoding];
    }
    auto pass=[MTLRenderPassDescriptor new];pass.colorAttachments[0].texture=generated;
    pass.colorAttachments[0].loadAction=partial ? MTLLoadActionLoad : MTLLoadActionDontCare;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    auto e=[buffer renderCommandEncoderWithDescriptor:pass];
    [e setRenderPipelineState:request[@"pipeline"]];
    if(viewportData) [e setViewport:viewport];
    if(scissorData) [e setScissorRect:scissor];
    NSData *vertexBytes=request[@"vertexBytes"];
    if(vertexBytes) [e setVertexBytes:vertexBytes.bytes length:vertexBytes.length atIndex:0];
    else [e setVertexBuffer:request[@"vertices"] offset:[request[@"vertexOffset"] unsignedIntegerValue] atIndex:0];
    NSData *constants=request[@"constants"];[e setFragmentBytes:constants.bytes length:constants.length atIndex:0];
    [e setFragmentSamplerState:request[@"sampler"] atIndex:0];
    [e setFragmentTexture:interpolated atIndex:0];[e setFragmentTexture:ui atIndex:1];
    DrawCall draw;memcpy(&draw,[request[@"draw"] bytes],sizeof(draw));
    if(id<MTLBuffer> indices=request[@"indexBuffer"])
        [e drawIndexedPrimitives:draw.type indexCount:draw.count indexType:draw.indexType indexBuffer:indices
            indexBufferOffset:draw.indexOffset instanceCount:draw.instances baseVertex:draw.baseVertex baseInstance:draw.baseInstance];
    else [e drawPrimitives:draw.type vertexStart:draw.start vertexCount:draw.count instanceCount:draw.instances baseInstance:draw.baseInstance];
    [e endEncoding];
    encodingFrameGeneration=false;
    objc_setAssociatedObject(buffer,&generatedPairKey,@{@"generated":generated,@"presenter":presenter,
        @"interval":@(interval),@"target":target},OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    record(@{@"event":@"frameGenerationEncoded",@"scene":texture(scene),@"generated":texture(generated),@"reset":@(parameters.reset),
        @"interval":@(interval),@"mode":objc_getAssociatedObject(buffer,&bufferScalingModeKey) ?: @0,
        @"target":texture(target),@"buffer":@((uintptr_t)(__bridge void *)buffer)});
}

static void captureSceneInputs(id encoder, NSString *fragment) {
    std::lock_guard<std::recursive_mutex> lock(guard());
    if ((!sceneProbe && !runtimeEnabled) || (sceneProbe && sceneProbeAttempts && !runtimeEnabled)) return;
    id<MTLCommandBuffer> buffer = encoderBuffer(encoder);
    NSDictionary *textures = boundTextures(encoder);
    id<MTLTexture> target = encoderTarget(encoder);
    id<MTLTexture> source = textures[@"0"];
    if ([fragment isEqualToString:@"LinearizeDepth"] && source &&
        target.pixelFormat == MTLPixelFormatR32Float &&
        target.width == source.width &&
        target.height == source.height &&
        source.pixelFormat == MTLPixelFormatDepth32Float_Stencil8 && buffer) {
        objc_setAssociatedObject(buffer, &deviceDepthKey, source, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if ([fragment isEqualToString:@"VelocityBufferCamera_PS"] && buffer) {
        NSData *camera = constantBytes(encoder,StageFragment,11,224);
        if (camera) {
            objc_setAssociatedObject(buffer,&sceneCameraKey,camera,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(buffer.commandQueue,&sceneCameraKey,camera,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (![fragment isEqualToString:@"PPTAA_PS"]) return;
    objc_setAssociatedObject(encoder, &taaInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id<MTLTexture> taaTarget = encoderTarget(encoder);
    NSDictionary *spatialSeed = nil;
    int mode = encoderScalingMode(encoder);
    if (mode != 3) {
        // Off, FSR and Spatial keep BG3's TAA. Seed the postprocess chain with
        // its output in linear HDR: Spatial upscales it, and Frame Generation
        // follows it to the composition.
        if (!buffer || !sceneTracked(mode,buffer) || !taaTarget || taaTarget.pixelFormat != MTLPixelFormatRG11B10Float) return;
        spatialSeed = @{@"color":taaTarget,@"taaColor":taaTarget,@"nativeTAA":taaTarget};
        objc_setAssociatedObject(encoder, &taaInputsKey, spatialSeed, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        noteAssociation(encoder,AssocTAAInputs);
        // Frame Generation also needs this frame's depth, motion and camera,
        // validated exactly as for Temporal. Without them the frame still
        // renders and upscales; it just cannot be paired.
        if (!frameGeneration(buffer)) return;
    }
    id<MTLTexture> motion = textures[@"2"];
    id<MTLTexture> depth = objc_getAssociatedObject(buffer, &deviceDepthKey);
    BOOL resetMotion = motion.width == 16 && motion.height == 16 && motion.pixelFormat == MTLPixelFormatRGBA8Unorm;
    // Usage of BG3's real velocity target. The zero stand-in matches it so
    // Frame Generation's configuration (which includes motion usage) does not
    // change on a reset frame and rebuild its interpolator twice.
    static MTLTextureUsage motionUsage = MTLTextureUsageShaderRead;
    static id<MTLTexture> zeroMotion;
    if (!resetMotion && motion.pixelFormat == MTLPixelFormatRG16Float) {
        std::lock_guard<std::recursive_mutex> lock(guard()); motionUsage = motion.usage;
        bg3MotionSeen = true;
    }
    if (resetMotion && source && buffer) {
        // BG3 invalidates velocity/history for the first frame after a quality
        // change. MetalFX must start a fresh history with zero displacement.
        // The stand-in is only read, so one per size serves every reset.
        std::lock_guard<std::recursive_mutex> lock(guard());
        if (zeroMotion.width != source.width || zeroMotion.height != source.height ||
            zeroMotion.usage != motionUsage || zeroMotion.device != buffer.device) {
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:source.width height:source.height mipmapped:NO];
            desc.storageMode = MTLStorageModeShared; desc.usage = motionUsage;
            zeroMotion = [buffer.device newTextureWithDescriptor:desc];
            NSMutableData *zeros = [NSMutableData dataWithLength:source.width*source.height*4];
            [zeroMotion replaceRegion:MTLRegionMake2D(0,0,source.width,source.height) mipmapLevel:0 withBytes:zeros.bytes bytesPerRow:source.width*4];
        }
        motion = zeroMotion;
    }
    if (!source || !motion || !depth || !taaTarget ||
        taaTarget.width != source.width || taaTarget.height != source.height || motion.pixelFormat != MTLPixelFormatRG16Float ||
        source.width != motion.width || source.height != motion.height ||
        source.width != depth.width || source.height != depth.height) {
        objc_setAssociatedObject(buffer,&sceneCaptureFailureKey,[NSString stringWithFormat:@"scene textures: color %lux%lu, motion %lux%lu format %lu, depth %lux%lu, target %lux%lu",(unsigned long)source.width,(unsigned long)source.height,(unsigned long)motion.width,(unsigned long)motion.height,(unsigned long)motion.pixelFormat,(unsigned long)depth.width,(unsigned long)depth.height,(unsigned long)taaTarget.width,(unsigned long)taaTarget.height],OBJC_ASSOCIATION_RETAIN_NONATOMIC); return;
    }
    NSData *camera = objc_getAssociatedObject(buffer,&sceneCameraKey) ?: constantBytes(encoder,StageFragment,11,224);
    if (!camera && resetMotion) camera = objc_getAssociatedObject(buffer.commandQueue,&sceneCameraKey);
    NSData *temporal = constantBytes(encoder,StageFragment,8,224);
    NSData *viewport = constantBytes(encoder,StageFragment,9,168);
    if (!camera || !temporal || !viewport) {
        objc_setAssociatedObject(buffer,&sceneCaptureFailureKey,[NSString stringWithFormat:@"constants: camera %@, jitter %@, viewport %@",camera ? @"available" : @"missing",temporal ? @"available" : @"missing",viewport ? @"available" : @"missing"],OBJC_ASSOCIATION_RETAIN_NONATOMIC); return;
    }
    const float *vp = (const float *)viewport.bytes;
    const uint32_t *size = (const uint32_t *)((const uint8_t *)viewport.bytes+16);
    // Split-screen, cropped, and scaled viewport support requires separate work.
    NSDictionary *content = @{};
    if (vp[0] != 1 || vp[1] != 1 || vp[2] != 0 || vp[3] != 0 || size[0] != source.width || size[1] != source.height) {
        // Dynamic resolution renders a smaller region at the origin of the
        // same targets; Temporal scales just that region.
        const uint32_t *minimum = size + 2;
        if (!BG3MFXDynamicResolutionInstalled() || spatialSeed || vp[2] != 0 || vp[3] != 0 || minimum[0] || minimum[1] ||
            !size[0] || !size[1] || size[0] > source.width || size[1] > source.height) return;
        content = @{@"contentWidth": @(size[0]), @"contentHeight": @(size[1])};
    }
    if (spatialSeed) {
        NSMutableDictionary *inputs = [spatialSeed mutableCopy];
        [inputs addEntriesFromDictionary:@{@"depth": depth, @"motion": motion, @"camera": camera, @"temporal": temporal, @"reset":@(resetMotion)}];
        objc_setAssociatedObject(encoder, &taaInputsKey, inputs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        noteAssociation(encoder,AssocTAAInputs);
        return;
    }
    NSMutableDictionary *inputs = [@{@"color": source, @"taaColor": taaTarget, @"nativeTAA":taaTarget,
          @"nativeTAAPreserved":@(!knownUpscaledTAA(taaTarget)),
          @"depth": depth, @"motion": motion, @"camera": camera, @"temporal": temporal, @"reset":@(resetMotion)} mutableCopy];
    [inputs addEntriesFromDictionary:content];
    objc_setAssociatedObject(encoder, &taaInputsKey, inputs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    noteAssociation(encoder,AssocTAAInputs);
}
static id<MTLBuffer> probeReadback(id<MTLCommandBuffer> buffer, id<MTLTexture> outputTexture) {
    NSUInteger row = outputTexture.width * 8; // RGBA16Float, aligned for these scene dimensions.
    row = (row + 255) & ~NSUInteger(255);
    id<MTLBuffer> data = [buffer.device newBufferWithLength:row*outputTexture.height options:MTLResourceStorageModeShared];
    if (!data) return nil;
    id<MTLBlitCommandEncoder> encoder = [buffer blitCommandEncoder];
    [encoder copyFromTexture:outputTexture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(outputTexture.width,outputTexture.height,1) toBuffer:data destinationOffset:0
        destinationBytesPerRow:row destinationBytesPerImage:row*outputTexture.height];
    [encoder endEncoding];
    return data;
}
[[maybe_unused]] static NSDictionary *probeStatistics(id<MTLBuffer> data, id<MTLTexture> outputTexture) {
    if (!data) return @{};
    NSUInteger row = (outputTexture.width*8 + 255) & ~NSUInteger(255);
    NSUInteger samples=0, nonfinite=0, positive=0;
    float maximum=0;
    for (NSUInteger y=0; y<outputTexture.height; y+=17) for (NSUInteger x=0; x<outputTexture.width; x+=19) {
        const __fp16 *pixel = (const __fp16 *)((const uint8_t *)data.contents+y*row+x*8);
        for (int c=0; c<3; ++c) {
            float v = pixel[c]; ++samples;
            if (!std::isfinite(v)) ++nonfinite;
            else { if (v > 0) ++positive; maximum = std::fmax(maximum,v); }
        }
    }
    return @{@"sampledComponents": @(samples), @"nonfinite": @(nonfinite), @"positive": @(positive), @"maximum": @(maximum)};
}
static void probeScene(id<MTLCommandBuffer> buffer, NSDictionary *inputs) {
    // Claim the attempt under the lock, then release it before calling MetalFX.
    // Synchronous scaler initialization waits on workers which invoke our hooks.
    { std::lock_guard<std::recursive_mutex> lock(guard());
      if (sceneProbeAttempts) return;
      ++sceneProbeAttempts; }
    if (!buffer.retainedReferences) {
        record(@{@"event": @"sceneProbeSkipped", @"reason": @"BG3 uses an unretained command buffer; resource lifetime integration is required."});
        return;
    }
    id<MTLTexture> rawDepth = inputs[@"depth"];
    id<MTLTexture> color = inputs[@"color"], motion = inputs[@"motion"];
    // Metal forbids casting combined depth/stencil into a Depth32Float view.
    // Sample the original depth aspect and copy unchanged device depth to R32F.
    NSError *error = nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void BG3MFXCopyDepth(depth2d<float> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {"
        "if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;"
        "constexpr sampler s(coord::pixel, filter::nearest, address::clamp_to_edge);"
        "dst.write(float4(src.sample(s, float2(p)+0.5)), p); }";
    id<MTLLibrary> library = [buffer.device newLibraryWithSource:source options:nil error:&error];
    id<MTLComputePipelineState> copy = library ? [buffer.device newComputePipelineStateWithFunction:[library newFunctionWithName:@"BG3MFXCopyDepth"] error:&error] : nil;
    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
        width:rawDepth.width height:rawDepth.height mipmapped:NO];
    desc.storageMode = MTLStorageModePrivate;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> depth = [buffer.device newTextureWithDescriptor:desc];
    if (!copy || !depth || !(rawDepth.usage & MTLTextureUsageShaderRead) ||
        rawDepth.hazardTrackingMode == MTLHazardTrackingModeUntracked) {
        record(@{@"event": @"sceneProbeSkipped", @"reason": @"Device depth copy could not be prepared safely.", @"error": error.description ?: @"", @"depth": texture(rawDepth)}); return;
    }
    const float *camera = (const float *)[inputs[@"camera"] bytes];
    const float *temporal = (const float *)[inputs[@"temporal"] bytes];
    BG3MFXFrameParameters p = {};
    BG3MFXApplyTemporalJitter(&p, temporal[52], temporal[53]);
    p.motionScaleX = p.motionScaleY = -1;
    p.depthReversed = YES; p.reset = YES;
    float nearPlane = camera[48], farPlane = camera[49];
    float nearDepth = camera[26] + camera[30]/nearPlane;
    float farDepth = camera[26] + camera[30]/farPlane;
    if (!std::isfinite(nearDepth) || !std::isfinite(farDepth) || std::abs(nearDepth-1) > 0.001 ||
        std::abs(farDepth) > 0.001 || nearPlane <= 0 || farPlane <= nearPlane ||
        !std::isfinite(p.jitterX) || !std::isfinite(p.jitterY) || std::abs(p.jitterX) > 0.5 || std::abs(p.jitterY) > 0.5) {
        record(@{@"event": @"sceneProbeSkipped", @"reason": @"Unexpected perspective camera or jitter constants."}); return;
    }
    BG3MFXPipeline *scaler = [[BG3MFXPipeline alloc] initWithDevice:buffer.device inputWidth:color.width inputHeight:color.height
        outputWidth:color.width*2 outputHeight:color.height*2 colorFormat:color.pixelFormat depthFormat:depth.pixelFormat
        motionFormat:motion.pixelFormat outputFormat:MTLPixelFormatRGBA16Float error:&error];
    if (!scaler) {
        record(@{@"event": @"sceneProbeFailed", @"error": error.description ?: @"Scaler creation failed"}); return;
    }
    id<MTLComputeCommandEncoder> encoder = [buffer computeCommandEncoder];
    [encoder setComputePipelineState:copy];
    [encoder setTexture:rawDepth atIndex:0]; [encoder setTexture:depth atIndex:1];
    [encoder dispatchThreads:MTLSizeMake(depth.width,depth.height,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)];
    [encoder endEncoding];
    BG3MFXFrame *frame = scaler ? [scaler encodeColor:color depth:depth motion:motion parameters:p commandBuffer:buffer error:&error] : nil;
    if (!frame) {
        record(@{@"event": @"sceneProbeFailed", @"error": error.description ?: @"unknown", @"color": texture(color), @"depth": texture(depth), @"motion": texture(motion)}); return;
    }
    [[maybe_unused]] id<MTLBuffer> temporalPixels = probeReadback(buffer,frame.rendered);
    id<MTLTexture> taaColor = inputs[@"taaColor"];
    BG3MFXPipeline *spatial = [[BG3MFXPipeline alloc] initWithDevice:buffer.device mode:BG3MFXScalingModeSpatial
        colorProcessingMode:MTLFXSpatialScalerColorProcessingModeHDR inputWidth:taaColor.width inputHeight:taaColor.height
        outputWidth:taaColor.width*2 outputHeight:taaColor.height*2 colorFormat:taaColor.pixelFormat
        depthFormat:MTLPixelFormatInvalid motionFormat:MTLPixelFormatInvalid outputFormat:MTLPixelFormatRGBA16Float error:&error];
    BG3MFXFrame *spatialFrame = spatial ? [spatial encodeColor:taaColor depth:nil motion:nil parameters:p
        commandBuffer:buffer error:&error] : nil;
    [[maybe_unused]] id<MTLBuffer> spatialPixels = spatialFrame ? probeReadback(buffer,spatialFrame.rendered) : nil;
    record(@{@"event": spatialFrame ? @"spatialSceneProbeEncoded" : @"spatialSceneProbeFailed",
        @"input": texture(taaColor), @"output": texture(spatialFrame.rendered), @"error": spatialFrame ? @"" : (error.description ?: @"unknown"),
        @"limitation": @"HDR processing of post-TAA scene color; output not displayed; color interpretation needs validation."});
    // Keep the backend and result alive until GPU completion. Never substitute
    // this experimental output into BG3's display or tone-mapping path.
    [buffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        (void)completed;
        record(@{@"event": @"sceneProbeCompleted", @"status": @(completed.status), @"error": completed.error.description ?: @"",
                 @"output": texture(frame.rendered), @"backend": NSStringFromClass(scaler.class),
                 @"statistics": completed.status == MTLCommandBufferStatusCompleted ? probeStatistics(temporalPixels,frame.rendered) : @{}});
        if (spatialFrame) record(@{@"event": @"spatialSceneProbeCompleted", @"status": @(completed.status),
            @"error": completed.error.description ?: @"", @"backend": NSStringFromClass(spatial.class),
            @"output": texture(spatialFrame.rendered),
            @"statistics": completed.status == MTLCommandBufferStatusCompleted ? probeStatistics(spatialPixels,spatialFrame.rendered) : @{}});
    }];
    record(@{@"event": @"sceneProbeEncoded", @"output": texture(frame.rendered), @"jitter": @[@(p.jitterX),@(p.jitterY)],
             @"limitation": @"One reset frame; output is not displayed. Jitter sign and temporal image quality still require validation."});
}
static void captureFrameComposition(id encoder, const DrawCall &call) {
    if(encodingFrameGeneration) return;
    id<MTLCommandBuffer> buffer=encoderBuffer(encoder);
    if(!frameGeneration(buffer) && !frameInterpolator && !framePresenter) return;
    NSDictionary *state=pipelineDescription(encoder);
    if(!compositionShader(state[@"fragment"])) return;
    // Only BG3's own CombineUI or CombineUI_HDR reaches here, never the worker's copy draws.
    if(!frameGeneration(buffer)) { releaseFrameGeneration(); return; }
    NSDictionary *textures=boundTextures(encoder);
    id<MTLTexture> scene=textures[@"0"],ui=textures[@"1"],target=encoderTarget(encoder);
    NSDictionary *frames=objc_getAssociatedObject(buffer,&temporalFrameKey);
    NSDictionary *inputs=scene ? frames[[NSValue valueWithPointer:(__bridge const void *)scene]] : nil;
    // Never invent motion or attach an inventory camera by size. Menus, loading
    // screens, and any frame without TAA depth, motion and camera are presented
    // unpaired; pairing resumes with the next one that has them. The Video menu
    // holds Anti-Aliasing at TAA while Frame Generation is on.
    if(!inputs) {
#ifndef BG3MFX_NO_TRACE
        // With BG3MFX_TRACE_TEMPORAL_CHAIN, show which pass lost the scene.
        NSMutableArray *associated=[NSMutableArray array];
        for(NSDictionary *frame in frames.allValues) [associated addObject:texture(frame[@"taaColor"])];
        record(@{@"event":@"frameGenerationNoScene",@"scene":texture(scene),@"mode":@(encoderScalingMode(encoder)),
            @"associated":associated,@"passes":objc_getAssociatedObject(buffer,&temporalPassHistoryKey) ?: @[]});
#endif
        return;
    }
    id pipeline=encoderPipeline(encoder);
    NSUInteger size=[objc_getAssociatedObject(pipeline,&compositorSizeKey) unsignedIntegerValue];
    ConstantBinding *vertexBinding=constantSlot(encoder,StageVertex,0);
    NSData *vertexBytes=vertexBinding && vertexBinding->hasBytes ? encoderState(encoder)->bytes[@(StageVertex*EncoderSlots)] : nil;
    NSData *constants=size && size<=4096 ? constantBytes(encoder,StageFragment,0,size) : nil;
    id sampler=encoderSampler(encoder);
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    // The generated frame replays this draw with the interpolated scene, which
    // MetalFX produces at the scene's size; BG3's pipeline, viewport and
    // sampling map it onto the output, so scene, UI and output sizes may differ.
    // The pipeline fixes the output format, which follows the layer's (BGRA8Unorm
    // for SDR, BGR10A2Unorm for HDR).
    NSString *mismatch=!inputs[@"depth"] || !inputs[@"motion"] ? @"the scene has no depth or motion" :
        !pipeline || !constants || !sampler || !s ? @"its pipeline, constants or sampler were not captured" :
        !vertexBinding || (!vertexBinding->buffer && !vertexBytes) ? @"its vertices were not captured" :
        !ui || !target ? @"its UI or output texture was not captured" :
        scene.pixelFormat!=MTLPixelFormatRGB10A2Unorm ? @"unsupported scene format" : nil;
    if(mismatch) {
        declineFrameGeneration([NSString stringWithFormat:@"BG3's final scene/UI composition does not match the supported frame generation path: %@ "
            "(%@; scene %lux%lu format %lu, UI %lux%lu format %lu, output %lux%lu format %lu).",mismatch,state[@"fragment"],
            (unsigned long)scene.width,(unsigned long)scene.height,(unsigned long)scene.pixelFormat,(unsigned long)ui.width,(unsigned long)ui.height,
            (unsigned long)ui.pixelFormat,(unsigned long)target.width,(unsigned long)target.height,(unsigned long)target.pixelFormat]);return;
    }
    DrawCall draw=call; draw.indexBuffer=nil;
    NSMutableDictionary *request=[@{@"scene":scene,@"ui":ui,@"target":target,@"inputs":inputs,@"pipeline":pipeline,
        @"vertexOffset":@(vertexBinding->offset),@"constants":constants,@"sampler":sampler,
        @"draw":[NSData dataWithBytes:&draw length:sizeof(draw)]} mutableCopy];
    if(vertexBinding->buffer) request[@"vertices"]=vertexBinding->buffer; else request[@"vertexBytes"]=vertexBytes;
    if(call.indexBuffer) request[@"indexBuffer"]=call.indexBuffer;
    if(s->hasViewport) request[@"viewport"]=[NSData dataWithBytes:&s->viewport length:sizeof(s->viewport)];
    if(s->hasScissor) request[@"scissor"]=[NSData dataWithBytes:&s->scissor length:sizeof(s->scissor)];
    objc_setAssociatedObject(encoder,&frameCompositionKey,request,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    noteAssociation(encoder,AssocComposition);
}
static void drawInputs(id encoder, const DrawCall &call) {
    captureFrameComposition(encoder,call);
    NSDictionary *state = pipelineDescription(encoder);
    NSString *fragment = state[@"fragment"] ?: @"";
    int mode = encoderScalingMode(encoder);
    id<MTLCommandBuffer> encoderCommands = encoderBuffer(encoder);
    if (runtimeEnabled && sceneTracked(mode,encoderCommands) && ![fragment isEqualToString:@"PPTAA_PS"]) {
        id<MTLCommandBuffer> buffer = encoderCommands;
        NSDictionary *sceneFrames = objc_getAssociatedObject(buffer,&temporalFrameKey);
        id<MTLTexture> target = encoderTarget(encoder);
        bool tonemap = [fragment isEqualToString:@"FSR_Tonemap"];
        if ((sceneFrames.count || (mode == 2 && tonemap)) && target) {
            id<MTLTexture> source = boundTextures(encoder)[@"0"];
            NSDictionary *inputFrame = source ? sceneFrames[[NSValue valueWithPointer:(__bridge const void *)source]] : nil;
            NSMutableDictionary *next = [@{@"target":target} mutableCopy];
            if (inputFrame && source != target && source.width == target.width && source.height == target.height &&
                ((temporalColorPass(fragment) && source.pixelFormat == MTLPixelFormatRG11B10Float && target.pixelFormat == MTLPixelFormatRG11B10Float) ||
                 (frameGeneration(buffer) && [fragment isEqualToString:@"PPToneMap_LUT"]))) {
                next[@"frame"] = inputFrame; next[@"source"] = source; next[@"pipeline"] = fragment;
                if (tonemap) next[@"tonemap"] = @YES;
            }
            // Spatial needs only the color image. With SMAA or no anti-aliasing
            // there is no TAA pass to seed the chain, but FSR_Tonemap's input is
            // still the linear HDR scene color at render size that MetalFX scales.
            if (!next[@"frame"] && mode == 2 && tonemap && source && source != target &&
                source.width == target.width && source.height == target.height &&
                source.pixelFormat == MTLPixelFormatRG11B10Float && target.pixelFormat == MTLPixelFormatRG11B10Float) {
                next[@"frame"] = @{@"color":source,@"taaColor":source}; next[@"source"] = source;
                next[@"pipeline"] = fragment; next[@"tonemap"] = @YES;
            }
            // In-place scene passes (grading with bloom off, UI model VFX) draw onto an
            // already tagged image; keep its tag. An unrecognized draw later in the
            // same encoder still clears it (lastDrawOther, applied in endEncoder).
            NSDictionary *targetFrame = sceneFrames[[NSValue valueWithPointer:(__bridge const void *)target]];
            if (!next[@"frame"] && targetFrame && inPlaceScenePass(fragment) &&
                (sceneOverlayShader(fragment) || target.pixelFormat == MTLPixelFormatRG11B10Float)) {
                next[@"frame"] = targetFrame; next[@"source"] = target; next[@"pipeline"] = fragment; next[@"keep"] = @YES;
            }
            objc_setAssociatedObject(encoder,&temporalPostprocessKey,next,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            noteAssociation(encoder,AssocPostprocess);
        }
    }
    if (traceCalls || [fragment isEqualToString:@"PPTAA_PS"] || [fragment isEqualToString:@"LinearizeDepth"] || [fragment isEqualToString:@"VelocityBufferCamera_PS"])
        captureSceneInputs(encoder,fragment);
    if ([fragment isEqualToString:@"PPTAA_PS"] || [fragment isEqualToString:@"LinearizeDepth"] || [fragment isEqualToString:@"VelocityBufferCamera_PS"] ||
        [fragment isEqualToString:@"VelocityBufferCamera_PS"] || [fragment containsString:@"_VEL_"]) {
        if (traceCalls) record(@{@"event": @"drawInputs", @"pipeline": state,
                 @"bindings": objc_getAssociatedObject(encoder, &bindingsKey) ?: @{},
                 @"attachments": objc_getAssociatedObject(encoder, &attachmentsKey) ?: @{}});
    }
}
static BOOL suppressTemporalTAA(id encoder) {
    if (!runtimeEnabled || temporalFailed || encoderScalingMode(encoder) != 3) return NO;
    NSDictionary *state = pipelineDescription(encoder);
    if (![state[@"fragment"] isEqualToString:@"PPTAA_PS"] || !objc_getAssociatedObject(encoder,&taaInputsKey)) return NO;
    if (!knownUpscaledTAA(encoderTarget(encoder))) return NO;
    objc_setAssociatedObject(encoder,&temporalSuppressedKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    noteAssociation(encoder,AssocSuppressed);
    record(@{@"event":@"temporalNativeTAADrawSkipped",@"pipeline":state});
    return YES;
}
// FSR_Tonemap's rgb/(1+max(rgb)) compression, for a frame that falls back to
// native FSR after its draw was skipped.
static id<MTLComputePipelineState> fsrTonemapPipeline(id<MTLDevice> device) {
    static id<MTLComputePipelineState> compress;
    static bool failed;
    std::lock_guard<std::recursive_mutex> lock(guard());
    if (compress && compress.device == device) return compress;
    if (failed) return nil;
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void BG3MFXFSRTonemap(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]], uint2 p [[thread_position_in_grid]]) {"
        "if (p.x >= dst.get_width() || p.y >= dst.get_height()) return;"
        "float3 c = src.read(p).rgb; dst.write(float4(c / (1.0 + max(c.r, max(c.g, c.b))), 1.0), p); }";
    NSError *error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:source options:nil error:&error];
    compress = library ? [device newComputePipelineStateWithFunction:[library newFunctionWithName:@"BG3MFXFSRTonemap"] error:&error] : nil;
    if (!compress) { failed = true; record(@{@"event":@"fsrTonemapKernelFailed",@"error":error.localizedDescription ?: @""}); }
    return compress;
}
static char skippedTonemapKey;
// Targets of skipped FSR_Tonemap draws: render passes into them start with a
// deferred store action (renderEncoder) so a skipped pass stores nothing.
static NSHashTable *fsrTonemapTargets() {
    static NSHashTable *targets = [NSHashTable hashTableWithOptions:
        NSPointerFunctionsWeakMemory | NSPointerFunctionsObjectPointerPersonality];
    return targets;
}
// The postprocess association drawInputs just made says whether this is a
// tracked FSR_Tonemap draw whose input MetalFX will read.
static BOOL suppressFSRTonemap(id encoder) {
    if (!skipFSRTonemap) return NO;
    int mode = encoderScalingMode(encoder);
    if (!((mode == 2 && !spatialFailed) || (mode == 3 && !temporalFailed))) return NO;
    if (!(encoderAssociations(encoderState(encoder)) & AssocPostprocess)) return NO;
    NSDictionary *postprocess = objc_getAssociatedObject(encoder,&temporalPostprocessKey);
    if (![postprocess[@"tonemap"] boolValue] || !postprocess[@"frame"]) return NO;
    id<MTLTexture> source = postprocess[@"source"], target = postprocess[@"target"];
    id<MTLCommandBuffer> buffer = encoderBuffer(encoder);
    if (!buffer || !source || !target || !(source.usage & MTLTextureUsageShaderRead) ||
        !(target.usage & MTLTextureUsageShaderWrite) || !fsrTonemapPipeline(buffer.device)) return NO;
    NSMutableDictionary *skipped = objc_getAssociatedObject(buffer,&skippedTonemapKey);
    if (!skipped) {
        skipped = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(buffer,&skippedTonemapKey,skipped,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    skipped[[NSValue valueWithPointer:(__bridge const void *)target]] = source;
    { std::lock_guard<std::recursive_mutex> lock(guard()); [fsrTonemapTargets() addObject:target]; }
    if (__unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder)) s->tonemapSkipped = true;
    record(@{@"event":@"fsrTonemapDrawSkipped",@"source":texture(source),@"target":texture(target)});
    return YES;
}
static BOOL suppressNativeDraw(id encoder) {
    if (suppressTemporalTAA(encoder) || suppressFSRTonemap(encoder)) return YES;
    if (__unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder)) s->storeNeeded = true;
    return NO;
}
// Called just before a native FSR dispatch: if this frame skipped the
// FSR_Tonemap draw that wrote FSR's input, write that input now in the same
// encoder, then restore BG3's pipeline and texture bindings. Bypassing the
// hooks keeps the encoder's binding cache describing BG3's state.
static void restoreSkippedTonemap(id encoder, id<MTLCommandBuffer> buffer, NSDictionary *textures) {
    NSMutableDictionary *skipped = objc_getAssociatedObject(buffer,&skippedTonemapKey);
    id<MTLTexture> target = textures[@"0"];
    if (!skipped || !target) return;
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)target];
    id<MTLTexture> source = skipped[key];
    id compress = source ? fsrTonemapPipeline(buffer.device) : nil;
    id native = encoderPipeline(encoder);
    if (!compress || !native) return;
    [skipped removeObjectForKey:key];
    SEL setPipeline = @selector(setComputePipelineState:), setTexture = @selector(setTexture:atIndex:);
    SEL run = @selector(dispatchThreads:threadsPerThreadgroup:);
    auto bindPipeline = (void(*)(id,SEL,id))originalOrCurrent(encoder,setPipeline);
    auto bindTexture = (void(*)(id,SEL,id,NSUInteger))originalOrCurrent(encoder,setTexture);
    bindPipeline(encoder,setPipeline,compress);
    bindTexture(encoder,setTexture,source,0);
    bindTexture(encoder,setTexture,target,1);
    ((void(*)(id,SEL,MTLSize,MTLSize))originalOrCurrent(encoder,run))(encoder,run,
        MTLSizeMake(target.width,target.height,1),MTLSizeMake(8,8,1));
    // Serial encoders order the two dispatches through tracked hazards already.
    if ([(id<MTLComputeCommandEncoder>)encoder dispatchType] == MTLDispatchTypeConcurrent) {
        id<MTLResource> written[] = {target};
        [(id<MTLComputeCommandEncoder>)encoder memoryBarrierWithResources:written count:1];
    }
    bindPipeline(encoder,setPipeline,native);
    bindTexture(encoder,setTexture,target,0);
    bindTexture(encoder,setTexture,textures[@"1"],1);
    record(@{@"event":@"fsrTonemapRestored",@"source":texture(source),@"target":texture(target)});
}
// BG3's subsurface scattering blurs (PPSSSS_H/V) step through the kernel by
// P00 (horizontal) or P11 (vertical) x width / (2 x view depth) in target UV,
// which assumes NDC spans the whole target; in the reduced viewport it spans
// the region's share, so the blur reached 1/scale too far. For each draw,
// rebind the fragment PerCamera with those projection terms scaled by the
// viewport's share (the shaders read the projection only there), then restore
// BG3's binding.
struct SubsurfaceDraw {
    static constexpr NSUInteger PerCameraIndex = 11, PerCameraBytes = 224;
    __unsafe_unretained id encoder = nil;
    __unsafe_unretained id<MTLBuffer> buffer = nil;
    NSUInteger offset = 0;
    NSData *bytes = nil;
    explicit SubsurfaceDraw(__unsafe_unretained id e) {
        __unsafe_unretained BG3MFXEncoderState *s = encoderState(e);
        if (!s || !s->subsurface || !s->hasViewport) return;
        ConstantBinding *binding = constantSlot(e, StageFragment, PerCameraIndex);
        NSData *camera = binding ? constantBytes(e, StageFragment, PerCameraIndex, PerCameraBytes) : nil;
        if (!camera) return;
        float sx = float(s->viewport.width / s->colorTarget.width), sy = float(s->viewport.height / s->colorTarget.height);
        if (!(sx > 0 && sx < 1) && !(sy > 0 && sy < 1)) return;
        float params[PerCameraBytes / 4];
        memcpy(params, camera.bytes, sizeof params);
        params[16] *= sx;  // g_ProjectionMat column 0 .x
        params[21] *= sy;  // g_ProjectionMat column 1 .y
        static SEL setBytes = @selector(setFragmentBytes:length:atIndex:);
        ((void(*)(id,SEL,const void *,NSUInteger,NSUInteger))original(e,setBytes))(e,setBytes,params,sizeof params,PerCameraIndex);
        encoder = e;
        if (binding->hasBytes) bytes = s->bytes[@(StageFragment*EncoderSlots+PerCameraIndex)];
        else { buffer = binding->buffer; offset = binding->offset; }
        static std::atomic<int> reported{0};
        if (reported.fetch_add(1) < 8) record(@{@"event":@"subsurfaceScale", @"scale":@[@(sx),@(sy)]});
    }
    ~SubsurfaceDraw() {
        if (!encoder) return;
        if (bytes) {
            static SEL setBytes = @selector(setFragmentBytes:length:atIndex:);
            ((void(*)(id,SEL,const void *,NSUInteger,NSUInteger))original(encoder,setBytes))(encoder,setBytes,bytes.bytes,bytes.length,PerCameraIndex);
        } else {
            static SEL bind = @selector(setFragmentBuffer:offset:atIndex:);
            ((void(*)(id,SEL,id,NSUInteger,NSUInteger))original(encoder,bind))(encoder,bind,buffer,offset,PerCameraIndex);
        }
    }
};
// BG3 draws its surfaces (blood, water) on a screen-space grid whose vertices
// are NDC positions, placed by EngineParams' first matrix; the vertex shader
// projects them and passes the matching view-space ray on for depth
// reconstruction. BG3 chooses the grid cells in full-target coordinates that
// already account for the reduced render region, so the reduced viewport
// shrinks the grid toward the top-left a second time. For each draw, rebind
// the vertex EngineParams with that matrix stretched by the reduction about
// NDC (-1, 1), so the grid and its rays cover the region they were chosen for,
// then restore BG3's binding.
struct SurfaceGridDraw {
    __unsafe_unretained id encoder = nil;
    __unsafe_unretained id<MTLBuffer> buffer = nil;
    NSUInteger offset = 0;
    explicit SurfaceGridDraw(__unsafe_unretained id e) {
        __unsafe_unretained BG3MFXEncoderState *s = encoderState(e);
        if (!s || !s->surfaceGrid || !s->watchedBuffer || !s->hasViewport || s->watchedBuffer.storageMode == MTLStorageModePrivate ||
            s->watchedOffset + 160 > s->watchedBuffer.length) return;
        float sx = float(s->viewport.width / s->colorTarget.width), sy = float(s->viewport.height / s->colorTarget.height);
        if (!(sx > 0 && sx < 1) && !(sy > 0 && sy < 1)) return;
        float params[40];
        memcpy(params, static_cast<const char *>(s->watchedBuffer.contents) + s->watchedOffset, sizeof params);
        // M' = M * S, with x' = (x + 1) / sx - 1 and y' = 1 - (1 - y) / sy.
        for (int i = 0; i < 4; ++i) {
            params[12 + i] += params[i] * (1 / sx - 1) + params[4 + i] * (1 - 1 / sy);
            params[i] /= sx; params[4 + i] /= sy;
        }
        static SEL bytes = @selector(setVertexBytes:length:atIndex:);
        ((void(*)(id,SEL,const void *,NSUInteger,NSUInteger))original(e,bytes))(e,bytes,params,sizeof params,SurfaceEngineIndex);
        encoder = e; buffer = s->watchedBuffer; offset = s->watchedOffset;
        static std::atomic<int> reported{0};
        if (reported.fetch_add(1) < 8) record(@{@"event":@"surfaceGrid", @"scale":@[@(sx),@(sy)]});
    }
    ~SurfaceGridDraw() {
        if (!encoder) return;
        static SEL bind = @selector(setVertexBuffer:offset:atIndex:);
        ((void(*)(id,SEL,id,NSUInteger,NSUInteger))original(encoder,bind))(encoder,bind,buffer,offset,SurfaceEngineIndex);
    }
};
// Native compute with Frame Generation: carry the scene's association from
// FSR's input through its upscale and RCAS sharpening, as for the MetalFX
// outputs, and through CAS, the FidelityFX sharpening BG3 applies after tone
// mapping when no upscaler runs.
static char nativeFSRKey;
static void forwardNativeCompute(id encoder, NSString *name, NSDictionary *textures, id<MTLCommandBuffer> buffer, int mode) {
    NSMutableDictionary *frames = objc_getAssociatedObject(buffer,&temporalFrameKey);
    if ([name isEqualToString:@"CAS"]) {
        id<MTLTexture> source = textures[@"0"], target = textures[@"1"];
        NSDictionary *frame = source ? frames[[NSValue valueWithPointer:(__bridge const void *)source]] : nil;
        if (frame && target && target != source && target.width == source.width && target.height == source.height)
            frames[[NSValue valueWithPointer:(__bridge const void *)target]] = frame;
    } else if (mode != 1) {
        // Spatial and Temporal replace FSR and RCAS and attach their own output.
    } else if ([name isEqualToString:@"FSR"]) {
        id<MTLTexture> source = textures[@"0"], scaled = textures[@"1"];
        NSDictionary *frame = source ? frames[[NSValue valueWithPointer:(__bridge const void *)source]] : nil;
        objc_setAssociatedObject(encoder,&nativeFSRKey,frame && scaled ? @{@"frame":frame,@"scaled":scaled} : nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    } else if ([name isEqualToString:@"FSR_RCAS"]) {
        NSDictionary *pending = objc_getAssociatedObject(encoder,&nativeFSRKey);
        objc_setAssociatedObject(encoder,&nativeFSRKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        id<MTLTexture> destination = textures[@"2"];
        if (pending && pending[@"scaled"] == textures[@"0"] && destination)
            frames[[NSValue valueWithPointer:(__bridge const void *)destination]] = pending[@"frame"];
    }
}
// A compute dispatch: Spatial and Temporal replace BG3's FSR and RCAS.
static DispatchAction dispatch(id self, [[maybe_unused]] SEL cmd, NSString *pipelineName) {
    BOOL suppressNative = NO;
    NSDictionary *textures = boundTextures(self);
    NSDictionary *pending = objc_getAssociatedObject(self,&fsrInputsKey);
    id<MTLCommandBuffer> buffer = encoderBuffer(self);
    int mode = pending ? [pending[@"mode"] intValue] : encoderScalingMode(self);
    BOOL temporal = mode == 3;
    BOOL selectedMetalFX = (mode == 2 && runtimeEnabled) || (temporal && runtimeEnabled);
    if (selectedMetalFX) {
#ifndef BG3MFX_NO_TRACE
        // Diagnostic: BG3MFX_TEST_FAIL_METALFX=<seconds> fails the running
        // MetalFX upscaler once after that long, to exercise the fallback live.
        static const double failAfter = getenv("BG3MFX_TEST_FAIL_METALFX") ? atof(getenv("BG3MFX_TEST_FAIL_METALFX")) : 0;
        static double firstMetalFX = 0;
        static std::atomic<bool> forced{false};
        if (failAfter > 0 && !forced.load()) {
            double now = NSProcessInfo.processInfo.systemUptime;
            if (!firstMetalFX) firstMetalFX = now;
            if (now - firstMetalFX >= failAfter && !forced.exchange(true)) {
                if (temporal) failTemporal(@"Forced failure (BG3MFX_TEST_FAIL_METALFX).");
                else failSpatial(@"Forced failure (BG3MFX_TEST_FAIL_METALFX).");
            }
        }
#endif
        if (temporal ? temporalFailed : spatialFailed) goto native;
        if ([pipelineName isEqualToString:@"FSR"]) {
            id<MTLTexture> source = textures[@"0"], scaled = textures[@"1"];
            if (pending || !source || !scaled || !buffer) {
                if (temporal) failTemporal(@"Unexpected FSR scaling resources or dispatch sequence.");
                else failSpatial(@"Unexpected FSR scaling resources or dispatch sequence.");
                return DispatchDropped;
            }
            NSDictionary *frames = objc_getAssociatedObject(buffer,&temporalFrameKey);
            NSDictionary *frame = frames[[NSValue valueWithPointer:(__bridge const void *)source]];
            id<MTLTexture> spatialColor = frame[@"color"];
            if (temporal) {
                if (!frame || source != frame[@"taaColor"] || scaled.width < source.width || scaled.height < source.height) {
#ifndef BG3MFX_NO_TRACE
                    NSMutableArray *targets = [NSMutableArray array];
                    for (NSDictionary *candidate in frames.allValues) [targets addObject:texture(candidate[@"taaColor"])];
                    record(@{@"event":@"nativeMenuTemporalMismatch",@"source":texture(source),@"capturedTargets":targets,
                        @"passes":objc_getAssociatedObject(buffer,&temporalPassHistoryKey) ?: @[]});
#endif
                    fallBackToNative(self,YES,[NSString stringWithFormat:@"The native upscaling stage did not match the captured temporal scene inputs (%@).", !frame ? (objc_getAssociatedObject(buffer,&sceneCaptureFailureKey) ?: @"no matching scene color") : source != frame[@"taaColor"] ? @"different scene color target" : @"invalid output dimensions"]);
                    goto native;
                }
                if (!temporalSizeSettled(scalerKey(buffer.device,spatialColor.width,spatialColor.height,scaled.width,scaled.height))) {
                    fallBackToNative(self,YES,@"The output size is changing; waiting for it to settle before creating a Temporal scaler.");
                    goto native;
                }
            } else if (!spatialColor || spatialColor.width != source.width || spatialColor.height != source.height ||
                       spatialColor.pixelFormat != MTLPixelFormatRG11B10Float) {
                fallBackToNative(self,NO,@"Could not match FSR input to BG3's linear HDR scene color.");
                goto native;
            } else if (!temporal && !spatialSizeSettled(scalerKey(buffer.device,spatialColor.width,spatialColor.height,scaled.width,scaled.height))) {
                fallBackToNative(self,NO,@"The output size is changing; waiting for it to settle before creating a Spatial scaler.");
                goto native;
            }
            NSMutableDictionary *request = [@{@"input":temporal ? source : spatialColor,@"encodedInput":source,
                @"scaled":scaled,@"mode":@(mode)} mutableCopy];
            // Absent when Spatial was seeded at FSR_Tonemap without a TAA pass.
            if (frame[@"nativeTAA"]) request[@"nativeTAA"] = frame[@"nativeTAA"];
            objc_setAssociatedObject(self,&fsrInputsKey,request,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            noteAssociation(self,AssocFSRInputs);
            suppressNative = YES;
        } else if ([pipelineName isEqualToString:@"FSR_RCAS"]) {
            // The fallback frame keeps BG3's own sharpening pass too.
            if (!pending && objc_getAssociatedObject(self,&nativeFallbackKey)) goto native;
            if (pending && !pending[@"destination"] && pending[@"scaled"] == textures[@"0"] && textures[@"2"]) {
                NSMutableDictionary *complete = [pending mutableCopy]; complete[@"destination"] = textures[@"2"];
                objc_setAssociatedObject(self,&fsrInputsKey,complete,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                noteAssociation(self,AssocFSRInputs);
                suppressNative = YES;
            } else {
                if (temporal) failTemporal(@"Unexpected native FSR sharpening resources or dispatch sequence.");
                else failSpatial(@"Unexpected FSR sharpening resources or dispatch sequence.");
                return DispatchDropped;
            }
        } else if (pending) {
            if (temporal) failTemporal(@"An unexpected compute dispatch interrupted the MetalFX replacement.");
            else failSpatial(@"An unexpected compute dispatch interrupted the MetalFX replacement.");
            return DispatchDropped;
        }
    }
native:
    if (runtimeEnabled && buffer && frameGeneration(buffer)) forwardNativeCompute(self,pipelineName,textures,buffer,mode);
    if (suppressNative) {
        record(@{@"event":temporal ? @"temporalNativeDispatchSkipped" : @"spatialNativeDispatchSkipped",
            @"pipeline":pipelineDescription(self),
            @"method":NSStringFromSelector(cmd)});
        return DispatchSuppressed;
    }
    // Native FSR after a skipped FSR_Tonemap draw (a fallback frame) needs that pass's output.
    if (skipFSRTonemap && buffer && [pipelineName isEqualToString:@"FSR"]) restoreSkippedTonemap(self,buffer,textures);
    return DispatchNative;
}
// While Frame Generation is active BG3 renders into stand-in drawables (see
// layerNextDrawable). BG3 schedules its present before encoding CombineUI, so
// the decision waits for commit, once the generated pair exists. The original
// present never sees a stand-in.
static BOOL deferPresent(id buffer, SEL cmd, id drawable) {
    if (![BG3MFXFramePresenter presenterForStandIn:drawable]) return NO;
    if (objc_getAssociatedObject(buffer,&deferredPresentKey)) { [drawable present]; return YES; }
    objc_setAssociatedObject(buffer,&deferredPresentKey,@{@"method":NSStringFromSelector(cmd),@"drawable":drawable},
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return YES;
}
// With Frame Generation off, BG3 presents real drawables itself. Latency is
// measured from the buffer's commit, as for Frame Generation's stand-ins.
static char nativePresentKey;
static void logNativePresent(id buffer, id drawable) {
    if (!BG3MFXFrameLogEnabled()) return;
    BG3MFXFrameLogMethod(BG3MFXPresentNative);
    objc_setAssociatedObject(buffer,&nativePresentKey,drawable,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
// The Frame Generation presenter's own presents pass through these hooks too
// (they hook every queue's command buffers); they are not BG3 frames.
static PresentAction present(id self, SEL cmd, id drawable) {
    if([BG3MFXFramePresenter isPresentationThread]) return PresentUncounted;
    if(deferPresent(self,cmd,drawable)) return PresentHandled;
    BG3MFXFrameLogRendered(); logNativePresent(self,drawable);
    return PresentCounted;
}
static void commit(id<MTLCommandBuffer> self, SEL cmd) {
    // Dynamic resolution follows how busy BG3's command buffers keep the GPU.
    if (BG3MFXDynamicResolutionMeasuring() && ![BG3MFXFramePresenter isPresentationThread])
        [self addCompletedHandler:^(id<MTLCommandBuffer> done){
            BG3MFXDynamicResolutionGPUWork(done.GPUStartTime,done.GPUEndTime);
        }];
    if (id<MTLDrawable> shown=objc_getAssociatedObject(self,&nativePresentKey)) {
        objc_setAssociatedObject(self,&nativePresentKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CFTimeInterval committed=CACurrentMediaTime();
        if (BG3MFXFrameLogEnabled()) {
            [self addCompletedHandler:^(id<MTLCommandBuffer> done){
                BG3MFXFrameLogGPU(done.GPUStartTime,done.GPUEndTime,committed,CACurrentMediaTime());
            }];
        }
        [shown addPresentedHandler:^(id<MTLDrawable> d){
            BG3MFXFrameLogShown(NO,d.presentedTime);
            if (d.presentedTime>0) BG3MFXFrameLogLatency(d.presentedTime-committed,0);
        }];
    }
    NSDictionary *request=objc_getAssociatedObject(self,&deferredPresentKey);
    NSDictionary *pair=objc_getAssociatedObject(self,&generatedPairKey);
    objc_setAssociatedObject(self,&deferredPresentKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self,&generatedPairKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    id<CAMetalDrawable> drawable=request[@"drawable"];
    BOOL paired=drawable && pair && pair[@"target"]==drawable.texture;
    if (pair && !paired) [pair[@"presenter"] discardGeneratedTarget:pair[@"generated"] afterCommandBuffer:self];
    if (drawable) {
#ifndef BG3MFX_NO_TRACE
        // BG3's vsync option toggles displaySyncEnabled on its layer at runtime.
        static int lastDisplaySync=-1; int displaySync=drawable.layer.displaySyncEnabled;
        if (displaySync!=lastDisplaySync) {
            lastDisplaySync=displaySync; record(@{@"event":@"frameGenerationDisplaySync",@"enabled":@(displaySync)});
        }
#endif
        [[BG3MFXFramePresenter presenterForStandIn:drawable] submitStandIn:drawable generated:paired ? pair[@"generated"] : nil
            afterBuffer:self interval:[pair[@"interval"] doubleValue]];
        BG3MFXFrameLogRendered(); countPresent(drawable,cmd);
#ifndef BG3MFX_NO_TRACE
        // Includes any time this buffer waited on the GPU for Metal 4 work.
        [self addCompletedHandler:^(id<MTLCommandBuffer> done){ recordFrameGPU(done); }];
        unsigned deferred=++deferredPresents; paired ? ++pairedPresents : ++replayedPresents;
        if (deferred<=3 || deferred%120==0)
            record(@{@"event":@"frameGenerationPresentSummary",@"deferred":@(deferred),
                @"paired":@(pairedPresents.load()),@"unpaired":@(replayedPresents.load())});
#endif
    }
}
// Frame Generation hands BG3 a stand-in instead of a real drawable; the
// presenter's own thread still receives real ones.
// BG3's own maximumDrawableCount (2 for double-buffered vsync) while Frame
// Generation holds the layer at 3.
static char bg3DrawableCountKey;
static thread_local bool ownDrawableCountWrite=false;
static void setLayerDrawableCount(CAMetalLayer *layer, NSUInteger count) {
    ownDrawableCountWrite=true; layer.maximumDrawableCount=count; ownDrawableCountWrite=false;
}
// While Frame Generation holds the layer, BG3's own changes (switching between
// double- and triple-buffered vsync) are recorded instead of applied.
static void layerSetMaximumDrawableCount(id self, SEL cmd, NSUInteger count) {
    if (!ownDrawableCountWrite && objc_getAssociatedObject(self,&bg3DrawableCountKey)) {
        objc_setAssociatedObject(self,&bg3DrawableCountKey,@(count),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        record(@{@"event":@"frameGenerationDrawableCount",@"bg3":@(count)});
        return;
    }
    ((void(*)(id,SEL,NSUInteger))original(self,cmd))(self,cmd,count);
}
static id layerNextDrawable(id self, SEL cmd) {
    if ([BG3MFXFramePresenter isPresentationThread]) return ((id(*)(id,SEL))original(self,cmd))(self,cmd);
    CAMetalLayer *layer=self;
    if (!runtimeEnabled || frameGenerationDeclined || !BG3MFXFrameGenerationEnabled()) {
        NSNumber *saved=objc_getAssociatedObject(layer,&bg3DrawableCountKey);
        if (saved) {
            objc_setAssociatedObject(layer,&bg3DrawableCountKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            setLayerDrawableCount(layer,saved.unsignedIntegerValue);
            record(@{@"event":@"frameGenerationDrawableCount",@"restored":saved});
        }
        BG3MFXFrameLogBuffering((unsigned)layer.maximumDrawableCount,0);
        BOOL logWait=BG3MFXFrameLogEnabled();
        CFTimeInterval waitStart=logWait ? CACurrentMediaTime() : 0;
        id drawable=((id(*)(id,SEL))original(self,cmd))(self,cmd);
        if (logWait) BG3MFXFrameLogDrawableWait(CACurrentMediaTime()-waitStart);
        return drawable;
    }
    // Each rendered frame becomes two presents, which needs three drawables
    // (Apple's frame interpolation guidance). BG3 only renders into stand-ins
    // here, so its double-buffered setting would just starve the presenter.
    // BG3's value is kept (and updated by the setter hook) to restore later.
    if (!objc_getAssociatedObject(layer,&bg3DrawableCountKey)) {
        objc_setAssociatedObject(layer,&bg3DrawableCountKey,@(layer.maximumDrawableCount),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        record(@{@"event":@"frameGenerationDrawableCount",@"bg3":@(layer.maximumDrawableCount),@"forced":@3});
    }
    if (layer.maximumDrawableCount!=3) setLayerDrawableCount(layer,3);
    BG3MFXFramePresenter *presenter;
    { std::lock_guard<std::recursive_mutex> lock(guard());
      if (!framePresenter || framePresenter.pixelFormat!=layer.pixelFormat) {
          NSError *error=nil;
          framePresenter=[[BG3MFXFramePresenter alloc] initWithDevice:layer.device format:layer.pixelFormat error:&error];
          if (!framePresenter) { declineFrameGeneration(error.localizedDescription ?: @"Could not initialize frame presentation.");
              return ((id(*)(id,SEL))original(self,cmd))(self,cmd); }
          framePresenter.failureHandler=^(NSError *e){declineFrameGeneration(e.localizedDescription ?: @"Metal could not present a generated frame.");};
#ifndef BG3MFX_NO_TRACE
          BG3MFXGPUTimingHook=recordGPUSubmission;
          framePresenter.presentedHandler=^(BOOL generated, CFTimeInterval time, CFTimeInterval target, double interval){
              recordDisplayed(generated,time,target,interval); };
#endif
          record(@{@"event":@"frameGenerationPresenterCreated",@"format":@(layer.pixelFormat),
              @"displaySync":@(layer.displaySyncEnabled),@"maximumDrawableCount":@(layer.maximumDrawableCount)});
      }
      presenter=framePresenter; }
    // BG3's requested buffering limits its stand-ins (two for double-buffered
    // vsync) while the real layer stays at three for the presenter.
    return [presenter nextStandInForLayer:layer
        limit:[objc_getAssociatedObject(layer,&bg3DrawableCountKey) unsignedIntegerValue]];
}
// A recycled encoder object: drop what its previous user left.
static void encoderRecycled(id encoder, uint16_t stale) {
    if (stale & AssocFSRInputs) objc_setAssociatedObject(encoder, &fsrInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (stale & AssocComposition) objc_setAssociatedObject(encoder,&frameCompositionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (stale & AssocTAAInputs) objc_setAssociatedObject(encoder, &taaInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (stale & AssocPostprocess) objc_setAssociatedObject(encoder, &temporalPostprocessKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (stale & AssocSuppressed) objc_setAssociatedObject(encoder, &temporalSuppressedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
// A pass whose only attachment is a skipped FSR_Tonemap draw's target (BG3
// loads nothing into it) defers its store action to endEncoding.
static MTLRenderPassDescriptor *prepareRenderPass(MTLRenderPassDescriptor *desc, bool *deferStore) {
    if (!skipFSRTonemap || desc.colorAttachments[0].storeAction != MTLStoreActionStore || desc.colorAttachments[1].texture ||
        desc.depthAttachment.texture || desc.stencilAttachment.texture) return desc;
    std::lock_guard<std::recursive_mutex> lock(guard());
    if (!desc.colorAttachments[0].texture || ![fsrTonemapTargets() containsObject:desc.colorAttachments[0].texture]) return desc;
    MTLRenderPassDescriptor *pass = [desc copy];
    pass.colorAttachments[0].storeAction = MTLStoreActionUnknown;
    *deferStore = true;
    return pass;
}
static void encoderCreated(id encoder, id<MTLCommandBuffer> buffer, [[maybe_unused]] MTLRenderPassDescriptor *desc, bool deferStore) {
    if (deferStore && encoder) {
        __unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder);
        // Without a state record endEncoding could not resolve the store.
        if (s) { s->deferredStore = true; s->tonemapSkipped = s->storeNeeded = false; }
        else [(id<MTLRenderCommandEncoder>)encoder setColorStoreAction:MTLStoreActionStore atIndex:0];
    }
#ifndef BG3MFX_NO_TRACE
    if (encoder && desc && stencilDumpDirectory() && desc.depthAttachment.texture.pixelFormat == MTLPixelFormatDepth32Float_Stencil8)
        objc_setAssociatedObject(encoder, &stencilDepthKey, desc.depthAttachment.texture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#endif
    setEncoderMode(encoder, objc_getAssociatedObject(buffer, &bufferScalingModeKey));
}
static void commandBufferCreated(id<MTLCommandBuffer> buffer) {
    // Selection changes apply to the next command buffer. Sampling the live
    // menu independently at TAA and FSR could mix two render paths in one frame.
    objc_setAssociatedObject(buffer,&bufferScalingModeKey,@(BG3MFXSelectedScalingMode()),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Frame Generation combines with every Upscaling Type: it uses the camera,
    // depth and motion captured at BG3's TAA pass.
    bool frameGenerationSelected=BG3MFXFrameGenerationEnabled();
    if (!frameGenerationSelected) frameGenerationDeclined=false;
    objc_setAssociatedObject(buffer,&frameGenerationModeKey,@(frameGenerationSelected && !frameGenerationDeclined),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(buffer,&generatedPairKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(buffer,&deferredPresentKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(buffer,&temporalFrameKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#ifndef BG3MFX_NO_TRACE
    objc_setAssociatedObject(buffer,&temporalPassHistoryKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#endif
    objc_setAssociatedObject(buffer,&sceneCameraKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(buffer,&deviceDepthKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void endEncoding(id self, SEL cmd, BG3MFXEncoderState *encoderRecord, id<MTLCommandBuffer> commandBuffer, FinishEncoder finish) {
    if (__unsafe_unretained BG3MFXEncoderState *s = skipFSRTonemap ? encoderRecord : nil; s && s->deferredStore) {
        s->deferredStore = false;
        bool drop = s->tonemapSkipped && !s->storeNeeded && !s->anyDrawOther;
        [(id<MTLRenderCommandEncoder>)self setColorStoreAction:drop ? MTLStoreActionDontCare : MTLStoreActionStore atIndex:0];
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
        if (drop) ++fsrTonemapStoresDropped;
#endif
    }
#ifndef BG3MFX_NO_TRACE
    NSString *stencilRole = stencilDumpDirectory() ? objc_getAssociatedObject(self, &stencilRoleKey) : nil;
    id<MTLTexture> stencilDepth = stencilRole ? objc_getAssociatedObject(self, &stencilDepthKey) : nil;
#endif
    // Only keys this encoder may hold are read and cleared (most hold none).
    uint16_t associations = encoderAssociations(encoderRecord);
    NSDictionary *probeInputs = associations & AssocTAAInputs ? objc_getAssociatedObject(self, &taaInputsKey) : nil;
    NSDictionary *fsrInputs = associations & AssocFSRInputs ? objc_getAssociatedObject(self, &fsrInputsKey) : nil;
    NSDictionary *temporalInputs = probeInputs;
    NSDictionary *postprocess = associations & AssocPostprocess ? objc_getAssociatedObject(self,&temporalPostprocessKey) : nil;
    // A recognized pass followed by an unrecognized draw in the same encoder, or
    // an encoder of only unrecognized draws, overwrites its target: drop any
    // scene association for it (the per-draw logic this replaces did the same).
    if (encoderRecord && encoderRecord->lastDrawOther && encoderRecord->colorTarget) {
        if (sceneTracked(encoderScalingMode(self),commandBuffer)) postprocess = @{@"target":encoderRecord->colorTarget};
    }
    NSDictionary *composition=nil;
    if (associations & AssocComposition) {
        composition=objc_getAssociatedObject(self,&frameCompositionKey);
        objc_setAssociatedObject(self,&frameCompositionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    BOOL replaceTAA = associations & AssocSuppressed ? [objc_getAssociatedObject(self,&temporalSuppressedKey) boolValue] : NO;
#ifndef BG3MFX_NO_TRACE
    if (traceTemporalChain() && commandBuffer && sceneTracked(encoderScalingMode(self),commandBuffer)) {
        NSMutableArray *history = objc_getAssociatedObject(commandBuffer,&temporalPassHistoryKey);
        if (!history) {
            history = [NSMutableArray array];
            objc_setAssociatedObject(commandBuffer,&temporalPassHistoryKey,history,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        [history addObject:@{@"pipeline":pipelineDescription(self) ?: @{},
            @"bindings":[objc_getAssociatedObject(self,&bindingsKey) copy] ?: @{},
            @"attachments":objc_getAssociatedObject(self,&attachmentsKey) ?: @{},@"replacedTAA":@(replaceTAA)}];
        if (history.count > 64) [history removeObjectAtIndex:0];
    }
#endif
    // The driver may recycle this encoder immediately when MetalFX work starts.
    // Consume the request before any nested Metal call, including creation paths
    // displaced by later instrumentation which no longer run instrumentEncoder.
    if (associations & AssocFSRInputs) objc_setAssociatedObject(self, &fsrInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (associations & AssocSuppressed) objc_setAssociatedObject(self, &temporalSuppressedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (associations & AssocPostprocess) objc_setAssociatedObject(self, &temporalPostprocessKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    finish(self,cmd,encoderRecord,commandBuffer);
#ifndef BG3MFX_NO_TRACE
    if (stencilDepth && commandBuffer) dumpStencil(commandBuffer, stencilDepth, stencilRole);
#endif
    if (postprocess && commandBuffer) {
        NSMutableDictionary *sceneFrames = objc_getAssociatedObject(commandBuffer,&temporalFrameKey);
        id<MTLTexture> target = postprocess[@"target"];
        NSValue *targetKey = [NSValue valueWithPointer:(__bridge const void *)target];
        // Any render write invalidates a previous association with this target.
        // Forward only explicitly identified HDR scene-color passes, never a
        // same-size texture selected by a heuristic.
        [sceneFrames removeObjectForKey:targetKey];
        NSDictionary *inputFrame = postprocess[@"frame"];
        if ([postprocess[@"keep"] boolValue]) {
            // In-place scene pass: the target keeps the frame inputs it already had.
            sceneFrames[targetKey] = inputFrame;
            record(@{@"event":@"temporalColorKept",@"pipeline":postprocess[@"pipeline"],@"target":texture(target)});
        } else if (inputFrame) {
            if (!sceneFrames) {
                // A Spatial frame seeded at FSR_Tonemap has no earlier association.
                sceneFrames = [NSMutableDictionary dictionary];
                objc_setAssociatedObject(commandBuffer,&temporalFrameKey,sceneFrames,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            NSMutableDictionary *next = [inputFrame mutableCopy];
            next[@"taaColor"] = target;
            next[@"color"] = postprocess[@"tonemap"] ? postprocess[@"source"] : target;
            sceneFrames[targetKey] = next;
            record(@{@"event":@"temporalColorForwarded",@"pipeline":postprocess[@"pipeline"],
                @"source":texture(postprocess[@"source"]),@"target":texture(target)});
        }
    }
    if (runtimeEnabled && temporalInputs && commandBuffer && !temporalFailed) {
        BOOL temporalMode = encoderScalingMode(self) == 3;
        // Every mode but Temporal keeps native TAA; its output seeds the chain.
        BOOL spatialMode = !temporalMode && sceneTracked(encoderScalingMode(self),commandBuffer) && !replaceTAA;
        if (spatialMode) {
            NSMutableDictionary *frames = objc_getAssociatedObject(commandBuffer,&temporalFrameKey);
            if (!frames) {
                frames = [NSMutableDictionary dictionary];
                objc_setAssociatedObject(commandBuffer,&temporalFrameKey,frames,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            frames[[NSValue valueWithPointer:(__bridge const void *)temporalInputs[@"taaColor"]]] = temporalInputs;
        }
        if (temporalMode && (!replaceTAA || copyTemporalAAColor(commandBuffer,temporalInputs))) {
            NSMutableDictionary *frames = objc_getAssociatedObject(commandBuffer,&temporalFrameKey);
            if (!frames) {
                frames = [NSMutableDictionary dictionary];
                objc_setAssociatedObject(commandBuffer,&temporalFrameKey,frames,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            frames[[NSValue valueWithPointer:(__bridge const void *)temporalInputs[@"taaColor"]]] = temporalInputs;
        }
    }
    int replacementMode = [fsrInputs[@"mode"] intValue];
    if (replacementMode == 2 && fsrInputs && commandBuffer && !spatialFailed) {
        if (!fsrInputs[@"destination"])
            failSpatial(@"The FSR dispatch sequence ended before a MetalFX output was identified.");
        else if (upscaleSpatial(commandBuffer,fsrInputs)) {
            rememberUpscaledTAA(fsrInputs[@"nativeTAA"]);
            // As Temporal does, attach the frame's inputs to the upscaled output
            // so the tone-mapping chain carries them to BG3's composition.
            NSMutableDictionary *frames = objc_getAssociatedObject(commandBuffer,&temporalFrameKey);
            NSDictionary *frame = frames[[NSValue valueWithPointer:(__bridge const void *)fsrInputs[@"encodedInput"]]];
            if (frameGeneration(commandBuffer) && frame[@"depth"])
                frames[[NSValue valueWithPointer:(__bridge const void *)fsrInputs[@"destination"]]] = frame;
        }
    }
    if (replacementMode == 3 && fsrInputs && commandBuffer && !temporalFailed) {
        id<MTLTexture> destination = fsrInputs[@"destination"];
        NSMutableDictionary *frames = objc_getAssociatedObject(commandBuffer,&temporalFrameKey);
        NSValue *key = [NSValue valueWithPointer:(__bridge const void *)fsrInputs[@"input"]];
        NSDictionary *frame = frames[key];
        [frames removeObjectForKey:key];
        // Native FSR was already skipped for this frame, so it cannot run now;
        // leave the previous output for this one frame and restart history.
        if (!destination) { temporalResetPending=true;
            record(@{@"event":@"metalFXFrameSkipped",@"reason":@"The FSR stage ended before its final output texture was identified."}); }
        else if (!frame) { temporalResetPending=true;
            record(@{@"event":@"metalFXFrameSkipped",@"reason":@"The temporal scaler did not receive a matching scene color, depth, and motion frame."}); }
        else upscaleTemporal(commandBuffer,frame,destination);
    }
    if(composition && commandBuffer) encodeGeneratedPair(commandBuffer,composition);
    if (sceneProbe && probeInputs && commandBuffer) probeScene(commandBuffer,probeInputs);
    // Nested Metal work above may have set keys again: use the current bits.
    associations = encoderAssociations(encoderRecord);
    if (associations & AssocTAAInputs) objc_setAssociatedObject(self, &taaInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (associations & AssocFSRInputs) objc_setAssociatedObject(self, &fsrInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static MTLRenderPipelineDescriptor *prepareRenderPipeline(id device, MTLRenderPipelineDescriptor *desc) {
    desc = viewportFogDescriptor(device, desc);
#ifndef BG3MFX_NO_TRACE
    desc = surfaceDebugDescriptor(device, desc);
#endif
    return desc;
}
// Frame Generation replays the composition with constants of the size its
// shader declares.
static bool wantsReflection(MTLRenderPipelineDescriptor *desc) { return compositionShader(desc.fragmentFunction.name); }
static void renderPipelineCreated(MTLRenderPipelineDescriptor *desc, id state, MTLRenderPipelineReflection *reflection, BG3MFXPipelineInfo *info) {
    NSString *fragment = desc.fragmentFunction.name;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    if (reflection && compositionShader(fragment)) for (MTLArgument *arg in reflection.fragmentArguments)
        if (arg.type==MTLArgumentTypeBuffer && arg.index==0) objc_setAssociatedObject(state,&compositorSizeKey,@(arg.bufferDataSize),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#pragma clang diagnostic pop
    // Quiet runtime: pipelines keep their fragment name only when this renderer reads it.
    if (!info->description && recognizedFragment(fragment)) info->description = @{@"fragment":fragment};
    info->kind = classifyPipeline(fragment);
    classifyDynamicResolution(info, desc);
}
static bool recognizedCompute(NSString *name) {
    return [name isEqualToString:@"FSR"] || [name isEqualToString:@"FSR_RCAS"] || [name isEqualToString:@"CAS"];
}
static bool pipelineBound([[maybe_unused]] id self, BG3MFXEncoderState *s, BG3MFXPipelineInfo *info, NSDictionary *description) {
    if (s->deferredStore && ![description[@"fragment"] isEqualToString:@"FSR_Tonemap"]) s->storeNeeded = true;
#ifndef BG3MFX_NO_TRACE
    // Viewport reduction: where the first pipeline of each pass and the
    // depth-reconstructing surface passes rasterize.
    if (stencilDumpDirectory()) {
        NSString *fragment = description[@"fragment"] ?: @"";
        NSString *role = [fragment isEqualToString:@"DeferredDecal_ExtractNormal_PS"] ? @"normals" :
            [fragment isEqualToString:@"BG3MFXSurfaceDebug"] || [fragment isEqualToString:@"Shared_Surface_VFX_Surface_AlphaBlend_Fluid_ST_DEF_fragmentMain"] ? @"surfaces" : nil;
        if (role) objc_setAssociatedObject(self, &stencilRoleKey, role, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (BG3MFXDynamicResolutionInstalled() && BG3MFXDynamicResolutionArea() < 1) {
        NSString *fragment = description[@"fragment"] ?: @"";
        bool watched = [fragment containsString:@"_Surface_"] || [fragment isEqualToString:@"LinearizeDepth"] ||
            [fragment hasPrefix:@"DeferredDecal_"];
        if (!s->pipeline || watched) {
            const MTLViewport &v=s->viewport; const MTLScissorRect &r=s->scissor;
            NSDictionary *pass = @{@"fragment":fragment, @"firstPipeline":@(!s->pipeline),
                @"viewport":s->hasViewport ? @[@(v.originX),@(v.originY),@(v.width),@(v.height),@(v.znear),@(v.zfar)] : @[],
                @"scissor":s->hasScissor ? @[@(r.x),@(r.y),@(r.width),@(r.height)] : @[],
                @"target":s->colorTarget ? @[@(s->colorTarget.width),@(s->colorTarget.height)] : @[]};
            // Each distinct pass, viewport and target once.
            static NSMutableSet *seenPasses = [NSMutableSet set];
            bool fresh;
            { std::lock_guard<std::recursive_mutex> lock(guard()); fresh = seenPasses.count < 2000 && ![seenPasses containsObject:pass]; if (fresh) [seenPasses addObject:pass]; }
            if (fresh) {
                NSMutableDictionary *event = [pass mutableCopy];
                event[@"event"] = @"viewportReductionPass";
                record(event);
            }
        }
    }
#endif
    bool reduced = info && (info->rendererFlags & (FlagSurfaceGrid | FlagSubsurface)) && s->colorTarget && BG3MFXDynamicResolutionArea() < 1;
    s->surfaceGrid = reduced && (info->rendererFlags & FlagSurfaceGrid);
    s->subsurface = reduced && (info->rendererFlags & FlagSubsurface);
    return s->surfaceGrid || s->subsurface;
}
static void draw(id encoder, BG3MFXEncoderState *s, const DrawCall &call, void (^forward)(void)) {
    SubsurfaceDraw subsurfaceDraw(call.indexed ? nil : encoder);
    SurfaceGridDraw surfaceGridDraw(call.indexed ? encoder : nil);
    // Draws with unrecognized pipelines skip all inspection (call tracing
    // excepted). Their only effect, invalidating a scene association for the
    // encoder's color target, is applied once in endEncoding.
    if (!traceCalls && s) {
        if (s->kind == PipelineOther) { s->lastDrawOther = s->anyDrawOther = true; forward(); return; }
        s->lastDrawOther = false;
    }
    drawInputs(encoder,call);
    if (suppressNativeDraw(encoder)) return;
    forward();
}

namespace {
BOOL installRenderer(const BG3MFXFeatureContext &, NSError **error) {
    sceneProbe = diagnostics && getenv("BG3MFX_SCENE_PROBE") && strcmp(getenv("BG3MFX_SCENE_PROBE"),"1") == 0;
    skipFSRTonemap = runtimeEnabled && !(getenv("BG3MFX_SKIP_FSR_TONEMAP") && strcmp(getenv("BG3MFX_SKIP_FSR_TONEMAP"),"0") == 0);
    RendererExtension extension = {};
    extension.constantSlots = ConstantSlots;
    // Dynamic resolution installs later, with metalfx; its corrections check.
    extension.vertexBufferSlot = SurfaceEngineIndex;
    extension.commandBufferCreated = commandBufferCreated;
    extension.prepareRenderPass = prepareRenderPass;
    extension.encoderCreated = encoderCreated;
    extension.encoderRecycled = encoderRecycled;
    extension.endEncoding = endEncoding;
    extension.prepareRenderPipeline = prepareRenderPipeline;
    extension.wantsReflection = wantsReflection;
    extension.renderPipelineCreated = renderPipelineCreated;
    extension.recognizedCompute = recognizedCompute;
    extension.pipelineBound = pipelineBound;
    extension.draw = draw;
    extension.dispatch = dispatch;
    extension.present = present;
    extension.commit = commit;
    if (extendRenderer(extension)) return YES;
    if (error) *error = [NSError errorWithDomain:@"BG3MFX" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"metal-hooks did not accept the MetalFX renderer."}];
    return NO;
}
// Frame Generation's stand-in drawables.
BOOL activateRenderer(const BG3MFXFeatureContext &, NSError **) {
    @autoreleasepool {
        CAMetalLayer *layer=[CAMetalLayer layer];
        hook(layer,"nextDrawable",(IMP)layerNextDrawable);
        hook(layer,"setMaximumDrawableCount:",(IMP)layerSetMaximumDrawableCount);
    }
    return YES;
}
// With metalfx, which requires it. Not native, so the standalone hook
// regressions run it with BG3MFX_FEATURE_METALFX=1 outside BG3.
bool rendererWanted(const BG3MFXFeatureContext &) { return BG3MFXFeatureEnabled("BG3MFX_FEATURE_METALFX"); }
const char *const rendererRequires[] = {"metal-hooks", nullptr};
}
BG3MFX_FEATURE(metalFXRenderer, {"metalfx-renderer", rendererRequires, false, rendererWanted, installRenderer, activateRenderer});
#if !defined(BG3MFX_NO_TRACE) || defined(BG3MFX_STANDALONE_TEST_HOOKS)
extern "C" NSDictionary *BG3MFXStandaloneGeneratedPair(id<MTLCommandBuffer> buffer) {
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) return nil;
    return objc_getAssociatedObject(buffer,&generatedPairKey);
}
extern "C" NSUInteger BG3MFXStandaloneFSRTonemapStoresDropped(void) {
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) return 0;
    return fsrTonemapStoresDropped.load();
}
extern "C" NSUInteger BG3MFXStandaloneTemporalScalersCreated(void) {
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) return 0;
    return temporalScalersCreated.load();
}
extern "C" NSUInteger BG3MFXStandaloneFrameInterpolatorsCreated(void) {
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) return 0;
    return frameInterpolatorsCreated.load();
}
extern "C" NSUInteger BG3MFXStandalonePresentedPairs(void) {
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) return 0;
    return framePresenter.presentedPairs;
}
#endif
