#pragma once
// custom-pipeline-bundles: BG3's handles for the pieces of a pipeline, and
// the pipeline record (op 0x2b) that carries them into a command list. Layout
// code with no state; CustomPipelineBundles.h describes and creates the
// handles. Offsets are in SupportedBuild.h (PipelineRecord).
#include "common/native/SupportedBuild.h"
#include <cstdint>
#include <cstring>

// BG3's object handle: index in bits 0-31, salt in bits 32-53, type in bits
// 54-63. The invalid handle has every type bit set and nothing else.
inline constexpr uint64_t BG3MFXInvalidHandle = 0xffc0000000000000ull;

// A program: one .bshd's stage functions and binding information. BG3 calls
// it a shader (ShaderID).
struct BG3MFXProgramID {
    static constexpr uint64_t Invalid = BG3MFXInvalidHandle;
    uint64_t handle = Invalid;
    bool valid() const { return handle != Invalid; }
};
struct BG3MFXDepthStateID {
    uint64_t handle = BG3MFXInvalidHandle;
    bool valid() const { return handle != BG3MFXInvalidHandle; }
};
// The invalid blend state is BG3's "blending off".
struct BG3MFXBlendStateID {
    uint64_t handle = BG3MFXInvalidHandle;
    bool valid() const { return handle != BG3MFXInvalidHandle; }
};
// BG3 passes rasterizer states by pointer, not handle.
struct BG3MFXRasterizerState {
    const void *pointer = nullptr;
    bool valid() const { return pointer != nullptr; }
};

// A pipeline record, as recorded (before replay). Setters change only this
// record. The program and the blend state are in the key of BG3's pipeline
// cache, so a new combination builds a pipeline the first time it replays;
// the depth-stencil state, stencil reference and rasterizer don't.
class BG3MFXPipelineRecord {
public:
    explicit BG3MFXPipelineRecord(void *record) : record(static_cast<uint8_t *>(record)) {}
    bool valid() const { return record && record[0] == Layout::Op; }

    BG3MFXProgramID program() const { return {get<uint64_t>(Layout::Program)}; }
    void setProgram(BG3MFXProgramID value) { set(Layout::Program, value.handle); }
    BG3MFXDepthStateID depthState() const { return {get<uint64_t>(Layout::DepthState)}; }
    void setDepthState(BG3MFXDepthStateID value) { set(Layout::DepthState, value.handle); }
    uint32_t stencilRef() const { return get<uint32_t>(Layout::StencilRef); }
    void setStencilRef(uint32_t value) { set(Layout::StencilRef, value); }
    BG3MFXRasterizerState rasterizer() const { return {get<const void *>(Layout::Rasterizer)}; }
    void setRasterizer(BG3MFXRasterizerState value) { set(Layout::Rasterizer, value.pointer); }
    BG3MFXBlendStateID blendState() const { return {get<uint64_t>(Layout::Blend)}; }
    void setBlendState(BG3MFXBlendStateID value) { set(Layout::Blend, value.handle); }

private:
    struct Layout {
        static constexpr uint8_t Op = BG3MFXBuild::PipelineRecord::Op;
        static constexpr size_t Program = BG3MFXBuild::PipelineRecord::Program;
        static constexpr size_t DepthState = BG3MFXBuild::PipelineRecord::DepthState;
        static constexpr size_t StencilRef = BG3MFXBuild::PipelineRecord::StencilRef;
        static constexpr size_t Rasterizer = BG3MFXBuild::PipelineRecord::Rasterizer;
        static constexpr size_t Blend = BG3MFXBuild::PipelineRecord::Blend;
    };
    template<class T> T get(size_t offset) const { T value; memcpy(&value, record + offset, sizeof value); return value; }
    template<class T> void set(size_t offset, T value) { memcpy(record + offset, &value, sizeof value); }
    uint8_t *record;
};
