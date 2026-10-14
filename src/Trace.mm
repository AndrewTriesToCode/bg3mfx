#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <objc/runtime.h>
#include <atomic>
#include <string>
#include <algorithm>
#include <vector>
#import "MetalFXPipeline.h"
#import "SpatialUpscaler.h"
#import "TemporalUpscaler.h"
#import "NativeMenu.h"
#import "FrameInterpolation.h"
#import "FrameLog.h"
#import "GPUResources.h"
#import <QuartzCore/CAMetalLayer.h>
#include <mach/mach_time.h>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <set>
#include <fcntl.h>
#include <unistd.h>
#include <dlfcn.h>

// Discover concrete driver classes from instances; never depend on an AGX class name.
// dyld may run the constructor before this translation unit's C++ initializers.
// Function-local statics guarantee initialization before the first hook/log call.
static std::recursive_mutex &guard() { static auto *value = new std::recursive_mutex; return *value; }
static std::map<std::pair<Class, SEL>, IMP> &originals() {
    static auto *value = new std::map<std::pair<Class, SEL>, IMP>;
    return *value;
}
static NSMutableSet<NSString *> *seen;
static NSFileHandle *output;
static unsigned long frames;
static unsigned long resourceCounter;
static char resourceKey, pipelineKey, bindingsKey, attachmentsKey;
static BOOL traceConstants;
#ifdef BG3MFX_NO_TRACE
static constexpr bool diagnostics = false;
// Compile away the arguments too: a no-op function would still construct the
// dictionaries, texture descriptions and strings on every intercepted call.
#define record(...) ((void)0)
#else
static constexpr bool diagnostics = true;
#endif
static NSMutableDictionary<NSString *, NSNumber *> *constantSamples;
static NSMutableDictionary<NSString *, NSDictionary *> *shaderBufferSizes;
static BOOL sceneProbe;
static BOOL metalFXEnabled;
static char bufferScalingModeKey;
static char frameGenerationModeKey, compositorSizeKey, frameCompositionKey, generatedPairKey;
static thread_local bool encodingFrameGeneration=false;
static char deferredPresentKey;
#ifndef BG3MFX_NO_TRACE
static std::atomic<unsigned> deferredPresents{0}, pairedPresents{0}, replayedPresents{0};
#endif
static bool frameGeneration(id buffer) { return [objc_getAssociatedObject(buffer,&frameGenerationModeKey) boolValue]; }
// Scene color, depth, motion and camera are associated with BG3's TAA output and
// followed through post-processing: for MetalFX Spatial and Temporal, and for
// every Upscaling Type while Frame Generation needs them at the composition.
static bool sceneTracked(int mode, id buffer) { return mode == 2 || mode == 3 || (buffer && frameGeneration(buffer)); }

// Per-encoder hook state, one object per encoder. BG3 issues about 12,000 draws
// and many more binds per frame; sampling showed half of its render thread in
// these hooks when they built strings and dictionaries per call. Binds now
// write fixed slots, and draws do real work only for the few pipelines the
// integration recognizes (classified once, at pipeline creation).
enum EncoderStage : uint8_t { StageVertex, StageFragment, StageCompute };
enum PipelineKind : uint8_t {
    PipelineOther, PipelineTAA, PipelineLinearizeDepth, PipelineVelocity,
    PipelinePostColor, PipelineToneMapLUT, PipelineCombineUI,
};
// Bound buffers, textures and the pipeline are not retained
// here: the encoder (from a retained-references command buffer; see
// commandBuffer) keeps everything bound to it alive until it ends, and BG3 keeps
// its pipeline states. That avoids a retain/release pair on every bind.
struct ConstantBinding { __unsafe_unretained id<MTLBuffer> buffer; NSUInteger offset; NSUInteger length; bool hasBytes; };
static constexpr NSUInteger EncoderSlots = 32;
// BG3's composition draw call, replayed for the generated frame.
struct CompositionDraw {
    MTLPrimitiveType type; NSUInteger start, count, instances, baseInstance; NSInteger baseVertex;
    __unsafe_unretained id<MTLBuffer> indexBuffer; NSUInteger indexOffset; MTLIndexType indexType;
};
@interface BG3MFXEncoderState : NSObject {
@public
    ConstantBinding constants[3][EncoderSlots];
    __unsafe_unretained id<MTLTexture> textures[EncoderSlots];
    __unsafe_unretained id pipeline;
    __strong NSDictionary *description;  // diagnostics may create one per pipeline set
    PipelineKind kind;
    __strong id<MTLCommandBuffer> buffer;
    // setBytes data by stage*EncoderSlots+index; rare, so the binding table
    // itself owns nothing and costs nothing to destroy (one per encoder).
    __strong NSMutableDictionary<NSNumber *, NSData *> *bytes;
    __strong id<MTLTexture> colorTarget;
    __unsafe_unretained id sampler0;
    int mode;            // command buffer's scaling mode; -1 when unknown
    bool lastDrawOther;  // the latest draw used an unrecognized pipeline
    // BG3's viewport and scissor, replayed for the generated composition.
    bool hasViewport, hasScissor;
    MTLViewport viewport;
    MTLScissorRect scissor;
}
@end
@implementation BG3MFXEncoderState
- (instancetype)init { if ((self=[super init])) mode=-1; return self; }
@end
static char encoderStateKey, pipelineKindKey;
// Encoders are used one at a time on a thread, so remember the last lookup.
// instrumentEncoder refreshes and endEncoder clears it, so a recycled encoder
// address never returns a previous encoder's state.
static thread_local __unsafe_unretained id cachedEncoder;
static thread_local __unsafe_unretained BG3MFXEncoderState *cachedState;
static BG3MFXEncoderState *encoderState(__unsafe_unretained id encoder) {
    if (!encoder) return nil;
    if (encoder == cachedEncoder) return cachedState;
    BG3MFXEncoderState *state = objc_getAssociatedObject(encoder,&encoderStateKey);
    cachedEncoder = encoder; cachedState = state;
    return state;
}
static void forgetEncoder(id encoder) { if (encoder == cachedEncoder) { cachedEncoder = nil; cachedState = nil; } }
// Encoders from paths not instrumented have no state; field reads through a
// nil object pointer would crash, unlike messages to nil.
static id<MTLCommandBuffer> encoderBuffer(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->buffer : nil; }
static id<MTLTexture> encoderTarget(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->colorTarget : nil; }
static NSDictionary *pipelineDescription(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->description : nil; }
static id encoderPipeline(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->pipeline : nil; }
static id encoderSampler(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->sampler0 : nil; }
static void setEncoderMode(id encoder, NSNumber *mode) {
    if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder)) s->mode=mode ? mode.intValue : -1;
}
static int encoderScalingMode(__unsafe_unretained id encoder) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    return s && s->mode>=0 ? s->mode : BG3MFXSelectedScalingMode();
}
// Bound textures by index, as a dictionary for the few recognized passes.
static NSDictionary *boundTextures(id encoder) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    if (!s) return nil;
    NSMutableDictionary *textures=[NSMutableDictionary dictionary];
    for (NSUInteger i=0;i<EncoderSlots;++i) if (s->textures[i]) textures[@(i).stringValue]=s->textures[i];
    return textures;
}
// BG3 composes scene and UI with CombineUI, or CombineUI_HDR when HDR output
// is enabled; both take the same scene, UI, constants and sampler bindings.
static BOOL compositionShader(NSString *fragment) {
    return [fragment isEqualToString:@"CombineUI"] || [fragment isEqualToString:@"CombineUI_HDR"];
}
static PipelineKind classifyPipeline(NSString *fragment) {
    if ([fragment isEqualToString:@"PPTAA_PS"]) return PipelineTAA;
    if ([fragment isEqualToString:@"LinearizeDepth"]) return PipelineLinearizeDepth;
    if ([fragment isEqualToString:@"VelocityBufferCamera_PS"]) return PipelineVelocity;
    if ([fragment isEqualToString:@"PPToneMap_LUT"]) return PipelineToneMapLUT;
    if (compositionShader(fragment)) return PipelineCombineUI;
    if ([fragment isEqualToString:@"PPBloomUpsampleBlurAndCombine_PS"] || [fragment isEqualToString:@"PPColorGradingApplyLUTPS"] ||
        [fragment isEqualToString:@"EoCOutlineCombinePS"] || [fragment isEqualToString:@"FSR_Tonemap"]) return PipelinePostColor;
    return PipelineOther;
}
static bool temporalInputsNeeded(__unsafe_unretained id encoder) {
    (void)encoder;
    return diagnostics || metalFXEnabled;
}
static bool constantInputNeeded(__unsafe_unretained id encoder, NSUInteger index) {
    return index < 32 && (diagnostics || (temporalInputsNeeded(encoder) && (index == 0 || index == 8 || index == 9 || index == 11)));
}
static NSUInteger sceneProbeAttempts;
static char deviceDepthKey, sceneCaptureFailureKey, sceneCameraKey, taaInputsKey;
static char fsrInputsKey, nativeFallbackKey;
// A frame whose FSR input matches no captured scene (loading, view or size
// transitions) runs BG3's native FSR instead of closing the game. Temporal
// history restarts on the next MetalFX frame.
static std::atomic<bool> temporalResetPending{false};
#ifndef BG3MFX_NO_TRACE
static void record(NSDictionary *event);
#endif
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
        [name isEqualToString:@"FSR_Tonemap"];
}
#ifndef BG3MFX_NO_TRACE
static char temporalPassHistoryKey;
#endif
static BOOL spatialFailed;
static BOOL temporalFailed;
static IMP original(__unsafe_unretained id object, SEL selector);

