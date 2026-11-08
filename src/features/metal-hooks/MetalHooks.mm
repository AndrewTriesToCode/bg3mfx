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

// metal-hooks: the Metal interception layer. Shared state and the renderer
// extension's interface are in MetalHooksInternal.h; the hook points other
// features use are in MetalHooks.h.
// Discover concrete driver classes from instances; never depend on an AGX class name.
using namespace metalhooks;
namespace metalhooks {
BOOL runtimeEnabled;
thread_local HookThreadCache hookCache;
char encoderStateKey;
// Encoders are used one at a time on a thread, so remember the last lookup.
// instrumentEncoder refreshes and endEncoder clears it on its own thread. Any
// thread's instrumentEncoder may release a state (or follow an encoder's
// dealloc at a reused address), so it bumps this generation and every other
// thread's cached state is looked up again: an encoder ended on another
// thread and then recycled never returns a freed state.
std::atomic<unsigned> encoderGeneration{1};
std::atomic<unsigned> originalsGeneration{1};
}
static char pipelineKey;
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
NSDictionary *metalhooks::boundTextures(id encoder) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    if (!s) return nil;
    NSMutableDictionary *textures=[NSMutableDictionary dictionary];
    for (NSUInteger i=0;i<EncoderSlots;++i) if (s->textures[i]) textures[@(i).stringValue]=s->textures[i];
    return textures;
}
static bool constantInputNeeded(NSUInteger index) { return index < 32 && (watchedConstants >> index & 1); }
static EncoderStage bindingStage(SEL cmd) {
    static SEL vertex[]={@selector(setVertexBuffer:offset:atIndex:),@selector(setVertexBuffers:offsets:withRange:),
        @selector(setVertexBufferOffset:atIndex:),@selector(setVertexBytes:length:atIndex:)};
    static SEL fragment[]={@selector(setFragmentBuffer:offset:atIndex:),@selector(setFragmentBuffers:offsets:withRange:),
        @selector(setFragmentBufferOffset:atIndex:),@selector(setFragmentBytes:length:atIndex:)};
    for (SEL v:vertex) if (cmd==v) return StageVertex;
    for (SEL f:fragment) if (cmd==f) return StageFragment;
    return StageCompute;
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
    ((void(*)(id,SEL,id,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,buffer,offset,index);
    if (index == watchedVertexSlot) noteWatchedBuffer(self,cmd,buffer,offset,false);
    if (!constantInputNeeded(index)) return;
    if (ConstantBinding *b=constantSlot(self,bindingStage(cmd),index)) { b->buffer=buffer; b->offset=offset; b->hasBytes=false; b->length=0; }
}
static void bindBuffers(__unsafe_unretained id self, SEL cmd, id<MTLBuffer> const *buffers, const NSUInteger *offsets, NSRange range) {
    ((void(*)(id,SEL,id<MTLBuffer> const *,const NSUInteger *,NSRange))original(self,cmd))(self,cmd,buffers,offsets,range);
    if (NSLocationInRange(watchedVertexSlot,range))
        noteWatchedBuffer(self,cmd,buffers[watchedVertexSlot-range.location],offsets[watchedVertexSlot-range.location],false);
    if (!watchedConstants) return;
    EncoderStage stage=bindingStage(cmd);
    for (NSUInteger i=0; i<range.length; ++i) {
        if (!constantInputNeeded(range.location+i)) continue;
        if (ConstantBinding *b=constantSlot(self,stage,range.location+i)) { b->buffer=buffers[i]; b->offset=offsets[i]; b->hasBytes=false; b->length=0; }
    }
}
static void bufferOffset(__unsafe_unretained id self, SEL cmd, NSUInteger offset, NSUInteger index) {
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
static void rememberTexture(__unsafe_unretained id self, __unsafe_unretained id<MTLTexture> t, NSUInteger index) {
    // Metal permits textures to be bound before pipeline state. Retain the
    // three required slots independently of shader identification. The
    // index test comes first: BG3 binds about 30,000 slots per frame.
    if (index > 2 || !runtimeEnabled) return;
    if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self)) s->textures[index]=t;
}
static void bindTexture(__unsafe_unretained id self, SEL cmd, __unsafe_unretained id<MTLTexture> t, NSUInteger index) {
    if (bindDedup && cmd==@selector(setFragmentTexture:atIndex:))
        if (__unsafe_unretained BG3MFXEncoderState *s=encoderState(self))
            if (!s->bindFilter.forwardTexture(t,index)) { rememberTexture(self,t,index); return; }
    ((void(*)(id,SEL,id,NSUInteger))original(self,cmd))(self,cmd,t,index);
    rememberTexture(self,t,index);
}
static void bindTextures(__unsafe_unretained id self, SEL cmd, id<MTLTexture> const *textures, NSRange range) {
    __unsafe_unretained BG3MFXEncoderState *s=bindDedup && cmd==@selector(setFragmentTextures:withRange:) ? encoderState(self) : nil;
    auto forward=((void(*)(id,SEL,id<MTLTexture> const *,NSRange))original(self,cmd));
    if (s) s->bindFilter.forwardTextures(textures,range,[&](id<MTLTexture> const *run, NSRange slots) {
        forward(self,cmd,run,slots);
    });
    else forward(self,cmd,textures,range);
    for (NSUInteger i=0; i<range.length; ++i) rememberTexture(self,textures[i],range.location+i);
}
// Ends the encoder in Metal; the renderer extension's endEncoding wraps it.
static void finishEncoder(id self, SEL cmd, BG3MFXEncoderState *encoderRecord, id<MTLCommandBuffer>) {
    // Free setBytes copies now; the state itself lasts until the driver recycles
    // this encoder. An ended encoder takes no more calls, so nothing reads its
    // binding table again.
    if (encoderRecord) { encoderRecord->buffer=nil; encoderRecord->bytes=nil; }
    ((void(*)(id,SEL))original(self,cmd))(self,cmd);
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
    __unsafe_unretained BG3MFXPipelineInfo *info = state ? (__bridge BG3MFXPipelineInfo *)pipelineInfoPointer(state) : nil;
    NSDictionary *description = info ? info->description : nil;
    if (s) {
        bool slow = info && info->kind;
        if (renderer.pipelineBound && renderer.pipelineBound(self,s,info,description)) slow = true;
        s->replaceDraws = info && info->replaceDraws;
        s->pipeline=state; s->description=description;
        s->kind=info ? info->kind : 0;
        s->slowDraw=slow;
    }
}
static BOOL reflectedShader(MTLRenderPipelineDescriptor *desc) {
    return renderer.wantsReflection && renderer.wantsReflection(desc);
}
// Classifies a render pipeline once, at creation (see BG3MFXPipelineInfo).
static void renderPipelineCreated(id self, MTLRenderPipelineDescriptor *desc, id state, MTLRenderPipelineReflection *reflection) {
    if (!state) return;
    BG3MFXPipelineInfo *info = [BG3MFXPipelineInfo new];
    if (renderer.renderPipelineCreated) renderer.renderPipelineCreated(desc, state, reflection, info);
    static SEL create = @selector(newRenderPipelineStateWithDescriptor:error:);
    info->replaceDraws = drawReplacement.claim && drawReplacement.claim(self, desc, state, (BG3MFXCreateRenderPipeline)original(self,create));
    objc_setAssociatedObject(state, &pipelineKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    pipelineGeneration.fetch_add(1, std::memory_order_release);
}
static id renderPipeline(id self, SEL cmd, MTLRenderPipelineDescriptor *desc, NSError **error) {
    if (renderer.prepareRenderPipeline) desc = renderer.prepareRenderPipeline(self, desc);
    id state;
    MTLRenderPipelineReflection *reflection = nil;
    if (reflectedShader(desc)) {
        SEL optionsSelector = sel_registerName("newRenderPipelineStateWithDescriptor:options:reflection:error:");
        state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,optionsSelector))
            (self,optionsSelector,desc,MTLPipelineOptionBindingInfo|MTLPipelineOptionBufferTypeInfo,&reflection,nullptr);
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
        state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,cmd))
            (self,cmd,desc,options|MTLPipelineOptionBindingInfo|MTLPipelineOptionBufferTypeInfo,&extraReflection,nullptr);
        if (state) {
            if (reflection) *reflection = extraReflection;
        } else state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,cmd))(self,cmd,desc,options,reflection,error);
    } else state = ((id(*)(id,SEL,id,MTLPipelineOption,MTLRenderPipelineReflection **,NSError **))original(self,cmd))(self,cmd,desc,options,reflection,error);
    renderPipelineCreated(self, desc, state, extraReflection);
    return state;
}
static id computePipeline(id self, SEL cmd, id<MTLFunction> function, NSError **error) {
    id state = ((id(*)(id,SEL,id,NSError **))original(self,cmd))(self,cmd,function,error);
    if (state) {
        NSString *name = function.name;
        BG3MFXPipelineInfo *info = [BG3MFXPipelineInfo new];
        if (renderer.recognizedCompute && renderer.recognizedCompute(name)) info->description = @{@"compute": name ?: @""};
        objc_setAssociatedObject(state, &pipelineKey, info, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        pipelineGeneration.fetch_add(1, std::memory_order_release);
    }
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
// Draws with pipelines nothing inspects skip all inspection; the renderer
// extension reads lastDrawOther and anyDrawOther.
static bool fastDraw(__unsafe_unretained id encoder) {
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
    slowDraw(self,DrawCall{type,0,count,1,0,0,buffer,offset,indexType,true},^{ ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset); });
}
static void drawIndexedInstances(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset, NSUInteger instances) {
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances); return; }
    slowDraw(self,DrawCall{type,0,count,instances,0,0,buffer,offset,indexType,true},^{ ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances); });
}
static void drawIndexedBase(__unsafe_unretained id self, SEL cmd, MTLPrimitiveType type, NSUInteger count, MTLIndexType indexType, __unsafe_unretained id<MTLBuffer> buffer, NSUInteger offset, NSUInteger instances, NSInteger baseVertex, NSUInteger baseInstance) {
    if (fastDraw(self)) { ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger,NSInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances,baseVertex,baseInstance); return; }
    slowDraw(self,DrawCall{type,0,count,instances,baseInstance,baseVertex,buffer,offset,indexType,true},^{ ((void(*)(id,SEL,MTLPrimitiveType,NSUInteger,MTLIndexType,id,NSUInteger,NSUInteger,NSInteger,NSUInteger))original(self,cmd))(self,cmd,type,count,indexType,buffer,offset,instances,baseVertex,baseInstance); });
}
static void dispatch(id self, SEL cmd, MTLSize grid, MTLSize threads) {
    NSString *pipelineName = pipelineDescription(self)[@"compute"];
    DispatchAction action = renderer.dispatch ? renderer.dispatch(self,cmd,pipelineName) : DispatchNative;
    if (action == DispatchDropped) return;
    if (action == DispatchSuppressed) return;
    ((void(*)(id,SEL,MTLSize,MTLSize))original(self,cmd))(self,cmd,grid,threads);
}
// Concrete driver classes already hooked, read without a lock on every encoder
// and command buffer. hook() would find each one installed, but only after
// taking the global lock about 25 times per encoder. Classes are never
// deallocated, so their addresses are stable keys.
using ClassTable = std::atomic<uintptr_t>[16];
static ClassTable instrumentedEncoderClasses, instrumentedBufferClasses;
static bool classInstrumented(ClassTable &table, Class cls) {
    uintptr_t key = (uintptr_t)(__bridge void *)cls;
    for (auto &known : table) {
        uintptr_t value = known.load(std::memory_order_acquire);
        if (value == key) return true;
        if (!value) return false;
    }
    return false;
}
static void markClassInstrumented(ClassTable &table, Class cls) {
    uintptr_t key = (uintptr_t)(__bridge void *)cls;
    for (auto &known : table) {
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
    if (!encoder || classInstrumented(instrumentedEncoderClasses,object_getClass(encoder))) return;
    if (runtimeEnabled) {
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
    if (runtimeEnabled) {
        hook(encoder,"dispatchThreads:threadsPerThreadgroup:",(IMP)dispatch);
        hook(encoder,"dispatchThreadgroups:threadsPerThreadgroup:",(IMP)dispatch);
    }
    markClassInstrumented(instrumentedEncoderClasses,object_getClass(encoder));
}
static id computeEncoderType(id self, SEL cmd, MTLDispatchType type);
static std::map<Class, IMP> &priorComputeMethods() { static auto *value = new std::map<Class, IMP>; return *value; }
static void refreshComputeHook(id buffer) {
    if (!runtimeEnabled) return;
    Class cls = object_getClass(buffer);
    static SEL selector = sel_registerName("computeCommandEncoderWithDispatchType:");
    // Every render encoder comes through here: the usual case takes no lock.
    if (class_getMethodImplementation(cls,selector) == (IMP)computeEncoderType) return;
    std::lock_guard<std::recursive_mutex> lock(guard());
    auto found = originals().find({cls,selector});
    Method method = class_getInstanceMethod(cls,selector);
    if (found == originals().end() || !method || method_getImplementation(method) == (IMP)computeEncoderType) return;
    // Preserve later instrumentation as the outer original. If it retained our
    // old wrapper, nested entry will use the earlier original to avoid a cycle.
    priorComputeMethods().emplace(cls,found->second);
    found->second = method_getImplementation(method);
    originalsGeneration.fetch_add(1, std::memory_order_release);
    class_replaceMethod(cls,selector,(IMP)computeEncoderType,method_getTypeEncoding(method));
}
static id renderEncoder(id self, SEL cmd, MTLRenderPassDescriptor *desc) {
    refreshComputeHook(self);
    bool passChanged = false;
    MTLRenderPassDescriptor *pass = renderer.prepareRenderPass ? renderer.prepareRenderPass(desc,&passChanged) : desc;
    id encoder = ((id(*)(id,SEL,id))original(self,cmd))(self,cmd,pass);
    instrumentEncoder(encoder);
    notifyNewEncoder(encoder,NO);
    for (size_t i = 0; i < renderPassObservers.count; ++i) renderPassObservers.entries[i](desc);
    if (runtimeEnabled && encoder) {
        if (__unsafe_unretained BG3MFXEncoderState *state=encoderState(encoder)) { state->buffer=self; state->colorTarget=desc.colorAttachments[0].texture; }
    }
    if (renderer.encoderCreated) renderer.encoderCreated(encoder,self,desc,passChanged);
    return encoder;
}
static id computeEncoder(id self, SEL cmd) {
    id encoder = ((id(*)(id,SEL))original(self,cmd))(self,cmd);
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
    instrumentEncoder(encoder);
    notifyNewEncoder(encoder,YES);
    if (runtimeEnabled) if (__unsafe_unretained BG3MFXEncoderState *state=encoderState(encoder)) state->buffer=self;
    if (renderer.encoderCreated) renderer.encoderCreated(encoder,self,nil,false);
    return encoder;
}
static void present(id self, SEL cmd, id drawable) {
    if (renderer.present && renderer.present(self,cmd,drawable) == PresentHandled) return;
    ((void(*)(id,SEL,id))original(self,cmd))(self,cmd,drawable);
}
static void presentTimed(id self, SEL cmd, id drawable, double time) {
    if (renderer.present && renderer.present(self,cmd,drawable) == PresentHandled) return;
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
    if (runtimeEnabled && cmd == @selector(commandBufferWithUnretainedReferences)) actual = @selector(commandBuffer);
    id buffer = ((id(*)(id,SEL))original(self,actual))(self,actual);
    if (renderer.commandBufferCreated) renderer.commandBufferCreated(buffer);
    if (!buffer || classInstrumented(instrumentedBufferClasses,object_getClass(buffer))) return buffer;
    hook(buffer,"renderCommandEncoderWithDescriptor:",(IMP)renderEncoder);
    hook(buffer,"computeCommandEncoder",(IMP)computeEncoder);
    hook(buffer,"computeCommandEncoderWithDispatchType:",(IMP)computeEncoderType);
    hook(buffer,"presentDrawable:",(IMP)present);
    hook(buffer,"presentDrawable:afterMinimumDuration:",(IMP)presentTimed);
    hook(buffer,"presentDrawable:atTime:",(IMP)presentTimed);
    hook(buffer,"commit",(IMP)commit);
    markClassInstrumented(instrumentedBufferClasses,object_getClass(buffer));
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
// Root installs metal-hooks before the features that require it.
static BOOL installMetalHooks(const BG3MFXFeatureContext &context, NSError **) {
    runtimeEnabled = context.runtimeEnabled;
    return YES;
}
// After every feature has installed, so the Metal hooks still come after the
// menu and the native patches, as they did in the constructor.
static BOOL activateMetalHooks(const BG3MFXFeatureContext &, NSError **) {
    // Every install has run: the hook points are complete.
    hooksActive = true;
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
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
BG3MFX_FEATURE(metalHooks, {"metal-hooks", nullptr, false, installMetalHooks, activateMetalHooks});
