# Frame Generation integration

Current implementation: [architecture](../architecture.md#frame-generation).
This document retains dated design iterations and measurements. Its live
acceptance status is maintained in the [validation index](README.md).

## Scope

Frame Generation is the "MetalFX Frame Generation" checkbox, shown after the
upscaling controls on supported devices, and combines with every Upscaling Type
(see [architecture](../architecture.md#frame-generation)). Clearing it releases
the interpolator and presentation worker. Earlier settings migrate to the
checkbox: the Temporal-only checkbox of the first builds, and the later
"MetalFX Temporal + Frame Generation" and "MetalFX Spatial + Frame Generation"
Upscaling Type entries. Results below predate the checkbox and were measured
with Temporal.

History: the first build offered an independent checkbox for all four upscalers.
Off/FSR/Spatial relied on native TAA supplying camera, depth, and motion, and
AA-off had no inputs. A Temporal-only checkbox followed. In live use it could
show checked while dimmed under another upscaler, and the HUD kept reporting
interpolation after unchecking because the idle effect stayed allocated. The
dropdown entry removes both mismatches.

The FPS limiter continues controlling rendered frames. Frame interpolation
attempts to insert one additional display frame between successive real frames;
actual display throughput remains subject to GPU cost and display scheduling.
Measured (HUD log, quiet runtime, 3840x2160 output on the 120 Hz MacBook
display, October 12): Temporal alone ~58-59 fps with vsync off; Temporal + Frame
Generation ~85 displayed fps (~42-43 real) with vsync Triple. No latency
measurement has been made.

## Rendering contract

`FrameInterpolation.*` owns a separate MetalFX interpolator and presentation
worker. It chooses `MTL4FXFrameInterpolator` on devices supporting Metal 4 FX,
otherwise retaining the Metal 3 implementation. The Metal 4 effect runs through
the reusable GPU-event bridge in `GPUResources.*`. Its inputs and outputs come
from texture pools. There is no per-frame CPU wait in interpolation.

The renderer hooks carry exact camera/depth/motion associations from Temporal's
captured inputs through the MetalFX output, postprocessing, and `PPToneMap_LUT`.
Views without that association (menus, loading screens, inventory preview) are
presented without a generated frame; the hooks must not invent a camera or zero
object motion.

At the final `CombineUI` draw, the integration reuses BG3's native compositor
pipeline, vertex buffer, reflected constant data and sampler. Scene color is a
full-resolution RGB10A2Unorm texture; UI is a separate RGBA8Unorm texture. The
interpolator reads the scene, Depth32Float_Stencil8 depth and RG16Float motion
in place. On macOS 27 it keeps the preceding scene itself
(`requiresPrevColorTexture = NO`); on macOS 26 it consumes a copied RGBA16Float
scene and retains the preceding copy. Synthetic tests cover both the direct and
copied paths under Metal API validation. Live, at 4K on the 120 Hz MacBook
display with vsync Triple, the direct and copy-path builds both showed about
85 displayed fps (about 42-43 real); no measurable difference. It receives BG3's near/far/FOV, reversed depth,
motion convention and jitter adapter. These conventions still require live
moving-scene validation for interpolation, separately from temporal scaling.

Presentation (second design, after live tests showed the first was slower and
choppier):

- While Frame Generation is on, BG3's `nextDrawable` returns a stand-in backed by
  one of three pooled textures in the layer's pixel format. BG3's own `CombineUI` composes the real
  frame into it; that image is used as-is. If all three stand-ins are still
  waiting to be shown, `nextDrawable` blocks up to one second, like a real
  drawable.
- The generated scene is composed once more with the same pipeline, constants
  and UI into a pooled texture. UI is not interpolated.
- BG3 calls `presentDrawable:` before it encodes `CombineUI`. The stand-in
  present is recorded and resolved at `commit`, which encodes a shared-event
  signal into BG3's buffer and queues the frame (with its generated image when
  the pair matches) for the worker. A stand-in never reaches the native present.
- The worker thread acquires real drawables itself. Its copy buffers wait for
  the shared event on the GPU. The generated image is presented at the last real
  frame's display time plus half the frame interval. The real image is presented
  at the generated image's measured display time plus half an interval.
- Live pacing measurements drove two changes. Waiting for display inside the
  worker slowed BG3 to about 13 fps (`build/fg-pacing-1.jsonl`), so the worker
  no longer waits for display with vsync on. `presentDrawable:atTime:` rounds to
  the display refresh even when BG3's vsync is off. Every present landed 16.7 or
  33.3 ms apart on the user's 60 Hz Studio Display, capping BG3 at about 24 real
  fps against about 55 with Temporal alone (`build/fg-pacing-2.jsonl`). With
  vsync off (`displaySyncEnabled == NO`) the worker now commits both copies at
  once and presents each drawable itself with `-present` at its time. The vsync-on
  path keeps `presentDrawable:atTime:`. Neither path is validated live yet.
- On a 60 Hz panel, frame generation cannot show more than 60 refreshes per
  second. It helps only below about 30 real fps; above 60 fps with vsync off it
  adds torn partial frames. ProMotion (up to 120 Hz) is the intended target. It
  is unmeasured here because only the Studio Display is connected.
- After the backlog fix (the worker never sleeps while another frame is
  waiting), the user ran the quiet build on the MacBook's built-in 120 Hz
  ProMotion display (3456x2234). They report Frame Generation "working well",
  including with the laptop set to 60 Hz, and better with BG3's vsync on than
  off. Vsync on uses the scheduled `presentDrawable:atTime:` path, which lands on
  8.3 ms refresh steps at 120 Hz. This is a user report without a trace;
  no frame rates were measured. The current build has not been rerun on the
  60 Hz Studio Display without the capture layer.
- The user reports that, with Frame Generation, switching vsync Off -> Triple is
  fast, Double drops sharply, and Double -> Triple recovers only partly. The
  likely causes, not yet traced live: double buffering leaves the presenter
  two drawables for two presents per frame; and pacing by BG3's interval
  included time BG3 spent blocked on stand-ins, so a slowdown could keep the
  schedule slow. Frame Generation now holds the layer at
  `maximumDrawableCount = 3` and restores BG3's value when the entry is left;
  the fixture checks this. Pacing subtracts stand-in wait time from BG3's
  interval; no fixture covers that subtraction. The diagnostic runtime logs
  drawable-count and vsync changes. The user confirmed Double is much improved.
  Stand-ins in flight now follow BG3's buffering choice (two for Double, three
  otherwise) for lower latency, while the real layer stays at three. A setter
  hook records BG3's later changes instead of applying them, and the latest one
  is restored on leaving the entry. The fixture checks the two/three limits and
  the restore. Recommended setting: vsync on with Frame Generation.
- Vsync off, Upscaling Off, no FPS limiter (diagnostic trace, October 13,
  `build/fg-vsyncoff.jsonl`): BG3 rendered about 20 fps without Frame Generation
  and about 19 with it (frames every ~52 ms; interpolation 5-6 ms GPU; BG3 never
  waited on stand-ins). The HUD showed about 10 "rendered" fps, so its rendered
  figure is unreliable with the unsynced `-present` path. Motion was very choppy:
  real and generated images became ready together and replaced each other
  before scan-out (generated-to-real gaps as low as 2 ms; 20-28% of generated
  images dropped). A standalone window test (`build/experiments/mindur.mm`, 120 Hz,
  display sync off, two presents every 50 ms) showed 59 of 120 images displayed
  with `presentDrawable:` and 118 of 120, every gap exactly 25 ms, with
  `presentDrawable:afterMinimumDuration:0.025`. At 125 pairs/s with a 4 ms
  minimum, `afterMinimumDuration:` still showed exactly 120 images/s (8.3 ms
  apart) and fell behind (500 images over 4.2 s), so it rounds to whole
  refreshes; plain presents ran uncapped (132 images/s, tearing, some lost). The
  vsync-off path therefore uses `afterMinimumDuration:` with half BG3's smoothed
  frame interval while that spans at least one refresh of the window's display,
  and plain presents (uncapped, may tear) when BG3 renders faster. The user
  reported the minimum-duration version "much better" at about 20 rendered fps;
  a one-refresh floor capped every Upscaling Type at 120 displayed, so it was
  replaced by the switch. Live with that switch, the fast case was "very jittery
  and unpaced": both images were presented together. That case now presents
  the generated image, waits half an interval on the worker, then presents the
  real one. With display sync on and 30 pairs/s, standalone, plain presents
  alternated 8.3/25 ms gaps while `afterMinimumDuration:` with half the interval
  gave 16.7 ms every time, so the VSync-on path now uses `afterMinimumDuration:`
  instead of `presentDrawable:atTime:` with display-time anchors. BG3's VSync
  setting is untouched. Live (October 13, quiet runtime with
  `BG3MFX_FRAME_LOG=1`), the user tested VSync on, VSync off fast and slow, and
  Frame Generation off, and reported all "working very well". Not yet
  confirmed live; the fixture's layer is unattached, so it does not measure
  display timing.
- Input delay (October 13, live, VSync on, no limiter, frame log): BG3 rendered
  about 36 fps and real frames reached the display about 110 ms (p90) after
  commit. A standalone window test (`build/experiments/lag.mm`: a game thread
  with two stand-ins, a presenter thread, 120 Hz) reproduced it: with half the
  interval as the minimum, frames at 36-50 fps were dragged to about 31 fps with
  107-113 ms, because `afterMinimumDuration:` rounds up past the frame time.
  Splitting each frame's whole refreshes between the images kept the rate with
  30-45 ms (without Frame Generation: about 22 ms synced, 7 ms unsynced). With
  VSync on at 90 fps, the display limits pairs to 60/s and the queue held
  65 ms; one stand-in cut it to 48 ms at the same rate, while with VSync off at
  90 fps one stand-in cost frames, so it applies only with VSync on. Not yet
  confirmed live. The frame log had counted the presenter's own presents as BG3
  frames; they are now excluded.
- Buffering (October 13, live, frame log with BG3's buffering, about 32-42 fps):
  without Frame Generation, 25 ms from commit to display double-buffered and
  50 ms triple-buffered. With Frame Generation and BG3 triple-buffered, 107 ms
  (four frames in flight) with three stand-ins and 47 ms (one in flight) with
  one, at the same frame rate. BG3 now gets one stand-in on every paced path,
  so its double/triple setting no longer adds queued frames there; the fast
  vsync-off path keeps BG3's buffering. Live after the change, Triple and
  Double both ran at 45-47 ms with one frame in flight (smooth). VSync off was
  not: 66 ms (p90 92-99), 2-11% of generated images dropped, and the stand-in
  count flipping between 1 and 3. Pacing used BG3's work time (its interval
  minus stand-in waits); with one stand-in a GPU-bound BG3 at 32 fps spends much
  of each frame waiting for it, so its work time looked faster than half the
  refresh rate and the vsync-off method flipped every few frames. Pacing now
  follows BG3's actual frame interval, rounded down with a margin, and the
  vsync-off spaced method requires BG3 to be held at about half the refresh
  rate with a shorter work time. Not yet confirmed live.
- Generated images above half the refresh rate with VSync off (October 13):
  live, 25-46% were dropped at 70-85 fps. A window test driving the real
  presenter (`build/experiments/presenter_waste.mm`, GPU-bound game with three
  stand-ins) dropped 77-84% windowed and 44-76% full screen, with every real
  image shown. The presenter skipped its half-interval spacing whenever BG3 had
  committed another frame, finished or not. Deferring the real image instead
  kept generated images (0-2% dropped) but dropped 10-35% of real ones: two
  images per frame exceed the display's refreshes at these rates, so some are
  lost either way. Kept as is; skipping interpolation above half the refresh
  rate would save GPU time but turn about 118 shown images into 80-90 at the
  switch. An apparent 30 fps cap in a window came from low power mode, not the
  presenter: rerun without it, windowed ran at 68-110 fps.
- Windowed VSync off (October 19, live, 120 Hz): the Metal HUD showed the window
  alternating between Direct and Composited. Capped below about 55 fps it stayed
  Composited: the minimum-duration presents composite the window, while the
  spaced path's plain presents go direct, and the method switched near half the
  refresh rate. VSync off now always uses spaced presents; the user reported the
  window no longer alternates. Spaced presents with one stand-in held BG3 at
  about 40 rendered fps (diagnostic frame log: 6.4 ms of each 25 ms frame
  waiting for a stand-in, 68 overflows in 2 s), so VSync off keeps BG3's own
  buffering at every rate. The user then reported it "perfect" uncapped in the
  quiet runtime. Displayed pacing was not measured; the earlier diagnostic run
  at a 30 fps cap with one stand-in dropped 11-22% of generated images, and
  that cap has not been rechecked with BG3's buffering.
- `MTL_CAPTURE_ENABLED=1` slows the whole session (Temporal measured 23-34 fps
  instead of about 55), so do not combine capture-enabled launches with pacing
  or frame-rate comparisons. A GPU profile of plain Temporal at 3840x2160 output
  showed about 20.6 ms of continuous GPU work per frame. Live per-queue averages
  showed about 6.3 ms per frame-interpolation submission.
- After the hook-overhead fix, the quiet runtime on the 60 Hz Studio Display
  (HUD log, October 12) presented about 106 frames/s with Frame Generation and
  vsync off (about 53 real; torn on the panel). It presented 59-61 with vsync
  on, at the panel's 30 real + 30 generated ceiling. Plain Temporal ran at
  53-61. A diagnostic trace of the vsync-on case showed BG3 frames finishing
  every 33.6 ms and every displayed gap exactly 16.7 ms, with no drops. The
  earlier 14-20 fps vsync-off results came from hook overhead (quiet runtime
  before the fix, and the diagnostic runtime, which inspects every draw). They
  were not a presenter limit. The diagnostic runtime is not representative for
  frame rates.
- Frames without a pair are copied to a real drawable and presented at once.
  Turning Frame Generation off makes `nextDrawable` return real drawables again and releases
  the effect; stand-ins already handed out keep their presenter until shown.

The first design overwrote BG3's acquired drawable after GPU completion and
competed with BG3 for drawables. It allocated two 4K images, four interpolation
textures and a Metal 4 allocator, residency set and two events every frame, and
ran `CombineUI` three times. The second design removes all of that.

HDR output: a live diagnostic trace (October 13, 1728x1080, macOS HDR on) showed
BG3 composing with `CombineUI_HDR` into a BGR10A2Unorm drawable from the same
RGB10A2Unorm scene and RGBA8 UI, so Frame Generation formed no pairs (0 paired,
5400 unpaired). The runtime now accepts `CombineUI_HDR` with a BGR10A2Unorm
output, and `frame-generation-hook-smoke ... hdr` covers it synthetically; HDR
image quality and pacing still need live confirmation.

Composition replay: the generated frame repeats BG3's own `CombineUI` draw with
its recorded draw call, viewport and scissor, and starts from a copy of the real
frame when the viewport does not cover the output. Scene, UI and output sizes
may therefore differ (windowed, non-native resolution, other aspect ratios).
`frame-generation-hook-smoke ... scaled` covers a letterboxed 256x256 scene in
a 320x288 output with a triangle-strip draw (byte-identical generated pair;
fails with exit 9 if the viewport replay is removed). Not yet confirmed live at
a mismatched size. A composition the runtime cannot replay turns Frame
Generation off without closing the game; the hook test checks unpaired
presentation, real drawables afterward, and retry on reselection.

Split-screen, minimize/resize/quit transitions, a BG3 path
that calls `-[drawable present]` directly (handled without GPU ordering), and
displayed pacing need further verification. Do not report broad compatibility
from the synthetic tests.

## Evidence

- `frame_interpolation_smoke.mm` runs GPU-produced private scene/depth/motion
  through Metal 4 interpolation, checks finite static output with preserved
  history and rejects invalid inputs. Metal API validation passes on M5 Pro.
- `frame_generation_hook_smoke.mm` steps through menu choices 0, 1, 2, 3, 4, 4,
  4, 3, 4 and follows BG3's order: present before `CombineUI`. Choices 0–3 must
  receive real drawables, produce no pair and leave no worker; FSR still runs its
  two native dispatches. Choice 4 must receive a stand-in, and its generated
  composite must match BG3's real composite for the static scene (observed
  difference 0). The worker must submit the pair to real drawables. The third
  consecutive choice-4 frame must allocate no pooled textures. The layer is
  unattached: this proves the stand-in, hook and worker handoff, not display or
  pacing. Both runtimes pass, with and without Metal API validation, in ten
  repeated runs.
