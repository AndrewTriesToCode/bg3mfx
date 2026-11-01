#pragma once
#import <Metal/Metal.h>
#import "features/metal-hooks/MetalHooks.h"
#include <cstdint>

// Depth prepass trim's rules, applied through metal-hooks' draw filter
// (DepthPrepassFeature.mm): pipeline tags, pass tags and the draw decision.
enum TrimPipeline : uint8_t { TrimNone, TrimPrepassOpaque, TrimGBufferOpaque };
enum TrimRole : uint8_t { RoleNone, RolePrepass, RoleGBuffer };
void BG3MFXClassifyPrepass(MTLRenderPipelineDescriptor *, id, BG3MFXTagPipeline);
TrimRole BG3MFXPrepassRole(MTLRenderPassDescriptor *);
void BG3MFXPreparePrepassDepth(id device, SEL selector, MTLDepthStencilDescriptor *, id state, BG3MFXCreateDepthState);
id BG3MFXPrepassReplacement(__unsafe_unretained id state);
// A tagged draw: an opaque stem's prepass draw is skipped, and its G-buffer
// draw tests GreaterEqual and writes depth instead of testing Equal.
BG3MFXDrawFilterAction BG3MFXPrepassDraw(uint8_t pipeline, uint8_t role, __unsafe_unretained id depthState);
struct BG3MFXPrepassCounts { unsigned skipped, swapped; };
// Diagnostic runtime: the draws skipped and swapped since the last drain.
BG3MFXPrepassCounts BG3MFXDrainPrepassCounts();
