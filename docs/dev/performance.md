# Core renderer performance analysis

These are dated measurements and renderer experiments, not current performance
benchmarks. Current implementation locations and active validation are in the
[architecture](architecture.md), [validation index](validation/README.md), and
feature READMEs under `src/features/`.

Separate from the MetalFX work: this directory studies BG3's own renderer.
Raw samples, logs and GPU traces live in the ignored `build/profiling/`.

## Method (October 13, 2026)

- BG3 4.1.1.7631656, pristine: no injected runtime (`DYLD_INSERT_LIBRARIES`
  unset), `-NoLauncher 1`, Metal HUD with `MTL_HUD_LOG_ENABLED=1`. M5 Pro,
  macOS 27.0.1. Ultra preset, VSync and frame cap off, still camera in one
  saved scene (a carriage with characters, foliage). Scene rendered at
  1280×800.
- Run A (no capture layer): frame rates from the HUD log
  (`tools/analysis/hudfps.sh`), a 10 s CPU `sample` summarized with
  `tools/analysis/sample_tree.py`, and a one-setting-at-a-time settings sweep.
- Run B (`MTL_CAPTURE_ENABLED=1`): one-frame `gpucapture` (Layer boundary) at
  Ultra and at Shadows Medium, replay-profiled with `gpudebug profile run`.
  `tools/analysis/pass_map.py` names each encoder by its shaders and attachments and
  checks which passes read a given texture; `tools/analysis/categorize.py` groups the
  costs.

Replay GPU time: 16.26 ms (Ultra), 14.41 ms (Shadows Medium). The HUD showed
about 16 ms GPU time at 62-67 fps, so the game is GPU-bound at this setting,
with the CPU render thread close behind.

## GPU frame (Ultra, 16.26 ms)

| Category | ms | % |
| --- | --- | --- |
| Cascade shadows, set 1 (never read; see below) | 3.17 | 19.5 |
| Cascade shadows, set 2 (used) | 3.08 | 18.9 |
| G-buffer (896 draws) | 2.49 | 15.3 |
| Depth prepass (`FadePattern`, 907 draws) | 2.32 | 14.3 |
| Clustered lighting | 0.97 | 6.0 |
| Velocity (276 draws) | 0.84 | 5.2 |
| Fog (volumetric + deferred) | 0.62 | 3.8 |
| Post (bloom, god rays, tone map, CAS, exposure) | 0.55 | 3.4 |
| SSAO | 0.49 | 3.0 |
| Shadow mask (`DirLight_Cascaded_PCSS_4x2048`) | 0.39 | 2.4 |
| Everything else | 1.33 | 8.2 |

Geometry passes dominate and are vertex-heavy: characters are submitted to
the depth prepass, G-buffer, velocity and two shadow sets, each with 3-15k
triangle meshes.

## Finding: cascade shadow maps are rendered twice per frame

The four 2048² cascades (one `Depth16Unorm` 2D array, `tex453`) plus a
second 2048² map (`tex431`) are rendered in encoders 8-13 of the main command
buffer, right after the G-buffer, and again in encoders 32-37, after SSAO.
Evidence that the first set is wasted:

- Each pass of both sets clears its target (`loadAction Clear`); the fifth
  pass of each set loads and adds.
- Per cascade, both sets bind byte-identical light view/projection constants
  (`buf[11]`, 224 bytes, compared for cascades 0 and 1), the same geometry
  buffers, and the same draw counts and materials.
- No pass between the sets reads either texture: every draw of the decal
  (241), helper (39) and velocity (276) passes, and all full-screen and
  compute passes, were checked. All readers (PCSS mask, clustered lighting,
  volumetric fog, SSSS, water, VFX) come after set 2.
- The Shadows Medium capture has the same duplicate at 1024².

Removing set 1 would save about 3.2 ms of GPU time at Ultra (1.85 ms at
Medium) with no visual change, more than switching Ultra to Medium shadows
(2.36 ms, measured +9.4 fps).

### Cause

`BaseApp::InitFrameStages(rf::RenderView*)` adds the stage-type list `[2]`
(`CascadedShadowBufferStage`) twice for the game view, before and after the
`[70, 54, 68, 24, 23, 64, 55, 56]` list (calls at `0x105d1a7ec` and
`0x105d1a830`). The main menu's view gets one. Ten in-game cascade passes per frame came from
two stage objects 11 slots apart in the same view. Each stage records and
encodes its own jobs, so the duplicate also costs CPU time.

