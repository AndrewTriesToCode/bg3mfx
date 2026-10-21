# Rendering architecture

## User-visible settings

`NativeMenu.mm` adds a persistent Show Metal HUD checkbox at the top of General
and appends the “MetalFX Spatial” and “MetalFX Temporal” choices to BG3's existing
Upscaling Type combo. These implement **MetalFX Spatial Upscaling** and
**MetalFX Temporal Upscaling**. The native Off and AMD FSR 1.0 entries remain
owned by BG3. The native quality combo supplies Ultra Quality, Quality,
Balanced, and Performance.

BG3's settings code accepts only Off and FSR as upscaling types. Selecting a
MetalFX type temporarily invokes BG3's FSR setup callback to retain its quality
and render-resolution behavior, then restores the custom menu value and stores
the selected type separately. Startup and Options → Back use the same setup.
The quality state is independent of the custom type. This bridge is
build-specific and guarded by the executable's Mach-O UUID. BG3's FSR quality
setter resets Upscaling Sharpness to 0.8 whenever the quality changes, and
BG3's Upscaling Type callback redraws the slider from that setting. A moved
slider reaches the setting only on Apply, so the bridge saves the slider's
displayed value and restores both across type changes, Options → Back and
MetalFX quality changes. The slider controls FSR's RCAS pass,
which MetalFX replaces, so it is dimmed while MetalFX Spatial or Temporal is
selected.

Spatial keeps the native anti-aliasing option enabled unless Frame Generation is
on. While Temporal or Frame Generation is on, the menu selects the Anti-Aliasing
entry labelled "TAA" through its own callback, dims the control, and saves the
player's previous choice (`BG3MFXSavedAntiAliasing`) to restore when neither is
on. Temporal keeps BG3's TAA
input production but skips the TAA draw only on exact targets previously seen
feeding the upscaling stage. Inventory and other auxiliary views retain native
TAA. A newly discovered upscaled target keeps native AA for its discovery frame;
Temporal history is reset before and after that frame so its filtered input is
not accumulated with later raw jittered inputs. Weak target identities avoid
retaining obsolete textures or matching a recycled address. Its output is
written where the game's upscaling result is expected, and the separate AA
control is disabled while Temporal is selected.

## Renderer flow

`Trace.mm` contains the Metal interception layer used by both runtime builds. It
tracks each command buffer's selected mode and associates exact BG3 textures
through TAA, post-processing, and the native FSR stage. Unknown or mismatched
resources fail closed instead of guessing from dimensions. Native FSR and RCAS
dispatches are skipped only for an active MetalFX mode. Off and FSR retain
BG3's callbacks and native rendering.

`SpatialUpscaler.mm` copies BG3's linear HDR scene color from RG11B10Float into
RGBA16Float, runs MetalFX Spatial in HDR mode, and copies the result into BG3's
FSR output target. The input is after bloom and color grading but before
`FSR_Tonemap`; BG3's tone mapping and UI composition remain downstream.
Spatial needs only this color image, not TAA. With TAA on, the chain is seeded
at BG3's TAA output as described below. With SMAA or no anti-aliasing there is
no TAA pass, so an untagged `FSR_Tonemap` input (RG11B10Float, the same size as
its output) seeds the chain there. A live trace with SMAA (October 19) showed
SMAA, bloom and color grading writing that input; before this seeding, every
SMAA frame fell back to native FSR.

