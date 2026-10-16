# Depth Prepass Optimization

Technical name: `depth-prepass-optimization`.

By default, skips opaque depth-prepass draws whose pipeline has no fragment
function, then lets those same G-buffer draws write depth using BG3's terrain
`GreaterEqual` behavior. It remains active in the runtime unless disabled with
`BG3MFX_DEPTH_PREPASS_OPTIMIZATION=0`.

[`DepthPrepass.mm`](DepthPrepass.mm) owns material classification, pass-role
recognition, replacement depth-state creation, and diagnostic counters.
[`DepthPrepass.h`](DepthPrepass.h) supplies the per-encoder state and inline draw
scope that skips or replaces depth state and restores it after the draw.
[`Trace.mm`](../../integration/renderer/Trace.mm) installs Metal hooks and passes
native resources and original-method callbacks into the module. Pipeline and
depth identities remain weak; unrecognized and first-frame passes stay native.

Live on October 14, on an M5 Pro with the duplicate-shadow fix already active,
Ultra, Upscaling Off, and windowed, 230 prepass draws were skipped and 230
G-buffer draws changed per frame. HUD GPU time fell from 12.0 to 10.5 ms and
frame rate changed from 82.9 to 84.4 fps; the render thread became the limit.
The user saw no character or distant-geometry artifacts. This is the trim's
incremental result on that configuration, not a standalone total-project gain.
Pixel regressions check depth behavior and negative controls. See [current
validation](../../../docs/dev/validation/README.md) and
[performance analysis](../../../docs/dev/performance.md).
