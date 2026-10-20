# Mac camera and scene input investigation

This is a build-specific research snapshot, not the active implementation
guide. Current renderer behavior and source locations are in the
[architecture](../architecture.md) and [validation index](../validation/README.md).

Observed on the pristine ARM64 executable with SHA-256
`d81e0420d9158e6e58c55af62e8490366768d7376a92868d3bf55d05d561519b`.
Diagnostics were injected at launch, preserving the app's original signature.
The windowed scene rendered at 1280 by 800.

## Shader reflection and live constants

Metal pipeline reflection identifies these fragment shader bindings:

| Shader | Binding | Name |
| --- | --- | --- |
| PPTAA_PS | texture 0 | Current |
| PPTAA_PS | texture 1 | History |
| PPTAA_PS | texture 2 | Velocity |
| PPTAA_PS | texture 3 | LinearDepth |
| PPTAA_PS | texture 4 | GBuffer2 |
| VelocityBufferCamera_PS | texture 0 | LinearDepth |
| Both | buffer 8 | TemporalConstants |
| Both | buffer 9 | Viewport |
| Both | buffer 10 | PerRT |
| VelocityBufferCamera_PS | buffer 11 | PerCamera |

TemporalConstants contains `g_Jitter` at 208 and `g_PreviousJitter` at 216
(two floats each). PerCamera contains the projection matrix at 64, near plane
at 192, and far plane at 196. These offsets are reflection results for this
build, not assumptions for other versions.

Live values show near 0.1, far 40000, vertical FOV approximately 0.837758 radians.
The projection maps the near plane to device depth 1 and far plane to depth 0.
This establishes reversed projection depth, but does not establish that the
LinearDepth texture has the same encoding.

The eight jitter samples in `GameRenderView::GetJitteredProjectionMatrix`
use Halton bases 2 and 3, starting at index 1, with 0.5 subtracted from each
component. Live jitter constants match this sequence. The perspective function
is at `0x105f8bd4c`; camera constant setup is at `0x105f8a8a0`.

An early TAA pass binds a 16-by-16 placeholder for Velocity. Later passes bind
RG16Float velocity at the scene resolution. Integration must reject placeholder
inputs and establish reset behavior before relying on temporal history.

## Compiled shader evidence

Core.metallib retains LLVM AIR bitcode in standard LLVM wrappers. Extracted
modules stay in ignored build files. `xcrun clang -S -emit-llvm` can decode them
for inspection; the compiler's target override warning does not turn AIR into
a runnable native shader. No extracted game shader is used by the runtime.

In `VelocityBufferCamera_PS` IR, the output is current minus previous position
in framebuffer pixels. Current position is adjusted by `(jitter.x, -jitter.y)`;
the previous projected position is adjusted by `(previousJitter.x,
-previousJitter.y)`. Thus this camera velocity pass compensates for jitter.
MetalFX's SDK specifies previous minus current pixel displacement, so this pass
requires negating both motion components. The active `Shared_Base_Base_AlphaTest_VT_ST_VEL_fragmentMain` material
shader also uses current-minus-previous pixel displacement with jitter
compensation. Other material/animation variants still need verification.

`LinearizeDepth` computes either `(deviceDepth - B) / A` for its orthographic
branch, or `B / (deviceDepth - A)` for its perspective branch. Device depth zero
becomes a special linear-depth value of 1. The constants A and B must be traced
before inverting this texture; assuming meters or blindly applying near/far
would be unsafe. Using the original sampled device-depth texture may avoid this
conversion if its format, usage, dimensions, and lifetime are suitable.

## Reproduction and remaining integration

Launch with `BG3MFX_TRACE_CONSTANTS=1`, then run
`python3 tools/analysis/analyze_camera_trace.py build/game-shader-layout.jsonl`.
The analyzer uses reflected field offsets and reports projection depth checks.
Current local evidence is in `game-shader-layout.jsonl`,
`camera-shader-layout-report.json`, `VelocityBufferCamera_PS.ll`, and
`LinearizeDepth-0.ll` under ignored build output.

The integration now captures motion and camera data, converts the observed
device-depth texture, encodes MetalFX in the game's command buffer, manages
render resolution, replaces the selected pass, and exposes both modes in the
graphics menu. Camera cuts, resizing, temporal image quality, and performance
remain validation topics; see [current status](../validation/README.md). App
bundle patching is deferred.

