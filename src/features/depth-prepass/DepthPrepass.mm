#import "features/depth-prepass/DepthPrepass.h"
#import <objc/runtime.h>
#include <atomic>
#include <mutex>

namespace {
char depthReplacementKey;
std::mutex &prepassGuard() { static std::mutex mutex; return mutex; }
#ifndef BG3MFX_NO_TRACE
std::atomic<unsigned> skipped{0}, swapped{0};
#endif
}
// A material's prepass pipeline uses `<stem>_DEP_vertexMain`, its G-buffer one
// `<stem>_DEF_vertexMain`. A prepass pipeline with no fragment function cannot
// discard, so its G-buffer draw relies on the prepass only to reject hidden
// fragments, which the GPU's hidden-surface removal already does. If any
// prepass variant of a stem has a fragment function (an alpha test or cutout),
// the stem's G-buffer draws may rely on the Equal test and are left alone.
void BG3MFXClassifyPrepass(MTLRenderPipelineDescriptor *desc, id state, BG3MFXMarkPrepassPipeline mark) {
    NSString *vertex = desc.vertexFunction.name;
    if (!state || !vertex) return;
    BOOL prepass = [vertex hasSuffix:@"_DEP_vertexMain"], gbuffer = [vertex hasSuffix:@"_DEF_vertexMain"];
    if (!prepass && !gbuffer) return;
    NSString *stem = [vertex substringToIndex:vertex.length - @"_DEP_vertexMain".length];
    std::lock_guard<std::mutex> lock(prepassGuard());
    static NSMutableSet<NSString *> *opaque = [NSMutableSet set], *excluded = [NSMutableSet set];
    static NSMutableDictionary<NSString *, NSHashTable *> *prepassStates = [NSMutableDictionary dictionary];
    static NSMutableDictionary<NSString *, NSHashTable *> *gbufferStates = [NSMutableDictionary dictionary];
    auto states = [](NSMutableDictionary<NSString *, NSHashTable *> *table, NSString *key) {
        NSHashTable *set = table[key];
        if (!set) table[key] = set = [NSHashTable weakObjectsHashTable];
        return set;
    };
    if (gbuffer) {
        [states(gbufferStates, stem) addObject:state];
        if ([opaque containsObject:stem]) mark(state, TrimGBufferOpaque);
        return;
    }
    BOOL vertexOnly = !desc.fragmentFunction && desc.depthAttachmentPixelFormat == MTLPixelFormatDepth32Float_Stencil8;
    for (NSUInteger i = 0; i < 8; ++i)
        if (desc.colorAttachments[i].pixelFormat != MTLPixelFormatInvalid) vertexOnly = NO;
    if (!vertexOnly) {
        [excluded addObject:stem];
        [opaque removeObject:stem];
        for (id pipeline in states(prepassStates, stem)) mark(pipeline, TrimNone);
        for (id pipeline in states(gbufferStates, stem)) mark(pipeline, TrimNone);
        return;
    }
    if ([excluded containsObject:stem]) return;
    [opaque addObject:stem];
    [states(prepassStates, stem) addObject:state];
    mark(state, TrimPrepassOpaque);
    for (id pipeline in states(gbufferStates, stem)) mark(pipeline, TrimGBufferOpaque);
}
// The G-buffer pass loads the depth its prepass cleared (Depth32Float_Stencil8,
// four or more color targets). Only a depth-only pass that clears a depth
// texture already seen feeding a G-buffer is trimmed; other depth passes and
// a view's first frame render unchanged.
TrimRole BG3MFXPrepassRole(MTLRenderPassDescriptor *desc) {
    id<MTLTexture> depth = desc.depthAttachment.texture;
    if (!depth || depth.pixelFormat != MTLPixelFormatDepth32Float_Stencil8) return RoleNone;
    NSUInteger colors = 0;
    for (NSUInteger i = 0; i < 8; ++i) if (desc.colorAttachments[i].texture) ++colors;
    std::lock_guard<std::mutex> lock(prepassGuard());
    static NSHashTable *gbufferDepths = [NSHashTable weakObjectsHashTable];
    if (colors >= 4 && desc.depthAttachment.loadAction == MTLLoadActionLoad) {
        [gbufferDepths addObject:depth];
        return RoleGBuffer;
    }
    if (!colors && desc.depthAttachment.loadAction == MTLLoadActionClear && [gbufferDepths containsObject:depth])
        return RolePrepass;
    return RoleNone;
}

void BG3MFXPreparePrepassDepth(id device, SEL selector, MTLDepthStencilDescriptor *desc, id state, BG3MFXCreateDepthState create) {
    if (state && desc.depthCompareFunction == MTLCompareFunctionEqual && !desc.isDepthWriteEnabled) {
        MTLDepthStencilDescriptor *writes = [desc copy];
        writes.depthCompareFunction = MTLCompareFunctionGreaterEqual;
        writes.depthWriteEnabled = YES;
        id replacement = (__bridge_transfer id)create(device,selector,writes);
        if (replacement) objc_setAssociatedObject(state, &depthReplacementKey, replacement, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

id BG3MFXPrepassReplacement(__unsafe_unretained id state) {
    return objc_getAssociatedObject(state,&depthReplacementKey);
}
#ifndef BG3MFX_NO_TRACE
void BG3MFXCountPrepass(bool skip) {
    if (skip) ++skipped; else ++swapped;
}
#endif
BG3MFXPrepassCounts BG3MFXDrainPrepassCounts() {
#ifndef BG3MFX_NO_TRACE
    return {skipped.exchange(0),swapped.exchange(0)};
#else
    return {};
#endif
}
