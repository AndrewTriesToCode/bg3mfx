#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

// The metal-hooks feature (MetalHooks.mm): what features that require it use.
// metalfx's renderer extends it through MetalHooksInternal.h instead.

// Hook points. Features that require metal-hooks register from their install;
// metal-hooks hooks Metal at its activation, after every install, and reads
// the registrations without locks from then on. NO once full or after that.
//
// Each encoder BG3 creates, right after it is created (`compute` for a
// compute encoder, otherwise a render encoder).
BOOL BG3MFXMetalHooksOnNewEncoder(void (*observer)(id encoder, BOOL compute));
// Each render pass BG3 begins, after its encoder is created.
BOOL BG3MFXMetalHooksOnRenderPass(void (*observer)(MTLRenderPassDescriptor *pass));
// The minimum duration of each presentDrawable:afterMinimumDuration: BG3 makes:
// each filter receives the duration so far (seconds, BG3's for the first) and
// returns the one to use, in registration order. Called on the render thread.
BOOL BG3MFXMetalHooksFilterPresentDuration(double (*filter)(double duration));

// Draw replacement: one feature may take the non-indexed draws of the render
// pipelines it claims. Other draws only check a per-pipeline flag.
//
// The original newRenderPipelineStateWithDescriptor:error:, which returns +1.
// Typed as void * so ARC does not retain it again; take it with __bridge_transfer.
using BG3MFXCreateRenderPipeline = void *(*)(id, SEL, MTLRenderPipelineDescriptor *, NSError **);
// Encoder calls that bypass metal-hooks, keeping its bind records true.
struct BG3MFXEncoderCalls {
    void (*setPipeline)(__unsafe_unretained id encoder, __unsafe_unretained id state);
    void (*setFragmentTexture)(__unsafe_unretained id encoder, __unsafe_unretained id<MTLTexture> texture, NSUInteger index);
};
struct BG3MFXDrawReplacement {
    // A render pipeline BG3 created: whether to take its draws.
    bool (*claim)(id device, MTLRenderPipelineDescriptor *desc, id state, BG3MFXCreateRenderPipeline create);
    // A draw with a claimed pipeline bound; `draw` repeats BG3's call, and
    // fragment0/1 are its bound fragment textures 0 and 1. Return false,
    // having drawn nothing, to let BG3's draw run.
    bool (*draw)(__unsafe_unretained id encoder, __unsafe_unretained id state, __unsafe_unretained id<MTLTexture> fragment0,
                 __unsafe_unretained id<MTLTexture> fragment1, const BG3MFXEncoderCalls &calls, void (^draw)(void));
};
BOOL BG3MFXMetalHooksReplaceDraws(BG3MFXDrawReplacement replacement);
// Redundant bind filtering: drop fragment texture and pipeline binds that
// repeat the encoder's current ones (BindFilter.h). It is inline in the
// hottest hooks, where a call per bind would cost more than it saves;
// render-thread-optimizations turns it on.
void BG3MFXMetalHooksFilterRedundantBinds(void);

