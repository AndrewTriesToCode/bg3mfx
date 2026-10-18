# Shadow Rendering Optimizations

Technical name: `shadow-rendering-optimizations`.

This feature removes BG3’s duplicate cascaded-shadow stage by default. The first
of the two identical stages writes maps that are overwritten before any reader
uses them. `BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS=0` keeps both stages for
comparison.

The implementation is in
[`ShadowDuplicateFix.mm`](../../../src/features/shadows/ShadowDuplicateFix.mm).
The fix was measured live on an M5 Pro, BG3 4.1.1.7631656, Ultra, Upscaling
Off, windowed, same save and camera: 73.9 to 86.0 fps, HUD GPU time 14.0 to
11.75 ms, and shadow passes 10 to 5 per frame. The user saw no shadow
difference; no post-fix GPU capture was taken. See
[performance analysis](../../../docs/dev/performance.md) and
[current validation](../../../docs/dev/validation/README.md).
