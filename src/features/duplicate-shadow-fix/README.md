# Duplicate Shadow Fix

Technical name: `duplicate-shadow-fix`.

Opt-in with `BG3MFX_FEATURE_DUPLICATE_SHADOW_FIX=1` (the `bg3mfx` launcher
sets it). It renders the sun shadow maps once per frame instead of twice. It
requires custom-render-stages
([`CustomRenderStages.h`](../custom-render-stages/CustomRenderStages.h)),
which runs only on the supported build. It doesn't patch game code itself:
custom-render-stages replaces vtable entries, and a view kind the feature
doesn't list keeps BG3's stages. It is independent of
[improved-shadows](../improved-shadows/README.md).

## Behavior

`BaseApp::InitFrameStages` passes the Shadow pack twice, so the game, player
and offscreen views each get two `CascadedShadowBufferStage`s. Both render the
same four cascades and the incrementally updated layer into the same maps
(re6–re10 and re29–re33 in the
[baseline capture](../../../docs/dev/baseline/frame-capture.md#findings)),
and nothing reads the first pass's maps before the second redraws them.

The feature registers BG3's own lists with the second Shadow pack removed:

| View kind | Packs |
| --- | --- |
| Game, Player | First, Shadow, Second, Third |
| Offscreen | First, EarlyVtResolve, Shadow, Second, Third, Additional |
| Fullscreen | BG3's (no shadow stage) |

The first stage is kept because the stages that hold a pointer to the shadow
buffer (Alpha, Lighting, CascadedShadowMask, VertexProcessing) look it up
by first match when they are created. The shadow maps are still complete
before CascadedShadowMask (re34), their first reader.

The game view's list assumes its frame isn't offscreen (it never was in the
traces); an offscreen game frame would also need EarlyVtResolve and
Additional.

This was first a code patch in the former shadows feature, which removed
BG3's first Shadow call, then a change in the former improved-render-engine
feature.

## Implementation

[`DuplicateShadowFix.mm`](DuplicateShadowFix.mm) builds the lists from
`BG3MFXStagePack` and registers them with `BG3MFXSetViewStages`, which checks
them against the stage types BG3 builds and their lookup order;
custom-render-stages installs them at its activation. The diagnostic trace
records `duplicateShadowFixRegistered`.
[`duplicate_shadow_fix_smoke.mm`](../../../tests/features/duplicate-shadow-fix/duplicate_shadow_fix_smoke.mm)
checks the lists each view receives against BG3's (synthetic, CPU only).

## Improvement

Estimated, not yet measured as its own feature: the same as the former
shadows feature's duplicate fix, which removed the same pass. That fix
measured 73.9 to 86.0 fps and HUD GPU time 14.0 to 11.75 ms (displayed, M5
Pro, BG3 4.1.1.7631656, Ultra, Upscaling Off, windowed, same save and
camera), with shadow passes 10 to 5 per frame.
