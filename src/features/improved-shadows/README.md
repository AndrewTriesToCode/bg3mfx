# Improved Shadows

Technical name: `improved-shadows`.

Opt-in with `BG3MFX_FEATURE_IMPROVED_SHADOWS=1` (the `bg3mfx` launcher sets
it). It requires custom-render-stages and custom-pipeline-bundles
([`CustomRenderStages.h`](../custom-render-stages/CustomRenderStages.h),
[`CustomPipelineBundles.h`](../custom-pipeline-bundles/CustomPipelineBundles.h)) and calls BG3
functions at the supported build's addresses, so it runs only on that build.
It draws improved sun shadows, without BG3's terrain seams and
low-resolution darkening. Without the feature, BG3's shadows are unchanged,
for comparison. It is independent of
[duplicate-shadow-fix](../duplicate-shadow-fix/README.md): this feature
changes how the shadow mask is drawn, that one how many times the shadow maps
are rendered.

This was the separate shadows feature (Shadow Rendering Optimizations,
`BG3MFX_FEATURE_SHADOWS`), then part of the former improved-render-engine
feature.

## Behavior

BG3's sun shadow mask draws dotted lines and diamond patches on terrain, and
darkens slopes facing away from the sun. Both get worse at low render
resolution and grazing views, so they are most visible with upscaling and
Dynamic resolution. They happen in BG3 without bg3mfx.

bg3mfx replaces BG3's shadow mask shaders with its own, using the G-buffer's
per-pixel normal:

- `DirLight_Cascaded_PCSS_<cascades>x<1024|2048>`: Medium (1024) and High
  (2048) shadows;
- `DirLight_Cascaded_PCF_<cascades>x1024`: Low shadows.

If BG3 has no G-buffer normal for a frame (during Bink videos, for example),
bg3mfx's shader draws it without a normal offset.

## Cause

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

## Implementation

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
- [`ImprovedShadows.mm`](ImprovedShadows.mm) works inside BG3's renderer,
  so BG3 builds and binds the pipeline itself
  ([plan and native facts](native-shadows-plan.md)):
  - **Clones.** BG3's `CascadedShadowMaskStage::Load` loads 12 programs (3
    quality rows × 1-4 cascades). At the first Load, bg3mfx compiles the
    shader source on BG3's device, specializes it for each row and cascade
    count, and makes 12 clones of BG3's programs with it
    ([custom-pipeline-bundles](../custom-pipeline-bundles/README.md)). It logs
    `improved shadows: ready` to os_log category `shadow`, or why BG3's
    shaders were kept.
  - **Load, Unload and StartRecording overrides**
    ([custom-render-stages](../custom-render-stages/README.md)). Load puts the
    clones in each stage's table, in place of BG3's. BG3's Load takes its
    programs from BG3's shader cache by name, so every stage holds the same
    12, and one copy is kept. Unload puts them back before BG3's Unload
    calls `RemoveShader` on each, so BG3 never releases the clones, which
    every stage shares. A stage whose programs differ from the stages
    holding the clones would keep BG3's (logged); this hasn't been seen.
  - **The G-buffer normal.** BG3 doesn't bind GBuffer0 to this pass. Each
    frame, before BG3's `StartRecording` schedules the stage's kernel, the
    override looks GBuffer0 up as the kernel looks up its own textures and
    records its bind at fragment texture 6 with BG3's `SetTextureSafe`, at
    the head of the stage's command list. Nothing in BG3's code is patched.
    - The bind holds through the kernel's subpass. `BeginRenderSubPass`
      resets the renderer's highest bound slot, not its texture table; the
      kernel's own binds (fragment 0-5 and 36) raise it to 36 again, and
      `PreDraw` sends slots 0-36, including 6. A slot above 36 would be
      dropped: the first version bound at slot 40 after `BeginRenderPass`,
      before the subpass, and displayed, the shadows flashed, showing
      correctly about one frame a second.
    - Slot 6 is `ShadowMask` in BG3's lighting shaders, which bind it
      themselves; stale table entries are normal, since every BG3 stage
      binds what its shader reads.
    - Without a GBuffer0, the override still binds the empty result.
      `SetTextureSafe` binds BG3's transparent default texture for a texture
      it doesn't know. Its alpha reads 0, while RG16Float's reads 1, so the
      shader takes no normal: no normal offset, only its minimum depth bias,
      and no back-face flip. In the first live run of the StartRecording
      override it happened only at startup, likely during the Bink videos.
    - On a list that binds immediately, `SetTextureSafe` binds at once
      instead of recording. That path hasn't been seen or tested live.
  - An earlier version of this path patched the kernel's
    `SetAndBindViewportInternal` call (`0x105d491fc`) with an island and an
    assembly trampoline that bound at slot 40 after the subpass. It was
    replaced before running live.
- The previous implementation swapped pipelines at the Metal level through
  metal-hooks. It is in git history (before this change); metal-hooks keeps
  its draw-replacement API.

## Planned: live check of the native path

The native path has been checked synthetically only (below). A live check
should show `improved shadows: ready` in the `shadow` log, the same displayed
results as before, and in a GPU capture BG3's own pipeline with
`BG3MFXImprovedShadows` as its fragment function and GBuffer0 at fragment
texture 6 at the draw. The first live run (bound at slot 40 after
`BeginRenderPass`) flashed; the StartRecording version hasn't been run live
yet.

## Improvement

Visual, not a speed change; the cost estimate is the last item below.

### Results

- Synthetic, offscreen (`make test`, `improved-shadows-smoke`, in
  `tests/features/improved-shadows/`): all 12 variants (1-4 cascades × PCSS 1024,
  PCSS 2048, PCF 1024) compile. On a ground plane under a checkerboard of
  blockers, both filters shadow every pixel well inside a blocker square and
  light every pixel well inside an open square, at 64×64 and 16×16; the sky
  stays lit. With a 1×1 transparent RGBA8 texture in place of GBuffer0, both
  match at 64×64 without a normal offset (a poisoned copy of the branch
  failed only those two runs, so the branch is taken).
- Synthetic (`make test`, `native-shadows-smoke`): against a stand-in stage
  and stand-ins for BG3's calls, the first Load makes 12 clones from Load's
  `.bshd` paths in row order, with specialized fragment functions compiled
  on the system device. They replace each stage's programs, are shared
  across stages, and are not retried after a failure. StartRecording binds
  GetTextureSRV's GBuffer0 at fragment slot 6 on the stage's list before
  BG3's StartRecording runs, with the clones in the table; without a
  GBuffer0 it binds the empty result and the clones stay. Unload hands BG3
  its programs, a stage with differing programs keeps BG3's, and after the
  last Unload a new set of programs is taken. The subpass behaviour it relies on is read from the code, not
  tested.
- Live, M5 Pro, BG3 4.1.1.7631656, MetalFX Temporal at a low render size,
  High and Medium (PCSS), with the same shader through metal-hooks (the
  previous implementation), on the development path to this design:
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
