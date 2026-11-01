# Depth Prepass Optimization

Technical name: `depth-prepass`.

With `BG3MFX_FEATURE_DEPTH_PREPASS=1` (the `bg3mfx` launcher sets it; requires
metal-hooks), skips opaque depth-prepass draws whose pipeline has no fragment
function, then lets those same G-buffer draws write depth using BG3's terrain
`GreaterEqual` behavior. Without the variable BG3's full prepass runs.

[`DepthPrepass.mm`](DepthPrepass.mm) owns material classification, pass-role
recognition, replacement depth-state creation, the per-draw decision and
diagnostic counters ([`DepthPrepass.h`](DepthPrepass.h)).
[`DepthPrepassFeature.mm`](DepthPrepassFeature.mm) registers the feature and
gives those rules to metal-hooks as its draw filter
([`MetalHooks.h`](../metal-hooks/MetalHooks.h)): metal-hooks tags pipelines
and passes through them, calls the draw decision only for tagged pipelines'
draws, and swaps and restores the depth-stencil state around a draw. The
diagnostic runtime reports `prepassTrim` with the counts at each trimmed
prepass. Pipeline and depth identities remain weak; unrecognized and
first-frame passes stay native.

Live on October 14, on an M5 Pro with the duplicate-shadow fix already active,
Ultra, Upscaling Off, and windowed, 230 prepass draws were skipped and 230
G-buffer draws changed per frame. HUD GPU time fell from 12.0 to 10.5 ms and
frame rate changed from 82.9 to 84.4 fps; the render thread became the limit.
The user saw no character or distant-geometry artifacts. This is the trim's
incremental result on that configuration, not a standalone total-project gain.
Pixel regressions check depth behavior and negative controls. See [current
validation](../../../docs/dev/validation/README.md) and
[performance analysis](../../../docs/dev/performance.md).
