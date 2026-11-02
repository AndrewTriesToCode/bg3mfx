#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <objc/runtime.h>
#include <atomic>
#include <string>
#include <algorithm>
#include <vector>
#include "common/Feature.h"
#import "common/EventLog.h"
#import "features/metal-hooks/MetalHooks.h"
#import "features/metal-hooks/MetalHooksInternal.h"
#import "common/gpu/GPUResources.h"
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

// metal-hooks: the Metal interception layer. Shared state and the renderer
// extension's interface are in MetalHooksInternal.h; the hook points other
// features use are in MetalHooks.h.
// Discover concrete driver classes from instances; never depend on an AGX class name.
using namespace metalhooks;
namespace metalhooks {
#ifndef BG3MFX_NO_TRACE
bool traceCalls, traceShaderConstants;
#endif
BOOL runtimeEnabled, traceConstants;
thread_local HookThreadCache hookCache;
char encoderStateKey, bindingsKey, attachmentsKey;
// Encoders are used one at a time on a thread, so remember the last lookup.
// instrumentEncoder refreshes and endEncoder clears it on its own thread. Any
// thread's instrumentEncoder may release a state (or follow an encoder's
// dealloc at a reused address), so it bumps this generation and every other
// thread's cached state is looked up again: an encoder ended on another
// thread and then recycled never returns a freed state.
std::atomic<unsigned> encoderGeneration{1};
std::atomic<unsigned> originalsGeneration{1};
}
static unsigned long frames;
static unsigned long resourceCounter;
static char resourceKey, pipelineKey;
// The diagnostic runtime records what active features report. Recording every
// Metal call (binds, pipelines, passes, encoders, command buffers, presents) is
// opt-in with BG3MFX_TRACE_RENDER_CALLS=1; BG3 binds about 30,000 texture
// slots a frame, so it slows the game. BG3MFX_TRACE_CONSTANTS=1 captures
// camera shader constants and their reflection (tools/analysis/analyze_camera_trace.py).
#ifndef BG3MFX_NO_TRACE
// Diagnostic settings read once.
static bool traceTemporalChain() { static const bool value = getenv("BG3MFX_TRACE_TEMPORAL_CHAIN"); return value; }
static const char *waterfallDirectory() { static const char *value = getenv("BG3MFX_CAPTURE_WATERFALL"); return value; }
#endif
static NSMutableDictionary<NSString *, NSNumber *> *constantSamples;
static NSMutableDictionary<NSString *, NSDictionary *> *shaderBufferSizes;
#ifndef BG3MFX_NO_TRACE
#endif
// Bind dedup: BG3 rebinds about 27 fragment texture slots per call when about
// two change (92% of slots repeat the current binding), and re-sets the bound
// pipeline about 12% of the time. Bindings persist for the encoder's lifetime,
// so only changed slots and pipelines are forwarded to the driver.
static bool bindDedup;
// Hook points (MetalHooks.h), registered from the features' install before
// activation and read without locks afterwards.
template<class Observer> struct Observers {
    static constexpr size_t Max = 4;
    Observer entries[Max];
    size_t count;
    BOOL add(Observer observer);
};
static bool hooksActive;
template<class Observer> BOOL Observers<Observer>::add(Observer observer) {
    if (hooksActive || !observer || count == Max) return NO;
    entries[count++] = observer;
    return YES;
}
void BG3MFXMetalHooksFilterRedundantBinds(void) { if (!hooksActive) bindDedup = runtimeEnabled; }
static Observers<void (*)(id, BOOL)> encoderObservers;
BOOL BG3MFXMetalHooksOnNewEncoder(void (*observer)(id, BOOL)) { return encoderObservers.add(observer); }
static Observers<void (*)(MTLRenderPassDescriptor *)> renderPassObservers;
BOOL BG3MFXMetalHooksOnRenderPass(void (*observer)(MTLRenderPassDescriptor *)) { return renderPassObservers.add(observer); }
static BG3MFXDrawReplacement drawReplacement;
BOOL BG3MFXMetalHooksReplaceDraws(BG3MFXDrawReplacement replacement) {
    if (hooksActive || drawReplacement.claim || !replacement.claim || !replacement.draw) return NO;
    drawReplacement = replacement;
    return YES;
}
static void notifyNewEncoder(__unsafe_unretained id encoder, BOOL compute) {
    if (!encoder) return;
    for (size_t i = 0; i < encoderObservers.count; ++i) encoderObservers.entries[i](encoder, compute);
}
#ifndef BG3MFX_NO_TRACE
static Observers<void (*)(id, NSUInteger, id)> computeBindObservers;
static Observers<void (*)(id, NSString *)> dispatchObservers;
BOOL BG3MFXMetalHooksOnComputeBind(void (*observer)(id, NSUInteger, id)) { return computeBindObservers.add(observer); }
BOOL BG3MFXMetalHooksOnDispatch(void (*observer)(id, NSString *)) { return dispatchObservers.add(observer); }
#endif
// The renderer extension (MetalHooksInternal.h); its constant slots and
// watched vertex buffer slot are copied out for the bind hooks.
static RendererExtension renderer;
static uint32_t watchedConstants;
static NSUInteger watchedVertexSlot = NSNotFound;
BOOL metalhooks::extendRenderer(const RendererExtension &extension) {
    if (hooksActive || renderer.endEncoding || !extension.endEncoding) return NO;
    renderer = extension;
    watchedConstants = extension.constantSlots;
    watchedVertexSlot = extension.vertexBufferSlot;
    return YES;
}
// Diagnostics: binds that repeat the encoder's current binding.
static bool redundantProbe;
enum RedundantCount { TextureCalls, TextureCallsRedundant, TextureSlots, TextureSlotsRedundant,
    BufferBinds, BufferBindsRedundant, PipelineBinds, PipelineBindsRedundant, DepthBinds, DepthBindsRedundant, RedundantCounts };