static EncoderStage bindingStage(SEL cmd) {
    static SEL vertex[]={@selector(setVertexBuffer:offset:atIndex:),@selector(setVertexBuffers:offsets:withRange:),
        @selector(setVertexBufferOffset:atIndex:),@selector(setVertexBytes:length:atIndex:)};
    static SEL fragment[]={@selector(setFragmentBuffer:offset:atIndex:),@selector(setFragmentBuffers:offsets:withRange:),
        @selector(setFragmentBufferOffset:atIndex:),@selector(setFragmentBytes:length:atIndex:)};
    for (SEL v:vertex) if (cmd==v) return StageVertex;
    for (SEL f:fragment) if (cmd==f) return StageFragment;
    return StageCompute;
}
static ConstantBinding *constantSlot(__unsafe_unretained id encoder, EncoderStage stage, NSUInteger index) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    return s && index<EncoderSlots ? &s->constants[stage][index] : nullptr;
}
// Dictionary view ("fragment:8" -> buffer/offset or bytes/length), diagnostics only.
static NSMutableDictionary *constantBindings(id encoder) {
    NSMutableDictionary *bindings=[NSMutableDictionary dictionary];
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    static NSString *const stages[]={@"vertex",@"fragment",@"compute"};
    if (s) for (int stage=0;stage<3;++stage) for (NSUInteger i=0;i<EncoderSlots;++i) {
        ConstantBinding &b=s->constants[stage][i];
        NSString *slot=[NSString stringWithFormat:@"%@:%lu",stages[stage],(unsigned long)i];
        NSData *data=b.hasBytes ? s->bytes[@(stage*EncoderSlots+i)] : nil;
        if (data) bindings[slot]=@{@"bytes":data,@"length":@(b.length)};
        else if (b.buffer) bindings[slot]=@{@"buffer":b.buffer,@"offset":@(b.offset)};
    }
    return bindings;
}
static void bindBuffer(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset, NSUInteger index) {
    ((void(*)(id,SEL,id,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,buffer,offset,index);
    if (!constantInputNeeded(self,index)) return;
    if (ConstantBinding *b=constantSlot(self,bindingStage(cmd),index)) { b->buffer=buffer; b->offset=offset; b->hasBytes=false; b->length=0; }
}
static void bindBuffers(__unsafe_unretained id self, SEL cmd, id<MTLBuffer> const *buffers, const NSUInteger *offsets, NSRange range) {
    ((void(*)(id,SEL,id<MTLBuffer> const *,const NSUInteger *,NSRange))original(self,cmd))(self,cmd,buffers,offsets,range);
    if (!temporalInputsNeeded(self)) return;
    EncoderStage stage=bindingStage(cmd);
    for (NSUInteger i=0; i<range.length; ++i) {
        if (!constantInputNeeded(self,range.location+i)) continue;
        if (ConstantBinding *b=constantSlot(self,stage,range.location+i)) { b->buffer=buffers[i]; b->offset=offsets[i]; b->hasBytes=false; b->length=0; }
    }
}
static void bufferOffset(__unsafe_unretained id self, SEL cmd, NSUInteger offset, NSUInteger index) {
    ((void(*)(id,SEL,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,offset,index);
    if (!constantInputNeeded(self,index)) return;
    if (ConstantBinding *b=constantSlot(self,bindingStage(cmd),index)) if (b->buffer) b->offset=offset;
}
static void bindBytes(__unsafe_unretained id self, SEL cmd, const void *bytes, NSUInteger length, NSUInteger index) {
    ((void(*)(id,SEL,const void *,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,bytes,length,index);
    if (!constantInputNeeded(self,index)) return;
    EncoderStage stage=bindingStage(cmd);
    if (ConstantBinding *b=constantSlot(self,stage,index)) {
        __unsafe_unretained BG3MFXEncoderState *s=encoderState(self);
        b->buffer=nil; b->offset=0; b->hasBytes=bytes && length; b->length=b->hasBytes ? length : 0;
        if (b->hasBytes) {
            if (!s->bytes) s->bytes=[NSMutableDictionary dictionary];
            s->bytes[@(stage*EncoderSlots+index)]=[NSData dataWithBytes:bytes length:MIN(length,4096)];
        }
    }
}
#ifndef BG3MFX_NO_TRACE
static void record(NSDictionary *event) {
    std::lock_guard<std::recursive_mutex> lock(guard());
    NSString *kind = event[@"event"];
    BOOL important = [kind hasPrefix:@"nativeMenu"] || [kind isEqualToString:@"nativeUpscalingApplied"] ||
        [kind isEqualToString:@"nativeQualityChanged"] || [kind hasPrefix:@"waterfall"] ||
        [kind isEqualToString:@"upscalingModeChanged"] || [kind isEqualToString:@"metalHUDChanged"] ||
        [kind isEqualToString:@"temporalValidationProgress"] || [kind isEqualToString:@"temporalScalerCreated"] || [kind hasPrefix:@"frameGeneration"] || [kind isEqualToString:@"nativeMenuOption"];
    if (!output || (!important && seen.count >= 20000 &&
        ![event[@"event"] isEqualToString:@"spatialUpscaleError"] &&
        ![event[@"event"] isEqualToString:@"temporalUpscaleError"])) return;
    NSMutableDictionary *identified = [event mutableCopy];
    identified[@"pid"] = @(getpid());
    if (important) identified[@"time"] = @(NSDate.timeIntervalSinceReferenceDate);
    NSData *data = [NSJSONSerialization dataWithJSONObject:identified options:NSJSONWritingSortedKeys error:nil];
    if (!data) return;
    NSString *key = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    NSMutableData *line = [data mutableCopy];
    [line appendData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
    [output writeData:line];
}
#endif
#ifndef BG3MFX_NO_TRACE
static char waterfallCopiesKey;
static NSDictionary *waterfallLayout(MTLRenderPipelineDescriptor *desc) {
    if (![desc.vertexFunction.name containsString:@"Water_Fall_Foam_STI_"]) return nil;
    NSMutableArray *attributes=[NSMutableArray array], *layouts=[NSMutableArray array];
    for (NSUInteger i=0;i<31;++i) {
        MTLVertexAttributeDescriptor *a=desc.vertexDescriptor.attributes[i];
        if (a.format!=MTLVertexFormatInvalid) [attributes addObject:@{@"attribute":@(i),@"format":@(a.format),@"offset":@(a.offset),@"buffer":@(a.bufferIndex)}];
        MTLVertexBufferLayoutDescriptor *l=desc.vertexDescriptor.layouts[i];
        if (l.stride) [layouts addObject:@{@"buffer":@(i),@"stride":@(l.stride),@"stepFunction":@(l.stepFunction),@"stepRate":@(l.stepRate)}];
    }
    return @{@"attributes":attributes,@"layouts":layouts};
}
static void captureWaterfall(id encoder, NSDictionary *draw) {
    const char *directory=getenv("BG3MFX_CAPTURE_WATERFALL");
    if (!directory || !*directory) return;
    NSDictionary *pipelineState=pipelineDescription(encoder);
    NSString *vertex=pipelineState[@"vertex"];
    if (![vertex containsString:@"Water_Fall_Foam_STI_DEP_vertexMain"] &&
        ![vertex containsString:@"Water_Fall_Foam_STI_VEL_vertexMain"]) return;
    std::lock_guard<std::recursive_mutex> lock(guard());
    static NSMutableDictionary *counts=[NSMutableDictionary dictionary];
    static NSUInteger totalBytes=0, serial=0;
    NSString *key=[NSString stringWithFormat:@"%d:%@",encoderScalingMode(encoder),vertex];
    NSUInteger count=[counts[key] unsignedIntegerValue];
    if (count>=4) return;
    counts[key]=@(count+1);
    NSString *root=[NSString stringWithUTF8String:directory];
    if (![root isAbsolutePath]) return;
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *stem=[NSString stringWithFormat:@"draw-%lu-mode-%d",(unsigned long)serial++,encoderScalingMode(encoder)];
    NSMutableDictionary *bindings=[constantBindings(encoder) mutableCopy];
    id<MTLBuffer> indexBuffer=draw[@"indexBuffer"];
    if (indexBuffer) bindings[@"index"]=@{@"buffer":indexBuffer,@"offset":draw[@"indexOffset"] ?: @0};
    NSMutableDictionary *snapshots=[NSMutableDictionary dictionary];
    NSMutableArray *copies=objc_getAssociatedObject(encoder,&waterfallCopiesKey);
    if (!copies) { copies=[NSMutableArray array]; objc_setAssociatedObject(encoder,&waterfallCopiesKey,copies,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    for (NSString *slot in bindings) {
        BOOL index=[slot isEqualToString:@"index"];
        NSUInteger slotIndex=[slot componentsSeparatedByString:@":"].lastObject.integerValue;
        BOOL stream=NO;
        for (NSDictionary *layout in pipelineState[@"vertexLayout"][@"layouts"])
            if ([layout[@"buffer"] unsignedIntegerValue]==slotIndex) stream=YES;
        if (!index && (![slot hasPrefix:@"vertex:"] || (!stream && slotIndex!=20 && slotIndex!=13 && slotIndex!=11 && slotIndex!=8))) continue;
        NSDictionary *binding=bindings[slot]; id<MTLBuffer> buffer=binding[@"buffer"];
        NSUInteger offset=[binding[@"offset"] unsignedIntegerValue];
        NSData *bytes=binding[@"bytes"];
        NSUInteger length=buffer ? (offset<=buffer.length ? buffer.length-offset:0) : bytes.length;
        NSUInteger limit=index || stream ? 8*1024*1024UL : (slotIndex==20 ? 64 : (slotIndex==13 ? 32 : 224));
        NSUInteger captured=MIN(length,limit);
        if (totalBytes+captured>128*1024*1024UL) captured=0;
        totalBytes+=captured;
        NSString *file=[stem stringByAppendingFormat:@"-%@.bin",[slot stringByReplacingOccurrencesOfString:@":" withString:@"-"]];
        snapshots[slot]=@{@"file":file,@"offset":@(offset),@"availableLength":@(length),@"capturedLength":@(captured),@"storage":buffer ? @(buffer.storageMode):@(-1)};
        if (!captured) continue;
        if (bytes) [[bytes subdataWithRange:NSMakeRange(0,captured)] writeToFile:[root stringByAppendingPathComponent:file] atomically:YES];
        else if (buffer.storageMode==MTLStorageModeShared && buffer.contents)
            [[NSData dataWithBytes:(const uint8_t *)buffer.contents+offset length:captured] writeToFile:[root stringByAppendingPathComponent:file] atomically:YES];
        else if (buffer.storageMode==MTLStorageModePrivate)
            [copies addObject:@{@"buffer":buffer,@"offset":@(offset),@"length":@(captured),@"path":[root stringByAppendingPathComponent:file]}];
    }
    NSMutableDictionary *drawInfo=[draw mutableCopy]; [drawInfo removeObjectForKey:@"indexBuffer"];
    NSDictionary *info=@{@"pipeline":pipelineState,@"mode":@(encoderScalingMode(encoder)),@"draw":drawInfo,@"bindings":snapshots,
        @"limitation":@"Bounded buffer capture; noise texture is not captured. Private buffers copied after this encoder."};
    [[NSJSONSerialization dataWithJSONObject:info options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[root stringByAppendingPathComponent:[stem stringByAppendingString:@".json"]] atomically:YES];
    record(@{@"event":@"waterfallDrawCaptured",@"path":[root stringByAppendingPathComponent:[stem stringByAppendingString:@".json"]],@"mode":@(encoderScalingMode(encoder))});
}
static void finishWaterfallCopies(id<MTLCommandBuffer> commandBuffer, NSArray *copies) {
    if (!commandBuffer || !copies.count) return;
    id<MTLBlitCommandEncoder> blit=[commandBuffer blitCommandEncoder];
    NSMutableArray *results=[NSMutableArray array];
    for (NSDictionary *copy in copies) {
        NSUInteger length=[copy[@"length"] unsignedIntegerValue];
        id<MTLBuffer> readback=[commandBuffer.device newBufferWithLength:length options:MTLResourceStorageModeShared];
        if (!readback) continue;
        [blit copyFromBuffer:copy[@"buffer"] sourceOffset:[copy[@"offset"] unsignedIntegerValue] toBuffer:readback destinationOffset:0 size:length];
        [results addObject:@{@"buffer":readback,@"path":copy[@"path"]}];
    }
    [blit endEncoding];
    [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (completed.status!=MTLCommandBufferStatusCompleted) return;
        for (NSDictionary *result in results) {
            id<MTLBuffer> readback=result[@"buffer"];
            [[NSData dataWithBytes:readback.contents length:readback.length] writeToFile:result[@"path"] atomically:YES];
        }
    }];
}
#endif
// Every hook calls this; a locked map search per call was measurable on BG3's
// render thread. Cache per thread; any change to originals() bumps the generation.
static std::atomic<unsigned> originalsGeneration{1};
static IMP original(__unsafe_unretained id object, SEL selector) {
    struct Entry { Class cls; SEL selector; IMP imp; unsigned generation; };
    static thread_local Entry cache[256];
    Class concrete = object_getClass(object);
    unsigned generation = originalsGeneration.load(std::memory_order_acquire);
    Entry &entry = cache[((uintptr_t)concrete >> 4 ^ (uintptr_t)selector >> 2) & 255];
    if (entry.cls == concrete && entry.selector == selector && entry.generation == generation) return entry.imp;
    std::lock_guard<std::recursive_mutex> lock(guard());
    for (Class cls = concrete; cls; cls = class_getSuperclass(cls)) {
        auto it = originals().find({cls, selector});
        if (it != originals().end()) { entry = {concrete, selector, it->second, generation}; return it->second; }
    }
    abort();
}
static void hook(id object, const char *name, IMP replacement) {
    if (!object) return;
    std::lock_guard<std::recursive_mutex> lock(guard());
    Class cls = object_getClass(object);
    SEL selector = sel_registerName(name);
    if (originals().count({cls, selector})) return;
    // If a superclass is already hooked, leave inherited dispatch alone.
    // Some driver methods are resolved lazily. Ask the instance first so the
    // runtime has a chance to install a supported selector before inspection.
    if (![object respondsToSelector:selector]) return;
    Method method = class_getInstanceMethod(cls, selector);
    if (!method || method_getImplementation(method) == replacement) return;
    originals()[{cls, selector}] = method_getImplementation(method);
    originalsGeneration.fetch_add(1, std::memory_order_release);
    class_replaceMethod(cls, selector, replacement, method_getTypeEncoding(method));
}
static NSDictionary *texture(id<MTLTexture> t) {
    if (!t) return @{};
    std::lock_guard<std::recursive_mutex> lock(guard());
    NSNumber *identifier = objc_getAssociatedObject(t, &resourceKey);
    if (!identifier) {
        identifier = @(++resourceCounter);
        objc_setAssociatedObject(t, &resourceKey, identifier, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return @{@"id": identifier, @"label": t.label ?: @"", @"width": @(t.width), @"height": @(t.height),
             @"format": @(t.pixelFormat), @"usage": @(t.usage), @"storage": @(t.storageMode),
             @"hazardTracking": @(t.hazardTrackingMode)};
}
static void label(id self, SEL cmd, NSString *value) {
    ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,value);
    if (value.length) record(@{@"event": @"label", @"class": NSStringFromClass(object_getClass(self)), @"value": value});
}
static void group(id self, SEL cmd, NSString *value) {
    ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,value);
    if (value.length) record(@{@"event": @"group", @"value": value});
}
static void rememberTexture(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id<MTLTexture> t, NSUInteger index) {
    (void)cmd; // Only diagnostic builds include the selector in event records.
    if (!diagnostics) {
        int mode = encoderScalingMode(self);
        // Metal permits textures to be bound before pipeline state. Retain the
        // three required slots independently of shader identification.
        if ((!metalFXEnabled && mode != 2) || index > 2) return;
    }
    if ((sceneProbe || metalFXEnabled) && index < EncoderSlots)
        if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self)) s->textures[index]=t;
    if (diagnostics) {
        std::lock_guard<std::recursive_mutex> lock(guard());
        NSString *slot = [NSString stringWithFormat:@"%lu", (unsigned long)index];
        NSMutableDictionary *bindings = objc_getAssociatedObject(self, &bindingsKey);
        if (!bindings) {
            bindings = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(self, &bindingsKey, bindings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (t) bindings[slot] = texture(t); else [bindings removeObjectForKey:slot];
        if (t) record(@{@"event": NSStringFromSelector(cmd), @"encoder": [self label] ?: @"", @"pipeline": pipelineDescription(self) ?: @{}, @"index": @(index), @"texture": texture(t)});
    }
}
static void bindTexture(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id<MTLTexture> t, NSUInteger index) {
    ((void(*)(id,SEL,id,NSUInteger))original(self,cmd))(self,cmd,t,index);
    rememberTexture(self,cmd,t,index);
}
static void bindTextures(__unsafe_unretained id self, SEL cmd, id<MTLTexture> const *textures, NSRange range) {
    ((void(*)(id,SEL,id<MTLTexture> const *,NSRange))original(self,cmd))(self,cmd,textures,range);
    for (NSUInteger i=0; i<range.length; ++i) rememberTexture(self,cmd,textures[i],range.location+i);
}
static void probeScene(id<MTLCommandBuffer> buffer, NSDictionary *inputs);
static std::atomic<bool> frameGenerationFailed{false};
static void failFrameGeneration(NSString *reason) {
    if(frameGenerationFailed.exchange(true)) return;
    dispatch_async(dispatch_get_main_queue(),^{
        NSAlert *alert=[NSAlert new]; alert.messageText=@"MetalFX Frame Generation could not continue";
        alert.informativeText=[reason stringByAppendingString:@"\n\nThe game will close."];
        [alert addButtonWithTitle:@"Close Game"]; [alert runModal]; _exit(78);
    });
}
// A frame whose inputs or composition Frame Generation cannot reproduce turns it
// off without closing the game: the selected upscaler keeps running, and frames
// already rendered into stand-ins are presented unpaired. Clearing the Frame
// Generation checkbox and checking it again retries.
static std::atomic<bool> frameGenerationDeclined{false};
static void declineFrameGeneration(NSString *reason) {
    if(frameGenerationDeclined.exchange(true)) return;
    record(@{@"event":@"frameGenerationDeclined",@"reason":reason ?: @""});
    dispatch_async(dispatch_get_main_queue(),^{
        NSAlert *alert=[NSAlert new]; alert.messageText=@"MetalFX Frame Generation is off";
        alert.informativeText=[(reason ?: @"") stringByAppendingString:@"\n\nThe game continues with the selected Upscaling Type and without Frame Generation. "
            "To retry, turn Frame Generation off and on again in Video options."];
        [alert addButtonWithTitle:@"OK"]; [alert runModal];
    });
}
static BG3MFXFrameInterpolation *frameInterpolator;
static BG3MFXFramePresenter *framePresenter;
static NSString *frameConfiguration;
static double previousFrameTime;
// Unchecking Frame Generation frees the interpolator and
// presentation worker instead of leaving an idle effect alive. The worker joins
// its thread after draining queued pairs, so release it off the render thread.
static void releaseFrameGeneration(void) {
    BG3MFXFramePresenter *presenter=framePresenter;
    frameInterpolator=nil; framePresenter=nil; frameConfiguration=nil; previousFrameTime=0;
    if (presenter) dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{ (void)presenter; });
    record(@{@"event":@"frameGenerationReleased"});
}
static void resetFrameGeneration(void) {
    [frameInterpolator resetHistory]; previousFrameTime=0;
}
static void encodeGeneratedPair(id<MTLCommandBuffer> buffer, NSDictionary *request);

static void failFeature(BOOL temporal, NSString *reason) {
    { std::lock_guard<std::recursive_mutex> lock(guard());
      if (temporal ? temporalFailed : spatialFailed) return;
      if (temporal) temporalFailed = YES; else spatialFailed = YES; }
    NSString *feature = temporal ? @"Temporal" : @"Spatial";
    if (![reason isKindOfClass:NSString.class] || reason.length == 0)
        reason = @"MetalFX could not initialize or validate the requested frame.";
    NSString *message = [[@"MetalFX " stringByAppendingString:feature] stringByAppendingFormat:@" stopped: %@",reason];
    fprintf(stderr,"%s\n",message.UTF8String); fflush(stderr);
    record(@{@"event":temporal ? @"temporalUpscaleError" : @"spatialUpscaleError",@"error":message});
    // Noninteractive mode is for the subprocess failure regression only.
    if (getenv("BG3MFX_TEST_ERRORS_STDERR") && strcmp(getenv("BG3MFX_TEST_ERRORS_STDERR"),"1") == 0) _exit(78);
    void (^showError)(void) = ^{
        [NSApplication sharedApplication];
        NSAlert *alert = [NSAlert new];
        alert.messageText = [NSString stringWithFormat:@"MetalFX %@ could not continue",feature];
        alert.informativeText = [reason stringByAppendingString:@"\n\nThe game will close."];
        alert.alertStyle = NSAlertStyleCritical; [alert addButtonWithTitle:@"Close Game"];
        [alert runModal]; _exit(78);
    };
    if ([NSThread isMainThread]) showError();
        else dispatch_async(dispatch_get_main_queue(),showError);
}
static void failSpatial(NSString *reason) { failFeature(NO,reason); }
static void failTemporal(NSString *reason) { failFeature(YES,reason); }
static void menuReport(NSDictionary *event) {
    record(event);
    if ([event[@"event"] isEqualToString:@"nativeMenuError"])
        failFeature(NO,event[@"error"]);
    if ([event[@"event"] isEqualToString:@"frameGenerationChanged"] || [event[@"event"] isEqualToString:@"upscalingModeChanged"]) {
        resetFrameGeneration();
        // Changing either way starts the next enabled run with fresh history.
        extern void BG3MFXResetTemporalHistory(void);
        BG3MFXResetTemporalHistory();
    }
}
static BOOL upscaleSpatial(id<MTLCommandBuffer> buffer, NSDictionary *inputs) {
    id<MTLTexture> input = inputs[@"input"], destination = inputs[@"destination"];
    if (!input || !destination) return NO;
    // Fetch/store under the tracer guard, but construct MetalFX outside it:
    // synchronous driver initialization can call our hooks on other threads.
    static NSMutableDictionary *cache;
    NSString *key = [NSString stringWithFormat:@"%p:%lu:%lu:%lu:%lu", (__bridge void *)buffer.device,
        input.width,input.height,destination.width,destination.height];
    BG3MFXSpatialUpscaler *upscaler;
    { std::lock_guard<std::recursive_mutex> lock(guard());
      if (!cache) cache = [NSMutableDictionary dictionary]; upscaler = cache[key]; }
    NSError *error = nil;
    if (!upscaler) {
        upscaler = [[BG3MFXSpatialUpscaler alloc] initWithDevice:buffer.device inputWidth:input.width
            inputHeight:input.height outputWidth:destination.width outputHeight:destination.height error:&error];
        if (upscaler) { std::lock_guard<std::recursive_mutex> lock(guard()); cache[key] = upscaler; }
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
static NSMutableDictionary *temporalUpscalerCache() {
    static NSMutableDictionary *value;
    if (!value) value = [NSMutableDictionary dictionary];
    return value;
}
static NSString *temporalScalerKey(id<MTLDevice> device, NSUInteger iw, NSUInteger ih, NSUInteger ow, NSUInteger oh) {
    return [NSString stringWithFormat:@"%p:%lu:%lu:%lu:%lu",(__bridge void *)device,iw,ih,ow,oh];
}
// Creating a Temporal scaler takes tens of milliseconds, and on macOS 27.0.1 a
// Temporal scaler whose output is 1512 px tall or less is never deallocated
// (Metal 3 and Metal 4 alike): each keeps an ANEServicesThread and tens to
// hundreds of MB. Dragging a window edge gives every frame a new size; creating one
// per frame stuttered, corrupted the image and eventually hung BG3 inside
// scaler creation with about a thousand leaked threads. A size with no scaler
// therefore runs BG3's native FSR until it has held for a moment; the first
// scaler of the session is created at once.
static BOOL temporalSizeSettled(NSString *key) {
    static NSString *pendingKey;
    static double pendingSince;
    std::lock_guard<std::recursive_mutex> lock(guard());
    if (temporalUpscalerCache()[key] || !temporalUpscalerCache().count) return YES;
    double now=NSProcessInfo.processInfo.systemUptime;
    if (![key isEqualToString:pendingKey]) { pendingKey=key; pendingSince=now; return NO; }
    return now-pendingSince>=0.3;
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
    BG3MFXApplyNativeJitter(&p, temporal[52], temporal[53]);
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
    NSString *key = temporalScalerKey(buffer.device,color.width,color.height,destination.width,destination.height);
    BG3MFXTemporalUpscaler *upscaler;
    { std::lock_guard<std::recursive_mutex> lock(guard()); upscaler = temporalUpscalerCache()[key]; }
    NSError *error = nil;
    if (!upscaler) {
        upscaler = [[BG3MFXTemporalUpscaler alloc] initWithDevice:buffer.device inputWidth:color.width
            inputHeight:color.height outputWidth:destination.width outputHeight:destination.height error:&error];
        if (upscaler) {
            upscaler.gpuFailureHandler=^(NSError *gpuError) {
                failTemporal(gpuError.localizedDescription ?: @"Metal 4 could not complete temporal scaling commands.");
            };
            record(@{@"event":@"temporalScalerCreated",@"api":upscaler.usesMetal4 ? @"metal4" : @"metal3"});
            std::lock_guard<std::recursive_mutex> lock(guard());
            temporalUpscalerCache()[key] = upscaler;
            // Retain only a small set of recent window/quality configurations.
            if (temporalUpscalerCache().count > 6) [temporalUpscalerCache() removeObjectForKey:temporalUpscalerCache().allKeys.firstObject];
        }
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
static void endEncoder(id self, SEL cmd) {
    id<MTLCommandBuffer> commandBuffer = encoderBuffer(self);
    NSDictionary *probeInputs = objc_getAssociatedObject(self, &taaInputsKey);
    NSDictionary *fsrInputs = objc_getAssociatedObject(self, &fsrInputsKey);
    NSDictionary *temporalInputs = objc_getAssociatedObject(self, &taaInputsKey);
    NSDictionary *postprocess = objc_getAssociatedObject(self,&temporalPostprocessKey);
    __unsafe_unretained BG3MFXEncoderState *encoderRecord = encoderState(self);
    // A recognized pass followed by an unrecognized draw in the same encoder, or
    // an encoder of only unrecognized draws, overwrites its target: drop any
    // scene association for it (the per-draw logic this replaces did the same).
    if (encoderRecord && encoderRecord->lastDrawOther && metalFXEnabled && encoderRecord->colorTarget) {
        if (sceneTracked(encoderScalingMode(self),commandBuffer)) postprocess = @{@"target":encoderRecord->colorTarget};
    }
    NSDictionary *composition=objc_getAssociatedObject(self,&frameCompositionKey);
    objc_setAssociatedObject(self,&frameCompositionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#ifndef BG3MFX_NO_TRACE
    NSArray *waterfallCopies=[objc_getAssociatedObject(self,&waterfallCopiesKey) copy];
    objc_setAssociatedObject(self,&waterfallCopiesKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#endif
    BOOL replaceTAA = [objc_getAssociatedObject(self,&temporalSuppressedKey) boolValue];
#ifndef BG3MFX_NO_TRACE
    if (getenv("BG3MFX_TRACE_TEMPORAL_CHAIN") && commandBuffer && sceneTracked(encoderScalingMode(self),commandBuffer)) {
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
    objc_setAssociatedObject(self, &fsrInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (encoderRecord) encoderRecord->buffer = nil;
    objc_setAssociatedObject(self, &temporalSuppressedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self, &temporalPostprocessKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    record(@{@"event": @"encoderEnd", @"pipeline": pipelineDescription(self) ?: @{},
             @"bindings": objc_getAssociatedObject(self, &bindingsKey) ?: @{},
             @"attachments": objc_getAssociatedObject(self, &attachmentsKey) ?: @{}});
    if (traceConstants) {
        std::lock_guard<std::recursive_mutex> lock(guard());
        NSDictionary *state = pipelineDescription(self);
        NSString *fragment = state[@"fragment"] ?: @"";
        if (diagnostics && ([fragment isEqualToString:@"PPTAA_PS"] || [fragment isEqualToString:@"VelocityBufferCamera_PS"] ||
             [fragment isEqualToString:@"BG3MFXConstantsSmoke"]) && [constantSamples[fragment] unsignedIntegerValue] < 8) {
            NSUInteger sample = [constantSamples[fragment] unsignedIntegerValue];
            constantSamples[fragment] = @(sample+1);
            NSMutableDictionary *snapshots = [NSMutableDictionary dictionary];
            [constantBindings(self) enumerateKeysAndObjectsUsingBlock:^(NSString *slot, NSDictionary *binding, BOOL *) {
                NSDictionary *sizes = shaderBufferSizes[fragment];
                NSNumber *declaredSize = sizes[slot];
                if (sizes && !declaredSize) return;
                NSUInteger limit = declaredSize ? MIN(declaredSize.unsignedIntegerValue,4096) : 4096;
                NSData *data = binding[@"bytes"];
                id<MTLBuffer> buffer = binding[@"buffer"];
                NSUInteger offset = [binding[@"offset"] unsignedIntegerValue];
                NSUInteger length = [binding[@"length"] unsignedIntegerValue];
                if (buffer) {
                    length = offset <= buffer.length ? buffer.length-offset : 0;
                    if (buffer.storageMode == MTLStorageModeShared && length && buffer.contents)
                        data = [NSData dataWithBytes:(const uint8_t *)buffer.contents+offset length:MIN(length,limit)];
                }
                if (data.length > limit) data = [data subdataWithRange:NSMakeRange(0,limit)];
                snapshots[slot] = @{@"offset": @(offset), @"availableLength": @(length),
                    @"capturedLength": @(data.length), @"base64": [data base64EncodedStringWithOptions:0] ?: @"",
                    @"storage": buffer ? @(buffer.storageMode) : @(-1)};
            }];
            record(@{@"event": @"shaderConstants", @"pipeline": state, @"sample": @(sample), @"bindings": snapshots});
        }
        // Release buffer references as soon as this encoder ends.
        if (encoderRecord) { for (auto &stage:encoderRecord->constants) for (auto &binding:stage) binding={}; encoderRecord->bytes=nil; }
    }
    ((void(*)(id,SEL))original(self,cmd))(self,cmd);
#ifndef BG3MFX_NO_TRACE
    finishWaterfallCopies(commandBuffer,waterfallCopies);
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
        if (inputFrame) {
            NSMutableDictionary *next = [inputFrame mutableCopy];
            next[@"taaColor"] = target;
            next[@"color"] = postprocess[@"tonemap"] ? postprocess[@"source"] : target;
            sceneFrames[targetKey] = next;
            record(@{@"event":@"temporalColorForwarded",@"pipeline":postprocess[@"pipeline"],
                @"source":texture(postprocess[@"source"]),@"target":texture(target)});
        }
    }
    if (metalFXEnabled && temporalInputs && commandBuffer && !temporalFailed) {
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
    if (encoderRecord) for (auto &texture:encoderRecord->textures) texture=nil;
    objc_setAssociatedObject(self, &taaInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (encoderRecord) encoderRecord->colorTarget=nil;
    forgetEncoder(self);
    objc_setAssociatedObject(self, &fsrInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void pipeline(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id state) {
    ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,state);
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(self);
    NSDictionary *description = objc_getAssociatedObject(state, &pipelineKey);
    if (diagnostics && !description) description = @{@"label": [state label] ?: @""};
    if (s) {
        s->pipeline=state; s->description=description;
        s->kind=(PipelineKind)[objc_getAssociatedObject(state,&pipelineKindKey) unsignedCharValue];
    }
    record(@{@"event": NSStringFromSelector(cmd), @"encoder": [self label] ?: @"", @"pipeline": description});
}
static BOOL cameraShader(MTLRenderPipelineDescriptor *desc) {
    NSString *name = desc.fragmentFunction.name;
    if (compositionShader(name)) return YES;
    return diagnostics && traceConstants && ([name isEqualToString:@"PPTAA_PS"] || [name isEqualToString:@"VelocityBufferCamera_PS"] ||
                              [name isEqualToString:@"BG3MFXConstantsSmoke"]);
}
static NSArray *structMembers(MTLStructType *type, NSUInteger depth) {
    NSMutableArray *members = [NSMutableArray array];
    if (depth > 3) return members;
    for (MTLStructMember *member in type.members) {
        NSMutableDictionary *entry = [@{@"name": member.name ?: @"", @"offset": @(member.offset), @"type": @(member.dataType)} mutableCopy];
        if (member.dataType == MTLDataTypeStruct) entry[@"members"] = structMembers(member.structType,depth+1);
        [members addObject:entry];
    }
    return members;
}
static void recordReflection(MTLRenderPipelineDescriptor *desc, MTLRenderPipelineReflection *reflection) {
    if (!reflection) return;
    NSMutableArray *buffers = [NSMutableArray array];
    NSMutableArray *textures = [NSMutableArray array];
    NSMutableDictionary *sizes = [NSMutableDictionary dictionary];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (MTLArgument *arg in reflection.fragmentArguments) {
        if (arg.type == MTLArgumentTypeBuffer) {
            sizes[[NSString stringWithFormat:@"fragment:%lu", (unsigned long)arg.index]] = @(arg.bufferDataSize);
            [buffers addObject:@{@"name": arg.name ?: @"", @"index": @(arg.index), @"size": @(arg.bufferDataSize),
                                 @"active": @(arg.active), @"members": structMembers(arg.bufferStructType,0)}];
        }
        if (arg.type == MTLArgumentTypeTexture)
            [textures addObject:@{@"name": arg.name ?: @"", @"index": @(arg.index), @"active": @(arg.active)}];
    }
#pragma clang diagnostic pop
    { std::lock_guard<std::recursive_mutex> lock(guard());
      shaderBufferSizes[desc.fragmentFunction.name ?: @""] = sizes; }
    record(@{@"event": @"shaderReflection", @"fragment": desc.fragmentFunction.name ?: @"", @"buffers": buffers, @"textures": textures});
}
static id renderPipeline(id self, SEL cmd, MTLRenderPipelineDescriptor *desc, NSError **error) {
    id state;
    if (cameraShader(desc)) {
        SEL optionsSelector = sel_registerName("newRenderPipelineStateWithDescriptor:options:reflection:error:");
        MTLRenderPipelineReflection *reflection = nil;
        NSError *reflectionError = nil;
        state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,optionsSelector))
            (self,optionsSelector,desc,MTLPipelineOptionBindingInfo|MTLPipelineOptionBufferTypeInfo,&reflection,&reflectionError);
        if (state) {
            recordReflection(desc,reflection);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if(compositionShader(desc.fragmentFunction.name))for(MTLArgument *arg in reflection.fragmentArguments)
                if(arg.type==MTLArgumentTypeBuffer && arg.index==0)objc_setAssociatedObject(state,&compositorSizeKey,@(arg.bufferDataSize),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#pragma clang diagnostic pop
        }
        else record(@{@"event": @"shaderReflectionFailed", @"fragment": desc.fragmentFunction.name ?: @"", @"error": reflectionError.description ?: @""});
        if (!state) state = ((id(*)(id,SEL,id,NSError **))original(self,cmd))(self,cmd,desc,error);
    } else state = ((id(*)(id,SEL,id,NSError **))original(self,cmd))(self,cmd,desc,error);
    NSString *fragment = desc.fragmentFunction.name;
    NSDictionary *description = diagnostics ? @{@"vertex": desc.vertexFunction.name ?: @"", @"fragment": fragment ?: @"", @"label": desc.label ?: @""} :
        (([fragment isEqualToString:@"PPTAA_PS"] || [fragment isEqualToString:@"LinearizeDepth"] || [fragment isEqualToString:@"VelocityBufferCamera_PS"] || temporalColorPass(fragment) || compositionShader(fragment) || [fragment isEqualToString:@"PPToneMap_LUT"]) ? @{@"fragment":fragment} : nil);
#ifndef BG3MFX_NO_TRACE
    NSDictionary *waterfall=waterfallLayout(desc);
    if (waterfall) { NSMutableDictionary *expanded=[description mutableCopy]; expanded[@"vertexLayout"]=waterfall; description=expanded; }
#endif
    if (state) {
        objc_setAssociatedObject(state, &pipelineKey, description, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(state, &pipelineKindKey, @(classifyPipeline(fragment)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    record(@{@"event": @"renderPipeline", @"pipeline": description, @"success": @(state != nil)});
    return state;
}
static id renderPipelineOptions(id self, SEL cmd, MTLRenderPipelineDescriptor *desc, MTLPipelineOption options, MTLRenderPipelineReflection **reflection, NSError **error) {
    MTLRenderPipelineReflection *extraReflection = nil;
    id state;
    if (cameraShader(desc)) {
        NSError *reflectionError = nil;
        state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,cmd))
            (self,cmd,desc,options|MTLPipelineOptionBindingInfo|MTLPipelineOptionBufferTypeInfo,&extraReflection,&reflectionError);
        if (state) {
            if (reflection) *reflection = extraReflection;
            recordReflection(desc,extraReflection);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            if(compositionShader(desc.fragmentFunction.name))for(MTLArgument *arg in extraReflection.fragmentArguments)
                if(arg.type==MTLArgumentTypeBuffer && arg.index==0)objc_setAssociatedObject(state,&compositorSizeKey,@(arg.bufferDataSize),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
#pragma clang diagnostic pop
        } else state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,cmd))(self,cmd,desc,options,reflection,error);
    } else state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,cmd))(self,cmd,desc,options,reflection,error);
    NSString *fragment = desc.fragmentFunction.name;
    NSDictionary *description = diagnostics ? @{@"vertex": desc.vertexFunction.name ?: @"", @"fragment": fragment ?: @"", @"label": desc.label ?: @""} :
        (([fragment isEqualToString:@"PPTAA_PS"] || [fragment isEqualToString:@"LinearizeDepth"] || [fragment isEqualToString:@"VelocityBufferCamera_PS"] || temporalColorPass(fragment) || compositionShader(fragment) || [fragment isEqualToString:@"PPToneMap_LUT"]) ? @{@"fragment":fragment} : nil);
#ifndef BG3MFX_NO_TRACE
    NSDictionary *waterfall=waterfallLayout(desc);
    if (waterfall) { NSMutableDictionary *expanded=[description mutableCopy]; expanded[@"vertexLayout"]=waterfall; description=expanded; }
#endif
    if (state) {
        objc_setAssociatedObject(state, &pipelineKey, description, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(state, &pipelineKindKey, @(classifyPipeline(fragment)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    record(@{@"event": @"renderPipeline", @"pipeline": description, @"success": @(state != nil)});
    return state;
}
static id computePipeline(id self, SEL cmd, id<MTLFunction> function, NSError **error) {
    id state = ((id(*)(id,SEL,id,NSError **))original(self,cmd))(self,cmd,function,error);
    NSString *name = function.name;
    NSDictionary *description = (diagnostics || [name isEqualToString:@"FSR"] || [name isEqualToString:@"FSR_RCAS"] ||
        [name isEqualToString:@"CAS"]) ? @{@"compute": name ?: @""} : nil;
    if (state) objc_setAssociatedObject(state, &pipelineKey, description, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    record(@{@"event": @"computePipeline", @"pipeline": description, @"success": @(state != nil)});
    return state;
}
static NSData *constantBytes(id encoder, EncoderStage stage, NSUInteger index, NSUInteger count) {
    ConstantBinding *binding = constantSlot(encoder,stage,index);
    if (!binding) return nil;
    NSData *bytes = binding->hasBytes ? encoderState(encoder)->bytes[@(stage*EncoderSlots+index)] : nil;
    if (bytes.length >= count) return [bytes subdataWithRange:NSMakeRange(0,count)];
    id<MTLBuffer> buffer = binding->buffer;
    NSUInteger offset = binding->offset;
    if (!buffer || buffer.storageMode != MTLStorageModeShared || !buffer.contents ||
        offset > buffer.length || count > buffer.length-offset) return nil;
    return [NSData dataWithBytes:(const uint8_t *)buffer.contents+offset length:count];
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
    if (BG3MFXFramePresenter *presenter=framePresenter)
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
    BG3MFXFramePresenter *presenter=framePresenter;
    if(![presenter ownsTexture:target]) return;
    NSDictionary *inputs=request[@"inputs"];
    id<MTLTexture> depth=inputs[@"depth"], motion=inputs[@"motion"];
    BG3MFXFrameParameters parameters={}; NSString *reason=nil;
    if(!temporalParameters(inputs,&parameters,&reason)) { declineFrameGeneration(reason); return; }
    NSString *configuration=[NSString stringWithFormat:@"%p:%lu:%lu:%lu:%lu:%d:%lu:%lu/%lu:%lu/%lu:%lu/%lu",(__bridge void *)buffer.device,
        depth.width,depth.height,scene.width,scene.height,[objc_getAssociatedObject(buffer,&bufferScalingModeKey) intValue],target.pixelFormat,
        scene.pixelFormat,scene.usage,depth.pixelFormat,depth.usage,motion.pixelFormat,motion.usage];
    NSError *error=nil;
    if(![configuration isEqualToString:frameConfiguration]) {
        frameInterpolator=[[BG3MFXFrameInterpolation alloc] initWithDevice:buffer.device scene:scene depth:depth motion:motion error:&error];
        if(!frameInterpolator) {declineFrameGeneration(error.localizedDescription ?: @"Could not initialize frame generation.");return;}
        frameInterpolator.failureHandler=^(NSError *e){failFrameGeneration(e.localizedDescription);};
        frameConfiguration=configuration;previousFrameTime=0;
        record(@{@"event":@"frameGenerationCreated",@"api":frameInterpolator.usesMetal4 ? @"metal4" : @"metal3",
            @"input":texture(depth),@"scene":texture(scene),@"direct":@[@(frameInterpolator.directColor),
            @(frameInterpolator.directDepth),@(frameInterpolator.directMotion)]});
    }
    double now=NSProcessInfo.processInfo.systemUptime;
    double interval=previousFrameTime>0 ? now-previousFrameTime : 1.0/60;
    previousFrameTime=now;
    if(interval<=0 || interval>0.1) {parameters.reset=YES;interval=1.0/60;}
    encodingFrameGeneration=true;
    id<MTLTexture> interpolated=[frameInterpolator encodeScene:scene depth:depth motion:motion camera:inputs[@"camera"]
        parameters:parameters deltaTime:interval commandBuffer:buffer error:&error];
    if(!interpolated) {encodingFrameGeneration=false;failFrameGeneration(error.localizedDescription);return;}
    // BG3's own CombineUI already composes the real frame into the stand-in;
    // compose only the generated scene with the same UI, pipeline and constants.
    id<MTLTexture> generated=[presenter generatedTargetLike:target];
    if(!generated){encodingFrameGeneration=false;failFrameGeneration(@"Could not allocate the frame generation composition output.");return;}
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
    CompositionDraw draw;memcpy(&draw,[request[@"draw"] bytes],sizeof(draw));
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
    if ((!sceneProbe && !metalFXEnabled) || (sceneProbe && sceneProbeAttempts && !metalFXEnabled)) return;
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
        // Frame Generation also needs this frame's depth, motion and camera,
        // validated exactly as for Temporal. Without them the frame still
        // renders and upscales; it just cannot be paired.
        if (!frameGeneration(buffer)) return;
    }
    id<MTLTexture> motion = textures[@"2"];
    id<MTLTexture> depth = objc_getAssociatedObject(buffer, &deviceDepthKey);
    BOOL resetMotion = motion.width == 16 && motion.height == 16 && motion.pixelFormat == MTLPixelFormatRGBA8Unorm;
    if (resetMotion && source && buffer) {
        // BG3 invalidates velocity/history for the first frame after a quality
        // change. MetalFX must start a fresh history with zero displacement.
        MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG16Float width:source.width height:source.height mipmapped:NO];
        desc.storageMode = MTLStorageModeShared; desc.usage = MTLTextureUsageShaderRead;
        motion = [buffer.device newTextureWithDescriptor:desc];
        NSMutableData *zeros = [NSMutableData dataWithLength:source.width*source.height*4];
        [motion replaceRegion:MTLRegionMake2D(0,0,source.width,source.height) mipmapLevel:0 withBytes:zeros.bytes bytesPerRow:source.width*4];
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
    if (vp[0] != 1 || vp[1] != 1 || vp[2] != 0 || vp[3] != 0 || size[0] != source.width || size[1] != source.height) return;
    if (spatialSeed) {
        NSMutableDictionary *inputs = [spatialSeed mutableCopy];
        [inputs addEntriesFromDictionary:@{@"depth": depth, @"motion": motion, @"camera": camera, @"temporal": temporal, @"reset":@(resetMotion)}];
        objc_setAssociatedObject(encoder, &taaInputsKey, inputs, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    objc_setAssociatedObject(encoder, &taaInputsKey,
        @{@"color": source, @"taaColor": taaTarget, @"nativeTAA":taaTarget,
          @"nativeTAAPreserved":@(!knownUpscaledTAA(taaTarget)),
          @"depth": depth, @"motion": motion, @"camera": camera, @"temporal": temporal, @"reset":@(resetMotion)},
        OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    BG3MFXApplyNativeJitter(&p, temporal[52], temporal[53]);
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
static void captureFrameComposition(id encoder, const CompositionDraw &call) {
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
    CompositionDraw draw=call; draw.indexBuffer=nil;
    NSMutableDictionary *request=[@{@"scene":scene,@"ui":ui,@"target":target,@"inputs":inputs,@"pipeline":pipeline,
        @"vertexOffset":@(vertexBinding->offset),@"constants":constants,@"sampler":sampler,
        @"draw":[NSData dataWithBytes:&draw length:sizeof(draw)]} mutableCopy];
    if(vertexBinding->buffer) request[@"vertices"]=vertexBinding->buffer; else request[@"vertexBytes"]=vertexBytes;
    if(call.indexBuffer) request[@"indexBuffer"]=call.indexBuffer;
    if(s->hasViewport) request[@"viewport"]=[NSData dataWithBytes:&s->viewport length:sizeof(s->viewport)];
    if(s->hasScissor) request[@"scissor"]=[NSData dataWithBytes:&s->scissor length:sizeof(s->scissor)];
    objc_setAssociatedObject(encoder,&frameCompositionKey,request,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static void bindViewport(__unsafe_unretained id self, SEL cmd, MTLViewport v) {
    ((void(*)(id,SEL,MTLViewport))original(self,cmd))(self,cmd,v);
    if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self)) { s->viewport=v; s->hasViewport=true; }
}
static void bindScissor(__unsafe_unretained id self, SEL cmd, MTLScissorRect r) {
    ((void(*)(id,SEL,MTLScissorRect))original(self,cmd))(self,cmd,r);
    if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self)) { s->scissor=r; s->hasScissor=true; }
}
static void sampler(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id state, NSUInteger index) {
    ((void(*)(id,SEL,id,NSUInteger))original(self,cmd))(self,cmd,state,index);
    if(index==0) if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self)) s->sampler0=state;
}
static void samplers(__unsafe_unretained id self, SEL cmd, id<MTLSamplerState> const *states, NSRange range) {
    ((void(*)(id,SEL,id<MTLSamplerState> const *,NSRange))original(self,cmd))(self,cmd,states,range);
    if(range.location==0 && range.length) if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self)) s->sampler0=states[0];
}
// Draws with unrecognized pipelines skip all inspection (diagnostics excepted).
// Their only effect on the integration, invalidating a scene association for
// the encoder's color target, is applied once in endEncoder.
static bool fastDraw(__unsafe_unretained id encoder) {
    if (diagnostics) return false;
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    if (s && s->kind!=PipelineOther) { s->lastDrawOther=false; return false; }
    if (s) s->lastDrawOther=true;
    return true;
}
static void drawInputs(id encoder, const CompositionDraw &call) {
    captureFrameComposition(encoder,call);
    if (!traceConstants || !temporalInputsNeeded(encoder)) return;
    NSDictionary *state = pipelineDescription(encoder);
    NSString *fragment = state[@"fragment"] ?: @"";
    int mode = encoderScalingMode(encoder);
    id<MTLCommandBuffer> encoderCommands = encoderBuffer(encoder);
    if (metalFXEnabled && sceneTracked(mode,encoderCommands) && ![fragment isEqualToString:@"PPTAA_PS"]) {
        id<MTLCommandBuffer> buffer = encoderCommands;
        NSDictionary *sceneFrames = objc_getAssociatedObject(buffer,&temporalFrameKey);
        id<MTLTexture> target = encoderTarget(encoder);
        if (sceneFrames.count && target) {
            id<MTLTexture> source = boundTextures(encoder)[@"0"];
            NSDictionary *inputFrame = source ? sceneFrames[[NSValue valueWithPointer:(__bridge const void *)source]] : nil;
            NSMutableDictionary *next = [@{@"target":target} mutableCopy];
            if (inputFrame && source != target && source.width == target.width && source.height == target.height &&
                ((temporalColorPass(fragment) && source.pixelFormat == MTLPixelFormatRG11B10Float && target.pixelFormat == MTLPixelFormatRG11B10Float) ||
                 (frameGeneration(buffer) && [fragment isEqualToString:@"PPToneMap_LUT"]))) {
                next[@"frame"] = inputFrame; next[@"source"] = source; next[@"pipeline"] = fragment;
                if ([fragment isEqualToString:@"FSR_Tonemap"]) next[@"tonemap"] = @YES;
            }
            objc_setAssociatedObject(encoder,&temporalPostprocessKey,next,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
    if (diagnostics || [fragment isEqualToString:@"PPTAA_PS"] || [fragment isEqualToString:@"LinearizeDepth"] || [fragment isEqualToString:@"VelocityBufferCamera_PS"])
        captureSceneInputs(encoder,fragment);
    if ([fragment isEqualToString:@"PPTAA_PS"] || [fragment isEqualToString:@"LinearizeDepth"] || [fragment isEqualToString:@"VelocityBufferCamera_PS"] ||
        [fragment isEqualToString:@"VelocityBufferCamera_PS"] || [fragment containsString:@"_VEL_"]) {
        record(@{@"event": @"drawInputs", @"pipeline": state,
                 @"bindings": objc_getAssociatedObject(encoder, &bindingsKey) ?: @{},
                 @"attachments": objc_getAssociatedObject(encoder, &attachmentsKey) ?: @{}});
    }
}
static BOOL suppressTemporalTAA(id encoder) {
    if (!metalFXEnabled || temporalFailed || encoderScalingMode(encoder) != 3) return NO;
    NSDictionary *state = pipelineDescription(encoder);
    if (![state[@"fragment"] isEqualToString:@"PPTAA_PS"] || !objc_getAssociatedObject(encoder,&taaInputsKey)) return NO;
    if (!knownUpscaledTAA(encoderTarget(encoder))) return NO;
    objc_setAssociatedObject(encoder,&temporalSuppressedKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    record(@{@"event":@"temporalNativeTAADrawSkipped",@"pipeline":state});
    return YES;
}
static void draw(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger start, NSUInteger count) {
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count); return; }
    drawInputs(self,CompositionDraw{type,start,count,1,0,0,nil,0,MTLIndexTypeUInt16});
    if (suppressTemporalTAA(self)) return;
    ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count);
}
static void drawInstances(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger start, NSUInteger count, NSUInteger instances) {
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count,instances); return; }
    drawInputs(self,CompositionDraw{type,start,count,instances,0,0,nil,0,MTLIndexTypeUInt16});
    if (suppressTemporalTAA(self)) return;
    ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count,instances);
}
static void drawBaseInstance(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger start, NSUInteger count, NSUInteger instances, NSUInteger base) {
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count,instances,base); return; }
    drawInputs(self,CompositionDraw{type,start,count,instances,base,0,nil,0,MTLIndexTypeUInt16});
    if (suppressTemporalTAA(self)) return;
    ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count,instances,base);
}
static void drawIndexed(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset) {
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset); return; }
    drawInputs(self,CompositionDraw{type,0,count,1,0,0,buffer,offset,indexType});
#ifndef BG3MFX_NO_TRACE
    captureWaterfall(self,@{@"indexCount":@(count),@"indexType":@(indexType),@"indexBuffer":buffer,@"indexOffset":@(offset),@"instances":@1,@"baseVertex":@0,@"baseInstance":@0});
#endif
    if (suppressTemporalTAA(self)) return;
    ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset);
}
static void drawIndexedInstances(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset, NSUInteger instances) {
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances); return; }
    drawInputs(self,CompositionDraw{type,0,count,instances,0,0,buffer,offset,indexType});
#ifndef BG3MFX_NO_TRACE
    captureWaterfall(self,@{@"indexCount":@(count),@"indexType":@(indexType),@"indexBuffer":buffer,@"indexOffset":@(offset),@"instances":@(instances),@"baseVertex":@0,@"baseInstance":@0});
#endif
    if (suppressTemporalTAA(self)) return;
    ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances);
}
static void drawIndexedBase(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset, NSUInteger instances, NSInteger baseVertex, NSUInteger baseInstance) {
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger,NSInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances,baseVertex,baseInstance); return; }
    drawInputs(self,CompositionDraw{type,0,count,instances,baseInstance,baseVertex,buffer,offset,indexType});
#ifndef BG3MFX_NO_TRACE
    captureWaterfall(self,@{@"indexCount":@(count),@"indexType":@(indexType),@"indexBuffer":buffer,@"indexOffset":@(offset),@"instances":@(instances),@"baseVertex":@(baseVertex),@"baseInstance":@(baseInstance)});
#endif
    if (suppressTemporalTAA(self)) return;
    ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger,NSInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances,baseVertex,baseInstance);
}
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
static void dispatch(id self, SEL cmd, MTLSize grid, MTLSize threads) {
    BOOL suppressNative = NO;
    NSDictionary *state = pipelineDescription(self);
    NSString *pipelineName = state[@"compute"];
    NSDictionary *textures = boundTextures(self);
    NSDictionary *pending = objc_getAssociatedObject(self,&fsrInputsKey);
    id<MTLCommandBuffer> buffer = encoderBuffer(self);
    int mode = pending ? [pending[@"mode"] intValue] : encoderScalingMode(self);
    BOOL temporal = mode == 3;
    BOOL selectedMetalFX = (mode == 2 && metalFXEnabled) || (temporal && metalFXEnabled);
    if (selectedMetalFX) {
        if (temporal ? temporalFailed : spatialFailed) return;
        if ([pipelineName isEqualToString:@"FSR"]) {
            id<MTLTexture> source = textures[@"0"], scaled = textures[@"1"];
            if (pending || !source || !scaled || !buffer) {
                if (temporal) failTemporal(@"Unexpected FSR scaling resources or dispatch sequence.");
                else failSpatial(@"Unexpected FSR scaling resources or dispatch sequence.");
                return;
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
                if (!temporalSizeSettled(temporalScalerKey(buffer.device,spatialColor.width,spatialColor.height,scaled.width,scaled.height))) {
                    fallBackToNative(self,YES,@"The output size is changing; waiting for it to settle before creating a Temporal scaler.");
                    goto native;
                }
            } else if (!spatialColor || spatialColor.width != source.width || spatialColor.height != source.height ||
                       spatialColor.pixelFormat != MTLPixelFormatRG11B10Float) {
                fallBackToNative(self,NO,@"Could not match FSR input to BG3's linear HDR scene color.");
                goto native;
            }
            objc_setAssociatedObject(self,&fsrInputsKey,
                @{@"input":temporal ? source : spatialColor,@"encodedInput":source,@"scaled":scaled,@"mode":@(mode),
                  @"nativeTAA":frame[@"nativeTAA"]},OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            suppressNative = YES;
        } else if ([pipelineName isEqualToString:@"FSR_RCAS"]) {
            // The fallback frame keeps BG3's own sharpening pass too.
            if (!pending && objc_getAssociatedObject(self,&nativeFallbackKey)) goto native;
            if (pending && !pending[@"destination"] && pending[@"scaled"] == textures[@"0"] && textures[@"2"]) {
                NSMutableDictionary *complete = [pending mutableCopy]; complete[@"destination"] = textures[@"2"];
                objc_setAssociatedObject(self,&fsrInputsKey,complete,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                suppressNative = YES;
            } else {
                if (temporal) failTemporal(@"Unexpected native FSR sharpening resources or dispatch sequence.");
                else failSpatial(@"Unexpected FSR sharpening resources or dispatch sequence.");
                return;
            }
        } else if (pending) {
            if (temporal) failTemporal(@"An unexpected compute dispatch interrupted the MetalFX replacement.");
            else failSpatial(@"An unexpected compute dispatch interrupted the MetalFX replacement.");
            return;
        }
    }
native:
    if (metalFXEnabled && buffer && frameGeneration(buffer)) forwardNativeCompute(self,pipelineName,textures,buffer,mode);
    if (traceConstants) {
        NSDictionary *state = pipelineDescription(self);
        NSString *name = state[@"compute"] ?: @"";
        if ([name isEqualToString:@"FSR"] || [name isEqualToString:@"FSR_RCAS"] ||
            [name isEqualToString:@"BG3MFXDispatchSmoke"]) {
            record(@{@"event": @"dispatchInputs", @"method": NSStringFromSelector(cmd), @"pipeline": state,
                @"grid": @[@(grid.width),@(grid.height),@(grid.depth)],
                @"threadsPerGroup": @[@(threads.width),@(threads.height),@(threads.depth)],
                @"bindings": objc_getAssociatedObject(self, &bindingsKey) ?: @{}});
        }
    }
    if (suppressNative) {
        record(@{@"event":temporal ? @"temporalNativeDispatchSkipped" : @"spatialNativeDispatchSkipped",
            @"pipeline":pipelineDescription(self),
            @"method":NSStringFromSelector(cmd)});
        return;
    }
    ((void(*)(id,SEL,MTLSize,MTLSize))original(self,cmd))(self,cmd,grid,threads);
}
// Encoder classes whose methods are already hooked. hook() would find each one
// installed, but only after taking the global lock about 25 times per encoder.
// Classes are never deallocated, so their addresses are stable keys.
static std::atomic<uintptr_t> instrumentedEncoderClasses[16];
static bool encoderClassInstrumented(Class cls) {
    uintptr_t key = (uintptr_t)(__bridge void *)cls;
    for (auto &known : instrumentedEncoderClasses) {
        uintptr_t value = known.load(std::memory_order_acquire);
        if (value == key) return true;
        if (!value) return false;
    }
    return false;
}
static void markEncoderClassInstrumented(Class cls) {
    uintptr_t key = (uintptr_t)(__bridge void *)cls;
    for (auto &known : instrumentedEncoderClasses) {
        uintptr_t empty = 0;
        if (known.load(std::memory_order_acquire) == key ||
            known.compare_exchange_strong(empty, key, std::memory_order_acq_rel)) return;
    }
}
static void instrumentEncoder(id encoder) {
    objc_setAssociatedObject(encoder, &fsrInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(encoder,&frameCompositionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    // Drivers recycle encoder objects: start each one with fresh state.
    if (encoder) {
        BG3MFXEncoderState *state = [BG3MFXEncoderState new];
        objc_setAssociatedObject(encoder,&encoderStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        cachedEncoder = encoder; cachedState = state;
    }
    objc_setAssociatedObject(encoder, &bindingsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(encoder, &attachmentsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(encoder, &taaInputsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(encoder, &temporalPostprocessKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(encoder, &temporalSuppressedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!encoder || encoderClassInstrumented(object_getClass(encoder))) return;
    if (traceConstants) {
        hook(encoder,"setFragmentBuffer:offset:atIndex:",(IMP)bindBuffer);
        hook(encoder,"setVertexBuffer:offset:atIndex:",(IMP)bindBuffer);
        hook(encoder,"setFragmentBuffers:offsets:withRange:",(IMP)bindBuffers);
        hook(encoder,"setVertexBuffers:offsets:withRange:",(IMP)bindBuffers);
        hook(encoder,"setFragmentBufferOffset:atIndex:",(IMP)bufferOffset);
        hook(encoder,"setVertexBufferOffset:atIndex:",(IMP)bufferOffset);
        hook(encoder,"setFragmentBytes:length:atIndex:",(IMP)bindBytes);
        hook(encoder,"setVertexBytes:length:atIndex:",(IMP)bindBytes);
        hook(encoder,"drawPrimitives:vertexStart:vertexCount:",(IMP)draw);
        hook(encoder,"drawPrimitives:vertexStart:vertexCount:instanceCount:",(IMP)drawInstances);
        hook(encoder,"drawPrimitives:vertexStart:vertexCount:instanceCount:baseInstance:",(IMP)drawBaseInstance);
        hook(encoder,"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:",(IMP)drawIndexed);
        hook(encoder,"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:",(IMP)drawIndexedInstances);
        hook(encoder,"drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:baseVertex:baseInstance:",(IMP)drawIndexedBase);
    }
    if (diagnostics) hook(encoder,"setLabel:",(IMP)label);
    if (diagnostics) hook(encoder,"pushDebugGroup:",(IMP)group);
    hook(encoder,"setViewport:",(IMP)bindViewport);
    hook(encoder,"setScissorRect:",(IMP)bindScissor);
    hook(encoder,"setFragmentSamplerState:atIndex:",(IMP)sampler);
    hook(encoder,"setFragmentSamplerStates:withRange:",(IMP)samplers);
    hook(encoder,"setFragmentTexture:atIndex:",(IMP)bindTexture);
    hook(encoder,"setTexture:atIndex:",(IMP)bindTexture);
    hook(encoder,"setFragmentTextures:withRange:",(IMP)bindTextures);
    hook(encoder,"setTextures:withRange:",(IMP)bindTextures);
    hook(encoder,"endEncoding",(IMP)endEncoder);
    hook(encoder,"setRenderPipelineState:",(IMP)pipeline);
    hook(encoder,"setComputePipelineState:",(IMP)pipeline);
    if (traceConstants) {
        hook(encoder,"dispatchThreads:threadsPerThreadgroup:",(IMP)dispatch);
        hook(encoder,"dispatchThreadgroups:threadsPerThreadgroup:",(IMP)dispatch);
    }
    markEncoderClassInstrumented(object_getClass(encoder));
}
static id computeEncoderType(id self, SEL cmd, MTLDispatchType type);
static std::map<Class, IMP> &priorComputeMethods() { static auto *value = new std::map<Class, IMP>; return *value; }
static void refreshComputeHook(id buffer) {
    if (!traceConstants) return;
    std::lock_guard<std::recursive_mutex> lock(guard());
    Class cls = object_getClass(buffer);
    SEL selector = sel_registerName("computeCommandEncoderWithDispatchType:");
    auto found = originals().find({cls,selector});
    Method method = class_getInstanceMethod(cls,selector);
    if (found == originals().end() || !method || method_getImplementation(method) == (IMP)computeEncoderType) return;
    // Preserve later instrumentation as the outer original. If it retained our
    // old wrapper, nested entry will use the earlier original to avoid a cycle.
    priorComputeMethods().emplace(cls,found->second);
    found->second = method_getImplementation(method);
    originalsGeneration.fetch_add(1, std::memory_order_release);
    class_replaceMethod(cls,selector,(IMP)computeEncoderType,method_getTypeEncoding(method));
    record(@{@"event": @"computeHookRefreshed", @"class": NSStringFromClass(cls)});
}
static id renderEncoder(id self, SEL cmd, MTLRenderPassDescriptor *desc) {
    refreshComputeHook(self);
    if (diagnostics) {
    [[maybe_unused]] BOOL computeRegistered;
    { std::lock_guard<std::recursive_mutex> lock(guard());
      computeRegistered = originals().count({object_getClass(self), sel_registerName("computeCommandEncoderWithDispatchType:")}); }
    Method computeMethod = class_getInstanceMethod(object_getClass(self),sel_registerName("computeCommandEncoderWithDispatchType:"));
    Dl_info computeImage = {};
    if (computeMethod) dladdr((const void *)method_getImplementation(computeMethod), &computeImage);
    record(@{@"event": @"commandBufferHooks", @"class": NSStringFromClass(object_getClass(self)),
        @"computeImplementationImage": computeImage.dli_fname ? [NSString stringWithUTF8String:computeImage.dli_fname] : @"",
        @"computeHookRegistered": @(computeRegistered),
        @"computeHookActive": @(computeMethod && method_getImplementation(computeMethod) == (IMP)computeEncoderType)});
    }
    id encoder = ((id(*)(id,SEL,id))original(self,cmd))(self,cmd,desc);
    instrumentEncoder(encoder);
    setEncoderMode(encoder, objc_getAssociatedObject(self, &bufferScalingModeKey));
    if (diagnostics) {
    NSMutableArray *colors = [NSMutableArray array];
    for (NSUInteger i=0; i<8; ++i) if (desc.colorAttachments[i].texture)
        [colors addObject:texture(desc.colorAttachments[i].texture)];
    NSDictionary *attachments = @{@"color": colors, @"depth": texture(desc.depthAttachment.texture)};
    if (encoder) objc_setAssociatedObject(encoder, &attachmentsKey, attachments, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        record(@{@"event": @"renderPass", @"color": colors, @"depth": attachments[@"depth"]});
    }
    if ((sceneProbe || metalFXEnabled) && encoder) {
        if (__unsafe_unretained BG3MFXEncoderState *state=encoderState(encoder)) { state->buffer=self; state->colorTarget=desc.colorAttachments[0].texture; }
    }
    return encoder;
}
static id computeEncoder(id self, SEL cmd) {
    id encoder = ((id(*)(id,SEL))original(self,cmd))(self,cmd);
    record(@{@"event": @"computeEncoderCreated", @"method": NSStringFromSelector(cmd), @"class": NSStringFromClass([encoder class])});
    instrumentEncoder(encoder);
    setEncoderMode(encoder, objc_getAssociatedObject(self, &bufferScalingModeKey));
    if (metalFXEnabled) if (__unsafe_unretained BG3MFXEncoderState *state=encoderState(encoder)) state->buffer=self;
    return encoder;
}
static id computeEncoderType(id self, SEL cmd, MTLDispatchType type) {
    static thread_local void *activeBuffer = nullptr;
    void *previous = activeBuffer;
    IMP forward = original(self,cmd);
    if (activeBuffer == (__bridge void *)self) {
        std::lock_guard<std::recursive_mutex> lock(guard());
        for (Class cls=object_getClass(self); cls; cls=class_getSuperclass(cls)) {
            auto found = priorComputeMethods().find(cls);
            if (found != priorComputeMethods().end()) { forward = found->second; break; }
        }
    }
    activeBuffer = (__bridge void *)self;
    id encoder = ((id(*)(id,SEL,MTLDispatchType))forward)(self,cmd,type);
    activeBuffer = previous;
    record(@{@"event": @"computeEncoderCreated", @"method": NSStringFromSelector(cmd), @"dispatchType": @(type), @"class": NSStringFromClass([encoder class])});
    instrumentEncoder(encoder);
    setEncoderMode(encoder, objc_getAssociatedObject(self, &bufferScalingModeKey));
    if (metalFXEnabled) if (__unsafe_unretained BG3MFXEncoderState *state=encoderState(encoder)) state->buffer=self;
    return encoder;
}
static void countPresent(id drawable, SEL cmd) {
    (void)drawable; (void)cmd;
    BG3MFXFrameLogRendered();
    std::lock_guard<std::recursive_mutex> lock(guard()); ++frames;
    if (frames == 1 || frames == 120 || frames % 3600 == 0)
        record(@{@"event": @"present", @"method": NSStringFromSelector(cmd), @"frames": @(frames), @"texture": texture([drawable texture])});
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
static void present(id self, SEL cmd, id drawable) {
    if([BG3MFXFramePresenter isPresentationThread]) { ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,drawable); return; }
    if(deferPresent(self,cmd,drawable)) return;
    countPresent(drawable,cmd); logNativePresent(self,drawable);
    ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,drawable);
}
static void presentTimed(id self, SEL cmd, id drawable, double time) {
    if([BG3MFXFramePresenter isPresentationThread]) { ((void(*)(id,SEL,id,double))original(self,cmd))(self,cmd,drawable,time); return; }
    if(deferPresent(self,cmd,drawable)) return;
    countPresent(drawable,cmd); logNativePresent(self,drawable);
    ((void(*)(id,SEL,id,double))original(self,cmd))(self,cmd,drawable,time);
}
static void commit(id self, SEL cmd) {
    if (id<MTLDrawable> shown=objc_getAssociatedObject(self,&nativePresentKey)) {
        objc_setAssociatedObject(self,&nativePresentKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        CFTimeInterval committed=CACurrentMediaTime();
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
        countPresent(drawable,cmd);
#ifndef BG3MFX_NO_TRACE
        // Includes any time this buffer waited on the GPU for Metal 4 work.
        [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> done){ recordFrameGPU(done); }];
        unsigned deferred=++deferredPresents; paired ? ++pairedPresents : ++replayedPresents;
        if (deferred<=3 || deferred%120==0)
            record(@{@"event":@"frameGenerationPresentSummary",@"deferred":@(deferred),
                @"paired":@(pairedPresents.load()),@"unpaired":@(replayedPresents.load())});
#endif
    }
    ((void(*)(id,SEL))original(self,cmd))(self,cmd);
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
    if (!metalFXEnabled || frameGenerationFailed || frameGenerationDeclined || !BG3MFXFrameGenerationEnabled()) {
        NSNumber *saved=objc_getAssociatedObject(layer,&bg3DrawableCountKey);
        if (saved) {
            objc_setAssociatedObject(layer,&bg3DrawableCountKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            setLayerDrawableCount(layer,saved.unsignedIntegerValue);
            record(@{@"event":@"frameGenerationDrawableCount",@"restored":saved});
        }
        BG3MFXFrameLogBuffering((unsigned)layer.maximumDrawableCount,0);
        return ((id(*)(id,SEL))original(self,cmd))(self,cmd);
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
          framePresenter.failureHandler=^(NSError *e){failFrameGeneration(e.localizedDescription);};
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
static id commandBuffer(id self, SEL cmd) {
    SEL actual = cmd;
    { std::lock_guard<std::recursive_mutex> lock(guard());
      if ((metalFXEnabled || (sceneProbe && !sceneProbeAttempts)) && cmd == sel_registerName("commandBufferWithUnretainedReferences"))
          actual = sel_registerName("commandBuffer"); }
    // Selection changes apply to the next command buffer. Sampling the live
    // menu independently at TAA and FSR could mix two render paths in one frame.
    int mode = BG3MFXSelectedScalingMode();
    id buffer = ((id(*)(id,SEL))original(self,actual))(self,actual);
    objc_setAssociatedObject(buffer,&bufferScalingModeKey,@(mode),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
    record(@{@"event": @"commandBuffer", @"method": NSStringFromSelector(cmd), @"actualMethod": NSStringFromSelector(actual),
             @"retainedReferences": @([buffer retainedReferences])});
    hook(buffer,"renderCommandEncoderWithDescriptor:",(IMP)renderEncoder);
    hook(buffer,"computeCommandEncoder",(IMP)computeEncoder);
    hook(buffer,"computeCommandEncoderWithDispatchType:",(IMP)computeEncoderType);
    hook(buffer,"presentDrawable:",(IMP)present);
    hook(buffer,"presentDrawable:afterMinimumDuration:",(IMP)presentTimed);
    hook(buffer,"presentDrawable:atTime:",(IMP)presentTimed);
    hook(buffer,"commit",(IMP)commit);
    if (diagnostics) hook(buffer,"pushDebugGroup:",(IMP)group);
    return buffer;
}
static void instrumentQueue(id queue) {
    hook(queue,"commandBuffer",(IMP)commandBuffer);
    hook(queue,"commandBufferWithUnretainedReferences",(IMP)commandBuffer);
}
static id newQueue(id self, SEL cmd) {
    id queue = ((id(*)(id,SEL))original(self,cmd))(self,cmd);
    instrumentQueue(queue);
    return queue;
}
static id newQueueLimit(id self, SEL cmd, NSUInteger count) {
    id queue = ((id(*)(id,SEL,NSUInteger))original(self,cmd))(self,cmd,count);
    instrumentQueue(queue);
    return queue;
}
__attribute__((constructor)) static void start() {
    @autoreleasepool {
        if (diagnostics) seen = [NSMutableSet set];
        traceConstants = getenv("BG3MFX_TRACE_CONSTANTS") && strcmp(getenv("BG3MFX_TRACE_CONSTANTS"),"1") == 0;
        sceneProbe = diagnostics && getenv("BG3MFX_SCENE_PROBE") && strcmp(getenv("BG3MFX_SCENE_PROBE"),"1") == 0;
        metalFXEnabled = getenv("BG3MFX_ENABLE_METALFX") && strcmp(getenv("BG3MFX_ENABLE_METALFX"),"1") == 0;
        if (metalFXEnabled) traceConstants = YES;
        if (diagnostics) {
            constantSamples = [NSMutableDictionary dictionary];
            shaderBufferSizes = [NSMutableDictionary dictionary];
        }
        if (diagnostics) {
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"bg3mfx-trace.jsonl"];
        const char *override = getenv("BG3MFX_TRACE");
        if (override) path = [NSString stringWithUTF8String:override];
        int fd = open(path.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0600);
        output = fd >= 0 ? [[NSFileHandle alloc] initWithFileDescriptor:fd closeOnDealloc:YES] : nil;
        }
        if (metalFXEnabled && [NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) {
            NSError *menuError = nil;
            if (!BG3MFXInstallNativeMenu(menuReport,&menuError))
                failFeature([menuError.domain isEqualToString:@"BG3MFXNativeJitter"],menuError.localizedDescription);
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        record(@{@"event": @"start", @"mode": metalFXEnabled ? @"metalfx-menu" : @"diagnostic", @"device": device.name ?: @"unavailable",
                 @"spatial": @([MTLFXSpatialScalerDescriptor supportsDevice:device]),
                 @"temporal": @([MTLFXTemporalScalerDescriptor supportsDevice:device])});
        hook(device,"newCommandQueue",(IMP)newQueue);
        if (metalFXEnabled) {
            CAMetalLayer *layer=[CAMetalLayer layer];
            hook(layer,"nextDrawable",(IMP)layerNextDrawable);
            hook(layer,"setMaximumDrawableCount:",(IMP)layerSetMaximumDrawableCount);
        }
        hook(device,"newCommandQueueWithMaxCommandBufferCount:",(IMP)newQueueLimit);
        hook(device,"newRenderPipelineStateWithDescriptor:error:",(IMP)renderPipeline);
        hook(device,"newRenderPipelineStateWithDescriptor:options:reflection:error:",(IMP)renderPipelineOptions);
        hook(device,"newComputePipelineStateWithFunction:error:",(IMP)computePipeline);
        // Multiple GPUs may use different concrete driver classes.
        for (id<MTLDevice> other in MTLCopyAllDevices()) {
            hook(other,"newCommandQueue",(IMP)newQueue);
            hook(other,"newCommandQueueWithMaxCommandBufferCount:",(IMP)newQueueLimit);
            hook(other,"newRenderPipelineStateWithDescriptor:error:",(IMP)renderPipeline);
            hook(other,"newRenderPipelineStateWithDescriptor:options:reflection:error:",(IMP)renderPipelineOptions);
            hook(other,"newComputePipelineStateWithFunction:error:",(IMP)computePipeline);
        }
    }
}
// Read-only fixture access; a real BG3 process cannot expose its generated pair.
extern "C" NSDictionary *BG3MFXStandaloneGeneratedPair(id<MTLCommandBuffer> buffer) {
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) return nil;
    return objc_getAssociatedObject(buffer,&generatedPairKey);
}
extern "C" NSUInteger BG3MFXStandalonePresentedPairs(void) {
    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.larian.bg3"]) return 0;
    return framePresenter.presentedPairs;
}
