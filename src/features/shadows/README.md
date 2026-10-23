# Shadow Rendering Optimizations

Technical name: `shadow-rendering-optimizations`.

This feature, on by default, has two parts:

- it removes BG3’s duplicate cascaded-shadow stage;
- it draws improved sun shadows, without BG3's terrain seams and low-resolution
  darkening.

`BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS=0` turns both off and leaves BG3's
shadows unchanged, for comparison.

## Duplicate shadow stage

The first of the two identical stages writes maps that are overwritten before
any reader uses them.

The implementation is in
[`ShadowDuplicateFix.mm`](../../../src/features/shadows/ShadowDuplicateFix.mm).
The fix was measured live on an M5 Pro, BG3 4.1.1.7631656, Ultra, Upscaling
Off, windowed, same save and camera: 73.9 to 86.0 fps, HUD GPU time 14.0 to
11.75 ms, and shadow passes 10 to 5 per frame. The user saw no shadow
difference; no post-fix GPU capture was taken. See
[performance analysis](../../../docs/dev/performance.md) and
[current validation](../../../docs/dev/validation/README.md).

## Improved shadows


BG3's sun shadow mask draws dotted lines and diamond patches on terrain, and
darkens slopes facing away from the sun. Both get worse at low render
resolution and grazing views, so they are most visible with upscaling and
Dynamic resolution. They happen in BG3 without bg3mfx.

bg3mfx replaces BG3's shadow mask shaders with its own, using the G-buffer's
per-pixel normal:

- `DirLight_Cascaded_PCSS_<cascades>x<1024|2048>`: Medium (1024) and High
  (2048) shadows;
- `DirLight_Cascaded_PCF_<cascades>x1024`: Low shadows.

The replacement is part of Shadow Rendering Optimizations; with
`BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS=0`, BG3's shaders run. It needs the
launcher (MetalFX hooks on). If the G-buffer normal can't be found, or its
size differs from the depth buffer, BG3's own draw runs.

### Cause

BG3 rebuilds a surface normal for each 2×2 pixel quad from screen-space
derivatives of the depth-reconstructed position. Both shaders use that normal
for:

- a normal-offset bias of about one shadow-map texel;
- a weight that fades the offset into a constant depth bias on grazing or
  non-planar quads;
- (PCSS only) deciding whether the quad pools its blocker search.

A quad that straddles two terrain triangles gets a blended normal and a
planarity failure. Its offset, bias and penumbra then differ from its
neighbours', which shows up as the dotted triangle edges and diamond patches.
Lower resolution makes each quad span more ground.

The fade also darkens slopes at low resolution. The footprint is measured per
screen pixel, so at low render resolution the weight rises across large areas
and the small constant bias replaces the normal offset; slopes facing away
from the sun then partly shadow themselves.

### Implementation

- [`ImprovedShadowsShader.h`](ImprovedShadowsShader.h) holds the Metal
  source, with function constants for cascade count, map size and filter
  (PCSS or PCF). It keeps BG3's bindings, cascade selection and blending,
  sample patterns, filter radii and distant (vista) shadows, and changes the
  normal:
  - each pixel's normal comes from GBuffer0 (stereographic, view space),
    rotated to world space as BG3's lighting pass does; nothing depends on
    the 2×2 quad;
  - the full normal offset applies everywhere: there is no fade to a constant
    bias and no quad blocker pooling.

  The G-buffer normal includes bump-map detail, so shadow edges can follow it
  slightly. Live, the user preferred this over keeping BG3's derived normal on
  planar quads (which avoids bump detail but still depends on the quad).
- [`ImprovedShadows.mm`](ImprovedShadows.mm) works with the renderer hooks:
  - when BG3 creates a PCSS or PCF shadow mask pipeline, it builds the
    matching bg3mfx pipeline from BG3's descriptor (BG3's vertex shader and
    attachments), logging `improved shadows: <name> ready` to os_log category
    `shadow`;
  - it records GBuffer0, colour 0 of the G-buffer pass, against GBuffer2 (colour
    2), which the shadow pass binds;
  - at the shadow draw, it swaps the pipeline, binds GBuffer0 at fragment
    texture 40, draws, then restores BG3's pipeline.
- [`Trace.mm`](../../integration/renderer/Trace.mm) calls these hooks from
  pipeline creation, `renderCommandEncoderWithDescriptor:` and the
  non-indexed draw hooks.

### Results

- Synthetic, offscreen (`make test`, `improved-shadows-smoke`, in
  `tests/features/shadows/`): all 12 variants (1-4 cascades × PCSS 1024,
  PCSS 2048, PCF 1024) compile. On a ground plane under a checkerboard of
  blockers, both filters shadow every pixel well inside a blocker square and
  light every pixel well inside an open square, at 64×64 and 16×16; the sky
  stays lit.
- Live, M5 Pro, BG3 4.1.1.7631656, MetalFX Temporal at a low render size,
  High and Medium (PCSS), on the development path to this design:
  - a reproduction of BG3's PCSS pass (since removed) matched BG3 exactly on
    99.98-99.99% of pixels and within 1/255 on 100.000%, so the shader's
    shared structure follows BG3's;
  - the G-buffer normal was within 0.05 (1 - cos) of BG3's derived normal on
    only about 80% of planar-quad pixels: it carries bump detail;
  - displayed, G-buffer normal on every quad with the fade kept: diamonds and
    dotted lines gone, bump-map ripples in their place;
  - displayed, with the fade removed: slopes "major improved", with no
    speckle or striping;
  - displayed, G-buffer normal on every pixel with no fade (this design): the
    user judged it good on terrain, foliage, decals and hair.
- Low (PCF): synthetic only; not yet checked live.
- Cost: one extra texture read (RG16Float at the pixel) and its decode per
  pixel, against 16-24 shadow-map samples (PCSS) or 6-17 (PCF); BG3's
  derivative normal and quad pooling are skipped. Estimated at a few percent
  of a render-resolution pass; not measured.