`Trace.mm` captures HDR scene color, device depth, motion, camera constants, and
BG3's original jitter at the TAA stage. It copies current color into the skipped
TAA output and tracks that color through native bloom, color grading, and outline
passes. `TemporalUpscaler.mm` receives the final tracked HDR color before
`FSR_Tonemap`, alongside the earlier scene inputs. MetalFX reads BG3's
RG11B10Float color, Depth32Float_Stencil8 depth and RG16Float motion in place
and writes straight into BG3's final upscaler target when that target has the
usage MetalFX requires (BG3's does); otherwise it writes a pooled output that is
copied into the target. The current motion scale is −1, −1 and depth is reversed, based
on inspected BG3 shader conventions. History is reset when the selected scaling
mode changes or input resources become invalid. `TemporalJitter.mm` substitutes
Halton (2,3) samples at three guarded native loads: projection, camera constants,
and velocity history. Only Temporal views with an enabled native FSR stage use
14/18/24/32 phases for Ultra Quality/Quality/Balanced/Performance. A frame-local
choice keeps all three consumers consistent during settings changes. BG3's
previous projection/jitter storage remains responsible for motion compensation;
the shared eight-sample table is unchanged for other views and modes.
`BG3MFXApplyTemporalJitter` converts BG3's sample displacement to MetalFX's
image displacement: X is negated and Y retains the native Y-up sign. The old
adapter supplied the opposite displacement in both framebuffer axes, preventing
correct temporal reconstruction. The analytic reconstruction test and captured
depth registration establish this conversion; see the
[quality diagnosis](validation/temporal-jitter-diagnosis.md).

Temporal uses `MTL4FXTemporalScaler` on devices reporting `supportsMetal4FX:`;
other devices retain `MTLFXTemporalScaler`. A dedicated Metal 4 queue waits on
an event signaled after BG3 produces the scaler inputs, then signals another
event that BG3's original Metal 3 buffer waits on before consuming the output.
Per-submission residency and feedback-owned resources preserve GPU lifetimes.
This does not convert BG3's renderer or presentation to Metal 4. See the
[Metal 4 audit](validation/metal4-temporal.md) for the API/model distinction and
validation limits.

`MetalFXPipeline.mm` owns only the MetalFX Spatial/Temporal scaler objects,
resource checks, output allocation, scaler encoding, and its cross-API GPU event bridge. It has no BG3 menu,
frame presentation, patching, or distribution responsibilities.

## Frame Generation

Frame Generation is the "MetalFX Frame Generation" checkbox (item `0x7f02`),
added right below VSync (after the upscaling controls if VSync is missing),
only on supported devices, and saved as `BG3MFXFrameGenerationEnabled`. It combines with every Upscaling Type, which
is back to BG3's Off and FSR plus MetalFX Spatial and Temporal (values 0–3).
Startup migrates earlier settings: Upscaling Type values 4 (Temporal + Frame
Generation) and 5 (Spatial + Frame Generation) become Temporal or Spatial with
the checkbox set, and the older Temporal-only checkbox carries over. Clearing
the checkbox releases the interpolator and presentation worker.

Frame Generation pairs frames using the depth, motion and camera constants
captured at BG3's TAA pass, validated as for Temporal, so the scene must be
followed from there to `CombineUI`. Temporal attaches them to its output.
Every other type keeps native TAA, whose output seeds the chain: MetalFX
Spatial attaches them to its output, BG3's FSR and RCAS dispatches forward them
from input to output, and with Off, BG3's CAS (FidelityFX sharpening) dispatch
after tone mapping forwards them from its input to its output. The
recognized color passes and tone mapping then carry them to `CombineUI`. Jitter
comes from BG3's constants, so the native eight-phase sequence is described as
is. Frames that reach `CombineUI` without these inputs (menus, loading screens,
native-FSR fallback frames) are presented unpaired, and pairing resumes with the
next frame that has them. With `BG3MFX_TRACE_TEMPORAL_CHAIN=1`, the diagnostic
runtime records the recent pass chain in each `frameGenerationNoScene` event.
A live trace (October 13) showed Off + Frame Generation losing the scene at
CAS, which reads the tone-mapped RGB10A2 scene and writes the one `CombineUI`
composes; with the CAS forward, Off + Frame Generation works live.
EoCSight (the stealth/visibility overlay, which ping-pongs a variable number of
times) forwards the inputs like the other color passes. Two passes draw onto an
image that already carries them, so they keep it in place instead of clearing it:
`PPColorGradingApplyLUTPS` with bloom off (it reads the untagged TAA input and
writes the tagged TAA output; with bloom on it reads the tagged output and
forwards normally) and the `Shared_UI_VFX_UI_Model_*` 3D UI effects alpha-blended
onto the final scene image. An unrecognized draw later in the same encoder still
clears the tag.

Presentation follows Apple's present-thread model. While Frame Generation is on, a
`CAMetalLayer nextDrawable` hook gives BG3 stand-in drawables backed by three
pooled textures; BG3 renders, composes UI, and "presents" into them unchanged,
and waits briefly for a preferred slot. On paced paths it prefers one stand-in
for lower latency, then borrows one bounded overflow slot if the previous slot
has not finished copying. BG3 presents before encoding `CombineUI`, so the
stand-in present is resolved at `commit`, which also signals a shared event.
The worker in `FrameInterpolation.*` acquires real
drawables itself and waits for that event on the GPU. It spaces the generated
and real images about half of BG3's smoothed frame interval apart:

| Case | Presentation |
| --- | --- |
| VSync on | `presentDrawable:afterMinimumDuration:`, the frame's whole refreshes (at least two) split between the images |
| VSync off, a frame spans at least two refreshes | The same |
| VSync off, faster | Generated image when its copy finishes, a half-interval wait on the worker, then the real image; uncapped and tearing |

`afterMinimumDuration:` rounds up to whole refreshes, so each minimum is set
just under its count of refreshes: half the interval rounded up past the frame
time and let the presenter fall behind. It would also cap the vsync-off fast
case. On the paced paths (the first two rows) BG3 prefers one stand-in, then can
borrow one overflow slot after a short grace wait; this lets a nearly-finished
copy release the low-latency slot while avoiding a long render-thread stall.
The fast vsync-off path keeps BG3's own buffering and allows at most one
additional stand-in up to a total of three. The frame log records BG3's
requested buffering, the stand-in limit, wait time, and overflow use. The
refresh interval is read on the main thread from the
layer's window. The stand-in is released when the real copy completes, before
any wait, and the worker skips the wait when BG3's next frame is already
queued. Frames without a generated image are presented at once. Only the generated scene goes through an extra
`CombineUI` pass. The worker never blocks BG3's or Metal's threads. Devices
without Metal 4 FX use the Metal 3 effect. This implementation still needs
displayed/pacing validation and does not establish HDR support. See the
[frame-generation record](validation/frame-generation.md).

## Hook overhead

Every intercepted Metal call runs on BG3's render thread, which issues about
12,000 draws per frame. A `sample` of the quiet runtime showed about half of
that thread inside the hooks, in Temporal and in Frame Generation alike, when
binds built strings and dictionaries and every call took a global lock to find
the original method. Hooks now keep one `BG3MFXEncoderState` per encoder with
fixed binding slots. Pipelines are classified once, at creation, and draws with
unrecognized pipelines go straight to Metal. Original-method lookups are cached
per thread. An unrecognized draw's only effect, dropping a scene association for
the encoder's target, is applied once at `endEncoding`. A synthetic run of
20,000 draws and 80,000 binds took 5.5 ms without hooks, 50.2 ms with the
original hooks, and 7.2 ms after the first rewrite. In the live game the hooks'
own share of the render thread fell from 52-54% to 14-22%. A second round caches
the current encoder's state per thread (refreshed at encoder creation, cleared at
`endEncoding`). It also holds bound buffers, textures and the pipeline without
retaining them, since the encoder of a retained-references command buffer keeps
them alive. That halved the remaining synthetic overhead (about 4.5 ms to
2.3 ms per 20,000 draws). Encoder classes already hooked skip re-hooking, which
otherwise took the global lock about 25 times per new encoder. A third round
makes the per-call hooks take `self` and object arguments as non-owning, so ARC
does not retain and release them around each call to the original method. It
also keeps `setBytes` data in a lazy side table, so each encoder's state owns
nothing in its binding table and is free to destroy. Synthetic overhead for 150
encoders and about 20,000 draws went from about 1.9 ms (round 2) to about
0.9 ms. Measured live on
the quiet runtime before round 3, with the game in the foreground (samples
taken while BG3 is in the background measure its background frame throttle,
`GameClock::CapFrame`, instead): about 16-17% of the render thread. Diagnostic builds still inspect every draw,
so use the quiet runtime (with `MTL_HUD_LOG_ENABLED=1` and `sample`) for
performance comparisons.