## Device depth probe

Direct-draw snapshots associate the `LinearizeDepth` source texture with the
subsequent TAA inputs on the same command buffer. In the observed menu scene,
the original source is private Depth32Float_Stencil8, the linearized target is
R32Float, and camera/object velocity uses an RG16Float target. TAA's current
scene color is RG11B10Float. Placeholder velocity inputs are rejected.

The first retained-buffer probe aborted on Metal's texture-view validation:
Depth32Float_Stencil8 cannot be cast into a Depth32Float view, even when the
source permits pixel format views. The revised probe samples the depth aspect
into R32Float without changing device depth values. This remains a single reset
frame whose output is not displayed. Trace records now include the process ID
and append complete lines so an injected child process cannot erase evidence
from its parent.

The revised temporal and spatial offscreen probes both completed on the live
menu scene (Metal command buffer status 4, no error) in
`build/game-dual-scaler-probe.jsonl`. They scaled 1280×800 to 2560×1600 into
RGBA16Float. Temporal scaling consumed pre-TAA scene color, copied device depth,
and actual RG16Float velocity. Spatial scaling consumed the TAA render target
with explicit HDR color processing. Each output had 38,475 sampled RGB components,
all finite and positive. This establishes successful execution and nonempty
output, not correct color interpretation, temporal stability, display integration,
or performance improvement.

Scaler initialization must happen outside the tracing mutex. MetalFX's synchronous
initialization waits for worker threads that call the instrumented device methods;
holding the mutex caused a deadlock in the earlier depth-copy attempt. A process
sample confirmed the main thread waiting in temporal scaler creation and workers
waiting on the tracing mutex. The revised probe claims its attempt under the lock
and releases it before calling MetalFX.

## Existing graphics menu and FSR path

The native Video menu exposes Upscaling Type (Off / AMD FSR 1.0), Upscaling Mode,
Upscaling Sharpness, and an independent Anti-Aliasing choice. The observed
baseline was Off with TAA and FidelityFX Sharpening enabled. FSR Quality reduces
scene rendering to 853×533 for a 1280×800 window; a transient mode change produced
752×470 before Quality was selected. The window and UI remain at 1280×800.

These symbols are present in the inspected ARM64 build:

| Address | Symbol |
| --- | --- |
| 0x103288fb8 | VideoOptionsManager::InitOptions |
| 0x103291ef8 | VideoOptionsManager::RefreshUIUpscaleMode |
| 0x10329253c | VideoOptionsManager::RefreshUIAntiAliasing |
| 0x103290180 | VideoOptionsManager::ApplyComboBox |
| 0x103294954 | ComboBoxManager::AddComboItem<EResolutionUpscaleType> |
| 0x10640df20 | GraphicSettings::SetResolutionUpscaleOff |
| 0x10640df94 | GraphicSettings::SetResolutionUpscaleFSR1 |
| 0x1060b4dac | PostProcessStep_FSR::ExecuteWTKernel |
| 0x1064608d0 | MetalRenderer::BeginComputePass |
| 0x10645eda8 | MetalRenderer::Dispatch |

InitOptions adds Upscaling Type enum values 0 and 1. AddComboItem stores the value
as a byte widened into the ComboItem's 32-bit field at offset 0x20; each item is
0x24 bytes with two TranslatedString objects. RefreshUIUpscaleMode selects the FSR
mode list when the manager's type byte at 0xf7 equals 1. These layout details are
build-specific observations, not a stable API or a finished menu patch.

The FSR shaders include FSR_Tonemap, compute FSR, and compute FSR_RCAS. Native
BeginComputePass requests computeCommandEncoderWithDispatchType:; BeginFrame
requests commandBufferWithUnretainedReferences. Early live traces missed the
compute encoder hook even though render encoders were observed. A later method
replacement displaced the initial hook. The tracer refreshes the hook from the
render-encoder entry point, preserves the later wrapper, and guards re-entry if
that wrapper retained our earlier implementation. A synthetic late-wrapper GPU
regression passed, and `game-refreshed-compute-trace.jsonl` captured both actual
FSR dispatches with active hook coverage.

FSR takes an 853×533 RG11B10Float input at texture slot 0 and writes a 1280×800
RG11B10Float intermediate at slot 1. RCAS reads that intermediate at slot 0, reads
an R8Unorm 107×67 sharpening-exclusion mask at slot 1, and writes RG11B10Float at
slot 2. Both dispatches share one compute encoder. The output feeds PPToneMap_LUT
before the full-resolution interface is composed.