### Fix

`src/features/shadows/ShadowDuplicateFix.mm` (on by default; `BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS=0`
disables it) verifies
both add sequences and the type byte, then replaces the first add's call with
a NOP through `src/common/native/CodePatch.mm`. The remaining stage renders where the readers
already read from. Results, October 13 (quiet runtime, Ultra, Upscaling Off,
Frame Generation off, windowed, same save and camera):

| | fps (HUD log) | GPU time (HUD) | Shadow passes per in-game frame |
| --- | --- | --- | --- |
| Fix off | 73.9 | 14.0 ms | 10 (2 stages) |
| Fix on | 86.0 | 11.75 ms | 5 (1 stage) |

The user saw no difference in shadows. No GPU capture was taken with the fix
on. A brief full-screen flash when switching borderless ↔ windowed happens
with the fix off too; it was softer in Dark Mode, which suggests the window
background showing during the resize.

## Shader costs (Ultra capture, before the shadow fix)

From `gpudebug`'s per-shader ranking (`/performance/shaders`; vertex 28%,
fragment 57%, compute 14% of the frame):

- **Skinning is already done once per frame in compute.** `SkinningCompute`
  (175 dispatches, 0.14 ms) runs in the first compute encoder with the blend
  shapes; the character materials' vertex shaders read its output. The TBDR
  notes' "re-skinned in every pass" was an inference and is wrong, so
  pre-skinning is not an opportunity. Character vertex work across all passes
  is 1.24 ms (shadows 0.61, velocity 0.24, prepass 0.21, G-buffer 0.19), about
  0.93 ms after the shadow fix; hair is the heaviest character material.
- **HLOD (distant merged meshes) vertex work** is about 1.9 ms across prepass,
  G-buffer and shadows: most of the prepass-trim estimate in the TBDR notes.
- **Alpha-tested foliage in the shadow maps is the single most expensive
  shader**: `Shared_Atmosphere_ATM_Wind_Vertex_RGB_AlphaTest_2S_Translucency_..._DEPS`
  fragment, 2.80 ms (17%) over both duplicate sets.

Shadow cost per cascade in the set that remains after the fix (ms,
`tools/analysis/encoder_draw_costs.py 9 16.2617 re28=c0 re29=c1 re30=c2 re31=c3 re32=c0load`;
profile costs overlap, so treat as approximate):

| | c0 | c1 | c2 | c3 | 5th pass (loads c0) | Total |
| --- | --- | --- | --- | --- | --- | --- |
| Foliage, alpha-tested | 0.02 | 0.52 | 0.60 | 0.18 | 0.24 | 1.56 |
| Tileset cutouts | — | 0.06 | 0.15 | 0.12 | 0.10 | 0.43 |
| Other alpha-test | 0.08 | 0.08 | 0.09 | 0.05 | 0.04 | 0.34 |
| Hair | 0.08 | 0.06 | 0.06 | 0.06 | — | 0.26 |
| HLOD | — | — | — | 0.16 | 0.03 | 0.19 |
| Everything else | 0.01 | 0.04 | 0.11 | 0.07 | 0.07 | 0.29 |
| All | 0.19 | 0.77 | 1.00 | 0.64 | 0.48 | 3.07 |

Foliage is half the shadow cost and sits in the middle cascades, not the far
one; the near cascade has almost none at this overhead camera. Skipping
foliage only in c3 would save about 0.18 ms; c2 and c3 together about 0.8 ms,
at the price of mid-distance grass shadows. That would be a quality option,
not a free fix. Why a fifth pass adds 371 draws into slice 0 is not yet known.
The split depends on scene and camera.

## Settings sweep (HUD fps, 8 s each, baseline Ultra 67.4)

