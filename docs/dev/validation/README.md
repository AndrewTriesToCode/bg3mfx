# Current validation status

Updated October 21, 2026. This page is the active record. Detailed dated notes
are archived under [`history/`](history/).

## Shadow Rendering Optimizations

### Duplicate shadow-stage elimination

BG3 builds its game view with two identical cascaded-shadow stages; the first
one's shadow maps are overwritten before anything reads them.
`ShadowDuplicateFix` removes the first whenever bg3mfx runs;
`BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS=0` keeps both for comparison. Live on
October 13 (quiet runtime, Ultra, Upscaling Off, windowed): 73.9 → 86.0 fps,
HUD GPU time 14.0 → 11.75 ms, in-game shadow passes 10 → 5 per frame, and the
user saw no difference in shadows. No GPU capture was taken
with the fix on. Analysis and method:
[`docs/dev/performance.md`](../performance.md).

### Improved shadows (October 23, 2026)

[Feature README](../../../src/features/shadows/README.md#improved-shadows).
On by default as part of Shadow Rendering Optimizations: bg3mfx replaces
BG3's PCSS (Medium, High) and PCF (Low) sun shadow mask shaders with its own,
using the G-buffer normal and no grazing fade.
`BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS=0` leaves BG3's shaders.

Synthetic, offscreen (`improved-shadows-smoke`, M5 Pro): all 12 variants
compile; on a plane under a checkerboard of blockers, PCSS and PCF shadow and
light the expected pixels at 64×64 and 16×16.

Live (M5 Pro, MetalFX Temporal at a low render size, High and Medium):
- A reproduction of BG3's PCSS pass, used while developing this and since
  removed, matched BG3 exactly on 99.98-99.99% of pixels and within 1/255 on
  100.000%.
- Displayed (user's eye): with BG3's grazing fade removed, slopes were no
  longer darker at low resolution, with no speckle or striping. With every
  pixel's G-buffer normal and no fade, diamonds and dotted lines were gone;
  judged good on terrain, foliage, decals and hair.

Not yet checked: Low (PCF) live; GPU cost.

## Depth Prepass Optimization

Whenever bg3mfx runs (`BG3MFX_DEPTH_PREPASS_OPTIMIZATION=0` disables it), opaque draws whose prepass pipeline has no
fragment function are skipped in the depth prepass, and their G-buffer draws
write depth (`GreaterEqual`) instead of testing `Equal`, as BG3's terrain
does. Live on October 14, with the shadow fix (quiet runtime, Ultra, Upscaling
Off, windowed): the diagnostic trace showed 230 prepass draws skipped and 230
G-buffer draws switched per frame; HUD GPU time 12.0 → 10.5 ms; 82.9 → 84.4
fps, because the frame is now limited by BG3's render thread. The user saw no
artifacts on characters or distant geometry. `prepass-trim-smoke` (in
`make test`) checks G-buffer pixels with the trim on and off, that the trim
skips only vertex-only prepass draws and leaves a discarding material's
Equal test intact, and that bind filtering forwards a changed texture slot;
negative controls (no depth swap, a dropped texture change) fail it.

## Render Thread Optimizations

BG3 calls `setFragmentTextures:withRange:` about 1,130 times per frame over
about 30,000 slots; 92% of those slots already hold the same texture, and 12%
of pipeline binds repeat the bound pipeline (diagnostic counters, October 14).
The runtime forwards only changed slot runs and new pipelines
(`BG3MFX_RENDER_THREAD_OPTIMIZATIONS=0` disables it). `make test` passes with it on. Live,
quiet runtime with the shadow fix and prepass trim (Ultra, Upscaling Off,
windowed): 83.1 → 84.0 fps at about 10.7 ms GPU time. CPU samples show
driver time on BG3's render thread down about 25% per frame (texture binds
−72%), but this scene is now mostly GPU-limited, so little of it shows as
frame rate; CPU-heavier scenes should gain more.

## Hook overhead, second round

Per-encoder diagnostic tables are compiled out of the quiet runtime; pipeline
binds use a per-thread pipeline-info cache invalidated whenever a pipeline is
created or deallocated; encoder setup and end touch only the associated
objects an encoder actually set (a per-encoder bitmask, with a full clear
whenever the state is unknown); and the per-thread caches share one
thread-local block, with `original()`'s fast path inlined. `make test` passes
with the defaults, with bind filtering off, and with bind filtering and the
prepass trim off. Live (Ultra, windowed, October 14): no measurable frame-rate
change against the previous commit (83.2 vs 83.2 fps, interleaved runs), as
that scene is mostly GPU-limited. The user saw no artifacts.

## CPU power: thread idling, worker core prioritization, and Lua

Live on October 14 (quiet runtime, Ultra, Upscaling Off, Frame Cap off, Lower
City, M5 Pro), measured with `tools/analysis/procpower.c`. BG3's CPU power fell
from 23.7 W to 7.4 W at the same 95–96 fps; server ticks stayed at 30.0/s
(the server pacing probe's worst interval 33.4–34.6 ms). Steps and method:
[`docs/dev/performance.md`](../performance.md).

- CPU Thread Idling alone: about 11 W. The in-game Frame Cap now idles
  between frames (user-confirmed lower CPU with the cap on). That build also
  blocked batch waiters (about −1 W), since removed because its single
  completion semaphore could strand a second waiter. On October 20, uncapped
  and CPU-bound on Low, the current defaults matched stock fps (185 vs 186)
  at 596% CPU against 727%; worker or scheduler polls added CPU without fps.
- Dynamic Worker Prioritization (removed October 21: with idle workers
  asleep it saved about 0.9 W and cost CPU time): 7.4 W where background costs nothing.
  Running through Lower City crowds, trials kept the `WT/High` workers at normal
  where background would have cost 6–11% (108.7 vs 102.0, 144.0 vs 128.7 fps),
  and the user saw no stutter at the switches. An earlier version also placed
  the `WT/Low` workers in background; dialogue replies then started late, and
  were on time again with them left at normal.
- Lua error handling: with `_setjmp`/`_longjmp`, `sigprocmask` and
  `__sigaltstack` no longer appear in server-thread samples (3.5% before);
  NPCs and combat behaved normally.
- The user played combat, dialogue and area loads on these builds with no
  issues.
- Not covered: Macs with fewer or slower cores (the `CapFrame` job stealing is
  kept for them), and a GPU capture.

## Reduced Locking

Live on October 20 (quiet runtime, Ultra, Upscaling Off, Frame Cap 60, Lower
City, M5 Pro; every run held 60 fps): with Dynamic Worker Prioritization off,
BG3 used 162% CPU and 5.8 W with per-thread uniform slices against 205% and
6.6 W without; with it on, 238% and 4.9 W against 257% and 5.6 W. Slices
removed 98% of the lock samples in System Traces. The diagnostic runtime ran
about 33,000 slices in play with no rendering errors; the largest frame used
0.47 MB of the 21 MiB uniform buffer. Not covered: uncapped (CPU-bound) frame
rate, and Macs with fewer cores. Details:
[`docs/dev/performance.md`](../performance.md).

`make test` exercises neither feature: both patch BG3's own code or threads.

## Frame Generation

Frame Generation is the "MetalFX Frame Generation" checkbox and combines with
every Upscaling Type; clearing it releases the effect. Off, FSR, Spatial, and
Temporal have all been exercised live, and `frame-generation-hook-smoke` pairs each
with a byte-identical generated composition, switches between them, and checks
that frames without TAA inputs are presented unpaired and pairing resumes. Live,
Temporal, Spatial and FSR with Frame Generation worked; Off first did not pair
because BG3's CAS sharpening pass broke the scene chain. With CAS followed, all
four worked live, and the October 13 presentation pacing (minimum-duration and
spaced presents, see [Frame Generation](frame-generation.md)) was reported
working very well with VSync on and off. Since October 19, VSync off always
uses spaced presents so a window no longer alternates between Direct and
Composited. Live tests of the
first presentation design showed generated frames reaching the display at
roughly twice the rendered rate. The user found it slower and choppier: the HUD
did not show a higher FPS and motion did not look smoother. Presentation has
been rebuilt on Apple's present-thread model: BG3 renders into pooled stand-in
drawables, a worker shows the generated and real images on its own drawables,
paced from measured display times, and there is no per-frame allocation. Spatial
and Temporal now reuse pooled intermediates too. After later pacing
fixes, the user reports it working well on the MacBook's 120 Hz ProMotion
display, and at 60 Hz on that display. That is a user report without measured
frame rates. The current build has not been retried on the 60 Hz Studio Display. The
Metal HUD keeps its interpolation layout after an interpolator has existed in
the process, so compare modes on fresh launches. See
[Frame Generation](frame-generation.md).

On BG3's history-reset frames (16×16 velocity texture) the zero-motion stand-in
had different usage from BG3's velocity target, which changed the interpolator
configuration. A live October 21 trace showed 20 back-to-back rebuild pairs in
6¾ minutes, one on each reset frame and one on the frame after it. The stand-in
is now cached per size with BG3's velocity usage. `frame-generation-hook-smoke`
checks that a reset frame pairs without a rebuild; with the old usage it reports
two rebuilds. Live (October 21), a reset with Frame Generation on kept the
interpolator. One rebuild per launch remained: BG3's first frames are resets,
before any real velocity target has shown the usage to copy. Frame Generation now
presents those frames unpaired; the `startup-reset` variant checks that the
first real frame creates the only interpolator.

## CPU worker threads (removed)

BG3 sizes its job system as N high- plus N low-priority workers, N = min(cores -
3, available cores, 6). The title "(6 + 6 WT)" reflects the hard cap of 6, set in
`CoreLibSDM::Init` at `0x1064b728c`. An opt-in launcher flag replaced the cap
with half the available cores (9 + 9 on the 18-core M5 Pro). The user found it
did not help and it was removed. The scheduler, thread names and worker bounds
check allow 16 per priority if this is revisited.

## Native (anti-aliasing only) quality (not pursued)

BG3's FSR1 scale table is `[1.3, 1.5, 1.7, 2.0]` at `0x107872d40`.
`BaseApp::InitAPI`, `RenderFrame::Resize` and `PostProcessStep_FSR` treat any
FSR1 mode above 3 as scale 1.0: the scene renders at output size and the FSR
stage still runs. MetalFX Temporal creates at 1:1 on the M5 Pro (supported
scale 1.0-3.0). A fifth "Native (Anti-Aliasing Only)" quality was prototyped
and dropped at the user's request, since it adds GPU cost without a
performance benefit.

## Direct MetalFX inputs

Temporal and Frame Generation feed BG3's native-format textures to MetalFX
instead of converted copies, and Temporal writes straight into BG3's target.
Synthetic: copied and direct variants of the Temporal and interpolation smoke
tests pass pixel checks, including under Metal API validation. Live A/B on the
MacBook's 120 Hz display at 3840x2160 output (quiet runtime, HUD log, October 12,
same scene, copy-path build loaded with `BG3MFX_RUNTIME`): Temporal with vsync
off ran ~57.8 and ~58.1 fps with copies and ~58.9 direct; Temporal + Frame
Generation with vsync Triple showed ~85.4 vs ~85.0 displayed. Both differences
are within HUD noise. The change is kept for fewer passes and less memory, not
for a measurable frame-rate gain; MetalFX itself (about 3.1 ms Temporal, 6.3 ms
interpolation) dominates.

Local traces, captures, samples and replay inputs under `build/` were deleted on
October 12, 2026. Validation pages that cite those paths describe results that
can no longer be re-inspected locally.

## Spatial without TAA (October 19, 2026)

With Anti-Aliasing set to SMAA, MetalFX Spatial fell back to native FSR on every
frame ("Could not match FSR input to BG3's linear HDR scene color"): the scene
chain was seeded only at BG3's TAA pass. A diagnostic trace with SMAA showed
SMAA, bloom and color grading writing `FSR_Tonemap`'s input, RG11B10Float at
render size (640×400 → 1280×800 windowed). Spatial now seeds the chain there
when nothing upstream tagged it. `spatial-hook-smoke no-taa` reproduced the
fallback before the change and passes its pixel checks after it in both
runtimes. Live, quiet runtime, SMAA, windowed: zero fallback messages at the
main menu and in game, and the user reported the image looks good. Displayed
acceptance only; no frame-rate comparison.

## Scaler caches across resizes (October 19, 2026)

A static review found two leaks in the per-size scaler caches; regression
checks reproduced both before the change. Offscreen, `spatial-hook-smoke
resize` measured +170.8 MB of GPU allocations after a 24-size sweep (every
Spatial size kept); with a two-size cache and the 0.3 s settle it measures
+6.3 MB (+10.8 MB diagnostic runtime). `temporal-hook-smoke` found 24 of 32
earlier-size BG3 textures kept alive by cached Temporal scalers (texture
properties and the Metal 4 residency set); none survive now. Live, before the
change, a 10 s Spatial window drag in BG3 (SMAA, 1280×800 window) retained
+280 MB of graphics memory, and a second shorter drag +6 MB; how much of the
first was BG3's own resize cost was not isolated. Live re-measurement after the
change is pending.

## Metal 4 residency at a steady size (October 19, 2026)

Live in BG3 with Frame Generation on, then MetalFX Temporal, in a window and
without changing the output size, the diagnostic `metal4Residency` events
showed sets gaining entries for replaced BG3 targets: Frame Generation from 4
to 7 allocations (+13.5 MB at that size) with no settings change, plausibly a
save load, and Temporal by one allocation twice after settings changes. The
sets were rebuilt only when the render size changed or at 64 allocations. Each
bridge now drops members idle for 16 submissions; `metal4-bridge-smoke`
reproduced the retention before the change and passes after it (offscreen).
Live after the change, same window and settings toggles (bloom, ambient
occlusion, shadows) plus save loads: each time BG3 replaced targets the sets
returned to their steady size within 1–3 s (`replaced`): Temporal 11 → 9 → 4
allocations (18.9 → 7.8 MB), Frame Generation 7 → 4 (21.2 → 14.5 MB). The run
before it, accidentally on the unfixed library, grew Temporal to 14.

## Deferred Metal 4 submission and FSR_Tonemap skip (October 24, 2026)

Synthetic, offscreen only (M5 Pro); live validation pending.
- The Metal 4 bridge now submits after BG3 commits the buffer it encoded into.
  `metal4-bridge-smoke` passes eight in-flight frames with immediate and
  deferred submission. With a buffer encoded and never committed, the next 40
  submissions take 0.02 s and release its inputs; before the out-of-order
  submission of dropped work, the scaler's next submission timed out on the GPU.
- `spatial-hook-smoke tonemap` (both libraries): the FSR_Tonemap draw is
  skipped, and once its target is known the pass stores nothing (two of three
  MetalFX frames). Two frames at an unsettled size run native FSR on the
  compressed colour (0.375, 0.625, 0.875) from the replacement kernel, the
  second after a dropped store. `BG3MFX_SKIP_FSR_TONEMAP=0` keeps the draw and
  drops no store. Clean under Metal API validation. The other Spatial and
  Temporal hook smokes pass unchanged. (Under validation, `temporal-hook-smoke`
  fails its resize retention check with the skip on or off: the validation
  layer keeps the textures.)
- A GPU capture (October 21, Temporal, 2304×1440 render size) shows BG3's
  FSR_Tonemap pass loads nothing and stores its 13.2 MiB target; the dropped
  store's saving is not measured.
- Not yet checked live: frame time, Metal 4 Temporal and Frame Generation in
  BG3, and the fallback frames during a resize.

## Dynamic resolution probe (October 21, 2026)

Goal: vary only the upscaler's input resolution per frame; output stays at the
player's resolution. Static analysis of this build found an unused engine
mechanism: `rf::RenderFrame::CalculateViewports` (`0x10641c930`) shrinks only
the render-resolution viewport by the square root of a reduction factor at
`RenderFrame` +0x4368 (constructor value 1), and about 50 render stages bind the
Viewport constant buffer from those rectangles through
`rf::IAppStage::BindViewport*`. The shaders already apply `g_ViewportScale`,
`g_ViewportOffset` and UV clamps (split-screen support), and TAA and SSSR carry
previous-frame viewport values. The diagnostic `ViewportReductionProbe` set
the factor before each frame recorded; see the
[architecture code map](../architecture.md#code-map).

The probe has since become the quiet-runtime Dynamic Upscaling Quality
([feature README](../../../src/features/dynamic-resolution/README.md)). Its
patches and corrections below are unchanged; the fixed or oscillating area is
now the diagnostic `BG3MFX_DYNAMIC_RESOLUTION_AREA`, and a GPU-busy controller
chooses the area otherwise. The area range comes from the device's MetalFX
Temporal input content scale limits. Synthetic: `make test` passes with the
feature in both runtimes, and `temporal-jitter-smoke` checks Dynamic's
ceil(8 / area) Halton phases. The controller and the Dynamic menu entry have
not yet been run live. "The probe" below refers to the same code.

Synthetic: `metalfx-smoke` creates a dynamic-resolution Temporal scaler (M5 Pro
maximum scale 3.0) and upscales alternating 256² and 384² regions of 384²
inputs on Metal 4 and Metal 3; pixels outside the region never reach the
output, and a fixed scaler or a region beyond the maximum scale is refused.
`make test` passes with the probe in the diagnostic runtime.

Displayed, fixed area 0.5 (2304×1440 targets, 1629×1018 rendered, 3456×2160
output, Bloomridge Park, M5 Pro). The probe holds full size for 60 frames after
each resize and stops if MetalFX Temporal has failed. Two passes did not
respect the reduced viewport and are fixed in the probe; everything else
inspected rendered correctly, water included, and grass showed no problem.
Auto-exposure, found by the later audit, is fixed the same way:

- Volumetric fog history (`dcb491a`). `ls::LightingRenderStage::ExecuteWTKernel`
  saves the previous viewport for the fog reprojection (`_ReprojectData`
  `g_ViewportScale_Prev`/`g_ViewportOffset_Prev`) from view +0x2170/+0x2178,
  which stay at scale 1, offset 0, so the history was read as if it filled the
  target. The probe patches the two loads (`0x105ff8f50`, `0x105ff8f58`, in
  memory only) to read the composed render viewport at +0x21f8/+0x2200 and
  refuses to install if the original instructions differ.
- Volumetric fog composite (`a12d631`). BG3 pairs `DeferredFog_*` with
  `DefaultVS`, whose texture coordinates span the whole target, instead of
  `PPDefaultVS`, which maps them through the `_Viewport` buffer. While the probe
  is enabled those pipelines get `BG3MFXViewportFogVS`, which applies the
  `_Viewport` scale and offset (buffer 9, already bound), with `DefaultVS`'s
  interface.
- Surfaces: blood, water and other ground fluids (`96f34a9`). Blood under
  Temporal was blocky with a hard edge up close and vanished when zoomed out;
  it was correct whenever the probe was idle (Spatial, FSR, Frame Generation).
  Stencil dumps, constant buffers, the grid textures and the depth and normal
  inputs matched between reduced and full frames. The surface shaders
  (`Shared_Surface_VFX_Surface_*` vertex functions) draw a fixed screen-space
  grid whose vertices are NDC positions in −1…1, placed by the first matrix of
  the vertex EngineParams (buffer 21); BG3 chooses the grid cells in
  full-target coordinates that already account for the reduced region, so the
  reduced viewport shrank the grid toward the top-left a second time (projecting
  the captured vertices: cells to x 815 of 1629 reduced vs 1632 of 2304 full).
  The fragment shader rebuilds world position from the vertex shader's
  view-space ray and linear depth, so the misplaced rays failed its surface
  layer and height tests and every pixel was discarded. Rasterizing through
  the full-target viewport moved the grid under the body but left the rays
  wrong (still all discarded). The fix rebinds the vertex EngineParams for each
  surface draw with that matrix stretched by the reduction about NDC (−1, 1)
  (`x' = (x+1)/sx − 1`, `y' = 1 − (1−y)/sy`, sx = sy ≈ 0.707), then restores
  BG3's binding; blood renders correctly displayed.
- Auto-exposure. `ls::PostProcessStep_ExposureOld::ExecuteWTKernel` builds the
  `OldPPCalculateEV64x64ComputeCS` `_SceneUVSettings` (UOffset, UScale,
  VOffset, VScale; `setBytes` index 1) from the same full-size +0x2170/+0x2178
  pair, so exposure averaged the whole target, including pixels outside the
  region. The 16-byte load cannot reach +0x21f8, so the probe replaces it and
  the following `ext` (`0x1060b357c`) with two 8-byte loads from +0x21f8 and
  +0x2200 that leave the same halves for the `st2`. Captured live at area 0.5
  (1728×1080 targets): (0, 1, 0, 1) before, (0, 0.7072, 0, 0.7074) after,
  matching `_Viewport` scale and `g_ViewportReduction`.

An audit after these fixes looked for the same patterns elsewhere: renderer
stages that read +0x2170/+0x2178 of a render view, live shaders that sample
without `_Viewport`, read per-target sizes, or carry previous-frame viewports.
`ls::SSRStage::ExecuteWTKernel` saves its history viewport the same way the fog
did (`0x106116d20`/`0x106116d28`), and also derives its UV clamps from the
view's full-size integer rectangle (+0x2180/+0x2188) over a texture size. The
probe branches from `0x106116cec` to a header-padding island that stores scale
and offset from +0x21f8/+0x2200 and clamps of offset + half a texel and
offset + scale − half a texel, then returns to `0x106116d30`; it refuses to
install unless all 17 original instructions match. The four values are the
SSSR `_Constants` `g_ViewportUVClampMinPrev`, `UVClampMaxPrev`, `ScalePrev`
and `OffsetPrev` (bytes 432–463); `SSSRResolveTemporal` reprojects with
`clamp((uv − Offset) / Scale × ScalePrev + OffsetPrev, min, max)` in target UV
and reads the history at `round(uv × target size)`. The divisor is the size of
the scene texture almost every render-resolution stage fetches first (hash
`0xff193183`, the target size). Synthetic: `ssr-history-island-smoke` runs
BG3's original instructions and the island on the CPU; at full size, area 0.5
and an offset region the island, given BG3's full-size fields, stores what
BG3's own code stores for the composed region, and unpatched code stores the
full target. A live run at 0.5 installed it and ran about five minutes without
a fault, but its trace shows no SSR pipelines, so SSR itself was not exercised
live. The other +0x2170 loads in
the renderer (clustered lighting, SSAO, velocity, volumetric clouds, shadows)
read different structures.

A second sweep covered every load of view +0x2170–+0x218c in the binary,
including the `ecl::` stages. `RecalculateViewports` writes the composed
integer size and offset to +0x2208/+0x2210 and the same divided by the target
to +0x21f8/+0x2200; +0x2180/+0x2188 stay at the full target (the probe log
shows view size 2304×1440 with render rect 1629×1018). Users of the full
rectangle:

- Projection jitter (fixed). `GameRenderView::UpdateConstantBuffersData` and
  `GetJitteredProjectionMatrix` divide the jitter by +0x2180, so at area 0.5 the
  projection moved 0.707 of a rendered pixel per step. `VelocityBufferCamera_PS`
  removes jitter with `_TemporalConstants` `g_Jitter`/`g_PreviousJitter` in
  whole rendered pixels (captured (0.3125, 0.2037) and (−0.1875, −0.1296)), so
  static pixels kept 0.29 × (J − J_prev) of velocity, about 0.15 px in that
  frame, which MetalFX would treat as motion. The probe moves both divisors to
  +0x2208 (`BeginFrame` recalculates it for every view before recording, and
  every pass binds the viewport built from it), so BG3 jitters a whole rendered
  pixel, velocity cancels exactly, and MetalFX gets BG3's jitter unscaled; the
  earlier region-share scaling and `BG3MFX_VIEWPORT_REDUCTION_JITTER` are
  removed. Velocity maps the previous position through the current viewport,
  in current rendered pixels, which stays consistent when the area changes
  between frames.
- Bloom and DOF radius (fixed). `PostProcessStep_Bloom` and
  `PostProcessStep_DOF` set `_CB` = view size / output size × output height /
  1080, which `PPBloomDownsampleAndBlur_PS` and the DOF circular blurs multiply
  into their tap offsets in render pixels. Captured at area 0.5 it was (1, 1)
  instead of 0.707, so bloom and DOF reached 1.41× too far across the picture.
  The probe moves both loads to +0x2208.
- Forward lighting and fog history clamps (fixed). `SetupForwardLightingConstants`
  builds UV clamps (+0x17c) from the full rectangle; `LightingRenderStage` copies
  them into the volumetric fog `_ReprojectData`, so the fog history could
  sample past the region's right and bottom edges. The probe moves the six
  loads to +0x2208–+0x2214.
- SSR tile dispatches size their grids from the full rectangle: wasted tiles
  outside the region, no wrong pixels.

Shaders: the outline TAA (`EocOutlineTAA_PS`) receives the reduced previous
viewport in `_TAAProperties` (captured scale 0.7072/0.7074, clamps inside the
region). Subsurface scattering (`PPSSSS_H/V`) reads no viewport: its kernel step
is `width × P[0][0] / (2 × depth …)`, NDC × 0.5 in target UV, so under reduction
skin scattering is 1/√area too wide and unclamped at the region edge. The
kernel step is `P00` (H) or `P11` (V) × width / (2 × depth × `g_FarPlane`), and
neither shader reads the projection anywhere else (`g_FarPlane` also weights
depth differences, so it cannot carry the correction). `SubsurfaceDraw` in
`Trace.mm` rebinds the fragment `PerCamera` for each `PPSSSS_*` draw with `P00`
× the viewport's x share and `P11` × its y share, then restores BG3's binding
(event `subsurfaceScale`). Not yet verified live; the region-edge taps are
still unclamped.

Other sweeps found nothing further. Among live shaders that sample, only SSSS
derives screen offsets from the projection matrix, and `PerView` holds no screen
size. Only bloom and DOF normalize by 1080. Live pipelines whose vertex and
fragment stages both ignore the viewport are the Noesis UI (`*31`), Bink video,
offscreen brushes, terrain and sky geometry, the LUT passes and the outline
object draws, which form coordinates from pixel position × 1 / target size. The
cloud upsample reads integer positions inside the half-resolution viewport;
`VolumetricClouds_ComposePS`, which ignores the viewport, never ran. God rays
and lens flares project the sun in their vertex shaders and map it through
`g_ViewportScale`/`g_ViewportOffset`, with taps clamped to the viewport.

Native FSR fallback frames would be wrong under reduction: BG3's
`PostProcessStep_FSR` builds the EASU constants with the input viewport equal
to the input texture size (`Const0` = in / out, `Const1` = 1 / in), so a
fallback frame would stretch the whole target with the picture in its top-left.
All 21 fallbacks in the reduced-run traces came from output-size changes, when
the probe holds full size until sizes settle, so none was reduced. A shipping
feature must keep that order (or rewrite `Const0` from the region). `DefaultVS` is otherwise paired only with
output-resolution UI composition, and the sky rebuilds rays from frustum
corners on a full-screen quad, which the viewport places correctly.

History resets (shader IR and native code, not yet tested live). BG3 drops
fog and SSR history on stage load, state change, render-target resize
(`OnSizeChanged`), disable, and a per-view reset flag at view +0x2b5d that
exposure also obeys. Fog: `LightingRenderStage` sets `_ReprojectData`
`ResetFog` from those events. Each froxel uses history only when `ResetFog` is
0, the reprojected point lies inside the previous frame's
`g_VolumetricSampleMin/Max_Prev`, and a previous-depth test passes; otherwise
it takes 8 fresh samples instead of 1. SSR: `g_discard_history` is the inverse
of a valid byte at stage +0x2148. On discard the temporal resolve uses no
history and `ClassifyTiles` ignores the previous tile counts. Otherwise the
main history read takes the current UV minus velocity (or the hit
reprojection on mirror surfaces) and bounds-checks it against the current
`_Viewport` rectangle, not the Prev one, under a 3×3 mean ± 2.2σ clamp. Only
the secondary radiance read maps through `ScalePrev`/`OffsetPrev`. Outline TAA
has no reset input. It maps history through `ScalePrev`/`OffsetPrev` and
keeps the current pixel when the result falls outside `UVClampMin/MaxPrev`.

None of these events fires when the probe changes the area, because reduction
never resizes a target. Fog and outline TAA cope through their Prev clamps,
which describe the previous frame's region (the fog clamps after the
forward-lighting fix). SSR's main history read assumes the previous region
equals the current one, so for a few frames after each area change it would
sample history scaled about the target origin by old/new scale, limited by the
variance clamp. The probe therefore discards SSR history for the two frames
recorded after each area change (two in case a changed frame's SSR stage runs
after the next frame starts recording): an island at the valid-byte load in
`SSRStage::ExecuteWTKernel` (0x10611268c) loads it as 0 while a flag the probe
sets at `StartRecording` is up, and BG3 then sets `g_discard_history` itself.
`ssr-history-island-smoke` runs the island on the CPU with the flag clear and
set. In an oscillating run the area changes almost every frame, so SSR runs
without temporal history there. Live October 21 (area 0.5-1 over 4 s, SSR on,
reflective water): the user saw no smearing or jumps and called SSR great.

Terrain shadow seams (native BG3, seen live October 21 with native FSR, with
MetalFX, and without the probe). At low render resolutions sand shows a diamond
grid of dotted lines and whole diamond-shaped patches with wrong shading,
worse up close and at grazing view angles, unchanged by Shadow Quality. A
capture (864×540 render for 1728×1080) shows a clean G-buffer, decals and SAO;
the pattern first appears in the sun shadow mask (`DirLight_Cascaded_PCSS`).
That shader rebuilds a face normal per 2×2 quad from `dfdx`/`dfdy` of the
depth-reconstructed position and checks quad planarity with `quad_shuffle_xor`.
The normal drives a normal-offset bias, a weight that fades it into a constant
bias on grazing or non-planar quads, and whether the quad pools its blocker
search. Quads straddling terrain triangle edges get a mixed normal and differ
from their neighbours, which shows as dotted lines and diamonds. Lower
resolution and grazing views make each quad span more ground, so the artifacts
grow as dynamic resolution lowers the area. (An earlier note blamed a sun-facing
cutoff; the full IR has none.) Experimental fix:
[improved shadows](#improved-shadows-october-23-2026). Evidence:
`build/evidence/2026-10-21-dynamic-resolution/fsr-seams.gputrace` and
`fsr-seams-fetch/`.

The investigation added diagnostic-only tools: per-pass viewport logging while
reducing (`viewportReductionPass`), a surface debug fragment shader that colors
each grid pixel by the test that rejects it (`BG3MFX_SURFACE_DEBUG=1`), and
stencil dumps after the decal normal and surface passes
(`BG3MFX_STENCIL_DUMP_DIR`). All nine fixes live in the diagnostic runtime
with the probe; a shipping Dynamic quality needs them in the quiet runtime.

Still open: live confirmation of the second-sweep fixes (bloom `_CB` 0.707 at
area 0.5, fog clamps, jitter; watch for shimmer on static scenes); subsurface
scattering width (`subsurfaceScale`) and region edges (above); Frame Generation, which the probe
leaves at full resolution (confirmed in a capture with it on: scale 1); and an
oscillating area run.

## Character creation GPU hang (October 19, 2026)

Unmodified BG3 4.1.1.7631656 hung the GPU on entering character creation in
fullscreen 2336×1460 with AMD FSR 1.0 Ultra Quality (render 1796×1123). The
AGX driver wedged, WindowServer hit its watchdog, and the process stayed until
a reboot. bg3mfx 0.3.0 and 0.3.1 reached it only through a saved MetalFX
Ultra Quality setting; Off and other FSR qualities passed. Metal API validation
showed, within about 110 ms before the fault, `ClusterAssignment` (index 6),
`ClusteredLighting_0..13`, `VolumetricFogInitialize`, `VolumetricFogLighting`
(index 1) and the character lash and tearline fragment shaders (fragment index
1) running without `ClusterInfoBuffer`. The hang was intermittent: one run at
the same settings passed.

The [cluster buffer guard](../../../src/features/cluster-buffer-guard/README.md)
binds a zero-filled stand-in at those indices on each new encoder. Live with
the diagnostic runtime and API validation, at the same settings, a first run of
many character-creation entries (some at higher output resolutions) never
reproduced the trigger: BG3 bound the buffer itself every time. In a second
run, the first entry into character creation did reproduce it.
`ClusterAssignment`, `VolumetricFogInitialize` and `VolumetricFogLighting` ran
on the stand-in every frame for about 1 min 47 s: about 2,100 frames, 6,400
dispatches, at render 1796×1123 for 2336×1460 output. There was no hang and no
validation error, and the user saw normal lighting and fog. The reads stopped
when the user returned to the menu. Later entries, including one made with
Upscaling Off and then switched to FSR inside character creation, bound the
buffer normally. `ClusteredLighting_*` and the fragment shaders bound it in
this run. Changing the starting character loaded geometry slowly under
validation and tracing; this has not been compared on the quiet runtime. The
first run's `VolumetricFogGather`/`VolumetricFogLighting` stand-in events were
a diagnostic gap (compute `setBytes`, and passes that don't declare the
buffer), fixed before the second run. Evidence:
`build/evidence/2026-10-19-cc-crash/` (`trace-guard-2.jsonl`).

Live lldb tracing (diagnostic runtime, guard on) of a reproduced entry found
the mechanism. Entering character creation loads `ecl::BasicGameObjectRenderer`
with its own scene graph and a 300×300 `ClusteredAssignmentStage`. The main
scene graph's next `rf::SceneGraph::ConfigureAliasing` cleared the main stage's
`ClusterInfoBuffer` entry: the binding at entry `+0x80`, written at
`0x106433e38`. The next call's create pass (`0x106438798`) copied a null view
into it. In a normal resize the same call clears and refills the entry. The
main stage stayed marked rendering with the null entry until the preview
renderer was destroyed, when two more main-graph reconfigurations restored a
buffer. Why the create pass found no view is not pinned down. lldb scripts and
logs: `build/evidence/2026-10-19-cc-crash/cluster_lldb*.py` and
`lldb-cluster*.txt`.

## Metal 4 Temporal path

Temporal now chooses the Metal 4 scaler on supported devices and retains the
Metal 3 path otherwise. Offscreen 1.5×/2× static and moving comparisons produce
byte-identical settled output through both APIs on this M5 Pro. The GPU-event
bridge and quiet/diagnostic hooks pass API validation, including eight in-flight
submissions after backend destruction. Live BG3 capture confirms Metal 4
encodes at 2258×1270 → 3840×2160; the user confirms correct, stable camera
movement and inventory. Replaying 16 dumped game-input frames produces
byte-identical output through both APIs. Specific M5 Pro neural hardware/model
selection and comparative performance remain unproven. The
[Metal 4 audit](metal4-temporal.md) separates API support from neural-model
selection and records capture/replay limitations.

## Temporal quality correction

Quality-dependent 14/18/24/32-phase Temporal jitter is implemented. Native-layout
fixtures verify phase wrapping, frame consistency, native/auxiliary isolation,
and complete integer/SIMD register preservation at all three sample loads.
Both runtime builds pass the renderer regressions. Live startup succeeds after
replacing near allocation with guarded header-padding islands. The Balanced
trace verifies 24-phase samples, and a three-frame GPU capture shows changing
MetalFX jitter with history preserved. The user reports reduced shimmer,
inventory still looking correct, and "looks good now" in the tested scene; see
[longer jitter](temporal-long-jitter.md).

The native-to-MetalFX jitter conversion had both signs reversed. It now reports
`(-nativeX, +nativeY)`. The [diagnosis](temporal-jitter-diagnosis.md) records the
GPU pipeline audit, depth-registration evidence, analytic negative control, and
captured-game before/after replay. The 1.5×/2× static and moving analytic tests
measure 78–88% less reconstruction error than bilinear after the correction;
the legacy conversion fails all four cases. Captured purple rune strokes are
visibly cleaner with identical inputs. These are offscreen results. Separately,
the user tested the rebuilt quiet game at Temporal/Balanced, the saved camera,
and slow camera movement, and confirmed "Clearly better and stable" on October
11. This accepts the correction in that live test case, not every material or
scene.

At the time of the October 11 reconstruction run, `make test` passed with the
new regression and both runtime libraries; the Python launch tests then numbered
three. The current `make test-python` suite has 19 tests (see the October 15
build-maintenance record below). Full Metal
shader validation still reports invalid threadgroup loads in Apple's private
`BBRNetAnisoGaussian` kernel, in both the analytic test and captured-input replay.
Successful completion and finite output do not make those validation runs clean.

## Cleanup refactor check

The cleanup refactor rebuilt the quiet and diagnostic runtimes and passed
`make test`: standalone Spatial/Temporal pixel checks, runtime hook checks, and
quiet/diagnostic renderer-hook tests all succeeded with Metal GPU access. The
reduced development-launch helper suite passed three tests. A quiet launch
started BG3 in a 1280×800 window with the Metal HUD enabled and the app bundle
unchanged. Screen capture was unavailable in this session, so the in-game menu
was not visually rechecked after the launch-tool and naming cleanup. The test
process was closed after normal quit via Apple Events failed; no settings were
changed.

## Feature coverage

| Area | Evidence | Status |
| --- | --- | --- |
| Menu | Native options preserve Off/FSR and add Spatial/Temporal; HUD is first under General | Live menu order and callbacks were verified on BG3 4.1.1.7631656 |
| Quality and resolution | Four BG3 quality levels drive the MetalFX input size | Render dimensions and startup/Back persistence were exercised live; one quiet Off-to-MetalFX selection can show a blank quality label while using Balanced dimensions |
| Spatial | Linear HDR after bloom/color grading enters MetalFX before `FSR_Tonemap`; output continues through BG3 tone mapping and UI | Synthetic and main-menu checks passed; user confirms good colors, persistent settings, and improved performance versus Off. No further Spatial testing requested |
| Temporal | Native jitter converted to MetalFX displacement, HDR color, depth, and motion feed MetalFX; TAA output is replaced and separate AA is disabled | Corrected jitter improves analytic reconstruction and captured-game replay; user confirms clearly better and stable in the quiet Temporal/Balanced saved-camera and slow-motion test. MetalFX shader-validation fault remains unresolved |
| Native Off and FSR | Original settings callbacks and rendering paths remain in use | Off, TAA, native FSR callbacks/dispatches were observed in live menu tests |
| Metal HUD | Persistent menu checkbox controls the Metal layer overlay | Menu ordering and HUD on/off were visually verified |
| Error path | No failure closes BG3. A failed MetalFX upscaler turns off with a notice, BG3's native TAA and FSR + RCAS render, and Video options select AMD FSR 1.0 (the saved MetalFX type is cleared) until MetalFX is chosen again; Frame Generation failures turn Frame Generation off; menu and startup problems show a notice and BG3 continues. A frame whose FSR input matches no captured scene (transitions) runs BG3's native FSR + RCAS for that frame, logs `metalFXNativeFallback`, and restarts Temporal history | Synthetic invalid-resource regressions pass; the hook fixture checks the unmatched-frame fallback. `spatial-hook-smoke bad-format` checks that a Spatial failure keeps the process running with native FSR/RCAS on later frames (October 19). Live October 21 with the diagnostic `BG3MFX_TEST_FAIL_METALFX=<seconds>`: a forced Temporal failure fell back, Video options reopened on the fallback type, and choosing MetalFX Temporal again resumed it (that run tested an Off fallback, since replaced by FSR); repeated with the FSR fallback: the notice fired, Video options reopened on AMD FSR 1.0, and MetalFX Temporal resumed when chosen again |
| Video Options Menu Fix | Restores `LSMTLView` first responder after BG3 detaches and reattaches it during fullscreen graphics-setting changes | User confirmed the fullscreen Video menu remains responsive after changing settings; modal and windowed paths still need broader checks |

## Known issues

- The user reports that quality-dependent jitter reduced shimmer and that the
  tested Temporal/Balanced scene now “looks good.” Earlier reports of foliage
  shimmer remain useful historical evidence, not a current reproduced defect.
  No acceptance claim covers every material or scene. Full-scene Metal shader
  validation remains unresolved below.
- Inventory character-preview shimmer was introduced by suppressing native TAA
  in a separate view that never reaches MetalFX. The fix preserves native TAA
  unless the exact target has previously fed the upscaling stage. Before/after
  captures prove the preview TAA draw is restored while world Temporal remains
  active. The user confirms the preview is steadier. This does not add inventory
  upscaling; see [inventory AA validation](inventory-aa.md).
- The quiet menu sometimes leaves the quality label blank after changing from Off
  to a MetalFX type, even when the renderer uses Balanced resolution. The
  diagnostic runtime showed a correct label in a similar test. This UI behavior
  has not been fixed or cleanly reproduced after the latest menu refactor.
- Metal shader validation has reported invalid threadgroup loads in Apple's
  private `BBRNetAnisoGaussian` shader on captured and synthetic sequences.
  Later replay passed, but there has not been a clean full-scene run proving the
  fault resolved. No MetalFX shader exclusion is active.
- A mouse hover could move the help highlight after closing a quality popup; the
  user's reported upward jump has not been reproduced or fixed.
- The Mac game's waterfall foam shaders report INF/NAN in an uninjected,
  pristine run. This is proven original-game behavior and no repair is included.

## Feature-folder reorganization (October 15, 2026)

The feature/common/integration source layout builds with `make`. Both quiet and
diagnostic runtimes pass `make test` with GPU access: these are synthetic and
offscreen pixel/hook checks, not displayed-game acceptance. All 19 Python
launcher and shadow-analysis tests pass after recursive test discovery updates.
Optional replay, API-comparison, and probe build targets also succeed. A staged
`make install` preserves the launcher and quiet-runtime installation paths.
No live game test was performed for this path-only reorganization.

## Feature extraction and build maintenance (October 15, 2026)

Bind filtering now lives in `src/features/render-thread-optimizations/BindFilter.h`, and
prepass classification, depth-state replacement, draw decisions, and counters
live in `src/features/depth-prepass/DepthPrepass.*`. The shared renderer retains
hook installation, original-method dispatch, and scene tracking. A value audit
against pre-change snapshots confirmed all centralized native addresses, object
layouts, and branch-island ranges retain their supported-build values.

`make` builds the quiet runtime and launcher under `build/bin/`. `make test`
passes with GPU access on both quiet and diagnostic runtimes, including the
existing native-jitter, prepass pixel, and renderer-hook checks.
New bind-filter checks cover mixed single/bulk calls, nil/unbinding, changed-run
coalescing, pipeline repeats, and cache bounds. Supported-build guard checks
include overlap, alignment, empty/bounds, and overflow negative cases. These are
synthetic/offscreen results; no live game, displayed-image, pacing, or new
performance acceptance is claimed for the refactor.

All 19 Python tests pass, including cleanup preservation/rejection checks and
launch defaults. Optional replay, API-comparison, and probe targets build; a
staged `make install` still installs only the launcher and quiet library at the
same player paths. New traces and quality images use `build/evidence/`; historical
artifacts and licensed reference downloads remain untouched by cleanup.

## Repeatable checks

The active [Temporal quality plan](../temporal-quality-plan.md) uses the user's
latest save and saved camera as the primary comparison case. Spatial and setting
persistence are accepted from the user's play; focus new work on Temporal image
quality.

Run the synthetic suite with:

```sh
make test
make test-python
```

Metal pixel tests cover static Spatial HDR, Temporal HDR/depth/history behavior,
invalid inputs, and renderer-hook selection on quiet and diagnostic runtimes.
Python tests cover the launch helper. Neither suite replaces live menu or image
quality checks.

For live checks, use the development launch commands in the repository README.
Keep Steam running, use `-NoLauncher 1` through the helper, enable the HUD, and
avoid rebuilding a loaded library. Routine checks stay at the main menu. The
already authorized Wilderness/Lower City Temporal tests may include camera
movement and dialogue opening, without quest choices. Close BG3 after testing.

## Dated history

- [October 10: Temporal HDR and settings integration](history/2026-10-10-temporal.md)
- [October 11: Spatial HDR pass ordering](history/2026-10-11-spatial.md)
- [October 11: Temporal quality inputs](history/2026-10-11-temporal-quality.md)
- [October 11: Temporal jitter diagnosis and correction](temporal-jitter-diagnosis.md)
- [October 11: pristine waterfall baseline](history/2026-10-11-waterfall-baseline.md)
- [macOS renderer and menu research](../reference/mac-renderer.md)
- [Windows DLSS research](../reference/windows-dlss.md)
