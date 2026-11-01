# Plan: improved shadows through BG3's own shader programs

Status: **implemented; synthetic tests only, not yet checked live.** The
previous implementation worked at the Metal level through metal-hooks. This
plan moves it into BG3's renderer, with
custom-pipeline-bundles and custom-render-stages, so BG3 builds and binds our pipeline
itself: no pipeline claim, no per-draw swap, and no dependency on metal-hooks.
It stays a launch-time option, the improved-shadows feature
(`BG3MFX_FEATURE_IMPROVED_SHADOWS=1`), not a runtime toggle. Everything marked Read is from BG3 4.1.1.7631656 (ARM64).

## How BG3 picks the shadow mask program (Read)

`CascadedShadowMaskStage` (`AppStageType` 0x03) draws the sun shadow mask as
one full-screen draw.

- **`Load`** (`0x105d45ac0`) loads 12 programs with
  `ResourceManager::InstantiateShader`, which caches by path and counts
  references. They're from `<default shader path>/Shadows/Generated/DirLight_Cascaded_<PCSS|PCF>_<n>x<1024|2048>.bshd`,
  in 3 quality rows of 4 (1–4 cascades), 0x20 bytes per row:

  | Row | Stage offset | Filter and map size |
  | --- | --- | --- |
  | 0 | +0x2198 (+0x2198, +0x21a0, +0x21a8, +0x21b0) | PCSS 2048 (High) |
  | 1 | +0x21b8 | PCSS 1024 (Medium) |
  | 2 | +0x21d8 | PCF 1024 (Low) |

  Each row's filter comes from `0x1078a0050` = {1, 1, 0} (1 = PCSS) and its
  map size from `0x1078a005c` = {1, 0, 0} (1 = 2048).
- **Each frame**, the kernel (`ExecuteWTKernel`, `0x105d48b44`) reads the shadow
  buffer stage (`[stage+0x2150]`): the quality row (s8 at +0x2658) and the
  cascade count (s32 at +0x2668). It stores
  `[stage + 0x2190 + row*0x20 + count*8]` at **stage+0x2190**
  (`0x105d48f8c`). Then, in order:
  1. `BeginRenderPass` (`bl` at `0x105d4917c`);
  2. reads +0x2190 back for the PrepareDraw (`0x105d49200`, record 0x2b);
  3. the draw (0x2e).
- **`OnStateChanged`** (`0x105d48af8`) only toggles a flag at +0x2270. A
  quality change selects another row the next frame; nothing is reloaded.
- **`Unload`** (`0x105d48588`) calls `ResourceManager::RemoveShader` on each of
  the 12 and clears the slot.
- **Pipelines** are built lazily, for the current pass, at the first draw that
  uses a program. Load creates none.

## Design

1. **Clones, once.** On the first `Load`, make 12 programs with
   `BG3MFXCreateProgram(<the row's .bshd path>, {.fragment = …})`. Each uses
   our fragment function specialized (function constants) for that row's
   filter and map size and that cascade count, from
   `BG3MFXFunctionLibrary("shadows")`. Every view's stage shares the same 12.
   They live until the process exits.
   - The `.bshd` path for the clone is relative to the default shader path,
     as `LoadEngineShader` builds it: `Shadows/Generated/DirLight_Cascaded_…`.
     (Read) `Load` builds its own string instead: a copy of
     `*s_DefaultShaderPath`, then `/Shadows/Generated`, `/DirLight_Cascaded`,
     `_PCSS` or `_PCF`, `_<n>` and `x1024.bshd` or `x2048.bshd`, then
     `Path::Normalize`. It names the same file from the same directory;
     `LoadEngineShader`'s root-1 form is the one every engine shader loads
     through. If a clone fails, BG3's programs stay (logged).
2. **`Load` override** (`BG3MFXOverrideStageMethod(0x03, Load, …)`): call
   BG3's Load and keep its bool. `InstantiateShader` takes each program
   from `ShaderManager::GetShader` by name (Read), so every stage gets the
   same 12 handles: keep one copy and a count of stages holding the clones,
   and write our 12 over stage+0x2198…+0x21f0. If a stage's handles differ
   from that copy while the count is nonzero, leave BG3's (logged).
3. **`Unload` override**: if the stage's table holds the clones, write the
   kept handles back, then call BG3's Unload. Its `RemoveShader` calls (one
   per entry, skipping `0xffc0000000000000`, Read) then release exactly what
   `InstantiateShader` gave, never the clones every stage shares.