| Change | fps | Δ |
| --- | --- | --- |
| Shadows Medium | 76.8 | +9.4 |
| Shadows Low | 77.1 | +9.7 |
| Ambient Occlusion Off | 69.9 | +2.5 |
| Dynamic Crowds Off | 69.8 | +2.4 |
| Bloom Off | 68.4 | +1.0 |
| Animation LOD Low | 68.3 | +0.9 |
| Instance + Detail Distance Low | 68.2 | +0.8 |
| Subsurface Scattering Off | 67.6 | +0.2 |
| Fog Low | 65.6 | −1.8 |
| Depth of Field Off | 65.1 | −2.3 |

Noise is about ±2 fps. The Mac build has no God Rays option.

## CPU (10 s sample during Ultra; the sampler lowers fps to ~41)

- BG3's main thread is the render thread (`ls::RenderThread::Update`). It
  is never waiting on the GPU or a drawable: about 55% encodes Metal
  (`rf::RendererCommandBuffer::Submit`, cascaded shadows, deferred, post) and
  about 42% spin-waits (`cthread_yield`) on worker batches for FX
  update/prepare and shadow culling.
- Worker job time: animation blueprints (Genome scripts) ≈ shadow-draw
  recording > FX update > G-buffer, depth-prepass and shadow culling >
  occlusion culling. Shadow and depth jobs contend on an `os_unfair_lock` in
  `AppliedMaterial::BindMaterialParameters` and
  `RenderableObject::SetupEngineParameters`.
- `ServerWorker` is the local game server running NPC behavior trees in Lua
  (`ls::anubis`), busy but off the render path.

Once the GPU is relieved, the render thread is the next limit.

## CPU power and heat (October 14, 2026)

Lower City, Ultra, Upscaling Off, Frame Cap off, 95–96 fps throughout; M5
Pro (6 Super + 12 Performance cores). CPU power and per-tier time are BG3's
own, from `proc_pid_rusage` (`tools/analysis/procpower.c`); per-thread CPU is from
`proc_pidinfo` (`tools/analysis/threadcpu.c`).

| Build | CPU power | CPU | On Super cores |
|---|---:|---:|---:|
| BG3 as shipped (with the renderer fixes above) | 23.7 W | 715% | 67% |
| CPU Thread Idling | ~11 W | ~350% | 85% |
| + Dynamic Worker Prioritization | 7.4 W | ~420% | 42% |

`sample` misleads here: it records a thread's stack while the thread waits for
a core and counts `swtch_pri` yields as waiting. It showed the scheduler thread
4% busy (it used 88% of a core) and `ServerWorker` 99% busy in its systems.

### Stock thread states (October 20, 2026)

BG3 as shipped (no bg3mfx), Lower City at Balduran's statue, standing still,
Ultra, Upscaling Off, Frame Cap 60 fps; M5 Pro. A 10 s Instruments System Trace, analyzed with
`tools/analysis/thread_states.py`. Running, runnable, asleep and core tier are
exact scheduler intervals. Running time is split into work, spin and lock by
1 ms on-CPU stack samples: spin is time in a wait loop (`CapFrame`,
`WaitForCompletion`, worker and scheduler `DoWork`, `WaitForEventAndDoWork`)
doing nothing but yield, clock, queue-poll and event calls. Jobs a waiter runs
count as work. Lock is time on a core inside a contended `os_unfair_lock`.
Work, spin, lock, runnable and asleep are shares of each thread's time; Super
and Performance are shares of its on-core time.

| Thread | n | Cores | Work | Spin | Lock | Runnable | Asleep | Super | Perf |
|---|--:|--:|--:|--:|--:|--:|--:|--:|--:|
| `ServerWorker` | 1 | 0.99 | 40% | 53% | 6% | 0.8% | 0.2% | 94% | 6% |
| `WorkerThreadScheduler` | 1 | 0.98 | 0.2% | 98% | 0% | 1.8% | 0% | 90% | 10% |
| `GameThread` | 1 | 0.94 | 27% | 58% | 10% | 0.8% | 5% | 94% | 6% |
| Main (render) | 1 | 0.35 | 23% | 12% | 0% | 2.7% | 62% | 86% | 14% |
| `WT/High` | 6 | 1.15 | 9% | 2% | 8% | 0.2% | 81% | 53% | 47% |
| Other BG3 threads | 12 | 0.26 | 2% | 0% | 0% | 0% | 98% | 99% | 1% |
| `WT/Low` | 6 | 0.02 | 0.3% | 0% | 0% | 0.1% | 99.6% | 43% | 57% |

