# Temporal image-quality plan

October 11 update: [the jitter diagnosis](validation/temporal-jitter-diagnosis.md)
establishes and corrects the native-to-MetalFX displacement signs. The quiet
runtime is rebuilt. Analytic and captured-input comparisons improve; the user
confirms the quiet Temporal/Balanced saved-camera and slow-camera-motion test is
clearly better and stable. The private MetalFX validation fault remains open.
The hypotheses below describe the audit, not additional changes to make blindly.

## Goal and test case

Improve MetalFX Temporal's reconstruction of thin geometry and foliage, at the
same input/output dimensions as the current implementation. The user reports
that Temporal is stable but looks bad. Spatial's colors, setting persistence,
and performance improvement over Off are accepted from the user's play; further
Spatial or settings-persistence testing is outside this investigation.

Use the user's latest save and its saved camera position for the displayed
comparison. At planning time, the latest local save is `HonourMode.lsv`, modified
October 11, 2026 at 11:51:59, under the Public profile's
`2b560c50-b846-e08a-fb53-1cdd0696f77d__HonourMode` directory. Preserve a local
snapshot before loading: Honour Mode can save on quit. Do not issue Save commands,
advance quests, or make dialogue choices. Keep old Wilderness captures for
offline input analysis; they are supporting evidence rather than the primary
visual acceptance case.

## What we know

- Matched Wilderness screenshots show jagged reeds with Temporal Balanced
  versus Spatial Balanced with native TAA, both using 1760×1100 input and
  2992×1870 output.
- Sixteen consecutive captured frames contain finite HDR, depth, and motion;
  requested resets are false and the original eight-sample jitter cycle repeats.
  Finite output and successful encoding do not prove good reconstruction.
- Inspected camera and one alpha-tested material shader emit current-minus-
  previous pixel displacement with jitter compensation. Negating those vectors
  matches MetalFX's convention. Coverage of the material used by the new test
  scene is still unknown.
- Current MetalFX input is the tracked HDR color after native bloom, color
  grading, and outline passes, before `FSR_Tonemap`. Depth, motion, and jitter
  are captured earlier at the TAA stage. The native TAA draw is replaced by a
  copy of the current color. This placement needs an image-quality audit.
- Temporal scaler history is currently cached by GPU and dimensions, without a
  view or command-queue identifier. Cross-view reuse is a hypothesis to verify,
  not a demonstrated cause.
- Auto exposure is disabled, pre-exposure is fixed at 1, and native RCAS is
  skipped. The inherited Upscaling Sharpness slider does not affect MetalFX.
- A prior native-jitter sequence triggered an Apple MetalFX shader-validation
  fault; another sequence passed. Stability during play does not settle that
  separate validation question.

## Investigation order

1. **Create a repeatable visual baseline.** At the latest save's saved camera,
   record actual output and input dimensions, not just quality names. Capture
   Temporal after settling, Spatial with the user's accepted AA, and Off/TAA at
   the same output resolution. Hold display mode, exposure-related settings,
   power mode, sharpening, and VSync constant. Inspect crops at native pixel
   size and record a short slow camera movement. Start with Balanced; use Ultra
   Quality as a diagnostic comparison. Distinguish static aliasing, motion
   shimmer, trails, and simple softness. Do not benchmark the diagnostic build.

2. **Prove the temporal input contract.** Export consecutive inputs and raw
   MetalFX output, with frame/view identity, current/previous jitter, viewport,
   projection, selected dimensions, scaler identity, and reset reasons. Check
   color/depth/motion refer to the same pixels and frame; verify pixel-center
   alignment, Y orientation, displacement units, and jitter compensation.
   Track calls per view and scaler reuse to rule out interleaved histories or
   stale histories after a scene/size change. Existing reset-free captures make
   repeated resets less likely in the old scene, but do not establish the new
   scene's behavior. Use a synthetic jittered thin-line scene with a known
   reference to measure convergence and correct reprojection under motion.

3. **Locate where quality is lost.** Extend the offline replay to export
   reconstruction results, not only check for finite pixels. Compare raw
   MetalFX output with the final displayed image using the appropriate native
   tone mapping for display comparisons. Capture both pre-post-processing HDR
   and the current late HDR input from the same frame sequence. Test whether
   filtering, outlines, color grading, or another pass disrupts the jittered
   samples. Only move the integration point if this comparison demonstrates a
   benefit and the downstream resolution/resource contracts are established.
   Check exposure/pre-exposure against actual BG3 data rather than tuning them
   until the result happens to look better.

4. **Investigate the failing materials and Windows reference.** If opaque static
   edges reconstruct correctly but foliage does not, identify the exact shader
   variant used by the affected geometry. Check its previous-frame deformation,
   alpha-test behavior, depth writes, and motion coverage. Trace the Windows
   DLSS parameter producer and its render-pass placement, jitter, reset,
   material, and mip-selection setup; the known NGX helper alone does not prove
   those values. Use that as evidence about BG3, with MetalFX's own input
   conventions. Consider texture mip bias or a reactive mask only if the
   measured problem calls for one and a small, supported integration is possible.

5. **Make the smallest demonstrated correction.** Change one cause at a time,
   replay the same sequences, and compare the same crops and motion. Add a
   focused regression that fails before the correction. A sharpening step is
   optional only after reconstruction is correct and residual softness is the
   issue; it cannot substitute for missing history or bad motion. Keep diagnostic
   capture and experimental switches out of the quiet runtime.

6. **Accept the result in the quiet game.** Use the latest save for the decisive
   comparison, then check the corrected path at the remaining qualities and
   briefly through a camera/dialogue transition if the fix touches history.
   Run the relevant synthetic/hook checks and replay with Metal validation.
   Recheck the known Apple kernel fault on the problematic sequence without
   excluding MetalFX kernels or altering BG3 jitter. Measure quiet-build frame
   times only if quality changes add work. Restore settings changed by the
   experiment and close the game after testing.

## Completion criteria and constraints

Static thin edges should accumulate useful detail instead of remaining visibly
pixelated; slow camera movement should improve without new trails or unstable
foliage. Show the current and corrected images/motion to the user for acceptance.
Spatial is a useful visual reference, not a requirement for identical pixels.
Record shader-validation status separately from image-quality and stability
results. If supplied data is correct but MetalFX still fails, retain a minimal
local reproducer and state the remaining framework limitation.

Preserve BG3's original jitter table, native Off/FSR behavior, and independent
Spatial AA. Temporal continues to replace TAA. No FSR fallback, per-frame history
reset, or unrelated renderer/menu repair is part of the solution.

## References

- [Current evidence](validation/README.md)
- [Earlier input analysis](validation/history/2026-10-11-temporal-quality.md)
- [Mac shader conventions](reference/mac-renderer.md)
- [Windows DLSS investigation](reference/windows-dlss.md)
- [Apple's MetalFX integration and input-validation guidance](https://developer.apple.com/videos/play/wwdc2022/10103/)
- [MetalFX motion-vector jitter interpretation](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerdescriptor/isjitteredmotionvectorsenabled)
- [MetalFX pre-exposure contract](https://developer.apple.com/documentation/metalfx/mtlfxtemporalscalerbase/preexposure)
