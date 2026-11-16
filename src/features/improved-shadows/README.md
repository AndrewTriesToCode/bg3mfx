# Improved Shadows

Technical name: `improved-shadows`.

Opt-in with `BG3MFX_FEATURE_IMPROVED_SHADOWS=1` (the `bg3mfx` launcher sets
it). It requires custom-render-stages, custom-pipeline-bundles and metal-hooks
([`CustomRenderStages.h`](../custom-render-stages/CustomRenderStages.h),
[`CustomPipelineBundles.h`](../custom-pipeline-bundles/CustomPipelineBundles.h),
[`MetalHooks.h`](../metal-hooks/MetalHooks.h)) and calls BG3 functions at the
supported build's addresses, so it runs only on that build. Without the
feature, BG3's shadows are unchanged, for comparison.

It has three parts, installed together by
[`ImprovedShadows.mm`](ImprovedShadows.mm):

| Part | Files | What it changes |
| --- | --- | --- |
| [Single sun shadow pass](#single-sun-shadow-pass) | [`DuplicateShadowFix.*`](DuplicateShadowFix.mm) | The sun shadow maps render once per frame instead of twice. |
| [Sun shadow mask](#sun-shadow-mask) | [`ShadowMask.*`](ShadowMask.mm), [`ImprovedShadowsShader.h`](ImprovedShadowsShader.h) | No terrain seams, diamond patches or low-resolution darkening in sun shadows. |
| [Point-light shadows](#point-light-shadows) | [`PointLightShadowFix.*`](PointLightShadowFix.mm) | No black wedges around torches, hearths and other shadowed point lights. |

The sun shadow mask was the separate shadows feature (Shadow Rendering
Optimizations, `BG3MFX_FEATURE_SHADOWS`), then part of the former
improved-render-engine feature. The single shadow pass was the separate
duplicate-shadow-fix feature and the point-light fix the separate
point-light-shadow-fix feature, until both were folded in here.

## Single sun shadow pass

### Behavior

`BaseApp::InitFrameStages` passes the Shadow pack twice, so the game, player
and offscreen views each get two `CascadedShadowBufferStage`s. Both render the
same four cascades and the incrementally updated layer into the same maps
(re6–re10 and re29–re33 in a frame capture),
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
feature, then the separate duplicate-shadow-fix feature
(`BG3MFX_FEATURE_DUPLICATE_SHADOW_FIX`).

### Implementation

[`DuplicateShadowFix.mm`](DuplicateShadowFix.mm) builds the lists from
`BG3MFXStagePack` and registers them with `BG3MFXSetViewStages`, which checks
them against the stage types BG3 builds and their lookup order;
custom-render-stages installs them at its activation.
[`duplicate_shadow_fix_smoke.mm`](../../../tests/features/improved-shadows/duplicate_shadow_fix_smoke.mm)
checks the lists each view receives against BG3's (synthetic, CPU only).

### Improvement

Estimated, not yet measured as its own feature: the same as the former
shadows feature's duplicate fix, which removed the same pass. That fix
measured 73.9 to 86.0 fps and HUD GPU time 14.0 to 11.75 ms (displayed, M5
Pro, BG3 4.1.1.7631656, Ultra, Upscaling Off, windowed, same save and
camera), with shadow passes 10 to 5 per frame.

## Sun shadow mask

### Behavior

BG3's sun shadow mask draws dotted lines and diamond patches on terrain, and
darkens slopes facing away from the sun. Both get worse at low render
resolution and grazing views, so they are most visible with upscaling and
reduced render resolution. They happen in BG3 without bg3mfx.

bg3mfx replaces BG3's shadow mask shaders with its own, using the G-buffer's
per-pixel normal:

- `DirLight_Cascaded_PCSS_<cascades>x<1024|2048>`: Medium (1024) and High
  (2048) shadows;
- `DirLight_Cascaded_PCF_<cascades>x1024`: Low shadows.

If BG3 has no G-buffer normal for a frame (during Bink videos, for example),
bg3mfx's shader draws it without a normal offset.

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
- [`ShadowMask.mm`](ShadowMask.mm) works inside BG3's renderer,
  so BG3 builds and binds the pipeline itself
  ([plan and native facts](native-shadows-plan.md)):
  - **Clones.** BG3's `CascadedShadowMaskStage::Load` loads 12 programs (3
    quality rows × 1-4 cascades). At the first Load, bg3mfx compiles the
    shader source on BG3's device, specializes it for each row and cascade
    count, and makes 12 clones of BG3's programs with it
    ([custom-pipeline-bundles](../custom-pipeline-bundles/README.md)). If that
    fails, it reports why through `BG3MFXFail` and keeps BG3's shaders.
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

### Live check of the native path

November 1, 2026 (displayed, M5 Pro, BG3 4.1.1.7631656, with
metalfx and the former duplicate-shadow-fix): `improved shadows: ready` was logged at
startup, and the user saw correct sun shadows, with no flashing, dotted
lines, diamond patches or dark slopes, at High and Low Shadow Quality,
with Upscaling Off and with MetalFX Temporal. No GPU capture was taken, so
the pipeline and the slot-6 bind were not inspected at the draw. The first
live run of this path (bound at slot 40 after `BeginRenderPass`) had
flashed.

### Improvement

Visual, not a speed change; the cost estimate is the last item below.

#### Results

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
- Low (PCF): checked live on November 1 through the native path (above).
- Cost: one extra texture read (RG16Float at the pixel) and its decode per
  pixel, against 16-24 shadow-map samples (PCSS) or 6-17 (PCF); BG3's
  derivative normal and quad pooling are skipped. Estimated at a few percent
  of a render-resolution pass; not measured.

## Point-light shadows

### Behavior

Point lights with shadows, such as a carried torch or a hearth, throw big
straight-edged black wedges on the floor around them. This happens in BG3
without bg3mfx. With this fix, those lights cast only the shadows of what is
really between them and the surface.

### Cause

Seen in captures of an interior courtyard (November 14, 2026, M5 Pro, BG3
4.1.1.7631656): Gale holding a torch, with captures taken with the torch out
and with it put away.

- BG3 renders a shadowed point light as four tetrahedron faces into one
  1024² tile of the 8192² local-light shadow atlas, through a 2048²
  Depth32Float target and `LinearizeDepth`. Each face has its own viewport,
  half of the tile (face 0 the bottom, 1 the right, 2 the top, 3 the left
  half), and its frustum is a full rectangle. Only a triangle of each half
  belongs to the face: `ClusteredLighting_*` picks the face whose normal is
  closest to the direction, then samples that face's projection.
- The halves overlap, so each face has to be clipped to its triangle. BG3's
  shadow vertex shaders declare a `TetrahedronClipDistances[4]` output for
  that, but none computes it: the material shaders leave it unset and
  `TerrainDEP_VS` writes zeros. Every face draws its whole half, and the
  depth test keeps the nearest of two faces' surfaces in the shared quarters.
- The lighting then reads another face's depth as an occluder. The floor
  here is terrain, a large caster right below the light, so the wedges are
  strongest on the floor. In the torch capture, the last face's terrain draw
  alone covers 246 8×8 blocks of face 0's triangle. Emulating the lighting's
  lookups against the captured atlas reproduces the two pairs of wedges.
- Non-tetrahedral shadow views (spot lights and orthographic views) have
  `g_TetrahedronFaceIndex` −1 and are not affected.

### Implementation

[`PointLightShadowFix.mm`](PointLightShadowFix.mm) takes
[metal-hooks](../metal-hooks/README.md)' draw
replacement, has it record fragment buffer 11 (BG3's `_PerCamera`), and
watches render passes for the depth target's size:

- **Claim.** Depth-only pipelines into a Depth32Float target (BG3's shadow
  casters, with or without an alpha-test fragment function) are claimed as
  they are. For BG3's atlas `LinearizeDepth` (R16Unorm target), the feature
  builds a compositing clone with BG3's descriptor and its own fragment
  function. The main-depth `LinearizeDepth` writes R32Float and is left alone.
- **Faces.** For a caster draw whose `_PerCamera` has
  `g_TetrahedronFaceIndex` 0–3 and whose viewport is one of BG3's half-tile
  face viewports, it notes the light's tile. Each face is drawn into a region
  of its own, then BG3's viewport is set again: the viewport moved by
  (face & 1, face >> 1) regions, so the four faces cannot overwrite each
  other. A region is the tile's size when two tiles fit in the 2048² target
  (face 0 then stays where it is). A close light gets a 2048² tile that fills
  the target; its faces are then drawn at half resolution into 1024² regions.
  Nothing is moved when the faces would drop below a quarter of their
  resolution, or when BG3 has set a scissor.
- **Copy.** The next atlas `LinearizeDepth` draw on that thread uses the clone
  ([`PointLightShadowFix.h`](PointLightShadowFix.h)): BG3's bindings and math
  (decoded from its AIR), reading each tile texel from the face whose
  triangle holds it, scaled to the region. The tile's diagonals divide the triangles: checked
  against `ClusteredLighting`'s face choice and BG3's projections for every
  4th texel of the torch's tile, they agree wherever a texel is looked up at
  all. Other atlas copies (spot lights, orthographic views) run BG3's.
- If the clone can't be built, it reports it through `BG3MFXFail` and BG3
  keeps its own pipelines; the rest of the feature is unaffected.

#### Limits

- Each moved face draw costs two extra viewport binds; the copy reads one
  texel per output texel, as BG3's does.
- A close light's 2048² tile is drawn at 1024² per face, so its shadows have
  the detail of a light at normal distance rather than BG3's.
- Texels on a triangle's edge go to one face by the diagonal rule, as with
  any tetrahedron shadow map.
- A first prototype instead clipped faces with a fragment function added to
  the casters. It could not reach the 127 of 166 casters in the torch's pass
  that already have BG3's own fragment functions, and the wedges stayed.

### Improvement

Visual, not a speed change.

#### Results

- Synthetic, offscreen (`make test`, `point-light-shadow-fix-smoke`, in `tests/features/improved-shadows/`):
  shadow casters with and without a fragment function are claimed, as is the
  atlas `LinearizeDepth`; main-view depth pipelines and the R32Float
  `LinearizeDepth` are not. BG3's four face viewports give the light's tile,
  and face −1 views are left alone. With BG3's face projections, every face
  covering its whole viewport, and the lighting's lookups for 64×128
  directions: BG3's layout leaves 50% of lookups reading another face's
  depth, the fix 0%, and also 0% with half-resolution faces when the tile
  fills the target.
- Live, displayed (Gale's torch in the courtyard): the floor wedges are gone
  at normal camera distance and up close, where BG3 gives the torch a 2048²
  tile and the faces are drawn at half resolution.
- Not this fix: a light-shaft shadow on a column that is soft from afar and
  turns sharp and darker up close. That light is orthographic (face −1), so
  the fix leaves it to BG3, which renders it into a 256² tile from afar and a
  512² tile up close.