4. **`StartRecording` override** (method 7; the stage inherits
   `ls::RenderStage::StartRecording`, `0x1060d914c`, which queues the stage's
   kernel job or runs the kernel, and doesn't reset the list). Before calling
   BG3's, once the clones exist:
   - looks up GBuffer0 with
     `SceneGraph::GetTextureSRV` (hash `0x4c0d1b61`), called as the kernel
     calls it (Read): `(out TextureBindingInfo*, [[stage+0x10]], hash, -1,
     0)`. A null `Texture*` at out+0x00 means not found. The size check of
     the previous implementation is dropped: GBuffer0 and GBuffer2 come from
     the same SceneGraph G-buffer, so they share a size;
   - found or not: `RendererCommandBuffer::SetTextureSafe(list, binding, info)`
     (`0x10642c5c0`) on the stage's list (stage+0x30, the kernel's), with a
     9-byte `sb::Binding` that is 0xff except fragment (+0x05) = 6 and byte
     0 = 1. Byte 0 is 1 in every `SetTextureSafe` call BG3 makes, and
     `MetalRenderer::SetTexture` doesn't read it (Read). The binding goes in
     x1 and w2. `SetTextureSafe` looks the texture up and binds
     `GlobalRenderResources::s_DefaultTransparentTextureID` for one it
     doesn't know, null included, and binds at once on an immediate list
     (list+0x82) (Read). The shader reads alpha 0 there (RG16Float reads 1)
     and drops the normal offset, so no frame needs BG3's programs back.

   Why slot 6 holds (Read): the record replays before the kernel's. The
   kernel's subpass (0x11) writes -1 over the highest-slot bytes (+0x2ad0,
   +0x2ad4) when it opens a new encoder, but doesn't clear the texture tables
   (fragment at +0x24a0); its `03` record clears +0x2ae8..+0x2b68 only. The
   kernel then binds fragment 0-5 and 36 (its `sb::Binding` constants), and
   `PreDraw` sends fragment textures 0 to the highest bound slot, so 6 goes
   with them. A slot above 36 doesn't. Slot 6 is `ShadowMask` in BG3's
   lighting shaders, which bind it themselves.

   (Changed twice.) The first version hooked the `BeginRenderPass` call
   (`0x105d4917c`) and bound at slot 40, above 36: the bind held only on
   frames that kept the encoder, and displayed, the shadows flashed. The
   second patched the kernel's `SetAndBindViewportInternal` call
   (`0x105d491fc`, after the subpass) through an island and an assembly
   trampoline; it was replaced by this override before running live. See
   [texture binding](../../../docs/dev/baseline/command-buffer.md#texture-binding).
5. **Our shader**: `ImprovedShadowsShader.h`'s source, compiled on BG3's
   device at the first Load and specialized 12 times, with GBuffer0 at
   `[[texture(6)]]`. The precompiled `shadows.metallib` was dropped: the
   Metal compiler is a separate download (the Metal toolchain), so a
   Homebrew build would need it, and every other bg3mfx shader compiles from
   source at runtime too. It keeps BG3's other bindings, since the clone
   keeps the base program's binding information.

## What goes away

- metal-hooks' pipeline claim, the render-pass observer for GBuffer0, and the
  per-draw pipeline swap and restore. The feature no longer requires
  metal-hooks.
- Compiling at BG3's first shadow mask pipeline: all 12 specializations
  compile at the first Load instead.

## Facts relied on

- `BG3MFXCreateProgram`, `BG3MFXFunctionLibrary`
  ([custom-pipeline-bundles](../custom-pipeline-bundles/README.md)).
- `BG3MFXOverrideStageMethod` for 0x03 Load and Unload
  ([custom-render-stages](../custom-render-stages/README.md)). `Load` returns
  a bool.
- Island pattern and header-padding space: see the encoder-merge plan's hook
  inventory ([encoder-merge-plan.md](../../../docs/dev/encoder-merge-plan.md)). Reserve 24
  bytes for this call site in `SupportedBuild.h`'s `Islands`.

## Open items

1. Resolved: the `GetTextureSRV` convention and the size check (item 4 of
   the design).
2. Resolved: the paths Load builds (item 1 of the design).
3. Resolved: no metallib (item 5 of the design).
4. Resolved: a new encoder resets the highest bound slot, not the texture
   table (see design item 4).
5. The cost of compiling 12 specializations at the first Load, on the thread
   that loads stages. Not measured in BG3. The synthetic test, which
   compiles them on the system device, takes about 0.2 s in all, possibly
   with a warm Metal shader cache.

## How to test

- **Synthetic** (done, `native-shadows-smoke`): the Load/Unload overrides
  against a stand-in stage (12 handles swapped in and restored), clone
  failure, the bind before BG3's StartRecording, the empty bind without
  GBuffer0, a stage with differing programs, and a new set after the last
  Unload. `improved-shadows-smoke` covers the shader's 12 variants and the
  no-normal path.
- **Displayed, live:** the same scenes as the README's results. Low (PCF)
  still needs its first live check. A GPU capture should show BG3's own
  pipeline creation with our fragment function, GBuffer0 at fragment slot 6
  at the draw, and no metal-hooks swap.
