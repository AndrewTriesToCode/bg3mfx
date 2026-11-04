#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "features/custom-pipeline-bundles/PipelineRecord.h"
#include <cstdint>

// The custom-pipeline-bundles feature: bg3mfx's own pieces of BG3 pipelines.
// A pipeline record (PipelineRecord.h) names a program, a depth-stencil
// state, a stencil reference, a rasterizer state and a blend state. This
// feature describes the ones BG3 made and has BG3 make new ones, through the
// functions BG3 makes its own with, so a new piece is an ordinary BG3 handle
// that a record can carry. Features then put them in records.
//
// BG3 keeps programs, depth-stencil states and blend states in its GPU
// device's object containers and passes rasterizer states by pointer. New
// pieces are never freed: BG3's pipeline cache keeps pipelines built from
// them. Every call here may be made from any thread once BG3's GPU
// device exists; before that they fail.

// Programs. BG3 calls a program a shader: a ShaderID made from a .bshd file,
// which holds stage function names (looked up in BG3's Core.metallib and
// Materials.metallib) and binding information.

// Stage functions; nil for a stage a program doesn't have (or, given to
// BG3MFXCreateProgram, one to keep). Each must be from BG3MFXMetalDevice()
// and of its stage's type.
struct BG3MFXProgramStages {
    id<MTLFunction> vertex;
    id<MTLFunction> fragment;
};
struct BG3MFXProgramDesc {
    // The .bshd path as BG3 loaded it (its program cache's key); nil for a
    // built-in program or one made before this feature installed.
    NSString *path;
    // Borrowed from the program's entry.
    BG3MFXProgramStages stages;
};
// Makes a new program from `baseBshd`, a path relative to BG3's engine shader
// directory as RenderStage::LoadEngineShader takes it (e.g.
// "DeferredDecal_ExtractNormal.bshd"), with the given stages (at least one)
// replaced. BG3 loads it as any program but outside its program cache, so no
// other caller gets it and BG3 never removes it. It keeps the base's binding information,
// so a replacement must use the same bindings or fewer. Each call makes
// another program; keep the handle. Invalid on failure.
BG3MFXProgramID BG3MFXCreateProgram(const char *baseBshd, const BG3MFXProgramStages &replace, NSError **error);
// What a program is made from. false for a handle with no entry.
bool BG3MFXDescribeProgram(BG3MFXProgramID program, BG3MFXProgramDesc *desc);
// BG3's Metal device, nil before BG3 creates it.
id<MTLDevice> BG3MFXMetalDevice(void);
// Loads `<name>.metallib` from the directory holding the bg3mfx runtime, on
// BG3's device, once per name: where replacement stage functions come from.
id<MTLLibrary> BG3MFXFunctionLibrary(const char *name, NSError **error);

// Depth-stencil states, with BG3's values: compare and stencil compare are
// MTLCompareFunction's; stencil operations are BG3's EStencilOp.
struct BG3MFXStencilOps { uint8_t fail, depthFail, pass, compare; };
struct BG3MFXDepthStateDesc {
    bool depthTest, depthWrite;
    uint8_t compare;
    bool stencil;
    uint8_t readMask, writeMask;
    BG3MFXStencilOps front, back;
};
// What BG3 made a depth-stencil state with, recorded as BG3 made it (Metal
// can't say). false for one made before this feature installed.
bool BG3MFXDescribeDepthState(BG3MFXDepthStateID state, BG3MFXDepthStateDesc *desc);
// A depth-stencil state made by BG3's GPUDevice::CreateDepthState. The same
// settings give the same handle.
BG3MFXDepthStateID BG3MFXGetOrCreateDepthState(const BG3MFXDepthStateDesc &desc, NSError **error);

// Blend states, with BG3's values. Factors: 0 zero, 1 one, 2 source color,
// 3 one minus source color, 4 destination color, 5 one minus destination
// color, 6 source alpha, 7 one minus source alpha, 8 destination alpha, 9 one
// minus destination alpha, 10 source alpha saturated. Operations: 0 add, 1
// subtract, 2 reverse subtract, 3 min, 4 max. Write mask: 1 red, 2 green, 4
// blue, 7 RGB, 8 alpha, 15 all, 0 none (BG3 maps no other combination). One
// state applies to every color attachment.
struct BG3MFXBlendStateDesc {
    bool enabled;
    uint8_t srcRGB, dstRGB, rgbOp, writeMask, srcAlpha, dstAlpha, alphaOp;
};
// BG3 keeps a blend state's settings in its entry. The invalid handle is
// blending off (and every channel written).
bool BG3MFXDescribeBlendState(BG3MFXBlendStateID state, BG3MFXBlendStateDesc *desc);
// A blend state made by BG3's GPUDevice::CreateBlendState; `enabled` false
// gives the invalid handle. To mask channels without blending, enable it
// with factors one and zero and operation add. The same settings give the
// same handle.
BG3MFXBlendStateID BG3MFXGetOrCreateBlendState(const BG3MFXBlendStateDesc &desc, NSError **error);

// Rasterizer states: cull 0 none, 1 back, 2 front; fill 1 lines, otherwise
// solid. Depth bias, when on, is BG3's fixed 5.0, slope 2.5, no clamp; depth
// clip off clamps instead.
struct BG3MFXRasterizerDesc {
    uint8_t cull, fill;
    bool scissor, depthBias, depthClip;
};
// Reads the state's bytes; it must be a pointer from a pipeline record or
// BG3MFXGetOrCreateRasterizerState.
bool BG3MFXDescribeRasterizerState(BG3MFXRasterizerState state, BG3MFXRasterizerDesc *desc);
// A rasterizer state made by BG3's GPUDevice::CreateRasterizerState. The same
// settings give the same pointer.
BG3MFXRasterizerState BG3MFXGetOrCreateRasterizerState(const BG3MFXRasterizerDesc &desc, NSError **error);
