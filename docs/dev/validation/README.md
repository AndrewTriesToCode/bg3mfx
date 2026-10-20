# Current validation status

Updated October 19, 2026. This page is the active record. Detailed dated notes
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
  between frames (user-confirmed lower CPU with the cap on).
- Dynamic Worker Prioritization: 7.4 W where background costs nothing.
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
| Error path | No failure closes BG3. A failed MetalFX upscaler turns off with a notice and BG3's native TAA and FSR + RCAS render until another Upscaling Type is chosen; Frame Generation failures turn Frame Generation off; menu and startup problems show a notice and BG3 continues. A frame whose FSR input matches no captured scene (transitions) runs BG3's native FSR + RCAS for that frame, logs `metalFXNativeFallback`, and restarts Temporal history | Synthetic invalid-resource regressions pass; the hook fixture checks the unmatched-frame fallback. `spatial-hook-smoke bad-format` checks that a Spatial failure keeps the process running with native FSR/RCAS on later frames (October 19); not yet triggered live |
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
