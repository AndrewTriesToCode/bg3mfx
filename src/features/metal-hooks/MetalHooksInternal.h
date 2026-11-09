#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <atomic>
#include <map>
#include <mutex>
#import "features/metal-hooks/BindFilter.h"

// metal-hooks' private interface for the renderer extension (metalfx's
// renderer, src/features/metalfx/renderer/MetalFXRenderer.mm): the per-encoder and
// per-pipeline state the hooks keep, the helpers that read it, and the points
// at which the hooks call the extension. Features other than metalfx use the
// public hook points in MetalHooks.h.


namespace metalhooks {
// BG3MFX_ENABLE=1; the draw, buffer and dispatch hooks are installed with it.
extern BOOL runtimeEnabled;

// Dyld may run the constructor before the C++ initializers: function-local
// statics are initialized before the first hook or log call.
inline std::recursive_mutex &guard() { static auto *value = new std::recursive_mutex; return *value; }
inline std::map<std::pair<Class, SEL>, IMP> &originals() {
    static auto *value = new std::map<std::pair<Class, SEL>, IMP>;
    return *value;
}

enum EncoderStage : uint8_t { StageVertex, StageFragment, StageCompute };
// Bound buffers, textures and the pipeline are not retained: the encoder
// (from a retained-references command buffer) keeps everything bound to it
// alive until it ends, and BG3 keeps its pipeline states.
struct ConstantBinding { __unsafe_unretained id<MTLBuffer> buffer; NSUInteger offset; NSUInteger length; bool hasBytes; };
inline constexpr NSUInteger EncoderSlots = 32;
// A draw call's arguments.
struct DrawCall {
    MTLPrimitiveType type; NSUInteger start, count, instances, baseInstance; NSInteger baseVertex;
    __unsafe_unretained id<MTLBuffer> indexBuffer; NSUInteger indexOffset; MTLIndexType indexType;
    bool indexed;
};
// Per-encoder associated objects set on an encoder, so encoder setup and end
// read and clear only those. The renderer extension's bits start at
// AssocRenderer.
enum EncoderAssociation : uint16_t {
    AssocRenderer = 0x100, AssocAll = 0xffff,
};
}

// Per-encoder hook state, one object per encoder. BG3 issues about 12,000
// draws and many more binds per frame; sampling showed half of its render
// thread in these hooks when they built strings and dictionaries per call.
// Binds now write fixed slots, and draws do real work only for the few
// pipelines the renderer extension recognizes (classified once, at pipeline
// creation).
@interface BG3MFXEncoderState : NSObject {
@public
    metalhooks::ConstantBinding constants[3][metalhooks::EncoderSlots];
    __unsafe_unretained id<MTLTexture> textures[metalhooks::EncoderSlots];
    __unsafe_unretained id pipeline;
    __strong NSDictionary *description;  // the bound pipeline's, when the renderer extension reads it
    // The bound pipeline's class from the renderer extension (0: none).
    uint8_t kind;
    // Draws go to the renderer extension: kind is set, or the extension asked
    // for this pipeline's draws when it was bound.
    bool slowDraw;
    __strong id<MTLCommandBuffer> buffer;
    // setBytes data by stage*EncoderSlots+index; rare, so the binding table
    // itself owns nothing and costs nothing to destroy (one per encoder).
    __strong NSMutableDictionary<NSNumber *, NSData *> *bytes;
    __strong id<MTLTexture> colorTarget;
    __unsafe_unretained id sampler0;
    int mode;            // the renderer extension's mode for this encoder; -1 when unknown
    bool lastDrawOther;  // the latest draw went the fast way (an unrecognized pipeline)
    bool anyDrawOther;   // some draw in this encoder did
    // BG3's viewport and scissor.
    bool hasViewport, hasScissor;
    MTLViewport viewport;
    MTLScissorRect scissor;
    // The renderer extension's per-encoder flags.
    // Dynamic resolution: a surface grid or subsurface blur pipeline is bound
    // while the viewport is reduced.
    bool surfaceGrid, subsurface;
    // FSR_Tonemap skip: this pass's store action is chosen at endEncoding.
    bool deferredStore, tonemapSkipped, storeNeeded;
    // A pipeline whose draws the draw replacement claimed is bound.
    bool replaceDraws;
    // The vertex buffer bound at the extension's watched slot.
    __unsafe_unretained id<MTLBuffer> watchedBuffer;
    NSUInteger watchedOffset;
    // Bind dedup: fragment textures this encoder has actually forwarded.
    BG3MFXBindFilter bindFilter;
    // EncoderAssociation bits; they only ever accumulate.
    uint16_t associations;
}
@end
// Everything a pipeline bind needs, classified once at creation.
@interface BG3MFXPipelineInfo : NSObject {
@public
    __strong NSDictionary *description;
    uint8_t kind;           // the renderer extension's class (0: none)
    uint8_t rendererFlags;  // and its flags
    // Its non-indexed draws go through the draw replacement.
    bool replaceDraws;
}
@end

