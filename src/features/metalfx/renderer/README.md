# MetalFX Renderer

Part of the [metalfx](../README.md) feature (`BG3MFX_FEATURE_METALFX`); not a
feature of its own.

## Behavior

Does MetalFX's rendering work from BG3's Metal calls: it tracks the scene
through TAA and post-processing, replaces FSR and RCAS with the MetalFX
Spatial or Temporal scalers, skips FSR_Tonemap, composes and presents Frame
Generation's pairs (with stand-in drawables), and applies Dynamic
resolution's draw corrections.

## Implementation

[`MetalFXRenderer.mm`](MetalFXRenderer.mm) is metal-hooks' renderer extension
([`MetalHooksInternal.h`](../../metal-hooks/MetalHooksInternal.h)).
metalfx's install registers it (`BG3MFXInstallMetalFXRenderer`) and its
activation hooks `CAMetalLayer` for Frame Generation's stand-in drawables
(`BG3MFXActivateMetalFXRenderer`). metal-hooks calls it at command buffer and
encoder creation, render and compute pipeline creation and bind, the draws
of the pipelines it recognized, compute dispatch, encoder end, present and
commit.

The test runtime (`libBG3MetalFXTest.dylib`, built with
`BG3MFX_STANDALONE_TEST_HOOKS`) runs outside BG3, where metalfx's native
parts and menu cannot install; there metalfx installs only this renderer, so
the Spatial, Temporal and Frame Generation hook regressions exercise it on
synthetic frames.

## Improvement

This folder holds the renderer side of MetalFX's improvements (see
[metalfx](../README.md)). Hook-overhead probe (synthetic, offscreen, 20,000
draws): about 144–150 ns per draw in scaling mode 3 with metalfx on.
