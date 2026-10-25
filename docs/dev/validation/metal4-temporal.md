# Metal 4 Temporal integration and neural implementation audit

Current implementation: [architecture](../architecture.md#renderer-flow)
and [`TemporalUpscaler.mm`](../../../src/features/metalfx-temporal-upscaling/TemporalUpscaler.mm).
This audit records the dated API investigation; current validation status is in
the [validation index](README.md).

October 11, 2026. Local device: Apple M5 Pro, macOS 27.0.1 (26A434).

## What the public APIs establish

Apple's [WWDC26 Metal guide](https://developer.apple.com/wwdc26/guides/metal/)
announces redesigned temporal upscaling using the Neural Engine and Neural
Accelerators on M5 Pro and M5 Max. This announcement does not document a neural
model-selection property on the temporal descriptor.

The installed SDK describes
[`supportsMetal4FX:`](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerdescriptor/supportsmetal4fx(_:))
as Metal 4 compatibility. It is a capability query, not a switch enabling a
specific network or proof of the network's revision. The creation APIs are:

- `newTemporalScalerWithDevice:` → `id<MTLFXTemporalScaler>`, encoded on
  `id<MTLCommandBuffer>`.
- `newTemporalScalerWithDevice:compiler:` → `id<MTL4FXTemporalScaler>`, encoded on
  `id<MTL4CommandBuffer>`, using an `MTL4Compiler`.

The Metal 4 API dates from macOS 26; its presence alone is not a WWDC26 model
identifier. Apple's [WWDC25 session](https://developer.apple.com/videos/play/wwdc2025/211/)
already describes MetalFX temporal upscaling as machine-learning based.
Consequently, calling the Metal 3 API does not establish a non-neural or outdated
reconstruction algorithm. No documented API to explicitly choose the WWDC26
network revision was found in the installed SDK or reviewed Apple references.

Both support queries return true locally. Without capture wrappers the existing
API returns `_MFXTemporalScalingEffectBBR`, and the Metal 4 API returns
`_M4FXTemporalScalingEffectBBR`. These private names are diagnostic observations,
not dependencies or a version contract.

## Runtime change

Temporal now chooses the Metal 4 creation API when `supportsMetal4FX:` is true.
Otherwise it retains the Metal 3 scaler. A supported Metal 4 creation, encoding,
or GPU failure is an error; it does not silently select another upscaler.
Spatial, native Off/FSR, menu settings, and jitter conventions are unchanged.
BG3's engine and presentation continue using Metal 3; this is a Metal 4 MetalFX
island, not a conversion of the closed-source game renderer.

The native command buffer remains uncommitted and intact:

1. Native passes and the color/depth conversion produce the inputs.
2. The command buffer signals an input-ready event at that point.
3. A dedicated Metal 4 queue waits for that event, executes the scaler and
   signals an output-ready event.
4. The same native buffer waits for that event before conversion, postprocessing
   and presentation consume the result.

There is no per-frame CPU wait or early native-buffer commit. Events make memory
visible across the queues. Each submission has its own events, allocator,
command buffer and committed residency set for its four external textures.
A feedback-handler-owned resource list retains them, the scaler and queue until
Metal 4 execution completes. Commit feedback routes GPU errors to the existing
Temporal error dialog. No installed app bytes or build-specific offsets change.

The diagnostic runtime supports `BG3MFX_TEMPORAL_API=metal3` for A/B comparison.
The quiet runtime compiles that override out and always chooses by capability.
`temporalScalerCreated` records the selected API in diagnostic traces.

## Offscreen evidence

`tests/features/metalfx-temporal-upscaling/temporal_api_compare.mm` compares identical analytic geometry, depth,
motion, jitter, exposure and reset values through both public APIs at 1.5×/2×,
with stationary and moving scenes over three full jitter cycles. The settled
RGBA16Float outputs are byte-identical in all four cases. The comparison was
repeated with the GPU-event bridge and during capture, with the same equality.
Temporal MSE is 12–22% of bilinear MSE in these cases for either API. This shows
no quality gain from changing the public command-buffer API on this OS/device;
it does not prove equality for all inputs or identify the exact neural model.

`gpucapture` captured the full standalone comparison through process exit (an
85 MiB trace, since deleted). `gpudebug` confirms separate `MTLFXTemporalScaler` and `MTL4FXTemporalScaler`
property/encode calls. This capture exposes the effects as opaque calls, not
internal neural kernels. Do not claim matching kernels from it. Metal 3 output
readback was fetchable; Metal 4 buffer replay reported empty data, so a replayed
pixel equality claim is not supported. Direct GPU readbacks during the captured
run do establish equality. No explicit scaler-history capture option is claimed.

The event bridge regression uses eight in-flight GPU-produced private inputs
with different per-frame colors, resets history for independent pixel checks,
and destroys the backend before waiting. Output correctness checks both
cross-queue dependencies and lifetime retention. It passes API validation.
Quiet/diagnostic renderer-hook tests also pass API validation. The retained
Metal 3 path passes its selection, pixel, reset and invalid-input checks under
the diagnostic override. Older hardware has not been physically tested.

The comparison logs and readbacks have since been deleted. The separate historical private
MetalFX shader-validation fault is not declared resolved by these API checks.

## Live validation

The diagnostic BG3 run recorded `temporalScalerCreated` with `api=metal4`
on this M5 Pro. World inputs were 2258×1270 and output was 3840×2160.
`metal4-live.gputrace` captured three frames; `gpudebug` confirms three
`MTL4FXTemporalScaler` encodes, changing jitter, reversed depth, and `reset=0`.
The scaler uses RGBA16Float color/output, R32Float depth and RG16Float motion.
The diagnostic trace reports completed native buffers without errors. The user
confirmed correct, stable rendering during slow camera movement and inventory,
and then closed the game. This is displayed acceptance of the Metal 4 path;
it is not a measured performance comparison or a settings-transition test.

The armed input dump saved 16 consecutive world frames. Replaying those same
inputs through each API produced byte-identical RGBA16Float outputs for all
16 frames (`metal4-live-pixel-comparison.json`). These are offscreen readbacks
with a fresh history reset at the start of each replay, not a comparison of
captured displayed frames with the original live history. They provide no
evidence of a different reconstruction result from switching APIs.

The live capture records the input-ready event signal, Metal 4 queue wait,
commit and output-ready signal. Its API listing does not expose the native
consumer `encodeWaitForEvent`, although the runtime encodes it. Therefore the
capture alone does not verify the complete consumer dependency. The independent
GPU producer/consumer pixel regression verifies the bridge's dependencies.
Internal neural kernels and Neural Engine/Neural Accelerator dispatch are not
exposed in this capture. Specific WWDC26 model selection or hardware utilization
remains unproven; Metal 4 support and encode calls must not be presented as that
proof. A trace exposing those hardware activities, or explicit Apple guidance
on selection, would be needed for a stronger claim.

Repeat the optional offscreen comparison:

```sh
make build/bin/temporal-api-compare
build/bin/temporal-api-compare build/evidence/DATE-temporal-api-comparison
```
