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
Two more things stopped the choice from sticking, found in a live test:

- `VideoOptionsManager::ApplyTickBox` drops a ticked CAS box while the native
  type is 1 to 3 (`b.lo` at `0x10329060c`, patched to a nop; checked against
  the original word first). Its anti-aliasing check never applies, because TAA
  is value 2.
- `rf::GraphicSettings::SetResolutionUpscaleFSR1`, which BG3's type and quality
  callbacks and MetalFX's own quality restore call, always clears CAS. The
  metalfx menu code saves the manager's CAS byte (`+0x101`, copied to settings
  `+0xa1` by `PublishSettings`) before those calls and puts it back after,
  showing it on the tick box (`BG3MFXMenuShowTickBoxValue`), and the startup
  publish for Ultra Performance does the same. BG3's own tick callback then
  enables the slider.

Closing Options applies every combo box again, after the CAS tick box, and
some of those applies run BG3's rules that clear CAS (live breakpoints showed the
flag at 1 after the tick store and 0 at the final apply). `applyCombo` in
`MetalFXOptions.mm` therefore saves the CAS flag around each combo's apply while
MetalFX is selected and puts it back.

BG3 also does not save the CAS tick under the FSR type MetalFX runs on: its
saved settings (`graphicSettings.lsx`) omit `CASEnabled` while it is on, and the
next launch loads it off. `MetalFXOptions.mm` keeps the choice itself
(`BG3MFXCASWithMetalFX` in the user defaults, written when the tick changes with
MetalFX selected) and starts the Video options manager with it when the menu is
built at launch.

With Frame Generation the renderer already carries the scene's depth and motion
through BG3's CAS dispatch by name (`MetalFXRenderer.mm`), as it did with Off.

If the hook cannot install, metalfx reports it through `BG3MFXFail` and carries
on, with CAS off with MetalFX as before.

## Status

The rule is covered by `tests/features/metalfx/cas-sharpening/cas_rule_smoke.mm`
(synthetic). Not yet tried live in the game; the quality effect on MetalFX
output is not measured.