Inspection of FSR_Tonemap AIR shows the compression `rgb/(1+max(rgb))`, without
a gamma transform. RCAS applies sharpening outside its exclusion mask and
decodes to linear HDR via `rgb/max(1-max(rgb), 1/32768)`. The mask is an input,
not an additional output. The Spatial path takes
the linear-HDR scene color immediately before `FSR_Tonemap`, after bloom and
color grading; it no longer decodes the bounded FSR input. MetalFX Spatial writes
the native full-resolution HDR target, which BG3 then feeds to `PPToneMap_LUT`
before UI composition. It uses our own small conversion shaders rather than
distributing extracted game code. The current revision suppresses both native
FSR/RCAS dispatches and stops with a MetalFX error on invalid resources or
unexpected sequencing. No FSR fallback is implemented. Synthetic GPU counters
verify zero native dispatches while the MetalFX HDR pixel checks pass. Error
subprocesses for bad output format, an incomplete FSR/RCAS pair, and an
intervening compute dispatch exit 78 with descriptive errors. These checks do
not establish a performance gain.

`game-spatial-preview-fixed.jsonl` recorded successful scaling encoding and
command-buffer completion status 4. The title screen and main menu displayed
normally, with HUD Spatial 853×533 → 1280×800, and the graphics controls remained
responsive. Off restored the native full-resolution path. The test quit normally
with Off/TAA/FidelityFX Sharpening restored. No gameplay was tested.

