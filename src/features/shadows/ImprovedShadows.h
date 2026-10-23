#pragma once
#import <Metal/Metal.h>

// Improved shadows, part of Shadow Rendering Optimizations: bg3mfx's own sun
// shadow mask shader replaces BG3's (DirLight_Cascaded_PCSS_* for Medium and
// High, DirLight_Cascaded_PCF_* for Low). It takes the surface normal from
// the G-buffer instead of each 2x2 quad's depth slope.
// BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS=0 leaves BG3's shaders.
bool BG3MFXImprovedShadowsEnabled(void);

// The original newRenderPipelineStateWithDescriptor:error:, which returns +1.
// Typed as void * so ARC does not retain it again; take it with __bridge_transfer.
using BG3MFXCreateRenderPipeline = void *(*)(id, SEL, MTLRenderPipelineDescriptor *, NSError **);
// For a shadow mask pipeline BG3 created, builds bg3mfx's replacement and
// keeps it with BG3's. Returns whether the draws of `state` should go through
// BG3MFXImprovedShadowsDraw.
bool BG3MFXPrepareImprovedShadows(id device, MTLRenderPipelineDescriptor *desc, id state, BG3MFXCreateRenderPipeline create);
// Learns GBuffer0 (the view-space normal) from BG3's G-buffer pass.
void BG3MFXNoteImprovedShadowsPass(MTLRenderPassDescriptor *desc);

// Encoder calls that bypass bg3mfx's hooks.
struct BG3MFXImprovedShadowsCalls {
    void (*setPipeline)(__unsafe_unretained id encoder, __unsafe_unretained id state);
    void (*setFragmentTexture)(__unsafe_unretained id encoder, __unsafe_unretained id<MTLTexture> texture, NSUInteger index);
};
// Draws a shadow mask draw (`draw` repeats BG3's call) with bg3mfx's
// pipeline. linearDepth and gbuffer2 are the draw's fragment textures 0 and 1.
// Returns false, having drawn nothing, when the G-buffer normal is unknown for
// these targets; BG3's own draw then runs.
bool BG3MFXImprovedShadowsDraw(__unsafe_unretained id encoder, __unsafe_unretained id state,
    __unsafe_unretained id<MTLTexture> linearDepth, __unsafe_unretained id<MTLTexture> gbuffer2,
    const BG3MFXImprovedShadowsCalls &calls, void (^draw)(void));