## GPU resource reuse

`GPUResources.*` provides pooled textures, returned on command-buffer
completion, and a reusable Metal 4 bridge with recycled allocators, command
buffers, events and a persistent residency set. Spatial, Temporal and frame
interpolation intermediates come from these pools, so steady-state frames
allocate no textures and create no Metal 4 submission objects.

Temporal scalers are cached per input/output size. Creating one takes tens of
milliseconds, and on macOS 27.0.1 MetalFX never deallocates a Temporal scaler
whose output is 1512 px tall or less, through either the Metal 3 or Metal 4 API.
Each keeps an `ANEServicesThread` and about 28 MB, or about 200 MB after
encoding. Taller outputs, Spatial scalers and the frame interpolator are freed.
Evicting such a scaler from the cache therefore reclaims nothing. A standalone
reproduction with the full measurements is kept outside this repository for an
Apple report. A live windowed-mode drag created one per frame
until BG3 hung inside scaler creation with about 1,000 `ANEServicesThread`s
(October 13). A size with no scaler now runs BG3's native FSR until it holds for
0.3 s; the session's first scaler is created at once. The cache keeps every
settled size whose scaler leaks: its former six-entry bound evicted by
`NSDictionary` key order, which could drop the scaler just added, so a steady
size recreated one every frame (about 1,000 in 35 s live, after nine window
sizes) and hung BG3 the same way. Once another size is rendered, cached scalers
with taller outputs, which MetalFX frees, are evicted. `temporal-hook-smoke`
resizes through nine sizes, returns to each, and checks that every size creates
exactly one scaler.