BG3 used 4.7 cores, about 2.3 of them spinning: the scheduler's yield window
0.96, `CapFrame` on `GameThread` (the frame cap) 0.58 and on `ServerWorker`
(the 30 Hz tick) 0.53, batch waits on the render thread 0.12, and the workers'
idle poll 0.14. The three spinning threads ran on the Super cores about 90% of
their time, holding half of them, while `WT/High` job work ran 47% on the
Performance cores. The render thread's batch waits are the smallest part.
Lock time is the material lock in
`AppliedMaterial::BindMaterialParameters` and
`RenderableObject::SetupEngineParameters` during shadow and depth recording.

In an uncapped run the same day (discarded: the render thread stalled for
about 3 of its 10 s), `GameThread` spun 2% and slept about half its time in
`WaitForEventAndDoWork`; with the cap that time moves into `CapFrame`. In the
capped run the render thread's activity also dropped in one second (62 wakeups
against about 200), a brief hitch.

The same scene and settings with only three thread-idling parts: scheduler
window 0, worker poll 0, and `CapFrame` sleeping straight to 200 us before its
deadline without checking for jobs (`BG3MFX_CAPFRAME_MARGIN_US=200
BG3MFX_CAPFRAME_POLL_US=0` in the current build). The batch-wait patch (since
removed) and every other feature were off, so bg3mfx's Metal hooks were loaded but only forwarded.

| Thread | Cores | Work | Spin | Lock | Runnable | Asleep | Super | Perf |
|---|--:|--:|--:|--:|--:|--:|--:|--:|
| `WorkerThreadScheduler` | 0.05 | 0% | 5% | 0% | 2.8% | 92% | 96% | 4% |
| `ServerWorker` | 0.30 | 29% | 0.3% | 0.4% | 0.6% | 70% | 85% | 15% |
| `GameThread` | 0.34 | 26% | 1% | 7% | 0.7% | 65% | 99% | 1% |
| Main (render) | 0.41 | 30% | 10% | 0% | 3.0% | 56% | 86% | 14% |
| `WT/High` | 1.41 | 13% | 1% | 10% | 1.4% | 75% | 68% | 32% |
| Other BG3 threads | 0.25 | 2% | 0% | 0% | 0.3% | 98% | 98% | 2% |
| `WT/Low` | 0.06 | 1% | 0% | 0% | 0.2% | 99% | 62% | 38% |

BG3 used 2.82 cores against 4.69, and spin fell from about 2.3 cores to about
0.12. `CapFrame` held 0.2% of `GameThread` and 2% of `ServerWorker` (60% and
67% stock); `ServerWorker` still ran a few shadow jobs on its first queue check.
The jobs it no longer steals moved to `WT/High` (+0.26 cores), which with the
spinning threads gone ran 68% on the Super cores (53% stock). Every second was
alike (render thread 400–414 ms on a core). The render thread used more than
stock (0.41 against 0.35 cores, about 600 wakeups/s against 210); the cause is
not yet separated between bg3mfx's forwarding Metal hooks and batch waits that
now end on a worker wake. Frame rate was not recorded.

### Poll sweep, CPU-bound (October 20, 2026)

To choose the worker and scheduler polls, BG3 ran uncapped where it is
CPU-bound: the same spot, Low, Upscaling Off, VSync, Frame Cap and Frame
Generation off, launched at nice 0. bg3mfx runs used only thread idling, with
`CapFrame` at its default 250 µs steps and 200 µs margin. Each row is the mean
of two 60 s windows: `procpower` CPU and power, and fps from the Metal HUD log
(`tools/analysis/hudfps.sh`).

