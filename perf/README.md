# Core renderer performance analysis

Separate from the MetalFX work: this directory studies BG3's own renderer.
Raw samples, logs and GPU traces live in the ignored `perf/data/`.

## Method (October 13, 2026)

- BG3 4.1.1.7631656, pristine: no injected runtime (`DYLD_INSERT_LIBRARIES`
  unset), `-NoLauncher 1`, Metal HUD with `MTL_HUD_LOG_ENABLED=1`. M5 Pro,
  macOS 27.0.1. Ultra preset, VSync and frame cap off, still camera in one
  saved scene (a carriage with characters, foliage). Scene rendered at
  1280×800.
- Run A (no capture layer): frame rates from the HUD log
  (`tools/hudfps.sh`), a 10 s CPU `sample` summarized with
  `tools/sample_tree.py`, and a one-setting-at-a-time settings sweep.
- Run B (`MTL_CAPTURE_ENABLED=1`): one-frame `gpucapture` (Layer boundary) at
  Ultra and at Shadows Medium, replay-profiled with `gpudebug profile run`.
  `tools/pass_map.py` names each encoder by its shaders and attachments and
  checks which passes read a given texture; `tools/categorize.py` groups the
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
`0x105d1a830`). The main menu's view gets one. The diagnostic runtime's
`BG3MFX_TRACE_SHADOW_STACKS=1` probe records a stack per cascade pass and reads
the stage slot that `CascadedShadowBufferStage::Submit` saved from
`GameRenderView::FinishRecording`'s loop: in-game, ten passes per frame come
from two stage objects 11 slots apart in the same view
(`perf/tools/shadow_stacks.py`). Each stage records and encodes its own jobs,
so the duplicate also costs CPU time.

### Fix

`src/ShadowDuplicateFix.mm` (on by default; `BG3MFX_SINGLE_SHADOW_STAGE=0`
disables it) verifies
both add sequences and the type byte, then replaces the first add's call with
a NOP through `src/CodePatch.mm`. The remaining stage renders where the readers
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

## Tools

- `tools/hudfps.sh [seconds]`: mean/min fps from the Metal HUD log.
- `tools/sample_tree.py SAMPLE [--thread T] [--group REGEX] [--children REGEX]`.
- `tools/pass_map.py SESSION CB [--watch texN ...]`: per-encoder shaders,
  attachments, cost, and reads of watched textures.
- `tools/categorize.py TSV FRAME_MS`.
