# Shadow Rendering Optimizations: vista-shadow probe — October 15, 2026

This dated record preserves the original read-only probe findings. Its
preliminary slice interpretation and next-gate list were superseded by the
corrected live mapping below. The probe itself did not exercise the rendering
prototype.

User-operated live run, Shadows High. Local input:
`build/shadow-stability-20261015-185653.jsonl`. The user confirmed completion
and High shadows; exact save and action timings were not separately confirmed.
No rendering changes were active. Diagnostic timings are not performance results.

## Observations

- 24,404 shadow-probe samples, with the last at 166.49 seconds.
- Reflection exposes the expected 224-byte camera block at vertex slot 11:
  view matrix at 0, projection at 64, offset view-projection at 128,
  near/far at 192/196, camera world position at 208.
- The later full-size four-slice depth array (trace resource 1081) is
  2048×2048 even at the user's High setting. Each clear pass has 2,574 readable
  first-draw samples (frames 5132–7705, elapsed 57.34–166.48 seconds), without
  missing reflection. All 2,573 consecutive-frame projection and near/far
  comparisons are identical for each slice.
- View matrices repeat exactly in 1,655 / 1,696 / 1,742 / 1,805 of those pairs
  for slices 0 / 1 / 2 / 3 respectively. This includes still-camera periods;
  it does not establish a cache hit rate during normal play.
- Offset view-projection matrices usually remain identical despite view
  translation. They must not alone be used as a world-space history key: the
  camera-relative coordinate origin needs accounting for.
- Full-viewport load passes on that array use **slice 3**, not slice 0.
  There are 4,432 such samples, including multiple passes in some frames.
  The old plan's claim that the vista writes c0 is therefore unsafe. Confirm
  each pass's native stage identity before treating these as vista submissions.
- Other Depth16 arrays have small atlas viewports. Format, dimensions or array
  shape alone do not identify a cascade pass.

## Preliminary snapping calculation

For consecutive frames with unchanged projection and view orientation within
1e-6 per coefficient, interpret the affine matrix's last vector as view
translation and calculate candidate texel movement:

`dx = delta(view[12]) * projection[0] * width / 2`

`dy = delta(view[13]) * projection[5] * height / 2`

For the later array's clear passes:

| Slice | Nonzero movements | Median distance to nearest integer (texels, max XY) | Maximum |
| --- | ---: | ---: | ---: |
| 0 | 915 | 0.003025 | 0.013366 |
| 1 | 873 | 0.001328 | 0.004984 |
| 2 | 818 | 0.000616 | 0.002065 |
| 3 | 754 | 0.000199 | 0.000972 |

These are encouraging observations consistent with texel snapping and float
roundoff. They are **not yet proof**: verify the shader multiplication convention,
camera-relative origin and full relative transform, including depth. Do not
round arbitrary movement to an integer in the renderer based on this table.

## Original next gate (superseded)

1. Verify the vertex transform from shader/capture evidence, including camera
   world position. Extend decoded fields to preserve that origin.
2. Identify the loaded-slice submissions and explain multiple load passes per
   frame. Correct the vista destination in the implementation plan.
3. Derive full relative light transforms and reject unsupported changes.
4. Build the opt-in low-resolution vista prototype once pass identity, depth
   comparison direction and merge ordering are established.

No quality, GPU savings, displayed FPS improvement or safe temporal reuse was
established by this probe.

## Corrected live mapping and prototype status

The live native baseline is
`build/shadow-baseline-20261015-195731.jsonl`. It establishes that the guarded
`CascadedShadowBufferStage::Submit` job at stage+0x21a0 calls
`rf::RendererCommandBuffer::Submit` at `0x106429f40` from `0x105d41154` and
targets a two-slice Depth16 atlas at 1024² or 2048². Native passes use partial
128² or 256² Load regions, with occasional Clear passes. The separate
four-slice 2048² cascade array is outside this submission's scope; its near
cascade remains native.

The saved capture association above has been superseded. Replay `re30` and its
resource 491 four-slice 2048² array were incorrectly identified as the vista
target. They must not be used as the implementation contract. The stage+0x2670
submission is a separate mountain submission.

The current `BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS_VISTA=1` implementation remains opt-in and disabled
by default. It seeds the half-size target from the selected native atlas slice
on Load using max reduction over 2×2 source footprints, halves native
viewport/scissor and slope bias, and replaces only draw-covered viewport /
scissor regions with clamped max-reduced depth. It supports two-slice Load and
Clear descriptors and leaves untouched Load regions and the sibling slice
intact. Max reduction assumes reversed depth; the saved capture's
`GreaterEqual`/depth-write state is not proof of the corrected atlas target's
state. The next live trace can record `shadowProbeSample.depthState` to verify
the native compare and write settings. The full history transform remains
unverified and is not used by this no-history implementation.

The live baseline verifies native descriptor compatibility; it does not verify
the corrected reduced path, image quality or performance. No new live reduced
rendering validation has been done. FULL/HALF diagnostic periods may reuse
cached atlas tiles across mode switches and cannot be treated as clean,
independent A/B references. Follow the user-operated procedure and evidence
checks in the [Shadow Rendering Optimizations plan](../smart-shadows-plan.md). Do not infer a
quality or performance result from the baseline or synthetic checks.

Offscreen validation of the corrected atlas path passed: two-slice redirection,
clearing and replacing an old blocker, adjacent-depth preservation, sibling
slice isolation, in-flight resource ownership, deferred encoder completion,
and vista-only native/reduced modes. The full `make test` suite passed;
after adding the shader-read eligibility guard, all eight vista smoke modes
passed again with Metal API validation enabled against the final libraries
(`build/vista-atlas-metal-validation.log`). The then-current Python suite passed
14 tests; the current suite contains 19 tests, as recorded in the
[validation index](README.md).
These are synthetic/offscreen results, not displayed-game acceptance.
