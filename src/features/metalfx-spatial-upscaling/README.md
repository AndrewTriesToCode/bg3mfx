# MetalFX Spatial Upscaling

Technical name: `metalfx-spatial-upscaling`.

Adds the “MetalFX Spatial” choice to BG3's Upscaling Type menu. It is user-selected and
defaults to BG3's native Off setting; native Off and AMD FSR 1.0 remain
available. Spatial consumes BG3's linear HDR scene after bloom and color
grading, before `FSR_Tonemap`, then returns the scaled image to BG3's normal
tone mapping and UI path. BG3's independent anti-aliasing setting remains active unless Frame Generation is enabled;
Spatial works with TAA, SMAA or no anti-aliasing, because it needs only the color image.

The upscaler is implemented in
[`SpatialUpscaler.mm`](../../../src/features/metalfx-spatial-upscaling/SpatialUpscaler.mm), using
the shared MetalFX resource code in
[`MetalFXPipeline.mm`](../../../src/common/gpu/MetalFXPipeline.mm) and
[`Trace.mm`](../../../src/integration/renderer/Trace.mm). Menu and saved-quality
integration is in [`NativeMenu.mm`](../../../src/integration/menu/NativeMenu.mm).

No per-feature frame-rate or GPU-time gain is measured. The user confirmed
good colors, saved settings, and improved performance versus Off, without a
recorded matched numerical comparison. Synthetic and main-menu checks passed.
See [architecture](../../../docs/dev/architecture.md) and
[current validation](../../../docs/dev/validation/README.md).
