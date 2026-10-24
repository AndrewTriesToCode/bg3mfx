# MetalFX Temporal Upscaling

Technical name: `metalfx-temporal-upscaling`.

Adds the “MetalFX Temporal” choice to BG3's Upscaling Type menu. It is user-selected and
defaults to BG3's native Off setting. Temporal replaces the TAA result used by
the upscaled scene, disables the separate anti-aliasing control while selected,
and uses BG3's depth, motion, camera, and post-processing inputs. Native and
auxiliary views retain BG3's TAA. Upscaled scenes use quality-dependent
14/18/24/32-phase Halton jitter, and the Dynamic quality
([dynamic resolution](../dynamic-resolution/README.md)) ceil(8 / area) phases;
other views keep the native eight-phase table.
BG3's `FSR_Tonemap` draw is skipped as for
[Spatial](../metalfx-spatial-upscaling/README.md). With the Metal 4 scaler, the
MetalFX work is submitted to its own queue once BG3 commits the frame's command
buffer (see [architecture](../../../docs/dev/architecture.md)).

The feature implementation is in
[`TemporalUpscaler.mm`](../../../src/features/metalfx-temporal-upscaling/TemporalUpscaler.mm),
[`TemporalJitter.mm`](../../../src/features/metalfx-temporal-upscaling/TemporalJitter.mm), and
[`TemporalJitter.S`](../../../src/features/metalfx-temporal-upscaling/TemporalJitter.S). The
shared renderer and MetalFX resource integration lives in
[`Trace.mm`](../../../src/integration/renderer/Trace.mm) and
[`MetalFXPipeline.mm`](../../../src/common/gpu/MetalFXPipeline.mm);
menu persistence is in [`NativeMenu.mm`](../../../src/integration/menu/NativeMenu.mm).

There is no isolated Temporal-versus-native performance result. At 3840×2160
output on an M5 Pro MacBook, the scaler itself measured about 3.1 ms with GPU
profiling; that is a cost, not a net improvement over a matched baseline. Analytic 1.5×/2× static and moving tests measured 78–88% less reconstruction
error than bilinear after the jitter-sign correction; these are offscreen image
quality results, not live performance measurements. The
user confirmed corrected jitter was clearly better and stable in a saved-camera
and slow-motion test, then reported that the longer quality-dependent sequence
looks good in the tested scene. That does not cover every scene or material;
full Metal shader validation still reports invalid threadgroup loads in Apple's
private `BBRNetAnisoGaussian` kernel. See [architecture](../../../docs/dev/architecture.md),
[jitter diagnosis](../../../docs/dev/validation/temporal-jitter-diagnosis.md),
[long-jitter validation](../../../docs/dev/validation/temporal-long-jitter.md),
and [current validation](../../../docs/dev/validation/README.md).
