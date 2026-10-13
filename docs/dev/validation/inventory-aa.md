# Inventory anti-aliasing correction

October 11, 2026. The user reported inventory character shimmer only with
Temporal selected. Spatial with native TAA did not show it.

## Cause and correction

The Temporal hook suppressed every eligible `PPTAA_PS` draw before confirming
that its view used the upscaling stage. Inventory renders a separate 933×920
view without FSR or MetalFX. Removing its TAA left jittered, unfiltered color.

The hook now learns exact TAA target identities only after their tracked color
successfully reaches the FSR replacement stage. Other views retain native TAA.
New world targets retain AA during discovery and reset Temporal history before
and after that frame. Weak identities do not retain old textures or match newly
allocated textures merely because their addresses coincide. This does not
change engine offsets, the native jitter sequence, or the installed bundle.

## GPU evidence

Ignored local captures:

- `build/temporal-quality/inventory-temporal.gputrace`: before fix, three frames.
- `build/temporal-quality/inventory-temporal-fixed.gputrace`: after fix, three
  frames, 4.1 GiB, captured from PID 9099.

Before: inventory `commands/cb2/re35` contains no TAA draw, followed by an
injected raw-current-color copy. After: `cb2/re35/draw0`, `cb8/re35/draw0`, and
`cb14/re35/draw0` execute native `PPTAA_PS` at 933×920. The subsequent copy
preserves the native TAA history. World TAA remains suppressed at `cb5/re52`,
and world MetalFX input/output copies remain 1505×847 → 2560×1440 in all three
frames. Inventory still renders at its own full target resolution.

## Validation and limits

`make test test-python` passes for quiet and diagnostic libraries. The renderer
hook regression checks retained native AA on a same-size auxiliary view, world
AA suppression, and a newly allocated world target's discovery frame. A separate
`MTL_DEBUG_LAYER=1` renderer-hook run passes. The user confirms the displayed
inventory character is steadier after relaunch.

GPU pass inspection proves routing, not long-term image-quality convergence.
CLI captures were not claimed to include MetalFX temporal scaler history.
The previously reported private MetalFX shader-validation errors remain a
separate unresolved issue. World foliage shimmer also remains under investigation.

Adding inventory upscaling would require a separate reduced-resolution view
configuration, input association, and Temporal history. It is not part of this
AA restoration. Engine reuse of one live texture object across different views
has not been exhaustively tested.