namespace metalhooks {
struct PipelineCacheEntry { const void *pipeline; void *info; unsigned generation; };
struct OriginalCacheEntry { Class cls; SEL selector; IMP imp; unsigned generation; };
// Every per-thread hook cache lives in one thread-local block, so a hooked
// call resolves one thread-local address instead of one per cache.
struct HookThreadCache {
    const void *encoder;          // last encoder looked up and its state
    void *state;
    unsigned encoderGeneration;   // encoderGeneration when it was cached
    PipelineCacheEntry pipelines[64];
    OriginalCacheEntry originals[256];
};
extern thread_local HookThreadCache hookCache;
extern std::atomic<unsigned> encoderGeneration, originalsGeneration;
extern char encoderStateKey;

// Returns a plain pointer: ARC would otherwise retain and release the state
// around every hooked call. The encoder keeps its state alive.
inline __attribute__((always_inline)) void *encoderStatePointer(__unsafe_unretained id encoder) {
    if (!encoder) return nullptr;
    HookThreadCache &cache = hookCache;
    unsigned generation = encoderGeneration.load(std::memory_order_acquire);
    if ((__bridge const void *)encoder == cache.encoder && generation == cache.encoderGeneration) return cache.state;
    __unsafe_unretained BG3MFXEncoderState *state = objc_getAssociatedObject(encoder,&encoderStateKey);
    cache.encoder = (__bridge const void *)encoder; cache.state = (__bridge void *)state; cache.encoderGeneration = generation;
    return (__bridge void *)state;
}
#define encoderState(encoder) ((__bridge BG3MFXEncoderState *)metalhooks::encoderStatePointer(encoder))

IMP originalSlow(Class concrete, SEL selector, unsigned generation, OriginalCacheEntry &entry);
// The original implementation of a hooked method, from this thread's cache.
inline __attribute__((always_inline)) IMP original(__unsafe_unretained id object, SEL selector) {
    Class concrete = object_getClass(object);
    unsigned generation = originalsGeneration.load(std::memory_order_acquire);
    OriginalCacheEntry &entry = hookCache.originals[((uintptr_t)concrete >> 4 ^ (uintptr_t)selector >> 2) & 255];
    if (entry.cls == concrete && entry.selector == selector && entry.generation == generation) return entry.imp;
    return originalSlow(concrete, selector, generation, entry);
}
// original() for a selector this object's class may not have hooked.
IMP originalOrCurrent(id object, SEL selector);
// Replaces `name` on the object's class, keeping the original for original().
void hook(id object, const char *name, IMP replacement);

inline void noteAssociation(__unsafe_unretained id encoder, uint16_t bit) {
    if (__unsafe_unretained BG3MFXEncoderState *s = encoderState(encoder)) s->associations |= bit;
}
// An encoder without our state may carry anything: treat every key as set.
inline uint16_t encoderAssociations(__unsafe_unretained BG3MFXEncoderState *s) { return s ? s->associations : AssocAll; }
// Encoders from paths not instrumented have no state; field reads through a
// nil object pointer would crash, unlike messages to nil.
inline id<MTLCommandBuffer> encoderBuffer(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->buffer : nil; }
inline id<MTLTexture> encoderTarget(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->colorTarget : nil; }
inline NSDictionary *pipelineDescription(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->description : nil; }
inline id encoderPipeline(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->pipeline : nil; }
inline id encoderSampler(id encoder) { __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder); return s ? s->sampler0 : nil; }
inline ConstantBinding *constantSlot(__unsafe_unretained id encoder, EncoderStage stage, NSUInteger index) {
    __unsafe_unretained BG3MFXEncoderState *s=encoderState(encoder);
    return s && index<EncoderSlots ? &s->constants[stage][index] : nullptr;
}
// Bound textures by index, as a dictionary for the few recognized passes.
NSDictionary *boundTextures(id encoder);
// The first `count` bytes of a recorded constant binding, if readable.
NSData *constantBytes(id encoder, EncoderStage stage, NSUInteger index, NSUInteger count);
// A texture's description for event records.