- `spatial_hook_smoke.mm` now also requires that Spatial frames after the first
  allocate no textures. Temporal, Spatial and Metal 4 bridge tests pass under
  Metal API validation with pooled resources.

### Live presentation audit

The first live run (`build/frame-generation-live-2.*`) confirmed the former
checkbox's insertion before ID 83 and Metal 4 interpolation at 2258×1270 depth/motion input and 3840×2160
scene/output, but zero presentation submissions. The user reported normal
response but slow performance: extra GPU work without displayed interpolation.

A bounded audit (`build/frame-generation-presentation-audit.jsonl`) spent its
budget at the main menu and was inconclusive. A second audit counted only after
the first encoded pair (`build/fg-audit-2.jsonl`, Temporal, Metal API
validation). Across 360 encoded pairs: 359 present calls, all
`presentDrawable:`, zero matched a pair, and 359 pairs were encoded on a buffer
that had already presented. All 64 logged presents were on buffers that later
encoded a pair, and every logged late pair targeted the exact drawable already
presented. This rules out a separate present path or command buffer: BG3
presents before `CombineUI`. The deferred-present change addresses this. It
was then tested live.

### Live display results (Temporal checkbox build)

`build/fg-live-4.jsonl`: all 742 encoded pairs reached the presentation worker.
`build/fg-live-5.jsonl` added presented handlers: 1,167 generated and 1,166 real
worker drawables were shown, 33/34 dropped (about 97% displayed). In steady play
the display received about 38 drawables/s against about 19 rendered frames/s;
displayed intervals were P10 14–17 ms, P50 19–24 ms, P90 22–30 ms. That pacing
is uneven. The user reports the Metal HUD's FPS roughly equal to its rendered FPS
and no visible smoothness change. The HUD and presented-handler evidence
disagree, and an on/off HUD comparison is still pending. `build/fg-live-6.jsonl`
shows encoding stopped whenever the checkbox was cleared or Spatial selected.
These runs were launched from the user's Terminal; a launch from a process
without Documents access starts BG3 with a blank profile.

