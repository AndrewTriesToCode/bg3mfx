#pragma once
// Single supported Steam executable. C/Objective-C, C++, and the Python
// development launcher consume these definitions. Addresses below are unslid
// ARM64 virtual addresses; installers retain their instruction/shape guards.
#define BG3MFX_SUPPORTED_VERSION "4.1.1.7631656"
#define BG3MFX_SUPPORTED_SHA256 "d81e0420d9158e6e58c55af62e8490366768d7376a92868d3bf55d05d561519b"
#define BG3MFX_SUPPORTED_ARM64_UUID "3B6F6492-114E-3EA2-BC64-DFDDBD361434"

#ifdef __cplusplus
#include <cstddef>
#include <cstdint>
namespace BG3MFXBuild {
inline constexpr uintptr_t ImageBase = 0x100000000;
inline constexpr uintptr_t HeaderPadding = 0x100004000;
inline constexpr uint32_t HeaderCommandBytes = 0x1b28;
namespace Menu {
inline constexpr uintptr_t ResolveText = 0x1065465e4;
inline constexpr uintptr_t SetQuality = 0x10640df94;
inline constexpr uintptr_t RefreshQuality = 0x103291ef8;
inline constexpr uintptr_t PublishSettings = 0x1032906c4;
inline constexpr uintptr_t TranslationRepository = 0x108b26098;
inline constexpr uintptr_t MakeHandle = 0x106535df4;
inline constexpr uintptr_t AddTranslatedString = 0x106549388;
inline constexpr uintptr_t MakeText = 0x106545cc4;
inline constexpr uintptr_t DestroyHandle = 0x1064d0c60;
inline constexpr uintptr_t DestroyText = 0x106545e94;
inline constexpr uintptr_t AppendComboValue = 0x103294954;
inline constexpr uintptr_t AddTickBox = 0x1030a39bc;
// OptionManagerBase::AddSliderOption(id, name, description, value, min, max,
// bool): Max Frame Rate (id 0x54) passes 10, 240 and true.
inline constexpr uintptr_t AddSlider = 0x1030a4784;
inline constexpr uintptr_t Callbacks = 0x1087ac1a0;
inline constexpr uintptr_t Init = 0x103288fb8;
inline constexpr uintptr_t ApplyCombo = 0x103290180;
}
namespace Temporal {
inline constexpr uintptr_t PostProcessStageVTable = 0x10886b5a0;
inline constexpr uintptr_t FSRStepVTable = 0x10886c380;
inline constexpr uintptr_t Settings = 0x108af4118;
inline constexpr uintptr_t ProjectionLoad = 0x105f8bdc8;
inline constexpr uintptr_t CameraLoad = 0x105f8af84;
inline constexpr uintptr_t VelocityLoad = 0x106253924;
inline constexpr uintptr_t PostProcessMethod = 0x10608f590;
}
namespace ThreadIdling {
inline constexpr uintptr_t WorkerBudget = 0x10655389c;
inline constexpr uintptr_t SchedulerWindowFirst = 0x106551aec;
inline constexpr uintptr_t SchedulerWindowSecond = 0x106551c84;
inline constexpr uintptr_t CapIdleYield = 0x1064d1e94;
inline constexpr uintptr_t CapTargetSelect = 0x1064d1c54;
}
namespace UniformSlices {
// The uniform allocator inlined in AppliedMaterial::BindMaterialParameters
// (14 instructions, then `b BindResume`) and RenderableObject::
// SetupEngineParameters (13, falling through to SetupResume), and
// MetalRenderer::BeginFrame's reset of the offset.
inline constexpr uintptr_t BindAlloc = 0x105d07dc0;
inline constexpr uintptr_t BindResume = 0x105d07ffc;
inline constexpr uintptr_t SetupAlloc = 0x1060e0174;
inline constexpr uintptr_t SetupResume = 0x1060e01a8;
inline constexpr uintptr_t FrameReset = 0x10645da54;
}
namespace Lua {
inline constexpr uintptr_t LongjmpCall = 0x100769e8c;
inline constexpr uintptr_t SetjmpCall = 0x100769f64;
}
namespace ServerPacing {
inline constexpr uintptr_t TickStart = 0x100c8ff0c;
inline constexpr uintptr_t World = 0x100c8ffa0;
inline constexpr uintptr_t TickEnd = 0x100c9002c;
inline constexpr uintptr_t Cap = 0x100c90090;
inline constexpr uintptr_t ProcessTarget = 0x1064bd494;
inline constexpr uintptr_t WorldTarget = 0x10638ec08;
inline constexpr uintptr_t GettimeofdayTarget = 0x1077cce0c;
inline constexpr uintptr_t CapTarget = 0x1064d1b8c;
}
// Dynamic resolution (src/features/dynamic-resolution/): BG3's render viewport reduction.
namespace ViewportReduction {
inline constexpr uintptr_t StartRecordingFirst = 0x1060dbd3c;
inline constexpr uintptr_t StartRecordingSecond = 0x1060dbe80;
inline constexpr uintptr_t StartRecording = 0x10641ec98;
inline constexpr uintptr_t CalculateViewports = 0x10641c930;
inline constexpr uintptr_t RecalculateViewports = 0x1064238c0;
inline constexpr uintptr_t MetalRenderFrameVTable = 0x108886248;
inline constexpr uint32_t CalculateViewportsFirst = 0x52886028;
inline constexpr uint32_t RecalculateViewportsFirst = 0x52843f08;
// ls::LightingRenderStage::ExecuteWTKernel saves the view's "previous" viewport
// for the volumetric fog history (_ReprojectData.g_ViewportScale/Offset_Prev)
// from view +0x2170/+0x2178, which stay 1/0; the composed render viewport is
// at +0x21f8/+0x2200.
inline constexpr uintptr_t FogPrevScaleLoad = 0x105ff8f50, FogPrevOffsetLoad = 0x105ff8f58;
inline constexpr uint32_t FogPrevScaleOriginal = 0xf950b909, FogPrevOffsetOriginal = 0xf950bd08; // ldr x9, [x8, #0x2170]; ldr x8, [x8, #0x2178]
inline constexpr uint32_t FogPrevScaleRender = 0xf950fd09, FogPrevOffsetRender = 0xf9510108;     // ldr x9, [x8, #0x21f8]; ldr x8, [x8, #0x2200]
// ls::PostProcessStep_ExposureOld::ExecuteWTKernel builds the auto-exposure
// _SceneUVSettings (UOffset, UScale, VOffset, VScale) from the same full-size
// +0x2170/+0x2178 pair, so exposure averages the whole target. The q load
// cannot reach +0x21f8, so the load and ext become two d loads that leave the
// same scale and offset halves in v1 and v0 for the st2.
inline constexpr uintptr_t ExposureUVLoad = 0x1060b357c;
inline constexpr uint32_t ExposureUVOriginal[2] = {0x3dc85ea1, 0x6e014020}; // ldr q1, [x21, #0x2170]; ext.16b v0, v1, v1, #8
inline constexpr uint32_t ExposureUVRender[2] = {0xfd50fea1, 0xfd5102a0};   // ldr d1, [x21, #0x21f8]; ldr d0, [x21, #0x2200]
// Code that sizes things from the view's full-target integer rectangle
// (+0x2180 size, +0x2188 offset) instead of the composed render rectangle
// RecalculateViewports writes at +0x2208/+0x2210. Each load moves to the
// composed field.
struct RectLoad { uintptr_t address; uint32_t original, render; };
inline constexpr RectLoad RenderRectLoads[] = {
    // ls::SetupForwardLightingConstants: UV clamps (+0x17c) that the forward
    // lighting and volumetric fog history read.
    {0x105e1c780, 0xb9618a89, 0xb9621289}, // ldr w9, [x20, #0x2188] -> #0x2210
    {0x105e1c7a4, 0xb9618e8a, 0xb962168a}, // ldr w10, [x20, #0x218c] -> #0x2214
    {0x105e1c7d0, 0xb9618a8a, 0xb962128a}, // ldr w10, [x20, #0x2188] -> #0x2210
    {0x105e1c7d4, 0xb961828b, 0xb9620a8b}, // ldr w11, [x20, #0x2180] -> #0x2208
    {0x105e1c7fc, 0xb9618e89, 0xb9621689}, // ldr w9, [x20, #0x218c] -> #0x2214
    {0x105e1c800, 0xb961868a, 0xb9620e8a}, // ldr w10, [x20, #0x2184] -> #0x220c
    // ls::PostProcessStep_Bloom and ls::PostProcessStep_DOF: the blur radius
    // factor (render size / output size x output height / 1080, _CB).
    {0x106095af8, 0xfd50c2ab, 0xfd5106ab}, // ldr d11, [x21, #0x2180] -> #0x2208
    {0x1060a4eb4, 0xfd50c280, 0xfd510680}, // ldr d0, [x20, #0x2180] -> #0x2208
    // ls::GameRenderView::UpdateConstantBuffersData and GetJitteredProjectionMatrix:
    // the projection jitter divisor, so a jitter step is one rendered pixel.
    // The velocity shader removes jitter (_TemporalConstants g_Jitter) in whole
    // rendered pixels; divided by the full target the projection moved only
    // the region's share of that, leaving jitter-correlated velocity.
    {0x105f8af68, 0xfd50c280, 0xfd510680}, // ldr d0, [x20, #0x2180] -> #0x2208
    {0x105f8bdb8, 0xfd50c282, 0xfd510682}, // ldr d2, [x20, #0x2180] -> #0x2208
};
// ls::SSRStage::ExecuteWTKernel saves the SSR history's previous viewport into
// its state (x26): UV clamps at +0x2470/+0x2478 from the view's integer rectangle
// (+0x2188 offset, +0x2180 size) over a texture size in v0, then scale and offset
// at +0x2480/+0x2488 from +0x2170/+0x2178. An island stores all four from the
// composed render viewport (x9 is the view) and returns after the last store.
inline constexpr uintptr_t SSRHistoryStart = 0x106116cec, SSRHistoryReturn = 0x106116d30;
inline constexpr uint32_t SSRHistoryOriginal[] = {0xfd50c521, 0x0e21d822, 0x0f0167e3, 0x0e23d442, 0x2e20fc42, 0xfd123b42,
                                                  0xfd50c122, 0x0ea18441, 0x0e21d821, 0x0f0567e2, 0x0e22d421, 0x2e20fc20,
                                                  0xfd123f40, 0xf950b928, 0xf9124348, 0xf950bd28, 0xf9124748};
inline constexpr uint32_t SSRHistoryRender[] = {
    0xfd50fd21, 0xfd510122,             // ldr d1, [x9, #0x21f8]; ldr d2, [x9, #0x2200]
    0x0f03f403, 0x2e20fc63,             // fmov.2s v3, #0.5; fdiv.2s v3, v3, v0 (half texel)
    0x0e23d440, 0xfd123b40,             // fadd.2s v0, v2, v3; str d0, [x26, #0x2470]
    0x0e21d440, 0x0ea3d400, 0xfd123f40, // fadd.2s v0, v2, v1; fsub.2s v0, v0, v3; str d0, [x26, #0x2478]
    0xfd124341, 0xfd124742,             // str d1, [x26, #0x2480]; str d2, [x26, #0x2488]
};
// ls::SSRStage::ExecuteWTKernel loads its history-valid byte (state +0x2148,
// x27 + 0x20) and sets g_discard_history to its inverse. BG3 clears it on
// target resizes, disable and view resets, never on a viewport reduction
// change, and the main history read assumes the previous viewport equals the
// current one. An island loads the byte as 0 while a flag the probe owns is
// set: ldrb w11, [x27, #0x20]; ldr x16, flag; ldrb w16, [x16]; cbz w16, back;
// mov w11, #0; back: b SSRValidReturn; .quad flag.
inline constexpr uintptr_t SSRValidLoad = 0x10611268c, SSRValidReturn = 0x106112690;
inline constexpr uint32_t SSRValidOriginal = 0x3940836b; // ldrb w11, [x27, #0x20]
inline constexpr uint32_t SSRValidRender[] = {0x3940836b, 0x580000b0, 0x39400210, 0x34000050, 0x5280000b};
}
namespace Shadows {
inline constexpr uintptr_t FirstStageAdd = 0x105d1a7c8;
inline constexpr uintptr_t SecondStageAdd = 0x105d1a818;
inline constexpr uintptr_t StageType = 0x10789ffc3;
}

namespace Menu::Layout {
inline constexpr size_t Items = 0x30;
inline constexpr size_t ItemCount = 0x3c;
inline constexpr size_t ItemID = 0x88;
inline constexpr size_t CheckboxValue = 0xa8;
inline constexpr size_t ItemEnabled = 0x2c;
inline constexpr size_t EnabledObservers = 0x78;
inline constexpr size_t EnabledObserverCount = 0x84;
inline constexpr size_t ObserverStride = 0x48;
inline constexpr size_t ComboCount = 0x9c;
inline constexpr size_t ComboItems = 0x90;
inline constexpr size_t ComboItemStride = 0x24;
inline constexpr size_t ComboItemValue = 0x20;
// RefreshUIUpscaleMode notifies these (no argument) after rebuilding a combo's items.
inline constexpr size_t ComboItemsObservers = 0xa8;
inline constexpr size_t ComboItemsObserverCount = 0xb4;
inline constexpr size_t ComboSelection = 0xd0;
inline constexpr size_t SelectionCallback = 0x38;
inline constexpr size_t SelectionObservers = 0xc0;
inline constexpr size_t SelectionObserverCount = 0xcc;
inline constexpr size_t NativeUpscalingType = 0xf7;
inline constexpr size_t NativeQuality = 0xf8;
// Upscaling Sharpness (slider 101): the manager's FSR RCAS sharpness (0-1),
// which SetResolutionUpscaleFSR1 resets to 0.8 whenever the quality changes,
// and the slider's displayed value (0-100) with its value observers.
inline constexpr size_t UpscaleSharpness = 0xfc;
inline constexpr size_t SliderValue = 0xb8;
inline constexpr size_t SliderObservers = 0xa8;
inline constexpr size_t SliderObserverCount = 0xb4;
inline constexpr size_t SettingsStorage = 0x60;
// PublishSettings(manager, bool) copies the storage's first 0xa8 bytes (two
// ls::STDStrings at +0x60 and +0x70 by copy construction) and reads +0x131.
inline constexpr size_t PublishedSettingsBytes = 0xa8, PublishedManagerBytes = 0x140;
inline constexpr size_t CallbackManager = 0x18;
inline constexpr size_t CapturedManager = 0x50;
inline constexpr size_t ItemType = 8, VTable = 0, ObserverContext = 8, TranslationMap = 8;
inline constexpr size_t InitSlot = 4, ApplyComboSlot = 7;
}

namespace Temporal::Layout {
inline constexpr size_t ViewStages = 0x20;
inline constexpr size_t ViewStageCount = 0x2c;
inline constexpr size_t Enabled = 0x18;
inline constexpr size_t StageSteps = 0x2150;
inline constexpr size_t StageStepCount = 0x215c;
inline constexpr size_t ViewFrame = 0x2050;
inline constexpr size_t ViewCamera = 0x21d8;
inline constexpr size_t ViewSize = 0x2180;
inline constexpr size_t CameraUnjittered = 0xa;
inline constexpr size_t SettingsQuality = 0x98;
// Menu::SetQuality resets it to 0.8 when the quality changes.
inline constexpr size_t SettingsSharpness = 0x9c;
// Video options, live: the refresh rate (int32 numerator, denominator), VSync
// (+0x28) with triple buffering (+0x29), and the frame cap's toggle (byte) and
// frames per second (uint16).
inline constexpr size_t SettingsRefreshNumerator = 0x18, SettingsRefreshDenominator = 0x1c;
inline constexpr size_t SettingsFrameCapEnabled = 0x5b, SettingsFrameCap = 0x5c;
inline constexpr size_t ClassifierMethodSlot = 0x10;
inline constexpr size_t VTable = 0, FrameIndex = 8, FrameIndexOffset = 12;
inline constexpr size_t JitterIslandStride = 64;
}

namespace ThreadIdling::Layout {
// GameClock: CapFrame measures elapsed time from ClockStart (mach ticks), valid
// once ClockStarted is set; at its idle yield x19 is the clock and x27 the wait
// target in us from ClockStart.
inline constexpr size_t ClockStart = 0x8, ClockStarted = 0x10;
}

// rf::metal::MetalRenderer: an os_unfair_lock guarding the bump offset into the
// frame's uniform buffer (BufferBytes each, four in a ring; with unified memory
// the GPU reads it directly). SetupEngineParameters reaches the renderer at
// SetupRenderer past the object it loads.
namespace UniformSlices::Layout {
inline constexpr size_t Lock = 0x8, Offset = 0x2090, SetupRenderer = 0x1f0;
inline constexpr uint64_t BufferBytes = 0x1500000;
}

// rf::RenderFrame: render size (output / FSR scale) and output size as int
// pairs; CalculateViewports shrinks only the render-size viewport by
// sqrt(Reduction) when it is below 1, storing its pixel size at
// RenderViewport. Registered views: pointer array and count. Settings: the
// global graphics settings' FSR-enabled byte (quality is Temporal::Layout).
namespace ViewportReduction::Layout {
inline constexpr size_t RenderSize = 0x18, OutputSize = 0x20, Reduction = 0x4368, RenderViewport = 0x4318;
inline constexpr size_t Views = 0x42f0, ViewCount = 0x42fc, ViewRenderRect = 0x2208;
inline constexpr size_t SettingsUpscaling = 0x97;
}

namespace ServerPacing::Layout {
inline constexpr size_t Target = 0x18, Debt = 0x28;
inline constexpr size_t WorkerTarget = 0x98, WorkerDebt = 0xa8;
}

// Reserved half-open ranges relative to HeaderPadding. Validate every island
// against its own zero bytes before patching, in addition to these overlap checks.
struct Island { size_t offset, bytes; };
namespace Islands {
inline constexpr Island Temporal{0x000, 3 * 64};
inline constexpr Island Lua{0x700, 32};
inline constexpr Island ServerPacing{0x800, 4 * 24};
inline constexpr Island ThreadIdle{0x9c0, 32};
inline constexpr Island UniformSlices{0xa00, 64};
inline constexpr Island ViewportReduction{0xa40, 2 * 24};
inline constexpr Island SSRHistory{0xa70, 12 * 4};
inline constexpr Island SSRValid{0xaa0, 32};
inline constexpr Island All[] = {Temporal, Lua, ServerPacing, ThreadIdle, UniformSlices, ViewportReduction, SSRHistory, SSRValid};
constexpr bool valid(const Island *ranges, size_t count) {
    for (size_t i=0; i<count; ++i) {
        const Island current = ranges[i];
        if (!current.bytes || current.offset % 4 || current.bytes % 4 ||
            current.offset > 0x4000 || current.bytes > 0x4000 - current.offset) return false;
        for (size_t j=0; j<i; ++j)
            if (current.offset < ranges[j].offset + ranges[j].bytes && ranges[j].offset < current.offset + current.bytes) return false;
    }
    return true;
}
static_assert(valid(All,sizeof(All)/sizeof(All[0])), "Native branch-island reservations must be aligned, disjoint, and within header padding");
}
}
#endif
