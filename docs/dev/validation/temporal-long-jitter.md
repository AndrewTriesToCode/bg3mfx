# Quality-dependent Temporal jitter

Current implementation: [`TemporalJitter.mm`](../../../src/features/metalfx-temporal-upscaling/TemporalJitter.mm)
and [architecture](../architecture.md#renderer-flow). This page records
the dated implementation investigation; current status is in the
[validation index](README.md).

October 11, 2026. The user authorized increasing Temporal's eight-phase jitter
sequence to match upscale quality. Counts are 14/18/24/32 for Ultra Quality,
Quality, Balanced, and Performance, approximating `ceil(8 * scale²)` using
BG3's quality ratios (1.3/1.5/1.7/2).

## Integration

`TemporalJitter.mm` reads the native frame index and supplies one uncentered
Halton (2,3) pair to three native sample loads. BG3 still subtracts 0.5, computes
the projection and camera constants, stores previous jitter/projection, and
compensates motion. The MetalFX adapter still converts that resulting sample
displacement using the previously verified signs.

An exact native PostProcessStage/FSR-step identity and enabled flag identify
views using upscaling. Off, FSR, Spatial, orthographic and auxiliary views retain
their original sample. The decision is frozen per native view/frame, including
multiple calls and a settings change during recording. Bookkeeping is bounded.
No shader modification or installed-bundle write is involved.

New ARM64 addresses, validated after the existing executable UUID guard:

| Sampling site | Address | Expected instruction |
| --- | --- | --- |
| GetJitteredProjectionMatrix | `0x105f8bdc8` | `0xfc685923` |
| UpdateConstantBuffersData | `0x105f8af84` | `0xfc685921` |
| VelocityRenderStage::StartRecording | `0x106253924` | `0xfc685920` |

View stages are at +0x20/count +0x2c. PostProcessStage's vtable is
`0x10886b5a0`, verified against GetType at slot +0x10. Its steps are at
+0x2150/count +0x215c; FSR's vtable is `0x10886c380`. Stage/step enabled flags
are +0x18. Native quality is +0x98 on the settings pointer at `0x108af4118`.
All addresses include the executable slide. Current/previous velocity constants
at stage +0x2220/+0x2228 are written by the original code, not reconstructed.

Single-instruction branches lead to RX islands in verified zero-filled Mach-O
header padding at `0x100004000` plus the executable slide. The installer parses
load commands and section bounds, checks the padding contents and both branch
directions, and prepares private writable pages before changing any bytes. No
load command or declared section is used for island storage. Assembly wrappers retain
all integer registers, full SIMD lanes, flags, and FPSR around sample selection.
Only the destination register of the original load changes. Code-page writes
are private process-memory copies installed before rendering starts.

## Evidence and pending checks

The standalone native-layout fixture verifies all phase counts over three
cycles, repeat calls in one frame, settings changes within that frame, disabled
FSR/post-processing, orthographic views, and untouched Off/FSR/Spatial samples.
The three real assembly wrappers pass integer/SIMD/flag snapshot comparisons.
Padding fixtures reject occupied bytes, insufficient room, malformed commands,
and out-of-range branches.
Fixtures contain no game code/assets. `make test test-python` passes for both
runtime builds. These results do not prove the live native view classification
or foliage improvement. Live evidence is recorded below.

Two live startup attempts failed to allocate branch islands. Searching both
directions was insufficient: the failed process memory map shows the executable
and its link-edit mapping occupy the reachable region, and addresses below its
text cannot be allocated. The replacement uses existing header padding rather
than a new allocation. `long-jitter-tests-v3.log` records passing regressions for
this replacement, and live startup now succeeds.

Diagnostic builds emit `nativeTemporalJitter` view/frame/phase/sample records;
quiet builds compile these records out. This change adds CPU hooks and modest
bookkeeping to both builds. It does not claim zero integration overhead or fix
the separately reported private MetalFX shader-validation fault. Shared Spatial
and Temporal geometry seams are also not an expected target of this change.


## Live result

`build/temporal-quality/long-jitter-live-v3.jsonl` records successful installation
in PID 10309 and 2,106 world-view samples using 24 phases at Balanced in the
initial audit. Every recorded longer-sequence sample matches its native frame
index modulo phase count. The world renders at 1505×847 for 2560×1440 output.

`build/temporal-quality/long-jitter-inventory.gputrace` is a three-frame capture,
4.0 GiB on disk. Despite its requested filename, the inspected capture contains
world rendering, not a separate inventory-preview pass; do not cite it as new
GPU proof of inventory routing. It records MetalFX jitter pairs
(0.3125, -0.3519), (-0.1875, -0.01852), (0.0625, 0.3148), with `setReset:0` in
all three frames. These match successive longer-sequence samples with the
previously corrected X conversion. CLI capture is not claimed to include scaler
history for representative image-quality replay. Native camera-buffer extraction
was interrupted, so all three native consumers are still covered synthetically,
not independently reverified from GPU constants in this capture.

The user reports reduced foliage shimmer, inventory looking correct with TAA,
and "looks good now." This accepts the longer sequence in the tested scene;
other scenes and the separate private MetalFX shader-validation fault remain
outside that acceptance. No sharpening or shader change was added.