static std::atomic<uint64_t> redundantCounts[RedundantCounts];
@implementation BG3MFXEncoderState
- (instancetype)init { if ((self=[super init])) mode=-1; return self; }
@end
// BG3 binds about 960 pipelines per frame from a few hundred long-lived ones.
// A small per-thread cache avoids the associated-object lookup. Each info is
// an associated object of its pipeline, so it is released exactly when the
// pipeline is: its dealloc, like every hooked pipeline creation, bumps the
// generation. A cache entry therefore never outlives its pipeline, even if
// the address is reused by a pipeline created through a path we do not hook.
static std::atomic<unsigned> pipelineGeneration{1};
@implementation BG3MFXPipelineInfo
- (void)dealloc { pipelineGeneration.fetch_add(1, std::memory_order_release); }
@end
static inline void *pipelineInfoPointer(__unsafe_unretained id state) {
    unsigned generation = pipelineGeneration.load(std::memory_order_acquire);
    PipelineCacheEntry &entry = hookCache.pipelines[((uintptr_t)(__bridge const void *)state >> 4) & 63];
    if (entry.pipeline == (__bridge const void *)state && entry.generation == generation)
        return entry.info;
    __unsafe_unretained BG3MFXPipelineInfo *info = objc_getAssociatedObject(state, &pipelineKey);
    entry = {(__bridge const void *)state, (__bridge void *)info, generation};
    return (__bridge void *)info;
}
static void forgetEncoder(id encoder) {
    if ((__bridge const void *)encoder == hookCache.encoder) { hookCache.encoder = nullptr; hookCache.state = nullptr; }
}
// Diagnostics: the renderer extension's mode for the encoder, -1 if unknown.
[[maybe_unused]] static int encoderMode(__unsafe_unretained id encoder) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    return s ? s->mode : -1;
}
NSDictionary *metalhooks::boundTextures(id encoder) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    if (!s) return nil;
    NSMutableDictionary *textures=[NSMutableDictionary dictionary];
    for (NSUInteger i=0;i<EncoderSlots;++i) if (s->textures[i]) textures[@(i).stringValue]=s->textures[i];
    return textures;
}
// Shaders whose constants BG3MFX_TRACE_CONSTANTS=1 snapshots at encoder end:
// the camera constants, and PPSAO_Blur_PS's direction (its two passes bind
// one shared buffer).
static bool snapshotShader(NSString *name) {
    return traceShaderConstants && ([name isEqualToString:@"PPTAA_PS"] || [name isEqualToString:@"VelocityBufferCamera_PS"] ||
                                    [name isEqualToString:@"PPSAO_Blur_PS"] || [name isEqualToString:@"BG3MFXConstantsSmoke"]);
}
static bool constantsNeeded() { return traceCalls || traceShaderConstants || watchedConstants; }
static bool constantInputNeeded(NSUInteger index) {
    return index < 32 && (traceCalls || traceShaderConstants || (watchedConstants >> index & 1));
}
#ifndef BG3MFX_NO_TRACE
static void record(NSDictionary *event);
#endif
static EncoderStage bindingStage(SEL cmd) {
    static SEL vertex[]={@selector(setVertexBuffer:offset:atIndex:),@selector(setVertexBuffers:offsets:withRange:),
        @selector(setVertexBufferOffset:atIndex:),@selector(setVertexBytes:length:atIndex:)};
    static SEL fragment[]={@selector(setFragmentBuffer:offset:atIndex:),@selector(setFragmentBuffers:offsets:withRange:),
        @selector(setFragmentBufferOffset:atIndex:),@selector(setFragmentBytes:length:atIndex:)};
    for (SEL v:vertex) if (cmd==v) return StageVertex;
    for (SEL f:fragment) if (cmd==f) return StageFragment;
    return StageCompute;
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
// Diagnostics: count binds that repeat the encoder's current binding. Called
// before forwarding; compute bindings are not counted.
static void countBuffers(__unsafe_unretained id self, SEL cmd, id<MTLBuffer> const *buffers, const NSUInteger *offsets, NSRange range, bool offsetOnly) {
#ifdef BG3MFX_NO_TRACE
    (void)self; (void)cmd; (void)buffers; (void)offsets; (void)range; (void)offsetOnly;
#else
    if (!diagnostics || !redundantProbe) return;
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(self);
    EncoderStage stage=bindingStage(cmd);
    if (!s || stage==StageCompute) return;
    for (NSUInteger i=0; i<range.length; ++i) {
        NSUInteger index=range.location+i;
        if (index>=32) continue;
        __unsafe_unretained id buffer=offsetOnly ? s->seenBuffer[stage][index] : buffers[i];
        bool same=buffer && s->seenBuffer[stage][index]==buffer && s->seenOffset[stage][index]==offsets[i];
        ++redundantCounts[BufferBinds];
        if (same) ++redundantCounts[BufferBindsRedundant];
        s->seenBuffer[stage][index]=buffer; s->seenOffset[stage][index]=offsets[i];
    }
#endif
}
static void countTextures(__unsafe_unretained id self, SEL cmd, id<MTLTexture> const *textures, NSRange range) {
#ifdef BG3MFX_NO_TRACE
    (void)self; (void)cmd; (void)textures; (void)range;
#else
    if (!diagnostics || !redundantProbe) return;
    static SEL one=@selector(setFragmentTexture:atIndex:), many=@selector(setFragmentTextures:withRange:);
    if (cmd!=one && cmd!=many) return;
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(self);
    if (!s) return;
    bool callSame=true;
    for (NSUInteger i=0; i<range.length; ++i) {
        NSUInteger index=range.location+i;
        bool same=index<64 && s->seenTexture[index]==textures[i];
        ++redundantCounts[TextureSlots];
        if (same) ++redundantCounts[TextureSlotsRedundant]; else callSame=false;
        if (index<64) s->seenTexture[index]=textures[i];
    }
    ++redundantCounts[TextureCalls];
    if (callSame) ++redundantCounts[TextureCallsRedundant];
#endif
}
static void flushRedundantCounts() {
    static unsigned long lastFrame;
    if (!diagnostics || !redundantProbe || frames-lastFrame<120) return;
    [[maybe_unused]] double n=(double)(frames-lastFrame);
    lastFrame=frames;
    uint64_t c[RedundantCounts];
    for (int i=0; i<RedundantCounts; ++i) c[i]=redundantCounts[i].exchange(0);
    record(@{@"event":@"redundantBinds",@"frame":@(frames),
        @"textureCallsPerFrame":@(c[TextureCalls]/n),@"textureCallsRedundant":@(c[TextureCallsRedundant]/n),
        @"textureSlotsPerFrame":@(c[TextureSlots]/n),@"textureSlotsRedundant":@(c[TextureSlotsRedundant]/n),
        @"bufferBindsPerFrame":@(c[BufferBinds]/n),@"bufferBindsRedundant":@(c[BufferBindsRedundant]/n),
        @"pipelineBindsPerFrame":@(c[PipelineBinds]/n),@"pipelineBindsRedundant":@(c[PipelineBindsRedundant]/n),
        @"depthBindsPerFrame":@(c[DepthBinds]/n),@"depthBindsRedundant":@(c[DepthBindsRedundant]/n)});
}
// The vertex buffer at the renderer extension's watched slot.
static void noteWatchedBuffer(__unsafe_unretained id encoder, SEL cmd, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset, bool offsetOnly) {
    if (bindingStage(cmd) != StageVertex) return;
    if (__unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder)) {
        if (!offsetOnly) s->watchedBuffer = buffer;
        s->watchedOffset = offset;
    }
}
static void bindBuffer(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset, NSUInteger index) {
    if (diagnostics && redundantProbe) { id<MTLBuffer> const one[1]={buffer}; countBuffers(self,cmd,one,&offset,NSMakeRange(index,1),false); }
    ((void(*)(id,SEL,id,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,buffer,offset,index);
    if (index == watchedVertexSlot) noteWatchedBuffer(self,cmd,buffer,offset,false);
    if (!constantInputNeeded(index)) return;
    if (ConstantBinding *b=constantSlot(self,bindingStage(cmd),index)) { b->buffer=buffer; b->offset=offset; b->hasBytes=false; b->length=0; }
}
static void bindBuffers(__unsafe_unretained id self, SEL cmd, id<MTLBuffer> const *buffers, const NSUInteger *offsets, NSRange range) {
    countBuffers(self,cmd,buffers,offsets,range,false);
    ((void(*)(id,SEL,id<MTLBuffer> const *,const NSUInteger *,NSRange))original(self,cmd))(self,cmd,buffers,offsets,range);
    if (NSLocationInRange(watchedVertexSlot,range))
        noteWatchedBuffer(self,cmd,buffers[watchedVertexSlot-range.location],offsets[watchedVertexSlot-range.location],false);
    if (!constantsNeeded()) return;
    EncoderStage stage=bindingStage(cmd);
    for (NSUInteger i=0; i<range.length; ++i) {
        if (!constantInputNeeded(range.location+i)) continue;
        if (ConstantBinding *b=constantSlot(self,stage,range.location+i)) { b->buffer=buffers[i]; b->offset=offsets[i]; b->hasBytes=false; b->length=0; }
    }
}
#ifndef BG3MFX_NO_TRACE
// Diagnostics: compute binds and dispatches for the features that observe them.
static void noteComputeBind(__unsafe_unretained id encoder, NSUInteger index, __unsafe_unretained id buffer) {
    for (size_t i = 0; i < computeBindObservers.count; ++i) computeBindObservers.entries[i](encoder, index, buffer);
}
static void computeBindBuffer(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset, NSUInteger index) {
    ((void(*)(id,SEL,id,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,buffer,offset,index);
    noteComputeBind(self,index,buffer);
}
static void computeBindBuffers(__unsafe_unretained id self, SEL cmd, id<MTLBuffer> const *buffers, const NSUInteger *offsets, NSRange range) {
    ((void(*)(id,SEL,id<MTLBuffer> const *,const NSUInteger *,NSRange))original(self,cmd))(self,cmd,buffers,offsets,range);
    for (NSUInteger i=0; i<range.length; ++i) noteComputeBind(self,range.location+i,buffers[i]);
}
static void computeBindBytes(__unsafe_unretained id self, SEL cmd, const void *bytes, NSUInteger length, NSUInteger index) {
    ((void(*)(id,SEL,const void *,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,bytes,length,index);
    noteComputeBind(self,index,bytes && length ? (id)kCFNull : nil);
}
static void noteDispatch(__unsafe_unretained id encoder, NSString *name) {
    for (size_t i = 0; i < dispatchObservers.count; ++i) dispatchObservers.entries[i](encoder, name);
}
#endif
static void bufferOffset(__unsafe_unretained id self, SEL cmd, NSUInteger offset, NSUInteger index) {
    if (diagnostics && redundantProbe) countBuffers(self,cmd,nullptr,&offset,NSMakeRange(index,1),true);
    ((void(*)(id,SEL,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,offset,index);
    if (index == watchedVertexSlot) noteWatchedBuffer(self,cmd,nil,offset,true);
    if (!constantInputNeeded(index)) return;
    if (ConstantBinding *b=constantSlot(self,bindingStage(cmd),index)) if (b->buffer) b->offset=offset;
}
static void bindBytes(__unsafe_unretained id self, SEL cmd, const void *bytes, NSUInteger length, NSUInteger index) {
    ((void(*)(id,SEL,const void *,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,bytes,length,index);
    if (index == watchedVertexSlot) noteWatchedBuffer(self,cmd,nil,0,false);
    if (!constantInputNeeded(index)) return;
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
// Features installed by root report through its log directly (all important),
// and the renderer extension keeps its own list; these are the hooks' own events.
static void record(NSDictionary *event) {
    NSString *kind = event[@"event"];
    BOOL important = [kind hasPrefix:@"waterfall"] || [kind hasPrefix:@"cullTiming"] ||
        [kind isEqualToString:@"redundantBinds"] || [kind isEqualToString:@"metal4Residency"] || [kind isEqualToString:@"metal4BridgeStall"];
    BG3MFXEventLogWrite(event, important);
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
    const char *directory=waterfallDirectory();
    if (!directory || !*directory) return;
    NSDictionary *pipelineState=pipelineDescription(encoder);
    NSString *vertex=pipelineState[@"vertex"];
    if (![vertex containsString:@"Water_Fall_Foam_STI_DEP_vertexMain"] &&
        ![vertex containsString:@"Water_Fall_Foam_STI_VEL_vertexMain"]) return;
    std::lock_guard<std::recursive_mutex> lock(guard());
    static NSMutableDictionary *counts=[NSMutableDictionary dictionary];
    static NSUInteger totalBytes=0, serial=0;
    NSString *key=[NSString stringWithFormat:@"%d:%@",encoderMode(encoder),vertex];
    NSUInteger count=[counts[key] unsignedIntegerValue];
    if (count>=4) return;
    counts[key]=@(count+1);
    NSString *root=[NSString stringWithUTF8String:directory];
    if (![root isAbsolutePath]) return;
    [NSFileManager.defaultManager createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *stem=[NSString stringWithFormat:@"draw-%lu-mode-%d",(unsigned long)serial++,encoderMode(encoder)];
    NSMutableDictionary *bindings=[constantBindings(encoder) mutableCopy];
    id<MTLBuffer> indexBuffer=draw[@"indexBuffer"];
    if (indexBuffer) bindings[@"index"]=@{@"buffer":indexBuffer,@"offset":draw[@"indexOffset"] ?: @0};
    NSMutableDictionary *snapshots=[NSMutableDictionary dictionary];
    NSMutableArray *copies=objc_getAssociatedObject(encoder,&waterfallCopiesKey);
    if (!copies) { copies=[NSMutableArray array]; objc_setAssociatedObject(encoder,&waterfallCopiesKey,copies,OBJC_ASSOCIATION_RETAIN_NONATOMIC); noteAssociation(encoder,AssocWaterfall); }
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
    NSDictionary *info=@{@"pipeline":pipelineState,@"mode":@(encoderMode(encoder)),@"draw":drawInfo,@"bindings":snapshots,
        @"limitation":@"Bounded buffer capture; noise texture is not captured. Private buffers copied after this encoder."};
    [[NSJSONSerialization dataWithJSONObject:info options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[root stringByAppendingPathComponent:[stem stringByAppendingString:@".json"]] atomically:YES];
    record(@{@"event":@"waterfallDrawCaptured",@"path":[root stringByAppendingPathComponent:[stem stringByAppendingString:@".json"]],@"mode":@(encoderMode(encoder))});
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
IMP metalhooks::originalSlow(Class concrete, SEL selector, unsigned generation, OriginalCacheEntry &entry) {
    std::lock_guard<std::recursive_mutex> lock(guard());
    for (Class cls = concrete; cls; cls = class_getSuperclass(cls)) {
        auto it = originals().find({cls, selector});
        if (it != originals().end()) { entry = {concrete, selector, it->second, generation}; return it->second; }
    }
    abort();
}
void metalhooks::hook(id object, const char *name, IMP replacement) {
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
#ifndef BG3MFX_NO_TRACE
static void setDepthStencilHook(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id state) {
    ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,state);
    if (__unsafe_unretained BG3MFXEncoderState *s = encoderState(self)) {
        ++redundantCounts[DepthBinds];
        if (s->seenDepth==state) ++redundantCounts[DepthBindsRedundant];
        s->seenDepth=state;
    }
}
#endif
NSDictionary *metalhooks::texture(id<MTLTexture> t) {
    if (!t) return @{};
    std::lock_guard<std::recursive_mutex> lock(guard());
    NSNumber *identifier = objc_getAssociatedObject(t, &resourceKey);
    if (!identifier) {
        identifier = @(++resourceCounter);
        objc_setAssociatedObject(t, &resourceKey, identifier, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return @{@"id": identifier, @"label": t.label ?: @"", @"width": @(t.width), @"height": @(t.height),
             @"format": @(t.pixelFormat), @"usage": @(t.usage), @"storage": @(t.storageMode),
             @"hazardTracking": @(t.hazardTrackingMode), @"textureType": @(t.textureType),
             @"arrayLength": @(t.arrayLength), @"sampleCount": @(t.sampleCount)};
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
    if (!traceCalls) {
        // Metal permits textures to be bound before pipeline state. Retain the
        // three required slots independently of shader identification. The
        // index test comes first: BG3 binds about 30,000 slots per frame.
        if (index > 2 || !runtimeEnabled) return;
    }
    if (runtimeEnabled && index < EncoderSlots)
        if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self)) s->textures[index]=t;
    if (traceCalls) {
        std::lock_guard<std::recursive_mutex> lock(guard());
        NSString *slot = [NSString stringWithFormat:@"%lu", (unsigned long)index];
        NSMutableDictionary *bindings = objc_getAssociatedObject(self, &bindingsKey);
        if (!bindings) {
            bindings = [NSMutableDictionary dictionary];
            objc_setAssociatedObject(self, &bindingsKey, bindings, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            noteAssociation(self,AssocBindings);
        }
        if (t) bindings[slot] = texture(t); else [bindings removeObjectForKey:slot];
        if (t) record(@{@"event": NSStringFromSelector(cmd), @"encoder": [self label] ?: @"", @"pipeline": pipelineDescription(self) ?: @{}, @"index": @(index), @"texture": texture(t)});
    }
}
static void bindTexture(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id<MTLTexture> t, NSUInteger index) {
    if (diagnostics && redundantProbe) { id<MTLTexture> const one[1]={t}; countTextures(self,cmd,one,NSMakeRange(index,1)); }
    if (bindDedup && cmd==@selector(setFragmentTexture:atIndex:))
        if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self))
            if (!s->bindFilter.forwardTexture(t,index)) { rememberTexture(self,cmd,t,index); return; }
    ((void(*)(id,SEL,id,NSUInteger))original(self,cmd))(self,cmd,t,index);
    rememberTexture(self,cmd,t,index);
}
static void bindTextures(__unsafe_unretained id self, SEL cmd, id<MTLTexture> const *textures, NSRange range) {
    countTextures(self,cmd,textures,range);
    __unsafe_unretained BG3MFXEncoderState *s=bindDedup && cmd==@selector(setFragmentTextures:withRange:) ? encoderState(self) : nil;
    auto forward=((void(*)(id,SEL,id<MTLTexture> const *,NSRange))original(self,cmd));
    if (s) s->bindFilter.forwardTextures(textures,range,[&](id<MTLTexture> const *run, NSRange slots) {
        forward(self,cmd,run,slots);
    });
    else forward(self,cmd,textures,range);
    for (NSUInteger i=0; i<range.length; ++i) rememberTexture(self,cmd,textures[i],range.location+i);
}
// Ends the encoder in Metal; the renderer extension's endEncoding wraps it.
static void finishEncoder(id self, SEL cmd, BG3MFXEncoderState *encoderRecord, id<MTLCommandBuffer> commandBuffer) {
#ifndef BG3MFX_NO_TRACE
    NSArray *waterfallCopies=nil;
    if (encoderAssociations(encoderRecord) & AssocWaterfall) {
        waterfallCopies=[objc_getAssociatedObject(self,&waterfallCopiesKey) copy];
        objc_setAssociatedObject(self,&waterfallCopiesKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
#else
    (void)commandBuffer;
#endif
    if (encoderRecord) encoderRecord->buffer = nil;
    if (traceCalls) record(@{@"event": @"encoderEnd", @"pipeline": pipelineDescription(self) ?: @{},
             @"bindings": objc_getAssociatedObject(self, &bindingsKey) ?: @{},
             @"attachments": objc_getAssociatedObject(self, &attachmentsKey) ?: @{}});
    if (traceConstants) {
        std::lock_guard<std::recursive_mutex> lock(guard());
        NSDictionary *state = pipelineDescription(self);
        NSString *fragment = state[@"fragment"] ?: @"";
        if (snapshotShader(fragment) && [constantSamples[fragment] unsignedIntegerValue] < 8) {
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
                    @"storage": buffer ? @(buffer.storageMode) : @(-1),
                    @"buffer": buffer ? [NSString stringWithFormat:@"%p",(__bridge void *)buffer] : @""};
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
}
static void endEncoder(id self, SEL cmd) {
    __unsafe_unretained BG3MFXEncoderState *encoderRecord = encoderState(self);
    id<MTLCommandBuffer> commandBuffer = encoderBuffer(self);
    if (renderer.endEncoding) renderer.endEncoding(self,cmd,encoderRecord,commandBuffer,finishEncoder);
    else finishEncoder(self,cmd,encoderRecord,commandBuffer);
    if (encoderRecord) { for (auto &texture:encoderRecord->textures) texture=nil; encoderRecord->colorTarget=nil; }
    forgetEncoder(self);
}
static void pipeline(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id state) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(self);
    if (!(bindDedup && s && !BG3MFXBindFilter::forwardPipeline(s->pipeline,state)))
        ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,state);
#ifndef BG3MFX_NO_TRACE
    if (redundantProbe && s) {
        ++redundantCounts[PipelineBinds];
        if (s->seenPipeline==state) ++redundantCounts[PipelineBindsRedundant];
        s->seenPipeline=state;
    }
#endif
    __unsafe_unretained BG3MFXPipelineInfo *info = state ? (__bridge BG3MFXPipelineInfo *)pipelineInfoPointer(state) : nil;
    NSDictionary *description = info ? info->description : nil;
    if (traceCalls && !description) description = @{@"label": [state label] ?: @""};
    if (s) {
        bool slow = info && info->kind;
        if (renderer.pipelineBound && renderer.pipelineBound(self,s,info,description)) slow = true;
        s->replaceDraws = info && info->replaceDraws;
        s->pipeline=state; s->description=description;
        s->kind=info ? info->kind : 0;
        s->slowDraw=slow;
    }
    if (traceCalls) record(@{@"event": NSStringFromSelector(cmd), @"encoder": [self label] ?: @"", @"pipeline": description});
}
// Camera shader constants and their reflection (BG3MFX_TRACE_CONSTANTS=1),
// and whatever the renderer extension reflects.
static BOOL reflectedShader(MTLRenderPipelineDescriptor *desc) {
    NSString *name = desc.fragmentFunction.name;
    if (renderer.wantsReflection && renderer.wantsReflection(desc)) return YES;
    return snapshotShader(name);
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
// Classifies a render pipeline once, at creation (see BG3MFXPipelineInfo).
static void renderPipelineCreated(id self, MTLRenderPipelineDescriptor *desc, id state, MTLRenderPipelineReflection *reflection) {
    NSString *fragment = desc.fragmentFunction.name;
    NSDictionary *description = traceCalls || snapshotShader(fragment) ? @{@"vertex": desc.vertexFunction.name ?: @"", @"fragment": fragment ?: @"", @"label": desc.label ?: @""} : nil;
#ifndef BG3MFX_NO_TRACE
    NSDictionary *waterfall=waterfallLayout(desc);
    if (waterfall) { NSMutableDictionary *expanded=[description mutableCopy]; expanded[@"vertexLayout"]=waterfall; description=expanded; }
#endif
    if (state) {
        BG3MFXPipelineInfo *info = [BG3MFXPipelineInfo new];
        info->description = description;
        if (renderer.renderPipelineCreated) renderer.renderPipelineCreated(desc, state, reflection, info);
        description = info->description;
        static SEL create = @selector(newRenderPipelineStateWithDescriptor:error:);
        info->replaceDraws = drawReplacement.claim && drawReplacement.claim(self, desc, state, (BG3MFXCreateRenderPipeline)original(self,create));
        objc_setAssociatedObject(state, &pipelineKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pipelineGeneration.fetch_add(1, std::memory_order_release);
    }
    if (traceCalls) record(@{@"event": @"renderPipeline", @"pipeline": description, @"success": @(state != nil)});
}
static id renderPipeline(id self, SEL cmd, MTLRenderPipelineDescriptor *desc, NSError **error) {
    if (renderer.prepareRenderPipeline) desc = renderer.prepareRenderPipeline(self, desc);
    id state;
    MTLRenderPipelineReflection *reflection = nil;
    if (reflectedShader(desc)) {
        SEL optionsSelector = sel_registerName("newRenderPipelineStateWithDescriptor:options:reflection:error:");
        NSError *reflectionError = nil;
        state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,optionsSelector))
            (self,optionsSelector,desc,MTLPipelineOptionBindingInfo|MTLPipelineOptionBufferTypeInfo,&reflection,&reflectionError);
        if (state) recordReflection(desc,reflection);
        else record(@{@"event": @"shaderReflectionFailed", @"fragment": desc.fragmentFunction.name ?: @"", @"error": reflectionError.description ?: @""});
        if (!state) state = ((id(*)(id,SEL,id,NSError **))original(self,cmd))(self,cmd,desc,error);
    } else state = ((id(*)(id,SEL,id,NSError **))original(self,cmd))(self,cmd,desc,error);
    renderPipelineCreated(self, desc, state, reflection);
    return state;
}
static id renderPipelineOptions(id self, SEL cmd, MTLRenderPipelineDescriptor *desc, MTLPipelineOption options, MTLRenderPipelineReflection **reflection, NSError **error) {
    if (renderer.prepareRenderPipeline) desc = renderer.prepareRenderPipeline(self, desc);
    MTLRenderPipelineReflection *extraReflection = nil;
    id state;
    if (reflectedShader(desc)) {
        NSError *reflectionError = nil;
        state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,cmd))
            (self,cmd,desc,options|MTLPipelineOptionBindingInfo|MTLPipelineOptionBufferTypeInfo,&extraReflection,&reflectionError);
        if (state) {
            if (reflection) *reflection = extraReflection;
            recordReflection(desc,extraReflection);
        } else state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,cmd))(self,cmd,desc,options,reflection,error);
    } else state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,cmd))(self,cmd,desc,options,reflection,error);
    renderPipelineCreated(self, desc, state, extraReflection);
    return state;
}
static id computePipeline(id self, SEL cmd, id<MTLFunction> function, NSError **error) {
    id state = ((id(*)(id,SEL,id,NSError **))original(self,cmd))(self,cmd,function,error);
    NSString *name = function.name;
    NSDictionary *description = (traceCalls || (renderer.recognizedCompute && renderer.recognizedCompute(name))) ?
        @{@"compute": name ?: @""} : nil;
    if (state) {
        BG3MFXPipelineInfo *info = [BG3MFXPipelineInfo new];
        info->description = description;
        objc_setAssociatedObject(state, &pipelineKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pipelineGeneration.fetch_add(1, std::memory_order_release);
    }
    if (traceCalls) record(@{@"event": @"computePipeline", @"pipeline": description, @"success": @(state != nil)});
    return state;
}
NSData *metalhooks::constantBytes(id encoder, EncoderStage stage, NSUInteger index, NSUInteger count) {
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
static void bindViewport(__unsafe_unretained id self, SEL cmd, MTLViewport v) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(self);
    ((void(*)(id,SEL,MTLViewport))original(self,cmd))(self,cmd,v);
    if (s) { s->viewport=v; s->hasViewport=true; }
}
static void bindScissor(__unsafe_unretained id self, SEL cmd, MTLScissorRect r) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(self);
    ((void(*)(id,SEL,MTLScissorRect))original(self,cmd))(self,cmd,r);
    if (s) { s->scissor=r; s->hasScissor=true; }
}
static void sampler(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id state, NSUInteger index) {
    ((void(*)(id,SEL,id,NSUInteger))original(self,cmd))(self,cmd,state,index);
    if(index==0) if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self)) s->sampler0=state;
}
static void samplers(__unsafe_unretained id self, SEL cmd, id<MTLSamplerState> const *states, NSRange range) {
    ((void(*)(id,SEL,id<MTLSamplerState> const *,NSRange))original(self,cmd))(self,cmd,states,range);
    if(range.location==0 && range.length) if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self)) s->sampler0=states[0];
}
// Draws with pipelines nothing inspects skip all inspection (call tracing
// excepted); the renderer extension reads lastDrawOther and anyDrawOther.
static bool fastDraw(__unsafe_unretained id encoder) {
    if (traceCalls) return false;
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    if (s && s->slowDraw) return false;
    if (s) { s->lastDrawOther=true; s->anyDrawOther=true; }
    return true;
}
// A draw the fast path did not take: the renderer extension's, if any.
static void slowDraw(__unsafe_unretained id encoder, const DrawCall &call, void (^forward)(void)) {
    if (renderer.draw) renderer.draw(encoder,encoderState(encoder),call,forward);
    else forward();
}
// original() for a selector this encoder's class may not have hooked.
IMP metalhooks::originalOrCurrent(id object, SEL selector) {
    std::lock_guard<std::recursive_mutex> lock(guard());
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        auto it = originals().find({cls, selector});
        if (it != originals().end()) return it->second;
    }
    return class_getMethodImplementation(object_getClass(object),selector);
}
// A draw with a claimed pipeline bound, through the draw replacement.
static bool replacedDrawBound(__unsafe_unretained id encoder) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    return s && s->replaceDraws;
}
static bool replacedDraw(__unsafe_unretained id encoder, void (^call)(void)) {
    static const BG3MFXEncoderCalls calls = {
        [](__unsafe_unretained id e, __unsafe_unretained id state) {
            static SEL set = @selector(setRenderPipelineState:);
            ((void(*)(id,SEL,id))original(e,set))(e,set,state);
        },
        [](__unsafe_unretained id e, __unsafe_unretained id<MTLTexture> t, NSUInteger index) {
            static SEL set = @selector(setFragmentTexture:atIndex:);
            ((void(*)(id,SEL,id,NSUInteger))original(e,set))(e,set,t,index);
            // Keep bind dedup's record true to what Metal now holds.
            if (bindDedup && index < 64) if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(e)) s->bindFilter.fragmentTexture[index]=t;
        },
    };
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    return drawReplacement.draw(encoder,s->pipeline,s->textures[0],s->textures[1],calls,call);
}
static void draw(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger start, NSUInteger count) {
    if (replacedDrawBound(self) && replacedDraw(self,^{ ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count); })) return;
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count); return; }
    slowDraw(self,DrawCall{type,start,count,1,0,0,nil,0,MTLIndexTypeUInt16,false},^{ ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count); });
}
static void drawInstances(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger start, NSUInteger count, NSUInteger instances) {
    if (replacedDrawBound(self) && replacedDraw(self,^{ ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count,instances); })) return;
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count,instances); return; }
    slowDraw(self,DrawCall{type,start,count,instances,0,0,nil,0,MTLIndexTypeUInt16,false},^{ ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count,instances); });
}
static void drawBaseInstance(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger start, NSUInteger count, NSUInteger instances, NSUInteger base) {
    if (replacedDrawBound(self) && replacedDraw(self,^{ ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count,instances,base); })) return;
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count,instances,base); return; }
    slowDraw(self,DrawCall{type,start,count,instances,base,0,nil,0,MTLIndexTypeUInt16,false},^{ ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,NSUInteger,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,start,count,instances,base); });
}
static void drawIndexed(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset) {
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset); return; }
#ifndef BG3MFX_NO_TRACE
    captureWaterfall(self,@{@"indexCount":@(count),@"indexType":@(indexType),@"indexBuffer":buffer,@"indexOffset":@(offset),@"instances":@1,@"baseVertex":@0,@"baseInstance":@0});
