# Animation Optimizations

Opt-in with `BG3MFX_FEATURE_ANIMATION_OPTIMIZATIONS=1` (the `bg3mfx` launcher
sets it), for the supported BG3 build. BG3 links the Granny 3D animation
runtime unoptimized (`-O0`, in both the ARM64 and x86_64 slices): every operand
round-trips through the stack, small helpers are out-of-line calls, and its
math has no vector code. This feature replaces Granny's hottest small functions
with optimized versions that produce **bit-identical** results, so animation is
unchanged.

| Granny function | How it is replaced |
|---|---|
| `ColumnMatrixMultiply4x3Impl` (affine 4x4 product) | its writable function pointer |
| `ColumnMatrixMultiply4x3TransposeImpl` | its writable function pointer |
| `BuildFullWorldPoseOnly` (bone world transform) | its writable function pointer |
| `BuildSingleCompositeFromWorldPoseTranspose` | its writable function pointer |
| `BuildIndexedCompositeBufferTransposed` (skinning matrices) | entry jump |
| `BuildCompositeTransform4x4`, `MatrixMultiply3x3` | entry jump |
| `MatrixEqualsQuaternion3x3` | entry jump |
| `Normalize4`, `NormalizeWithTest4` (quaternion normalization) | entry jump |
| `QuadraticCoefficients`, `SampleBSpline2x3`, `SampleBSpline2x4n` (spline sampling) | entry jump |
| `CurveExtractKnotValuesD4nK16uC15u`, `D4nK8uC7u` (quaternion curves) | entry jump |
| `CurveExtractKnotValuesD3K8uC8u` (8-bit vector curves) | entry jump |
| `FindKnotInteger<u8/u16/u32>` (knot search) | entry jump |

## Implementation

The kernels are in [`GrannyKernels.h`](GrannyKernels.h). Each one does the same
multiplies and fused multiply-adds as Granny, in the same order, with floating-point
contraction turned off. Where the compiler could commute a multiply or an add,
the kernel uses fixed-order instructions instead, so even NaN results keep
Granny's sign and payload. Matrix products use NEON across a row. When the output
overlaps an input, a product falls back to Granny's element-by-element order.
Knot searches keep Granny's exact upper-bound probe sequence, so they match even
on unsorted knots.

[`AnimationOptimizations.mm`](AnimationOptimizations.mm) checks these before
patching:

- the four function pointers still hold the `_Generic` functions
- each patched function's first four instructions
- Granny's quaternion scale/offset table and its 0..255 identity table

It then overwrites each function's first 16 bytes with
`ldr x16, #8; br x16; .quad hook`, and swaps the pointers. Addresses are in
`BG3MFXBuild::Animation` (`src/common/native/SupportedBuild.h`). No branch
targets those first 16 bytes.

## Verification and measured improvement

During development, a harness mapped the executable's own Granny code and
compared each original with its replacement on 2 million random cases per seed
(including aliasing, NaNs and other special values, unsorted knots, and the
composite buffer's argument checks). There were 0 mismatches over three seeds. `make test` runs a lightweight synthetic check of the kernels
against scalar references in Granny's order.

Per call, on an M5 Pro (synthetic, CPU only):

| Function | Granny | Replacement |
|---|--:|--:|
| Multiply4x3 | 16.1 ns | 2.0 ns |
| Multiply4x3Transpose | 15.6 ns | 1.9 ns |
| MatrixEqualsQuaternion3x3 | 6.0 ns | 1.6 ns |
| FindKnotInteger<u16> | 19.2 ns | 4.0 ns |
| D4nK16uC15u decode, 4 knots | 93.4 ns | 7.1 ns |
| D4nK8uC7u decode, 4 knots | 62.2 ns | 7.3 ns |
| D3K8uC8u decode, 4 knots | 19.5 ns | 2.4 ns |
| NormalizeWithTest4 | 5.3 ns | 0.9 ns |
| SampleBSpline2x4n | 22.9 ns | 1.4 ns |
| SampleBSpline2x3 | 11.3 ns | 0.6 ns |
| BuildCompositeTransform4x4 | 22.0 ns | 4.1 ns |
| BuildFullWorldPoseOnly | 37.9 ns | 6.0 ns |
| BuildIndexedCompositeBufferTransposed, 64 bones | 1251 ns | 127 ns |

Live, Lower City (displayed, M5 Pro), first set of functions only (the matrix
products, quaternion-to-matrix, knot searches and D4nK16uC15u): two 10-second
System Traces at the same
spot, both with `thread-idling`, run A without this feature and run B with it.
Figures are from 1 ms on-CPU samples:

| | A | B |
|---|--:|--:|
| Replaced functions (self, incl. `local_upper_bound` and `UnsignedShortToFloat`) | ≈0.12 cores | 0.03 cores |
| Granny, inclusive | 0.41 cores | 0.31 cores |
| Animation blueprints, inclusive | 0.81 cores | 0.65 cores |
| Process on-core | 5.86 cores | 5.72 cores |

Granny's CPU fell by about 24% (≈0.1 core), mostly on the high-priority
worker threads, where animation runs, with some on GameThread. That matches the
time saved in the replaced functions. The whole-process change is
within run-to-run noise, and frame rate was not measured. The knot searches
appear memory-bound.

The second set of functions (composite transforms, normalization, spline
sampling and the 8-bit curves), measured as run C the same way: Granny,
inclusive, stayed at 0.31 cores, and the replaced functions fell from about
0.075 to 0.063 cores. That is within run-to-run noise. In game these functions
wait on memory, not on Granny's unoptimized code: the skinning-matrix loop
gathers each bone's inverse world transform (164-byte stride) and world
transform, and the time BuildIndexedCompositeBufferTransposed spent in run B
moved into the matrix product in run C. Faster arithmetic alone does not help
the remaining Granny time; reducing the work does.
