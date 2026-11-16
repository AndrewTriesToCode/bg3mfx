# CAS sharpening with MetalFX

Part of the [metalfx](../README.md) feature (`BG3MFX_FEATURE_METALFX`).

BG3's own sharpener is CAS (FidelityFX Contrast Adaptive Sharpening), the "CAS"
tick box and sharpness slider in Video options. It runs after tone mapping, on
the display-range image, before the UI is composed. BG3 allows it only while
the Upscaling Type is Off: its stage turns itself off for FSR, and the menu
dims the options. MetalFX Spatial and Temporal run on BG3's FSR type
underneath, so CAS was off with them too, and neither MetalFX scaler sharpens
its output. FSR's own sharpening, RCAS, is part of the FSR chain that MetalFX
replaces.

This part lets CAS run with MetalFX Spatial and Temporal, with the player's own
CAS settings. Off and FSR behave as BG3 decides.

## How

`ls::PostProcessStep_CAS::UpdateIsRenderingInternal` sets the stage's rendering
byte to `settings.casEnabled && settings.upscalingType < 1` (checked against a
REA decompile of the same function). [`CASSharpening.mm`](CASSharpening.mm)
hooks it at its second instruction (an entry hook through the `CASRendering`
island) and writes the byte as
`BG3MFXCASRenders(casEnabled, type, mode)`: the same rule, also true while MetalFX
Spatial or Temporal is selected (and not failed back to FSR).

The menu dims the CAS tick box and slider for the upscaling types 1 to 3.
[`MetalFXOptions.mm`](../MetalFXOptions.mm) keeps them available (the slider
while the box is ticked) when MetalFX is selected and this part is installed.
BG3's `PublishSettings` copies the options' values (CAS enabled at settings
`+0xa1`, sharpness at `+0xa4`) whatever the type.

With Frame Generation the renderer already carries the scene's depth and motion
through BG3's CAS dispatch by name (`MetalFXRenderer.mm`), as it did with Off.

If the hook cannot install, metalfx reports it through `BG3MFXFail` and carries
on, with CAS off with MetalFX as before.

## Status

The rule is covered by `tests/features/metalfx/cas-sharpening/cas_rule_smoke.mm`
(synthetic). Not yet tried live in the game; the quality effect on MetalFX
output is not measured.
