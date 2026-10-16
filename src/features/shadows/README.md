# Shadow Rendering Optimizations

Technical name: `shadow-rendering-optimizations`.

This feature groups two shadow-rendering changes. Duplicate-stage elimination
is enabled by default and skips the first of two identical cascaded-shadow
stages whose maps are overwritten before any reader uses them. A separate
low-resolution vista experiment is opt-in (`BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS_VISTA=1`), disabled
by default, and renders an identified distant-shadow submission at half
resolution while keeping near shadows native. The implementation identifiers
are `shadow-stage-deduplication` and `low-resolution-vista-shadows`.

The stage fix is in
[`ShadowDuplicateFix.mm`](../../../src/features/shadows/ShadowDuplicateFix.mm).
The vista prototype is in [`VistaShadows.mm`](../../../src/features/shadows/VistaShadows.mm)
and uses shared renderer interception in
[`Trace.mm`](../../../src/integration/renderer/Trace.mm).

The duplicate-stage fix was measured live on an M5 Pro, BG3 4.1.1.7631656,
Ultra, Upscaling Off, windowed, same save and camera: 73.9 to 86.0 fps, HUD GPU
time 14.0 to 11.75 ms, and shadow passes 10 to 5 per frame. The user saw no
shadow difference; no post-fix GPU capture was taken. This result belongs to
the duplicate-stage fix alone. No performance gain is measured for Smart
Shadows. Its guarded target and descriptor shape are verified, and its atlas
operations pass offscreen validation, but corrected reduced rendering has not
been validated live for image quality or speed. See [performance analysis](../../../docs/dev/performance.md),
[Vista-shadow probe](../../../docs/dev/validation/smart-shadows-probe.md),
[vista-shadow plan](../../../docs/dev/smart-shadows-plan.md), and
[current validation](../../../docs/dev/validation/README.md).
