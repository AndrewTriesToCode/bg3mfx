# Wilderness Temporal quality investigation — October 11, 2026

**Archive notice:** This report describes the implementation and evidence on
October 11. Its descriptions of the active jitter sequence were superseded;
see the [architecture](../../architecture.md) and
[validation index](../README.md) for current behavior. Referenced local capture
paths are historical and may no longer exist.

Superseded for jitter interpretation by the
[controlled reconstruction diagnosis](../temporal-jitter-diagnosis.md).
The same-sign depth-gradient fit below describes sample displacement, not
MetalFX image displacement; the old adapter's signs were incorrect.

Matched quiet screenshots at windowed 2992×1870 show more jagged thin reeds with Temporal Balanced than Spatial Balanced with native TAA. Both modes render 1760×1100 internally. Screenshots remain local under ignored `build/quality-comparison/`. HUD timing snapshots are not controlled benchmarks; Low Power Mode was enabled.

## Input and history checks

Inspected `VelocityBufferCamera_PS` IR emits current minus previous displacement in framebuffer pixels. MetalFX SDK motion-vector documentation expects a vector back to the previous pixel location; the current −1, −1 scale matches those conventions. This verifies the camera shader convention, not every animated foliage shader.

Diagnostic capture can now wait for `BG3MFX_CAPTURE_TEMPORAL_ARM` to exist and capture up to 16 frames via `BG3MFX_CAPTURE_TEMPORAL_FRAMES` (default remains three). Capture is compiled out of the quiet runtime. PID 3662 launched with the launcher bypass and HUD enabled, loaded Honour Mode - Wilderness, selected Temporal Balanced, returned from Options, and captured the settled scene without camera or gameplay interactions. Live API/shader validation was not enabled in this capture run.

Local inputs: `build/wilderness-quality-inputs/frame-{0..15}.{json,bin}` (binary filenames also contain color/depth/motion). All 16 HDR/depth/motion inputs are finite. Color ranges extend to 148, depth approximately 0.000624–0.036205. Motion median is approximately zero; the 95th percentile absolute component stays below 0.0035 pixels horizontally and 0.0014 vertically. Moving character regions have larger vectors. Every captured reset flag is false. The eight distinct jitter samples repeat exactly for the second cycle. This rules out requested history resets each frame in this captured scene, not every possible history rejection inside MetalFX.

A first-order depth-gradient fit gives sampling shifts with the same signs as reported jitter deltas; it is preliminary evidence against a global jitter sign reversal. Animated geometry and discontinuities limit precision. It is not a proof of complete color/depth/motion registration or foliage motion correctness.

Standalone `temporal-replay-smoke` now supports `BG3MFX_REPLAY_FRAMES=16`. The actual consecutive sequence passed with `MTL_DEBUG_LAYER=1`, `MTL_SHADER_VALIDATION=1`, and `MTL_SHADER_VALIDATION_ABORT_ON_FAULT=1`; all output pixels finite, no exclusions. Validation and finite output do not establish reconstruction quality.

## Validation and disposition

Both runtime libraries built; eight Python tests passed. Synthetic Temporal conversion/HDR/depth/history checks passed API/shader validation. The standalone replay initially lacked a Metal device in the shell sandbox; running with authorized GPU access succeeded. A device/allocation guard now reports this condition instead of throwing an NSArray exception.

PID 3662 quit normally (exit 0) after selecting Off (trace confirms nativeType 0). TAA, HUD and windowed 2992×1870 were retained. Honour Mode may autosave on normal quit; no explicit Save commands, quest actions or dialogue choices were issued. Do not claim absence of save writes.

At the time of this report, no image-quality fix was established. The reduced
Halton sampling amplitude had been removed at the user's request, and the
runtime then used BG3's original jitter table. That pattern had previously
reproduced a MetalFX BBR shader-validation fault. Later quality-dependent jitter
and displacement corrections are documented in the
[current validation index](../README.md); this report's result is historical.

## Behavior after the October 11 workaround removal

At that point, the runtime retained BG3's original Halton samples at startup and
across menu switches. This behavior was later superseded by quality-dependent
sampling for upscaled Temporal views; native and auxiliary views retain eight
phases.
