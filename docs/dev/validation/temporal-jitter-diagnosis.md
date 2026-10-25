# Temporal displacement diagnosis — October 11, 2026

Current adapter implementation: [`TemporalUpscaler.mm`](../../../src/features/metalfx-temporal-upscaling/TemporalUpscaler.mm).
This page preserves the dated diagnosis and measurements; see the
[architecture](../architecture.md#renderer-flow) and
[current validation status](README.md) for active behavior and open issues.

## Root cause and correction

The integration reported BG3's sampling offset as MetalFX's image/projection
displacement. Those have opposite signs. The old conversion was `(nativeX,
-nativeY)`; the corrected conversion is `(-nativeX, nativeY)`, in input framebuffer
pixels. BG3's projection, eight-phase Halton sequence, motion scale (−1, −1),
depth convention, HDR pass placement, exposure, and history management remain
unchanged. No sharpening or mip bias was added.

The conversion is shared by the real renderer, diagnostic probe, and new
analytic reconstruction regression in `BG3MFXApplyTemporalJitter`.

## Evidence

The analytic fixture point-samples known thin lines, a circle, and a rectangle
at `scene((pixelCenter + samplingOffset) * scale)`. Independent 8×8 output-pixel
supersampling supplies the reference; the bilinear reference is de-jittered.
The moving case translates the scene 0.35 output pixels per frame and supplies
previous-minus-current motion in input pixels. This is synthetic offscreen
evidence, not a native BG3 screenshot or a complete test of animated materials.
The test runs three Halton cycles: 18 phases at 1.5× and 32 at 2×.

| Case | Legacy Temporal MSE | Corrected Temporal MSE | Bilinear MSE | Corrected / bilinear |
| --- | ---: | ---: | ---: | ---: |
| 1.5× static | 0.0028411 | 0.0002519 | 0.0016534 | 0.152 |
| 1.5× moving | 0.0022001 | 0.0003329 | 0.0015230 | 0.219 |
| 2× static | 0.0025862 | 0.0002232 | 0.0016041 | 0.139 |
| 2× moving | 0.0024048 | 0.0001852 | 0.0015069 | 0.123 |

Legacy signs fail both convergence and the bilinear comparison. Correct signs
pass. Repeating with BG3's eight phases also passes (Temporal/bilinear MSE
0.163–0.244); changing the game's sequence is not needed to demonstrate this
fix. The test is part of `make test`. Its legacy negative control exits 7:

```sh
BG3MFX_QUALITY_LEGACY_JITTER=1 build/bin/temporal-quality-smoke \
  build/evidence/DATE-temporal-jitter/legacy-negative-control
```

Consecutive captured BG3 depth images independently establish the sampling
direction. Fitting `depthNext - depthCurrent = gradientX * deltaSampleX +
gradientY * deltaSampleY` on interior, smooth depth pixels gives:

| Transition | Old reported jitter delta | Fitted sample delta |
| --- | --- | --- |
| 0 → 1 | (+0.500, +0.556) | (+0.440, +0.495) |
| 1 → 2 | (−0.625, −0.333) | (−0.664, −0.289) |
| 2 → 3 | (+0.500, −0.333) | (+0.437, −0.290) |

All seven checked transitions agree in sign. This is a first-order fit affected
by animation and depth discontinuities, not an exact offset estimator. Combined
with the independent reconstruction fixture, it identifies the adapter error.
An earlier note's conclusion that same-sign depth shifts argued against
a sign reversal was incorrect: it confused sampling and image displacement.

The same 16 captured game frames were replayed with legacy and corrected
conversions. Purple rune strokes are visibly cleaner after correction. The
sequence was captured while loading/exposure was settling, so it does not prove
stationary convergence in a fully settled game. The comparison uses identical
inputs and no sharpening. The captured inputs, replay outputs and crops have
since been deleted. `make test` regenerates the analytic native-reference,
bilinear, and Temporal PPM comparisons (both scales, stationary and moving)
under a dated `build/evidence/` folder.

Replay diagnostics are test-only:

```sh
BG3MFX_REPLAY_SEQUENCE=1 BG3MFX_REPLAY_FRAMES=16 BG3MFX_REPLAY_JITTER_SIGN=-1 BG3MFX_REPLAY_OUTPUT=OUT_DIR build/bin/temporal-replay-smoke INPUTS/frame-0
```