Moving-scene image quality and pacing remain pending. Logs remain ignored in
`build/`.

### 2026-10-19 chain breaks found in a live diagnostic trace

A live diagnostic trace (`build/evidence/2026-10-19-diagnostic/`) had 5807
unpaired frames, from three breaks in the pass chain between TAA and `CombineUI`.
`PPColorGradingApplyLUTPS` with bloom off (4602 frames, including the 1728x1080
menu-background and loading frames and the MetalFX Spatial "Could not match FSR
input" fallback with bloom off) reads the untagged TAA input but writes the
tagged TAA output, and the write cleared the tag. `EoCSight` during the Shift
visibility overlay (533 frames) ping-pongs two textures 2-7 times and was not
forwarded. The `Shared_UI_VFX_UI_Model_*` VFX blends onto the CAS output that
`CombineUI` reads (masked by the ColorGrading break). The Bink title video
(672 frames, no TAA) stays unpaired by design. The fix forwards EoCSight and
keeps an existing tag in place for ColorGrading (RG11B10Float target) and the UI
model VFX. It is covered synthetically by `frame-generation-hook-smoke ...
overlays` (and a negative frame with an unrecognized draw on the scene image,
which must stay unpaired). Live with the quiet runtime (2026-10-19), Frame
Generation stayed on with bloom off and during the Shift overlay, and photo mode
camera modes paired; the UI model VFX case and moving-scene image quality were
not checked separately.