#endif
    slowDraw(self,DrawCall{type,0,count,1,0,0,buffer,offset,indexType,true},^{ ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset); });
}
static void drawIndexedInstances(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset, NSUInteger instances) {
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances); return; }
#ifndef BG3MFX_NO_TRACE
    captureWaterfall(self,@{@"indexCount":@(count),@"indexType":@(indexType),@"indexBuffer":buffer,@"indexOffset":@(offset),@"instances":@(instances),@"baseVertex":@0,@"baseInstance":@0});
#endif
    slowDraw(self,DrawCall{type,0,count,instances,0,0,buffer,offset,indexType,true},^{ ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances); });
}
static void drawIndexedBase(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset, NSUInteger instances, NSInteger baseVertex, NSUInteger baseInstance) {
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger,NSInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances,baseVertex,baseInstance); return; }
#ifndef BG3MFX_NO_TRACE
    captureWaterfall(self,@{@"indexCount":@(count),@"indexType":@(indexType),@"indexBuffer":buffer,@"indexOffset":@(offset),@"instances":@(instances),@"baseVertex":@(baseVertex),@"baseInstance":@(baseInstance)});
#endif
    slowDraw(self,DrawCall{type,0,count,instances,baseInstance,baseVertex,buffer,offset,indexType,true},^{ ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger,NSInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances,baseVertex,baseInstance); });
}
static void dispatch(id self, SEL cmd, MTLSize grid, MTLSize threads) {
    NSString *pipelineName = pipelineDescription(self)[@"compute"];
    DispatchAction action = renderer.dispatch ? renderer.dispatch(self,cmd,pipelineName) : DispatchNative;
    if (action == DispatchDropped) return;
#ifndef BG3MFX_NO_TRACE
    if (diagnostics) noteDispatch(self,pipelineName);
#endif
    if (traceCalls) {
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
    if (action == DispatchSuppressed) return;
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
    // Drivers recycle encoder objects: start each one with fresh state, and
    // drop whatever the previous user of this object left. Its state records
    // which keys were set; an object never seen before is cleared in full.
    uint16_t stale = AssocAll;
    if (encoder) {
        __unsafe_unretained BG3MFXEncoderState *previous = objc_getAssociatedObject(encoder,&encoderStateKey);
        if (previous) stale = previous->associations;
    }
    if (encoder && renderer.encoderRecycled) renderer.encoderRecycled(encoder,stale);
    if (encoder) {
        BG3MFXEncoderState *state = [BG3MFXEncoderState new];
        unsigned generation = encoderGeneration.fetch_add(1, std::memory_order_acq_rel) + 1;
        objc_setAssociatedObject(encoder,&encoderStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        hookCache.encoder = (__bridge const void *)encoder; hookCache.state = (__bridge void *)state;
        hookCache.encoderGeneration = generation;
    }
    if (stale & AssocBindings) objc_setAssociatedObject(encoder, &bindingsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (stale & AssocAttachments) objc_setAssociatedObject(encoder, &attachmentsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
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
#ifndef BG3MFX_NO_TRACE
        if (redundantProbe) hook(encoder,"setDepthStencilState:",(IMP)setDepthStencilHook);
#endif
    }
    if (traceCalls) hook(encoder,"setLabel:",(IMP)label);
#ifndef BG3MFX_NO_TRACE
    if (diagnostics && (computeBindObservers.count || dispatchObservers.count)) {
        hook(encoder,"setBuffer:offset:atIndex:",(IMP)computeBindBuffer);
        hook(encoder,"setBuffers:offsets:withRange:",(IMP)computeBindBuffers);
        hook(encoder,"setBytes:length:atIndex:",(IMP)computeBindBytes);
    }
#endif
    if (traceCalls) hook(encoder,"pushDebugGroup:",(IMP)group);
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
    if (traceCalls) record(@{@"event": @"computeHookRefreshed", @"class": NSStringFromClass(cls)});
}
static id renderEncoder(id self, SEL cmd, MTLRenderPassDescriptor *desc) {
    refreshComputeHook(self);
    if (traceCalls) {
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
    bool passChanged = false;
    MTLRenderPassDescriptor *pass = renderer.prepareRenderPass ? renderer.prepareRenderPass(desc,&passChanged) : desc;
    id encoder = ((id(*)(id,SEL,id))original(self,cmd))(self,cmd,pass);
    instrumentEncoder(encoder);
    notifyNewEncoder(encoder,NO);
    for (size_t i = 0; i < renderPassObservers.count; ++i) renderPassObservers.entries[i](desc);
    flushRedundantCounts();
    if (traceCalls) {
    NSMutableArray *colors = [NSMutableArray array];
    for (NSUInteger i=0; i<8; ++i) if (desc.colorAttachments[i].texture)
        [colors addObject:texture(desc.colorAttachments[i].texture)];
    NSDictionary *attachments = @{@"color": colors, @"depth": texture(desc.depthAttachment.texture)};
    if (encoder) objc_setAssociatedObject(encoder, &attachmentsKey, attachments, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    noteAssociation(encoder,AssocAttachments);
        record(@{@"event": @"renderPass", @"color": colors, @"depth": attachments[@"depth"]});
    }
    if (runtimeEnabled && encoder) {
        if (__unsafe_unretained BG3MFXEncoderState *state=encoderState(encoder)) { state->buffer=self; state->colorTarget=desc.colorAttachments[0].texture; }
    }
    if (renderer.encoderCreated) renderer.encoderCreated(encoder,self,desc,passChanged);
    return encoder;
}
static id computeEncoder(id self, SEL cmd) {
    id encoder = ((id(*)(id,SEL))original(self,cmd))(self,cmd);
    if (traceCalls) record(@{@"event": @"computeEncoderCreated", @"method": NSStringFromSelector(cmd), @"class": NSStringFromClass([encoder class])});
    instrumentEncoder(encoder);
    notifyNewEncoder(encoder,YES);
    if (runtimeEnabled) if (__unsafe_unretained BG3MFXEncoderState *state=encoderState(encoder)) state->buffer=self;
    if (renderer.encoderCreated) renderer.encoderCreated(encoder,self,nil,false);
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
    if (traceCalls) record(@{@"event": @"computeEncoderCreated", @"method": NSStringFromSelector(cmd), @"dispatchType": @(type), @"class": NSStringFromClass([encoder class])});
    instrumentEncoder(encoder);
    notifyNewEncoder(encoder,YES);
    if (runtimeEnabled) if (__unsafe_unretained BG3MFXEncoderState *state=encoderState(encoder)) state->buffer=self;
    if (renderer.encoderCreated) renderer.encoderCreated(encoder,self,nil,false);
    return encoder;
}
void metalhooks::countPresent(id drawable, SEL cmd) {
    (void)drawable; (void)cmd;
    std::lock_guard<std::recursive_mutex> lock(guard()); ++frames;
    if (frames == 1 || frames == 120 || frames % 3600 == 0)
        if (traceCalls) record(@{@"event": @"present", @"method": NSStringFromSelector(cmd), @"frames": @(frames), @"texture": texture([drawable texture])});
}
static void present(id self, SEL cmd, id drawable) {
    PresentAction action = renderer.present ? renderer.present(self,cmd,drawable) : PresentCounted;
    if (action == PresentHandled) return;
    if (action == PresentCounted) countPresent(drawable,cmd);
    ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,drawable);
}
static void presentTimed(id self, SEL cmd, id drawable, double time) {
    PresentAction action = renderer.present ? renderer.present(self,cmd,drawable) : PresentCounted;
    if (action == PresentHandled) return;
    if (action == PresentCounted) countPresent(drawable,cmd);
    ((void(*)(id,SEL,id,double))original(self,cmd))(self,cmd,drawable,time);
}
static void commit(id self, SEL cmd) {
    if (renderer.commit) renderer.commit(self,cmd);
    ((void(*)(id,SEL))original(self,cmd))(self,cmd);
    // Metal 4 MetalFX work recorded into this buffer waits for it on the GPU;
    // submit it only now that BG3 has committed the buffer.
    BG3MFXMetal4BridgeCommitted(self);
}
static id commandBuffer(id self, SEL cmd) {
    // Encoder state does not retain what is bound (ConstantBinding): with
    // BG3MFX_ENABLE every buffer retains its references.
    SEL actual = cmd;
    if (runtimeEnabled && cmd == sel_registerName("commandBufferWithUnretainedReferences")) actual = sel_registerName("commandBuffer");
    id buffer = ((id(*)(id,SEL))original(self,actual))(self,actual);
    if (renderer.commandBufferCreated) renderer.commandBufferCreated(buffer);
    if (traceCalls) record(@{@"event": @"commandBuffer", @"method": NSStringFromSelector(cmd), @"actualMethod": NSStringFromSelector(actual),
             @"retainedReferences": @([buffer retainedReferences])});
    hook(buffer,"renderCommandEncoderWithDescriptor:",(IMP)renderEncoder);
    hook(buffer,"computeCommandEncoder",(IMP)computeEncoder);
    hook(buffer,"computeCommandEncoderWithDispatchType:",(IMP)computeEncoderType);
    hook(buffer,"presentDrawable:",(IMP)present);
    hook(buffer,"presentDrawable:afterMinimumDuration:",(IMP)presentTimed);
    hook(buffer,"presentDrawable:atTime:",(IMP)presentTimed);
    hook(buffer,"commit",(IMP)commit);
    if (traceCalls) hook(buffer,"pushDebugGroup:",(IMP)group);
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
// Root installs metal-hooks in every process, before the features that
// require it.
static BOOL installMetalHooks(const BG3MFXFeatureContext &context, NSError **) {
    @autoreleasepool {
        runtimeEnabled = context.runtimeEnabled;
#ifndef BG3MFX_NO_TRACE
        // The temporal-chain and waterfall captures read the recorded bindings
        // and full pipeline descriptions, so they trace calls too.
        traceCalls = (getenv("BG3MFX_TRACE_RENDER_CALLS") && strcmp(getenv("BG3MFX_TRACE_RENDER_CALLS"),"1") == 0) ||
            traceTemporalChain() || (waterfallDirectory() && *waterfallDirectory());
        traceShaderConstants = getenv("BG3MFX_TRACE_CONSTANTS") && strcmp(getenv("BG3MFX_TRACE_CONSTANTS"),"1") == 0;
#endif
        // The draw, buffer and dispatch hooks.
        traceConstants = runtimeEnabled || traceShaderConstants;
        // Each feature is opt-in (common/Feature.h); the player launcher enables them all.
        redundantProbe = diagnostics && runtimeEnabled && getenv("BG3MFX_TRACE_REDUNDANT") && strcmp(getenv("BG3MFX_TRACE_REDUNDANT"),"1") == 0;
        if (diagnostics) {
            constantSamples = [NSMutableDictionary dictionary];
            shaderBufferSizes = [NSMutableDictionary dictionary];
        }
    }
    return YES;
}
// After every feature has installed, so the Metal hooks still come after the
// menu and the native patches, as they did in the constructor.
static BOOL activateMetalHooks(const BG3MFXFeatureContext &, NSError **) {
    // Every install has run: the hook points are complete.
    hooksActive = true;
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
#ifndef BG3MFX_NO_TRACE
        // Growth at a steady size means a set still holds textures BG3 replaced.
        BG3MFXResidencyHook = [](NSString *label, NSUInteger allocations, uint64_t bytes, NSUInteger added, BOOL replaced) {
            record(@{@"event":@"metal4Residency",@"label":label ?: @"",@"allocations":@(allocations),
                @"megabytes":@(bytes/1048576.0),@"added":@(added),@"replaced":@(replaced)});
        };
        // Which texture enters or leaves a set: a BG3 target or a bg3mfx stand-in.
        BG3MFXResidencyDetailHook = [](NSString *label, NSArray<NSDictionary *> *added, NSArray<id<MTLAllocation>> *dropped) {
            auto describe=[](id<MTLAllocation> allocation) -> NSDictionary * {
                NSMutableDictionary *d=[@{@"object":@((uintptr_t)(__bridge const void *)allocation)} mutableCopy];
                if ([(id)allocation conformsToProtocol:@protocol(MTLTexture)]) [d addEntriesFromDictionary:texture((id<MTLTexture>)allocation)];
                return d;
            };
            NSMutableArray *a=[NSMutableArray array], *r=[NSMutableArray array];
            for (NSDictionary *entry in added) {
                NSMutableDictionary *d=[describe(entry[@"allocation"]) mutableCopy]; d[@"index"]=entry[@"index"]; [a addObject:d];
            }
            for (id<MTLAllocation> allocation in dropped) [r addObject:describe(allocation)];
            record(@{@"event":@"metal4ResidencyDetail",@"label":label ?: @"",@"added":a,@"dropped":r});
        };
        // A Metal 4 queue abandons an event wait after 4 s; show which side waited.
        BG3MFXBridgeStallHook = [](NSString *label, NSDictionary *stalled, NSArray<NSDictionary *> *recent) {
            record(@{@"event":@"metal4BridgeStall",@"label":label ?: @"",@"now":@(CACurrentMediaTime()),
                @"stalled":stalled,@"recent":recent});
        };
        NSMutableDictionary *startup = [@{@"event": @"start", @"mode": runtimeEnabled ? @"metalfx-menu" : @"diagnostic", @"device": device.name ?: @"unavailable",
                 @"spatial": @([MTLFXSpatialScalerDescriptor supportsDevice:device]),
                 @"temporal": @([MTLFXTemporalScalerDescriptor supportsDevice:device])} mutableCopy];
        record(startup);
#endif
        hook(device,"newCommandQueue",(IMP)newQueue);
        // Metal 4 bridges defer their submission to the commit hook only while
        // the buffer's commit is still ours (a later swizzle could bypass it).
        BG3MFXMetal4CommitHooked = [](id<MTLCommandBuffer> buffer) -> BOOL {
            Method method = class_getInstanceMethod(object_getClass(buffer),@selector(commit));
            return method && method_getImplementation(method) == (IMP)commit;
        };
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
    return YES;
}
static bool metalHooksWanted(const BG3MFXFeatureContext &) { return true; }
BG3MFX_FEATURE(metalHooks, {"metal-hooks", nullptr, false, metalHooksWanted, installMetalHooks, activateMetalHooks});
