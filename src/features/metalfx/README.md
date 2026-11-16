# MetalFX

Technical name: `metalfx`.

Opt-in with `BG3MFX_FEATURE_METALFX=1` (the `bg3mfx` launcher sets it).
Requires custom-menu and metal-hooks, which it turns on too, and the supported
ARM64 executable.

## Behavior

Adds the MetalFX options to Options → Video:

- **MetalFX Spatial** and **MetalFX Temporal**, two more Upscaling Types.
- **Ultra Performance**, an Upscaling Quality offered with Temporal that renders
  the smallest region the device allows (1/9 of the pixels on the M5 Pro).
- **MetalFX AA**, an Anti-Aliasing entry: MetalFX Temporal at 1x scale, with no
  upscaling. It is selected (and dimmed) automatically while a Temporal upscaler
  is on; picking it with Upscaling Type Off runs Temporal at native resolution
  (Upscaling Quality stays dimmed, as with Off). It is offered only with Off
  and MetalFX Temporal: with AMD FSR 1.0 or MetalFX Spatial it is not in the
  list. Picking another Anti-Aliasing option or Upscaling Type ends it; FSR and
  Spatial return to the player's previous Anti-Aliasing choice.
- **MetalFX Frame Generation**, a checkbox shown on devices that support it. It requires BG3's VSync (Double or
  Triple Buffering): it is dimmed while VSync is Off, and choosing VSync Off while
  it is ticked snaps back to the previous setting.

The parts:

- [Spatial upscaling](spatial-upscaling/README.md)
- [Temporal upscaling](temporal-upscaling/README.md), with its jitter
- [Ultra Performance](ultra-performance/README.md)
- [Frame generation](frame-generation/README.md)

## Implementation

[`MetalFX.mm`](MetalFX.mm) registers the feature, the only one in this
folder. Its install puts in each part, in order:

1. Temporal's native jitter ([`TemporalJitter.mm`](temporal-upscaling/TemporalJitter.mm)).
   If it cannot install it shows "MetalFX could not start" and the install
   fails, so root skips metalfx.
2. Ultra Performance ([`UltraPerformance.mm`](ultra-performance/UltraPerformance.mm)),
   optional: if it cannot install, metalfx reports it through `BG3MFXFail` and
   carries on without Ultra Performance.
3. The renderer ([`MetalFXRenderer.mm`](renderer/MetalFXRenderer.mm)), below.
4. The options, registered with custom-menu.

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

[`MetalFXRenderer.mm`](renderer/MetalFXRenderer.mm) is the renderer work
([renderer](renderer/README.md)). metalfx's install registers it as metal-hooks'
renderer extension
([`MetalHooksInternal.h`](../metal-hooks/MetalHooksInternal.h)),
and metalfx's activation hooks `CAMetalLayer` for Frame Generation's stand-in
drawables. metal-hooks calls it at:

- command buffer and encoder creation;
- render and compute pipeline creation, and each pipeline bind;
- draws of the pipelines it recognized (other draws take metal-hooks' fast
  path);
- compute dispatch, encoder end, present and commit.

From those it tracks the scene through TAA and post-processing, replaces FSR
and RCAS with the MetalFX scalers, skips FSR_Tonemap, composes and presents
Frame Generation's pairs.
Hook-overhead probe (synthetic, offscreen, 20,000 draws): with metalfx on,
the move left the cost per draw the same or slightly lower than before it
(about 144–150 vs 147–155 ns in scaling mode 3).

## Improvement

See each part's README for what was measured and how. Neither the move into
one feature nor the renderer's move out of metal-hooks has been re-checked live.
