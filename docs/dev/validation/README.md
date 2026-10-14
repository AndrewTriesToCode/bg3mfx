# Current validation status

Updated October 12, 2026. This page is the active record. Detailed dated notes
are archived under [`history/`](history/).

## Duplicate shadow stage fix

BG3 builds its game view with two identical cascaded-shadow stages; the first
one's shadow maps are overwritten before anything reads them.
`ShadowDuplicateFix` removes the first whenever bg3mfx runs;
`BG3MFX_SINGLE_SHADOW_STAGE=0` keeps both for comparison. Live on
October 13 (quiet runtime, Ultra, Upscaling Off, windowed): 73.9 → 86.0 fps,
HUD GPU time 14.0 → 11.75 ms, in-game shadow passes 10 → 5 per frame (probe
trace), and the user saw no difference in shadows. No GPU capture was taken
with the fix on. Analysis and method:
[`perf/README.md`](../../../perf/README.md).

## Depth prepass trim

Whenever bg3mfx runs (`BG3MFX_PREPASS_TRIM=0` disables it), opaque draws whose prepass pipeline has no
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

## Redundant bind filtering

BG3 calls `setFragmentTextures:withRange:` about 1,130 times per frame over
about 30,000 slots; 92% of those slots already hold the same texture, and 12%
of pipeline binds repeat the bound pipeline (diagnostic counters, October 14).
The runtime forwards only changed slot runs and new pipelines
(`BG3MFX_TEXTURE_DEDUP=0` disables it). `make test` passes with it on. Live,
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

## Frame Generation (initial integration)

Frame Generation is the "MetalFX Frame Generation" checkbox and combines with
every Upscaling Type; clearing it releases the effect. As of October 13, only
Temporal + Frame Generation has run live. Off, FSR and Spatial with Frame
Generation are covered synthetically: `frame-generation-hook-smoke` pairs each
with a byte-identical generated composition, switches between them, and checks
that frames without TAA inputs are presented unpaired and pairing resumes. Live,
Temporal, Spatial and FSR with Frame Generation worked; Off first did not pair
because BG3's CAS sharpening pass broke the scene chain. With CAS followed, all
four worked live, and the October 13 presentation pacing (minimum-duration and
spaced presents, see [Frame Generation](frame-generation.md)) was reported
working very well with VSync on and off. Live tests of the
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

`make test` passes with the new reconstruction regression and both rebuilt
runtime libraries; `make test-python` passes three launch tests. Full Metal
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
| Error path | Setup and resource failures display a clear error and exit 78. A frame whose FSR input matches no captured scene (transitions) runs BG3's native FSR + RCAS for that frame, logs `metalFXNativeFallback`, and restarts Temporal history | Synthetic invalid-resource regressions pass; the hook fixture checks the unmatched-frame fallback. User reported scene-match closures before this change; not yet retested live |

## Known issues

- After the jitter correction, the user reports remaining shimmer on grass,
  foliage, or thin geometry even with the camera still. The correction remains
  accepted as clearly better and stable; temporal image quality is not fully
  accepted. Compare Temporal/Balanced, Temporal/Ultra Quality, and
  Spatial/Balanced with native TAA at the same saved camera before changing
  renderer behavior. The user reports Ultra Quality reduces the shimmer and
  Spatial with native TAA does not show it in the tested foliage. Wind
  deformation motion coverage, alpha-tested visibility, and the previous
  eight-phase sampling are hypotheses, not established causes. The longer jitter
  sequence reduces shimmer in the user's tested scene, which they now report
  looks good. This does not establish every material or scene as artifact-free.
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
- Temporal produced more jagged thin reeds than Spatial in a matched Wilderness
  screenshot comparison. The user also reported poor foliage quality and lower
  performance. Captured inputs were finite and a 16-frame standalone replay
  passed full Metal validation, but separate native-jitter input sequences
  previously triggered an invalid threadgroup load in Apple's private
  `BBRNetAnisoGaussian` shader. The new longer jitter uses native history handling;
  there has not been a clean full-scene shader-validation run proving that fault
  resolved. No jitter workaround or MetalFX shader exclusion is active.
- A mouse hover could move the help highlight after closing a quality popup; the
  user's reported upward jump has not been reproduced or fixed.
- The Mac game's waterfall foam shaders report INF/NAN in an uninjected,
  pristine run. This is proven original-game behavior and no repair is included.

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