// The renderer extension: metalfx's renderer, registered from its install.
// Each entry is optional.
enum DispatchAction { DispatchNative, DispatchSuppressed, DispatchDropped };
// PresentOwn: the extension's own present, forwarded with its own duration
// (present-duration filters apply only to BG3's).
enum PresentAction { PresentForward, PresentHandled, PresentOwn };
using FinishEncoder = void (*)(id encoder, SEL cmd, BG3MFXEncoderState *state, id<MTLCommandBuffer> buffer);
struct RendererExtension {
    // Constant slots (bit per index below 32) whose bindings encoder state records.
    uint32_t constantSlots;
    // A vertex buffer slot recorded as watchedBuffer/watchedOffset (NSNotFound: none).
    NSUInteger vertexBufferSlot;
    void (*commandBufferCreated)(id<MTLCommandBuffer> buffer);
    // A render pass about to be created; may return a replacement descriptor.
    MTLRenderPassDescriptor *(*prepareRenderPass)(MTLRenderPassDescriptor *desc, bool *changed);
    // After the hooks set up a new encoder; pass is nil for compute.
    void (*encoderCreated)(id encoder, id<MTLCommandBuffer> buffer, MTLRenderPassDescriptor *pass, bool passChanged);
    // A recycled encoder object: clear the extension's associations in `stale`.
    void (*encoderRecycled)(id encoder, uint16_t stale);
    // Ends the encoder: must call finish, which ends it in Metal.
    void (*endEncoding)(id encoder, SEL cmd, BG3MFXEncoderState *state, id<MTLCommandBuffer> buffer, FinishEncoder finish);
    // Before a render pipeline is created; may return a replacement descriptor.
    MTLRenderPipelineDescriptor *(*prepareRenderPipeline)(id device, MTLRenderPipelineDescriptor *desc);
    // Whether to create it with reflection (passed to renderPipelineCreated).
    bool (*wantsReflection)(MTLRenderPipelineDescriptor *desc);
    // Classifies a new render pipeline: kind, rendererFlags, and a description
    // when the extension will read it.
    void (*renderPipelineCreated)(MTLRenderPipelineDescriptor *desc, id state, MTLRenderPipelineReflection *reflection,
                                  BG3MFXPipelineInfo *info);
    // Compute functions whose pipelines keep their name.
    bool (*recognizedCompute)(NSString *name);
    // A pipeline is about to be bound (state still holds the previous one).
    // Returns whether its draws go to draw().
    bool (*pipelineBound)(id encoder, BG3MFXEncoderState *state, BG3MFXPipelineInfo *info, NSDictionary *description);
    // A draw on a slow-draw pipeline; forward issues it.
    void (*draw)(id encoder, BG3MFXEncoderState *state, const DrawCall &call, void (^forward)(void));
    DispatchAction (*dispatch)(id encoder, SEL cmd, NSString *pipeline);
    // `minimum`: presentDrawable:afterMinimumDuration:'s duration after the
    // present-duration filters (as BG3's would be); negative for the other presents.
    PresentAction (*present)(id buffer, SEL cmd, id drawable, double minimum);
    // Before the original commit.
    void (*commit)(id<MTLCommandBuffer> buffer, SEL cmd);
};
// From the extension's install only; NO once installs are over or if one is
// already registered.
BOOL extendRenderer(const RendererExtension &extension);
}