The sign override applies only to historical metadata containing the old
conversion. New diagnostic captures already contain the corrected conversion.

## GPU audit

The user launched the unmodified bundle with `MTL_CAPTURE_ENABLED=1`, selected
Continue/Temporal/Balanced, and kept the saved camera. `gpucapture` recorded
eight layer frames from PID 8058; `gpudebug` inspected the resulting capture
(about 11 GiB, since deleted). This capture predates the fix.

- Input: 1129×635, RG11B10Float HDR → private RGBA16Float, exact integer copy.
- Original device depth: 1129×635 Depth32Float_Stencil8 → private R32Float;
  nearest depth read at matching pixel centers. Reversed Z agrees with native
  near/far projection checks.
- Motion: same-size private RG16Float, scene camera/object vectors; scale −1,
  −1 agrees with inspected native current-minus-previous shader conventions.
  All animation/alpha-tested shader variants are not exhaustively verified.
- MetalFX input-content dimensions exactly match its input textures.
- MetalFX output: 1920×1080 private RGBA16Float, required usage plus ShaderRead.
- Output integer copy → native full-size RG11B10Float `@tex296`.
- `PPToneMap_LUT` reads that exact texture and writes 1920×1080 RGB10A2Unorm.
- `CombineUI` samples that full-size target and writes a 1920×1080 BGRA8 drawable,
  using linear sampling. No downstream reduced-resolution target/stretch was
  found in this captured path.
- Eight `setReset:0` calls, changing jitter, and one scaler encode per captured
  scene frame. No evidence of resetting history each frame or interleaved
  same-size views in this capture.
- Conversion, scaler encode, output copy, tone mapping, and UI are ordered on
  the scene command buffer. Resources are hazard tracked and lifetime retained.
  This is a structural audit, not a GPU synchronization/performance trace.

Mip bias remains native. The conversion copies sample values exactly and the
full-size presentation textures have no mip chain to select a degraded level.
The global material sampler/LOD-bias policy has not been exhaustively audited.
Apple recommends `log2(renderWidth/outputWidth)-1` for temporal texture detail,
but applying it globally is not justified before evaluating the corrected path.
[Apple's MetalFX introduction](https://developer.apple.com/videos/play/wwdc2022/10103/)
describes that bias and 32-phase jitter at 2×.

## Validation and remaining work

`make test` and `make test-python` pass after rebuilding quiet and diagnostic
libraries. Captured-input replay completes with finite pixels. Full API plus
shader validation nevertheless reports invalid threadgroup loads in Apple's
private `BBRNetAnisoGaussian`, offset 4294967294 or 4294967142: 102 reports in
the four analytic cases and four reports in this captured 16-frame replay.
These are not clean validation passes. The analytic reproduction shows the
fault is not restricted to BG3 resources; its driver/kernel/validator cause
remains unproven. No exclusion, reduced jitter workaround, or FSR fallback is
enabled.

Full Xcode is not installed/configured; `xctrace` requires it. The capture CLI
does not expose a documented “Include MetalFX temporal scaler history” switch.
Therefore this capture is useful for resource/API auditing, but its replay is
not claimed to reproduce the pre-capture temporal history. A follow-up Xcode
capture with that option enabled would help investigate the private kernel
fault and internal history. See
[Apple's capture documentation](https://developer.apple.com/documentation/xcode/capturing-a-metal-workload-in-xcode).
No Metal System Trace or measured scheduling conclusion is claimed.

The user tested the rebuilt quiet runtime at Temporal/Balanced, the saved camera,
and slow camera motion, and confirmed "Clearly better and stable" on October 11.
This is displayed-game acceptance for that case, separate from the synthetic
and offscreen evidence. It does not clear the private shader-validation fault
or verify every animated material. BG3 was manually quit by the user before
rebuilding; the app bundle was not modified.

The user subsequently reports remaining shimmer on grass/foliage/thin geometry
even with a stationary camera. This qualifies the acceptance: the jitter fix
improves clarity and stability, but image-quality work remains. A still camera
does not mean wind-animated foliage is static. Compare Temporal/Balanced and
Ultra Quality with Spatial/Balanced plus native TAA first, then capture the
affected material's consecutive color/depth/motion and output. Verify actual
deformation motion and changing alpha-test coverage before testing a longer
jitter sequence or any reactive mask. Do not infer a material motion bug from
the global camera-vector checks or add sharpening to address temporal shimmer.
