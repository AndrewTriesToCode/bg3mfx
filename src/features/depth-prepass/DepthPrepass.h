#pragma once
#import <Metal/Metal.h>
#include <cstdint>

enum TrimPipeline : uint8_t { TrimNone, TrimPrepassOpaque, TrimGBufferOpaque };
enum TrimRole : uint8_t { RoleNone, RolePrepass, RoleGBuffer };
struct BG3MFXPrepassState {
    TrimPipeline pipeline;
    TrimRole role;
    __unsafe_unretained id depthState;
};
using BG3MFXMarkPrepassPipeline = void (*)(id, TrimPipeline);
// The original newDepthStencilStateWithDescriptor:, which returns +1. Typed as
// void * so ARC does not assume +0 and retain it again; take it with
// __bridge_transfer.
using BG3MFXCreateDepthState = void *(*)(id, SEL, id);
using BG3MFXSetDepthState = void (*)(__unsafe_unretained id, __unsafe_unretained id);
void BG3MFXClassifyPrepass(MTLRenderPipelineDescriptor *, id, BG3MFXMarkPrepassPipeline);
TrimRole BG3MFXPrepassRole(MTLRenderPassDescriptor *);
void BG3MFXPreparePrepassDepth(id device, SEL selector, MTLDepthStencilDescriptor *, id state, BG3MFXCreateDepthState);
id BG3MFXPrepassReplacement(__unsafe_unretained id state);
#ifndef BG3MFX_NO_TRACE
void BG3MFXCountPrepass(bool skipped);
#endif
struct BG3MFXPrepassCounts { unsigned skipped, swapped; };
BG3MFXPrepassCounts BG3MFXDrainPrepassCounts();
// Setter calls the original Metal method, bypassing interception. The state is
// borrowed from the encoder; no additional retains occur on each draw.
struct BG3MFXPrepassDraw {
    __unsafe_unretained id encoder = nil, restore = nil;
    BG3MFXSetDepthState setter;
    bool skip = false;
    BG3MFXPrepassDraw(__unsafe_unretained id self, BG3MFXPrepassState *state,
        BG3MFXSetDepthState set, bool diagnostics) : setter(set) {
        if (!state || state->pipeline == TrimNone) return;
        if (state->pipeline == TrimPrepassOpaque && state->role == RolePrepass) {
            skip = true;
#ifndef BG3MFX_NO_TRACE
            if (diagnostics) BG3MFXCountPrepass(true);
#endif
            return;
        }
        if (state->pipeline != TrimGBufferOpaque || state->role != RoleGBuffer || !state->depthState) return;
        id replacement = BG3MFXPrepassReplacement(state->depthState);
        if (!replacement) return;
        setter(self,replacement);
        encoder = self; restore = state->depthState;
#ifndef BG3MFX_NO_TRACE
        if (diagnostics) BG3MFXCountPrepass(false);
#endif
        (void)diagnostics;
    }
    ~BG3MFXPrepassDraw() { if (encoder) setter(encoder,restore); }
    BG3MFXPrepassDraw(const BG3MFXPrepassDraw &) = delete;
    BG3MFXPrepassDraw &operator=(const BG3MFXPrepassDraw &) = delete;
};