The subsequent `game-spatial-no-fsr.jsonl` main-menu run confirmed the current
revision: both native FSR/RCAS dispatches logged as skipped, MetalFX encoding
succeeded and completion status was 4, and the HUD displayed Spatial
853×533 → 1280×800. It exited normally after baseline settings were restored;
the original executable hash remained unchanged. An isolated AppKit harness
verified the visible failure reason and Close Game action (exit 78); the error
does not contain a sentence about FSR fallback. (Superseded on October 19: a
failed upscaler now turns off and BG3's native FSR renders instead; see
[architecture](../architecture.md#failure-and-diagnostics).)

The first scaling attempt deadlocked because the driver's recycled encoder retained a
replacement request while a later wrapper bypassed encoder-creation cleanup.
Consume the request before calling any nested Metal APIs. The synthetic
`spatial-hook-smoke` deliberately displaces plain encoder creation, dispatches
FSR/RCAS-shaped work, and verifies replacement HDR pixels over three frames.

## Native Spatial menu and Metal HUD

The development runtime replaces the VideoOptionsManager InitOptions slot at
vtable 0x1087ac1a0 + 0x20 and calls the original first. The ordered option array
is at manager +0x30/count +0x3c. **Upscaling Type is option ID 99**; its
ComboItems array/count are at +0x90/+0x9c. Items are 0x24 bytes, with label +0,
description +0x10, and enum value +0x20. The native entries are Off=0 and
AMD FSR 1.0=1; the runtime appends MetalFX Spatial=2 and MetalFX Temporal=3
without editing the native labels or descriptions.

Upscaling Mode is a separate control, option ID 100. ID 107 is a checkbox and
does not control upscaling. `RefreshUIUpscaleMode`
populates that quality list only when the graphics setting's upscale type is 1.
`ApplyComboBox` sends type 1 to `SetResolutionUpscaleFSR1` and other values to
`SetResolutionUpscaleOff`. For a MetalFX choice, the callback temporarily passes
value 1 through BG3's original callback so its FSR quality and render-resolution
settings remain active, then restores the visible value 2 or 3. The runtime
stores that MetalFX selection separately in app preferences. Off=0 and native
FSR=1 use the original callback and dispatch path unchanged. Runtime hooks
replace FSR/RCAS only for selected values 2 and 3. No on-disk game asset is
changed.

AddTickBoxOption (0x1030a39bc) adds Show Metal HUD using custom ID 0x7f01. Its
inline Function table begins +0x38 (Call/Copy/MoveDestroy), with the table pointer
at +0x30. Replacing Call preserves native POD Copy/MoveDestroy. The ID is at
item +0x88, checked value +0xa8. This callback updates the app's CAMetalLayers'
developerHUDProperties mode (default/disabled), preserving other properties.
It saves BG3MFXMetalHUD in app preferences. The user requested this checkbox as
the first control under General, before Display Mode.

New strings register through RuntimeStringHandle construction (0x106535df4),
TranslatedStringRepository AddTranslatedString (0x106549388), and TranslatedString
construction (0x106545cc4). AddTranslatedString uses an explicit result pointer
in x0, repository in x1, consumed handle pointer in x2, StringView pointer/length
in x3/x4, map pointer in x5 and flags in x6. Repository global is 0x108b26098;
its default identity map is +8. Each registered string is resolved and compared
to the requested text before modifying controls. String references use the native
copy/assignment/destructor functions.

Runtime guards the ARM64 UUID 3B6F6492-114E-3EA2-BC64-DFDDBD361434 and expected
original vtable slot. The CLI additionally checks the pristine executable SHA.
Injected dyld image 0 may be the dylib; scan for MH_EXECUTE. Only the relevant
data page is made writable for callback replacement, then restored read-only.

Earlier live tests verified the prototype spatial label, the explanation, and a
working Show Metal HUD checkbox. Those screenshots predate the separate FSR,
Spatial, and Temporal values and do not validate the current menu implementation.
The final `game-native-menu-top-hud.jsonl` run verified Show Metal HUD as the
first control under General, before Display Mode. The inherited Upscaling
Sharpness slider currently has no MetalFX effect. Revalidate the new option IDs,
FSR path, and both MetalFX selections in the main menu.


### October 10 HDR and Options-close corrections

PPTAA Current is linear HDR, before FSR_Tonemap; captured finite values reached
59. Temporal must copy this source to RGBA16Float, without Spatial's inverse
compression. Both MetalFX final targets stay linear HDR for PPToneMap_LUT and
UI composition. This internal HDR representation applies with display HDR Off.

OptionManagerBase::Apply (0x1030a34d4) dispatches ComboItems through the native
vtable. VideoOptionsManager::ApplyComboBox (0x103290180) occupies raw slot 7 of
the table at 0x1087ac1a0 (including the two ABI header entries). The runtime
intercepts that entry in addition to InitOptions: custom Upscaling Type values
2/3 temporarily become native 1 during Apply, then are restored. Off/FSR and
other controls pass through unchanged. Without this, leaving Options calls
SetResolutionUpscaleOff for custom values and drops displayed MetalFX scaling.

Full shader validation remains failing inside MetalFX Temporal on consecutive
finite captured frames, including a standalone replay without runtime hooks.
See validation-2026-10-10.md for precise coverage and reproduction.
# Fullscreen versus windowed fullscreen (Mac ARM64 build)

Static inspection on October 10 distinguishes actual display-mode switching
from borderless scaling. Addresses below refer to the guarded 4.1.1.7631656 build.

- `rf::metal::MetalAPI::ResizeRenderFrameWindow` at `0x1064498e0`
  uses separate branches. Regular fullscreen calls `GetDisplayMode` at
  `0x106449c08` with requested dimensions and refresh rate, then
  `ChangeDisplayMode` at `0x106449c14`. It subsequently invokes
  `CocoaWindow::SetFullscreen` through vtable offset `0x70`.
- `ChangeDisplayMode` at `0x10644bcb4` schedules the block at `0x10644c118`;
  that block calls the imported `CGDisplaySetDisplayMode` at `0x10644c134`.
  This is a real display-mode request, although support and success depend on
  available display modes and the OS. It does not prove exclusive scanout.
- The windowed-fullscreen branch invokes `SetFakeFullscreen` via vtable
  offset `0x80` at `0x106449cc8`, then `Resize`, without selecting a new
  display mode. Leaving regular fullscreen can restore the saved display mode.
- `CocoaWindow::Resize` at `0x100bb3b7c` checks the fake-fullscreen flag.
  In that branch it reads current display width/height through
  `CGDisplayCopyDisplayMode` / `CGDisplayModeGetWidth` / `GetHeight`, sizes
  the view to the display, keeps drawableSize at the requested render dimensions,
  and records those dimensions through `setFakeWidth:fakeHeight:`. The other
  branch sizes both view and drawable to the requested dimensions.
- Both paths use the same Metal API and layer. Static inspection establishes
  different mode/resizing behavior, not an FPS or latency improvement. No live
  display-mode changes were made for this investigation.

