# MetalFX

Technical name: `metalfx`.

Opt-in with `BG3MFX_FEATURE_METALFX=1` (the `bg3mfx` launcher sets it).
Requires custom-menu, metal-hooks and metalfx-renderer, which it turns on too,
and the supported ARM64 executable.

## Behavior

Adds the MetalFX options to Options → Video:

- **MetalFX Spatial** and **MetalFX Temporal**, two more Upscaling Types.
- **Dynamic**, an Upscaling Quality offered with Temporal, together with its
  Upscaler Target Minimum FPS slider and Dynamic Upscaler Thermal Guard
  checkbox.
- **MetalFX Frame Generation**, a checkbox shown on devices that support it.

The parts:

- [Spatial upscaling](spatial-upscaling/README.md)
- [Temporal upscaling](temporal-upscaling/README.md), with its jitter
- [Dynamic resolution](dynamic-resolution/README.md)
- [Frame generation](frame-generation/README.md)

## Implementation

[`MetalFX.mm`](MetalFX.mm) registers the feature, and its install registers
the options with custom-menu. Two native parts are features of their own,
installed by root:

1. temporal-upscaling ([`TemporalJitter.mm`](temporal-upscaling/TemporalJitter.mm)),
   Temporal's jitter, which metalfx requires. If it cannot install it shows
   "MetalFX could not start" and root skips metalfx.
2. dynamic-resolution ([`DynamicResolution.mm`](dynamic-resolution/DynamicResolution.mm)),
   wanted with metalfx but not required. If it cannot install, root reports
   it in `featureSkipped` and MetalFX carries on without Dynamic.

Its activation restores the saved choices before BG3 creates its first command
buffer, and migrates earlier preference keys.

[`MetalFXOptions.mm`](MetalFXOptions.mm) holds the options. BG3's settings
code accepts only Off and FSR, so a MetalFX type runs BG3's FSR setup for its
quality and render resolution. The MetalFX type itself is tracked separately.
While Temporal or Frame Generation is on, the options also do two things:

- select TAA and dim Anti-Aliasing, restoring the player's choice afterwards;
- dim Upscaling Sharpness, which only FSR uses.

When the type or Frame Generation changes, they call
`BG3MFXMetalFXSelectionChanged`. That retries a failed upscaler after a type
change, and resets Frame Generation and Temporal history.

[`MetalFXRenderer.mm`](MetalFXRenderer.mm) is the renderer work, registered
as its own feature, metalfx-renderer (requires metal-hooks). It is wanted with
`BG3MFX_FEATURE_METALFX=1` and is not native, so the standalone hook
regressions run it outside BG3. Its install registers it as metal-hooks'
renderer extension
([`MetalHooksInternal.h`](../metal-hooks/MetalHooksInternal.h)),
and its activation hooks `CAMetalLayer` for Frame Generation's stand-in
drawables. metal-hooks calls it at:

- command buffer and encoder creation;
- render and compute pipeline creation, and each pipeline bind;
- draws of the pipelines it recognized (other draws take metal-hooks' fast
  path);
- compute dispatch, encoder end, present and commit.

From those it tracks the scene through TAA and post-processing, replaces FSR
and RCAS with the MetalFX scalers, skips FSR_Tonemap, composes and presents
Frame Generation's pairs, and applies Dynamic resolution's draw corrections.
Hook-overhead probe (synthetic, offscreen, 20,000 draws): with metalfx on,
the move left the cost per draw the same or slightly lower than before it
(about 144–150 vs 147–155 ns in scaling mode 3).

## Improvement

See each part's README for what was measured and how. Neither the move into
one feature nor the renderer's move out of metal-hooks has been re-checked live.