| Run | Worker poll | Scheduler poll | fps | CPU | Super | Perf | Power |
|---|--:|--:|--:|--:|--:|--:|--:|
| Stock (BG3's own) | 500 µs | 101 µs | 186.0 | 727% | 538% | 189% | 18.6 W |
| BG3's polls + `CapFrame` sleep | 500 µs | 101 µs | 179.9 | 939% | 565% | 374% | 25.0 W |
| **Default** | 0 | 0 | 185.4 | **596%** | 452% | 144% | 16.7 W |
| Short worker poll | 50 µs | 0 | 187.2 | 643% | 491% | 152% | 18.1 W |
| BG3's scheduler window | 0 | 101 µs | 187.1 | 662% | 486% | 176% | 18.5 W |
| Short scheduler window | 0 | 25 µs | 184.6 | 636% | 473% | 163% | 21.0 W |
| Default, second launch | 0 | 0 | 188.6 | 585% | 445% | 140% | 17.9 W |

The two scheduler-window rows are one window each: their second windows were
disturbed (165.6 fps at 11.6 W, and a stall to 30 fps). The second default
launch took one window. Within a run the first window read about 189 fps
and the second about 183, so fps differences under about 2% are noise; power
varied by up to 4.6 W between windows.

- Sleeping at once costs no measurable fps even CPU-bound, and saves 18% CPU
  against stock.
- The `CapFrame` sleep alone, with BG3's polls, costs CPU: the jobs
  `ServerWorker` no longer steals go to workers that spin 500 µs and spill onto
  the Performance cores.
- Any scheduler window keeps the scheduler awake; at 0 it sleeps most of the
  time. Each idle worker signals its semaphore, and with a window the pending
  signals arrive before it blocks. 15 s traces after the 60 s windows:

  | Scheduler window | Scheduler cores | Spin | Asleep | Render thread waiting on jobs |
  |---|--:|--:|--:|--:|
  | 101 µs | 0.91 | 91% | 0.1% | 23% |
  | 25 µs | 0.84 | 84% | 0% | – |
  | 0 (default) | 0.15 | 15% | 79% | 20% |

  The 25 µs trace caught a lighter moment (the render thread 57% asleep, 4.0
  cores in all), but the scheduler still never slept. The 101 µs and default
  traces were CPU-bound (the render thread on a core 92–98% of the time).
- Not measured: burst-heavy scenes (combat, crowds), frame-time percentiles,
  and Macs with fewer workers.

### Uniform allocator lock (October 20, 2026)

The lock time in the thread-state tables is one lock. `AppliedMaterial::BindMaterialParameters`
(lock call at 0x105d07dcc) and `RenderableObject::SetupEngineParameters`
(0x1060e0180) both run BG3's per-frame uniform allocator inline: lock
`MetalRenderer` +0x8 (`os_unfair_lock`), round the offset at +0x2090 up to 16,
add the size, unlock. `MetalRenderer::AllocUniformsBuffer` (0x10645ed44) is the
same code and ignores its alignment argument; `MetalRenderer::BeginFrame`
zeroes the offset (0x10645da54), and nothing checks it against the buffer's
size. The sequence is inlined in about 70 functions (about 130 sites: post
process, shadows, fog, terrain, Noesis UI). The critical section is five
instructions; the cost is the contended handoff (`__ulock_wait`/`__ulock_wake`
and context switches). In the thread-state traces it is about 0.65 cores at a
60 fps cap and 0.9 cores uncapped, about a quarter of BG3's CPU once thread
idling removes the spins.

Making only the hot sites lock-free would race with the locked sites. The
candidate fix keeps BG3's protocol: the hot sites take a per-thread slice
(16 KB) through the same lock and bump within it without the lock, starting a
new slice after `BeginFrame`.

Synthetic model (`tools/probes/uniform_lock_sim.cpp`; not BG3): worker threads
record draws of 0.25–1.75× a mean cost, each allocating 64–512 bytes; 10% of
allocations stay on the locked path in slice mode. Means of 2–3 runs (repeats
within about 1%):

| Threads, mean cost | Mode | Frame (parallel part) | Worker CPU | Contended locks |
|---|---|--:|--:|--:|
| 6, 500 ns, uncapped | locked | 0.77 ms | 521% | 18% |
| | slices | 0.62 ms | 512% | 0.2% |
| | no allocator | 0.62 ms | 523% | – |
| 12, 500 ns, uncapped | locked | 1.01 ms | 1048% | 32% |
| | slices | 0.43 ms | 930% | 1.9% |
| | no allocator | 0.41 ms | 949% | – |
| 6, 500 ns, 20k draws, 60 fps cap | locked | 3.95 ms | 118% | 27% |
| | slices | 2.59 ms | 77% | 0.4% |
| | no allocator | 2.52 ms | 74% | – |

Slices came within 2–5% of no allocator. Every run checked each allocation for
alignment and overlap with locked and slice allocations mixed: no errors. 16 KB
slices used 130–210 KB more per frame than the 5.7 MB of data (4 KB slices
wasted more in partly used tails). With uniform draw costs the threads stagger
and contention stays under 1%, so the model's gain depends on how bursty BG3's
recording is.

In the executable, each frame's uniform buffer is 21 MiB (`0x1500000`, four in
a ring). `MetalRenderer::CommitCommandBuffer` copies new uniform bytes to a
private GPU buffer only without unified memory; on Apple Silicon BG3 binds the
shared buffer directly, so `BeginFrame` is the only point slices must reset.
The opt-in feature `src/features/uniform-slices` (`BG3MFX_REDUCE_LOCKING=1`)
patches the two sites and that reset.

