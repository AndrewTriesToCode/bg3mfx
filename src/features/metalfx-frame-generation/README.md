# MetalFX Frame Generation

Technical name: `metalfx-frame-generation`.

Adds the supported-device-only “MetalFX Frame Generation” checkbox after the
upscaling controls. It is off by default and combines with Off, FSR, Spatial,
or Temporal. The interpolator uses scene color, depth, motion, and camera data
to generate an image between rendered frames; BG3 continues to compose the UI
on the real frame. BG3's drawable path is paired with a worker that presents
generated and rendered images.

Interpolation and presentation live in
[`FrameInterpolation.mm`](../../../src/features/metalfx-frame-generation/FrameInterpolation.mm)
and [`FrameLog.mm`](../../../src/features/metalfx-frame-generation/FrameLog.mm), with
scene tracking and menu integration in
[`Trace.mm`](../../../src/integration/renderer/Trace.mm) and
[`NativeMenu.mm`](../../../src/integration/menu/NativeMenu.mm). Shared MetalFX
resources are in [`GPUResources.mm`](../../../src/common/gpu/GPUResources.mm).

At 3840×2160 on the 120 Hz MacBook display, quiet-runtime HUD logs recorded
Temporal alone at about 58–59 fps with VSync off, and Temporal + Frame
Generation at about 85 displayed fps (about 42–43 rendered fps) with VSync
Triple. Since VSync differs, this is not a matched FPS comparison; it shows
displayed throughput for that run, not a higher game render rate or a measured
latency improvement. Later pacing is user-reported as
working well on the 120 Hz MacBook display, but displayed pacing has not been
measured across refresh rates or on the 60 Hz Studio Display. Offscreen hook
coverage does not replace display validation. See [Frame Generation
validation](../../../docs/dev/validation/frame-generation.md),
[architecture](../../../docs/dev/architecture.md), and
[current validation](../../../docs/dev/validation/README.md).