MetalFX scalers retain the textures last assigned to them, and a Metal 4
residency set retains every allocation added to it (both verified standalone).
A cached scaler for a size no longer rendered therefore kept that size's BG3
color, depth and motion targets alive after BG3 freed them. The pipeline now
clears the scaler's texture properties after encoding (the command buffer or
the Metal 4 bridge keeps them for the GPU), and the previous size's scaler drops
its residency set when the size changes. `temporal-hook-smoke` checks that no
earlier size's textures survive (24 of 32 did before).

BG3 also replaces render targets at the same size (live: save loads and
settings changes), which no size change releases. Each Metal 4 bridge records
the submission that last used each member of its residency set and rebuilds the
set without members idle for 16 submissions; pooled textures rotate well within
that. `metal4-bridge-smoke` replaces its inputs at the same size and checks that
the old ones are freed (the earlier set kept them until it reached 64
allocations). The diagnostic runtime logs each set change as `metal4Residency`.

The Metal 4 queue waits on an event that BG3's command buffer signals before
the FX work. If that buffer fails before signaling, the queue would wait
forever and stall every later submission, so each slot's event is a shared
event and BG3's buffer completion raises it when the buffer ended in error.
This path has no regression: a command buffer cannot be made to fail on
demand.

Spatial uses the same 0.3 s settle and keeps at most two sizes, the current one
and the one before it; MetalFX frees evicted Spatial scalers. Keeping every size
held each one's scaler and pooled textures for the session: `spatial-hook-smoke
resize` measured +170.8 MB of GPU allocations after 24 sizes at 200–384 px input,
and +6.3 MB with the bound.

MetalFX consumes BG3's textures directly wherever it accepts their format and
usage, avoiding per-frame conversion passes (about 0.7 ms each for Temporal and
Frame Generation at 4K, measured with GPU timestamps). Frame Generation reads
the RGB10A2 scene in place only on macOS 27, where `requiresPrevColorTexture = NO`
lets the interpolator keep its own history; macOS 26 still copies the scene so a
retained copy can serve as the previous color. Inputs that do not qualify are
converted into pooled copies. Live, the saving is within HUD noise (about 1 fps
at 4K); it is kept because it removes passes and memory, not for frame rate.

## Failure and diagnostics

No failure closes BG3: the player may have unsaved progress. Each turns off
what failed and shows one notice on the main run loop (`showNotice` in
`Trace.mm`); with `BG3MFX_TEST_ERRORS_STDERR=1` the message goes only to stderr.

- A MetalFX Spatial or Temporal initialization, resource, sequencing,
  encoding, or GPU-completion failure turns that upscaler off. BG3's TAA and
  FSR + RCAS, which the menu already configured underneath, render instead:
  the FSR dispatches are forwarded and the TAA draw is no longer replaced.
  Choosing another Upscaling Type clears the failure, so selecting the
  MetalFX type again retries.
- Frame Generation turns itself off with a notice naming the problem for
  frames it cannot reproduce (unexpected composition bindings or scene
  format, camera parameters) and for interpolator or presenter creation,
  encoding, allocation, and GPU failures. The selected Upscaling Type
  continues, and turning the checkbox off and on again retries.
- Native menu problems leave BG3's own options working and show one notice.
  If the native integration cannot be installed at startup, BG3 runs without
  MetalFX or the other optimizations.

`libBG3MetalFX.dylib` is the quiet development runtime. `libBG3MetalFXTrace.dylib`
adds JSONL traces, shader reflection, and opt-in captures. Diagnostics are not
part of the rendering feature contract and are compiled out of the quiet build.
Both builds retain the interception and lifetime work required to integrate with
BG3. `tools/launch/bg3mfx.py` supports only inspection and launch-time injection; it
does not alter the app bundle.

## Repository layout

- `src/features/<feature>/`: feature implementations and a README describing
  behavior, integration, measured results, and validation limits.
- `src/common/gpu/`: reusable MetalFX encoding and GPU resource ownership.
- `src/common/native/`: shared guarded code patching and the canonical supported-build manifest.
- `src/integration/menu/`: native settings and feature installation.
- `src/integration/renderer/`: shared Metal interception and scene tracking.
  Feature modules own prepass classification/draw decisions and bind filtering;
  this layer owns hook installation, shared encoder state, and original-method dispatch.
  HUD settings still use the shared menu/layer integration.
- `src/integration/diagnostics/`: runtime probes; standalone probes and analysis
  programs live under `tools/probes/` and `tools/analysis/`.
- `src/launcher/` and `packaging/homebrew/`: the player launcher and formula.
- `tests/`: feature, common, integration, and launcher checks. Python package
  markers keep recursive discovery working with `make test-python`.
- `tools/launch/`, `tools/reference/`, `tools/release/`, and `tools/build/`: development
  launch, licensed-reference downloads, release maintenance, and scoped cleanup.
- `build/bin/`: disposable compiled launchers, libraries, tests, and probes.
- `build/evidence/<date>-<experiment>/`: retained captures, traces, and pixel-test
  images. New diagnostic traces and temporal quality runs use dated folders.
- Other existing `build/` paths are retained historical artifacts and downloaded
  references, including `build/profiling/` (formerly `perf/data/`). Cleanup never
  removes these. Never place game assets in tracked folders.
- `docs/dev/performance.md`: renderer and CPU performance measurements.

Use source-root include paths (for example `common/gpu/GPUResources.h`) with
`-Isrc`. Both runtime variants share the Makefile's source and header lists;
`make install` still installs only the player launcher and quiet runtime.

## Supported native build

[`SupportedBuild.h`](../../src/common/native/SupportedBuild.h) is the single
source for the supported Steam version, universal-executable SHA-256, ARM64
runtime UUID, unslid native addresses, native object-layout offsets, and reserved
branch-island ranges. Addresses and offsets are grouped by feature. The player
launcher compiles its identity constants from this header; the source-tree
Python helper reads its version and hash from the same definitions.

The runtime still checks the ARM64 UUID before installing native hooks, and each
installer retains its instruction, resource-shape, branch-range, and zero-byte
checks. Centralizing values does not expand the supported build. Compile-time
checks reject overlapping, misaligned, empty, overflowing, or out-of-padding
island reservations; a synthetic guard test includes negative cases. Native
fixtures keep independent layouts/expected instructions to catch drift.

## Code map

- `src/integration/menu/NativeMenu.mm`: settings menu, custom mode persistence, HUD checkbox.
- `src/features/metalfx-temporal-upscaling/TemporalJitter.*`: guarded Temporal sample selection and ARM64 preservation.
- `src/common/native/CodePatch.*`: shared in-memory code patching (header-padding branch
  islands, branch range checks, all-or-nothing page protection).
- `src/features/depth-prepass/DepthPrepass.*` implements Depth Prepass Optimization (on by default;
  `BG3MFX_DEPTH_PREPASS_OPTIMIZATION=0` disables it): vertex-only opaque prepass draws are skipped and
  their G-buffer draws write depth. `Trace.mm` supplies the hook bridge;
  `BG3MFXClassifyPrepass` and `BG3MFXPrepassDraw` own the feature decisions.
- `src/features/render-thread-optimizations/BindFilter.h` filters redundant binds (on by default;
  `BG3MFX_RENDER_THREAD_OPTIMIZATIONS=0` disables it): fragment texture slots and pipelines
  already bound in the encoder are not forwarded to the driver. The diagnostic
  runtime counts BG3's redundant binds with `BG3MFX_TRACE_REDUNDANT=1`.
- `src/features/shadows/ShadowDuplicateFix.*`: removes BG3's duplicate cascaded-shadow stage
  (on by default; `BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS=0` disables it); see
  [`docs/dev/performance.md`](performance.md).
- `src/features/thread-idling/ThreadIdling.*`: CPU Thread Idling (on by default;
  `BG3MFX_CPU_THREAD_IDLING=0` disables it). BG3's idle workers, job scheduler,
  and frame limiter (`GameClock::CapFrame`, the server tick and client frame
  cap) sleep instead of spinning; batch completion waits keep BG3's yield.
- `src/features/uniform-slices/UniformSlices.*`: Uniform Allocation Slices
  (opt-in; `BG3MFX_REDUCE_LOCKING=1`). `BindMaterialParameters` and
  `SetupEngineParameters` take their uniform allocations from a per-thread
  slice reserved through BG3's own `MetalRenderer` lock; a hook on
  `BeginFrame`'s reset retires the slices.
- `src/features/dynamic-worker-prioritization/DynamicWorkers.*`: Dynamic Worker Prioritization (on by default;
  `BG3MFX_DYNAMIC_WORKER_PRIORITIZATION=0` disables it). Puts the `WT/High` workers and the
  job scheduler in Darwin background while frame-rate trials show it costs no
  frame rate. It changes no BG3 code: threads apply their placement when they
  next block in an interposed `semaphore_wait`/`semaphore_timedwait`, and the
  present hooks in `Trace.mm` count frames. Decisions are logged to subsystem
  `com.bg3mfx`, category `threads`.
- `src/features/cluster-buffer-guard/ClusterBufferGuard.*`: Character Creation Crash Fix (on by default;
  `BG3MFX_CLUSTER_BUFFER_GUARD=0` disables it). `Trace.mm` binds a zero-filled,
  untracked stand-in at compute buffer indices 1 and 6 and fragment index 1 on
  each new encoder, so a clustered-lighting pass that BG3 dispatches without
  `ClusterInfoBuffer` reads no lights instead of faulting the GPU. Diagnostic
  builds record `clusterBufferGuard` when one of those passes reads the stand-in.
- `src/features/lua-jump-fix/LuaJumpFix.*`: BG3's Lua error handling uses `_setjmp`/`_longjmp`,
  avoiding two system calls per protected call (on by default;
  `BG3MFX_LUA_SYSTEM_CALL_ELIMINATION=0` disables it).
- `src/integration/diagnostics/ServerPacingProbe.*`: opt-in measurement
  (`BG3MFX_TRACE_SERVER_PACING=1`, diagnostic runtime) of the server tick's work,
  CPU time and limiter, logged to category `pacing`.
- Header-padding islands: Temporal jitter `0x000`–`0x0c0`, Lua `0x700`, server
  pacing probe `0x800`, thread idling `0x9c0`, uniform slices `0xa00` (offsets from
  `0x100004000`). Each install checks its range is still zero.
- `src/integration/renderer/Trace.mm`: Metal hooks, exact texture association, pass replacement,
  diagnostic instrumentation.
- `src/features/metalfx-spatial-upscaling/SpatialUpscaler.*` and `src/features/metalfx-temporal-upscaling/TemporalUpscaler.*`: BG3-specific inputs,
  conversions, and destinations for each scaler.
- `src/common/gpu/MetalFXPipeline.*`: backend MetalFX scaler setup and encoding.
- `src/common/gpu/GPUResources.*`: texture pools and the reusable Metal 4 submission bridge.
- `src/features/metalfx-frame-generation/FrameInterpolation.*`: frame interpolation, stand-in drawables, and the
  presentation worker.
- `tests/features/`, `tests/common/`, and `tests/integration/`: synthetic Metal pixel and hook regressions.
- `tools/launch/bg3mfx.py`: guarded, bundle-preserving development launch.
- `docs/dev/validation/`: current status and dated evidence.