Live A/B (Lower City, Ultra, Upscaling Off, Frame Cap 60, all runs at 60 fps;
two 10–30 s `procpower` windows each, within 3 points of each other):

| Dynamic Worker Prioritization | Slices | CPU | Super | CPU power |
|---|---|--:|--:|--:|
| on | off | 257% | 130% | 5.6 W |
| on | on | 238% | 115% | 4.9 W |
| off | off | 205% | 175% | 6.6 W |
| off | on | 162% | 143% | 5.8 W |

10 s System Traces of the last two (`thread_states.py` now lists lock samples
by caller): 4,448 lock samples against 90; `BindMaterialParameters` held 50%
and `SetupEngineParameters` 41% of them, and the rest is spread thinly
(`IAppStage::BindViewport`, `BindAtmosphere`, `DecalObject::PrepareDraw`,
post-process steps). `WT/High` fell from 1.02 to 0.61 cores and the render
thread's spin waiting on jobs from 9.6% to 2.7%. Dynamic Worker Prioritization
hides much of the CPU difference: background workers on the Performance cores
take more CPU time (+76 points with slices) for about 0.9 W less. In play with
the diagnostic runtime there were no rendering errors in about 33,000 slices,
and the largest frame used 0.47 MB of the 21 MiB buffer (the diagnostic
runtime's own logging held that session to about 27 fps). Not yet measured:
uncapped (CPU-bound) frame rate.

### CPU Thread Idling (`src/features/thread-idling/ThreadIdling.mm`)

BG3 spins wherever it waits:

- `WorkerThreadWorker::DoWork` polls the job queues for 500 µs (its budget,
  set in `Init` when there are more than 3 cores) before sleeping.
- `WorkerThreadScheduler::DoWork` yield-spins for 101 µs after every wake;
  workers signal it each time they go idle, so it ran 88% of a Super core.
- `GameClock::CapFrame`, the server's 30 Hz tick limiter and the client frame
  cap, never sleeps: with more than 1 ms left it runs queued worker jobs or
  yields, then spins the last 1 ms. The server pacing probe
  (`BG3MFX_TRACE_SERVER_PACING=1`) showed each tick does about 9 ms of work and
  spends about 24 ms in `CapFrame`; ticks were exactly 30 per second.
- `WorkerThreadBatch::WaitForCompletion` yields until another thread finishes
  the batch (the render thread's `cthread_yield` time above).

The patch removes the worker and scheduler windows and makes `CapFrame` sleep
250 µs at a time when no job is queued (it still runs queued jobs, which
matters on Macs with few workers), then sleep until 200 µs before its deadline.
Batch waits keep BG3's yield. An earlier version blocked batch waiters after
50 µs on the batch's completion event, about −1 W; that event holds one
semaphore that each blocking waiter resets, so two blocking waiters could
strand one or leak the semaphore, and it was removed. Live A/B steps (same fps
each): worker and scheduler spins 23.7 → 14.0 W; `CapFrame` 14.0 → ~11.9 W
(250 µs steps with BG3's 1 ms spin tail). Server ticks stayed at 30.0/s with a 33.4 ms worst interval; the in-game
Frame Cap now idles between frames.

### Dynamic Worker Prioritization (`src/features/dynamic-worker-prioritization/DynamicWorkers.mm`)

BG3 sets thread priorities by hand (QoS changes fail with `EPERM`), so
everything runs on the Super cores. Darwin background
(`setpriority(PRIO_DARWIN_THREAD)`, applied by each thread for itself when it
next blocks) moves a thread to the Performance tier at lower clocks: a test
loop ran 2.9× slower at 1/22 the power.

| Thread group | In background | Kept |
|---|---|---|
| `WT/High` + scheduler | 11.0 → 7.9 W at the same fps when GPU-bound; −6 to −25% fps in CPU-bound scenes | dynamic |
| `WT/Low` | no measurable saving; dialogue lines started late (Darwin background also throttles disk reads) | normal |
| `ServerWorker` | its sleeping limiter woke late: 27.5–28 ticks/s | normal |
| main, `GameThread`, audio | frame and audio critical paths | normal |

The frame threads wait on `WT/High` 12–14% of the time even at normal
priority, so their waiting is no signal. Instead a trial alternates
normal/background in 1 s windows and keeps background while it reaches 95% of
normal's frame rate (trial noise is about 2%); a 1 s frame rate below 85% of
the trial's returns to normal at once. Trials repeat every 30 s, backing off to
60 s while normal wins, and pause while BG3 is not the active app. With a frame
cap or vsync both sides reach the cap, so background wins.

### Lua error handling (`src/features/lua-jump-fix/LuaJumpFix.mm`)

BG3's Lua 5.4 was built without `LUA_USE_POSIX`, so each protected call uses
`setjmp`, which saves the signal mask and alternate stack with two system calls.
Redirecting `luaD_rawrunprotected` and `luaD_throw` to `_setjmp`/`_longjmp`
removed `sigprocmask`/`__sigaltstack` from the server thread (3.5% of its
samples) and cut its protected Lua call time by 14%.

### Ruled out

- Culling: timed at its seven `Scene::Cull` sites and the render thread's
  waits; it finishes on the workers before the render thread needs it.
- Server tick cap or sleep: the tick is already capped at 30 Hz; it only
  looked saturated because of `CapFrame`'s spin.
- Lua and AI speed-ups: the AI's Lua is about 2 ms of the 9 ms tick, off the
  frame path; Lua GC tuning trades memory for CPU.
- Pre-skinning (BG3 skins once in compute), memoryless or TBDR attachment
  changes, foliage shadow cuts beyond resolution, the room-trigger mask and
  velocity passes.

## Tools

- `tools/analysis/hudfps.sh [seconds]`: mean/min fps from the Metal HUD log.
- `tools/analysis/sample_tree.py SAMPLE [--thread T] [--group REGEX] [--children REGEX]`.
- `tools/analysis/pass_map.py SESSION CB [--watch texN ...]`: per-encoder shaders,
  attachments, cost, and reads of watched textures.
- `tools/analysis/categorize.py TSV FRAME_MS`.
- `tools/analysis/encoder_draw_costs.py SESSION FRAME_MS ENC[=LABEL] ...`: per-encoder
  draw cost grouped by material (foliage, hair, characters, tilesets, HLOD).
- `tools/analysis/foliage_shadows.py SESSION FRAME_MS CB TREE_ENC=PROFILE_ENC ...`:
  foliage order and costliest foliage draws in the cascade shadow passes.
- `tools/analysis/procpower.c PID [seconds] [samples]`: a process's CPU use, power and
  Super-core share (`xcrun clang -O2 tools/analysis/procpower.c -o procpower`; no root).
- `tools/analysis/threadcpu.c PID [seconds]`: CPU use per named thread, as consumed
  rather than sampled.
- `tools/analysis/thread_states.py record PID SECONDS OUT.trace` and
  `analyze OUT.trace [--json FILE]`: per thread, work, spin, lock, runnable and
  asleep time and Super/Performance core time, from an Instruments System Trace.
- `tools/probes/uniform_lock_sim.cpp` (`make build/bin/uniform-lock-sim`):
  `uniform-lock-sim locked|chunked|none THREADS DRAWS WORK_NS [FRAMES]
  [COLD_PERCENT] [CHUNK_BYTES] [FPS_CAP]`, the synthetic uniform allocator model.
- Dynamic worker decisions: `log stream --predicate 'subsystem == "com.bg3mfx"
  AND category == "threads"'`.
