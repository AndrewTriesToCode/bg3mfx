# BG3 default renderer: one captured frame, mapped to stages

This is one frame of the unmodified game, captured with `gpucapture` and read
with `gpudebug`. Each Metal command buffer, encoder, draw and dispatch is
mapped to the stages and post-process steps in the
[renderer overview](README.md).

## Capture

| | |
| --- | --- |
| Trace | `build/analysis/baseline/scene-3-gpu-3456x2160-fsr3-taa-ultra-20261025T170351Z.gputrace` (4.6 GB, local only) |
| Captured | 2026-10-25 17:04 UTC, PID 69380, layer boundary, 1 frame |
| Game | Unmodded Steam build 4.1.1.7631656, launched by the user with `MTL_CAPTURE_ENABLED=1`, no bg3mfx runtime |
| Settings | Ultra preset, TAA, borderless windowed, 3456×2160 output, AMD FSR 1.0 mode 3, VSync on, 30 fps cap, CAS off |
| Scene | Gameplay 3D view chosen by the user, camera still |
| Device | Apple M5 Pro |

The scene renders at **1728×1080**, half the output size in each axis, which
confirms that FSR mode 3 is Performance. The capture layer adds overhead, so
this trace shows structure only and says nothing about timing.

### Shader libraries

The trace has no shader source. For what a game shader does, read its AIR
disassembly in `build/analysis/baseline/shaders-4.1.1.7631656/` (local only).
It holds `Core.metallib` (499 functions) and `granite.metallib` (18), each
with a function index, and a README with the source hashes and the command
that produced them. `Materials.metallib` is not dumped.

## Shape of the frame

| Command buffer | Encoders | Content |
| --- | --- | --- |
| cb0 | 1 render, 0 draws | Clears tex451 (1728×1080 RG11B10Float) |
| cb1 | 1 render, 0 draws | Clears tex452 (1728×1080 RG11B10Float) |
| cb2 | 78: 62 render, 10 compute, 6 blit | The whole frame: 5,655 draws, 78 dispatches, 6 blits |

All three come from one queue ("MTLCommandQueue 1"). Each stage records its
own command list, but `RendererCommandBuffer::Submit` replays all of them into
one `MTLCommandBuffer`. Each stage pass becomes one or more encoders in that
buffer, and the encoders keep stage-list order.

Formats: scene depth is Depth32Float_Stencil8. Scene HDR color is
RG11B10Float. The G-buffer is RG16Float plus three or four RGBA8Unorm targets.
Shadow maps are 2048² Depth16Unorm arrays.

## Encoder-by-encoder mapping

Each Stage entry is labelled by how it was matched:

- **Shader:** the shader names match the stage.
- **Order:** the encoder sits where that stage falls in the stage list.

| Encoder | Targets | Work | Stage / step | Basis |
| --- | --- | --- | --- | --- |
| cb0/re0, cb1/re0 | RG11B10 1728×1080 | Clear only | Clear the diffuse and specular lighting targets (tex451, tex452) that clustered lighting (ce36) writes into. See [textures](#textures) | Bindings |
| ce0 | — | 45 × `SkinningCompute`, 2 × `BlendShapeComputeNoMeshes` | **VertexProcessing** | Shader |
| ce1 | — | `ClusterAssignment` | **ClusteredAssignment** | Shader |
| re2 | Depth 1728×1080 | 1 `FadePattern` + 568 material `_DEP` | **DeferredBuffer: DepthFirstPass** | Shader |
| re3 | RG16F + 4 × RGBA8, depth | 563 material `_DEF`, 8 terrain | **DeferredBuffer: GBufferPass** | Shader |
| re4 | R32Float | `LinearizeDepth` | DeferredBuffer, end of stage | Order |
| re5 | RG16F, depth | `DeferredDecal_ExtractNormal_PS` | DeferredBuffer: decal normal extract, read by Decal (re12). Before CascadedShadowBuffer (re6), so not the Decal stage | Order |
| re6–re9 | tex426: 2048² Depth16, 4-layer array, Clear | 204 / 388 / 533 / 670 draws, `_DEPS` and `TerrainDEP_VS` | **CascadedShadowBuffer, first instance**: 4 cascades | Shader |
| re10 | tex404: 2048² Depth16, 2-layer array, Load | 102 draws `_DEPS` | CascadedShadowBuffer, first instance: incrementally updated layer, probably static or vista | Shader |
| ce11 | — | `PPKernel4`. Reads linear depth (R32Float) and the extracted RG16F normals | Start of **Decal** (not identified) | Order |
| re12 | RG16F + 3 × RGBA8, depth | 65 material `_DEF` decals | **Decal** (deferred decals into the G-buffer) | Shader |
| re13 | RG11B10, depth | `PPEmissiveSkydome_Procedural_PS` | **Sky** | Shader |
| ce14 | — | `VolumetricClouds_Downsample`, `VolumetricClouds_Q0` | **VolumetricClouds** | Shader |
| re15 | RGBA16F 864×540 | Clouds upsample-and-blend | VolumetricClouds | Shader |
| re16 | RG11B10, depth | Clouds upsample-and-blend into the scene | VolumetricClouds | Shader |
| re17 | RG11B10, depth | 46 material `_EMI` | **Emissive** | Shader |
| re18 | RG11B10, depth | 9 material `_EMI` | **SurfaceEmissive** (game) | Order |
| re19 | RG11B10, depth | 0 draws | **EmissiveGameDecal**, empty this frame | Order |
| re20 | RG16F, depth | 285 material `_VEL` + `VelocityBufferCamera_PS` | **Velocity** | Shader |
| re21–re28 | 864×540 R16F ×4 → R8, then RGB10A2 1728×1080 | Deinterleave, 4 × `PPSAO_PS`, reinterleave, 2 × blur | **SSAO** | Shader |
| re29–re33 | Same tex426 (Clear) and tex404 (Load) | 204 / 388 / 533 / 670 / 102, identical to re6–re10 | **CascadedShadowBuffer, second instance** | Shader |
| re34 | R8 1728×1080 | `DirLight_Cascaded_PCSS_4x2048`. Reads tex426 and tex404 | **CascadedShadowMask** (4 cascades, PCSS, 2048) | Shader |
| ce35 | — | `ClusteredClear`, `DepthMaxZx9`, `DilateMax2`, `ClusterLightingClassification` | **Lighting**: tile counts, volumetric-fog depth tiles and dilate, tile classification | Shader |
| ce36 | — | `ClusteredLighting_0`–`_13`, `VolumetricFogInitialize`, `VolumetricFogLighting` | **Lighting**: clustered lighting and fog. Reads tex426 | Shader |
| ce37 | — | `VolumetricFogGather`. Reads the fog tiles (tex410) and volumes (tex412, tex414) | **Lighting**: fog gather | Shader |
| re38, re39 | RG11B10, depth | `PPSSSS_H`, `PPSSSS_V` | **LightingCombine**: SSSS | Shader |
| re40 | RG11B10 | `DeferredFog_Cubic_PS` | **LightingCombine**: DrawFog | Shader |
| be41 | — | Copies tex454 → tex431 | Before Alpha; probably the scene-color copy for refraction | Order |
| re42 | RG11B10, depth | 83 material `_FOR`. Reads tex426 | **Alpha** (forward transparents) | Shader |
| ce43 | — | `FadeBlending`, `OldPPCalculateEV64x64ComputeCS`, `OldPPExposureCompute_ProgressiveCS` | **Post: FadeBlending**, then **ExposureOld** | Shader |
| re44 | RG11B10 | `PPRexpose_PS` | **Post: ReExpose** | Shader |
| be45, be46 | — | Copies tex451 → tex431 → tex451 | Around TAA (input/history shuffle) | Order |
| re47 | RG11B10 | `PPTAA_PS` | **Post: TAA** | Shader |
| be48 | — | Copies tex431 → tex416 | **Post: History** | Order |
| re49–re58 | 864×540 down to 54×34 and back up, RG11B10 | Scale-bias downsample, 4 downsamples, 4 upsamples, combine | **Post: Bloom** | Shader |
| be59 | — | Copies tex451 → tex431 | Between Bloom and ColorGrading | Order |
| re60 | RG11B10 | `PPColorGradingApplyLUTPS` | **Post: ColorGrading** | Shader |
| re61 | RG11B10 | `FSR_Tonemap` | **Post: FSR** (draw) | Shader |
| ce62 | — | `FSR`, `FSR_RCAS` | **Post: FSR** (upscale to 3456×2160 and sharpen) | Shader |
| re63 | RGB10A2 3456×2160 | `PPToneMap_LUT` | **Post: ToneMap** | Shader |
| re64–re74 | RGBA8 3456×2160 + Stencil8, blur chain at 1728×1080 down to 248×167 | Noesis paths, SDF text, masks, shadows, down/upsample blur | **GameUI** (full-screen view) | Shader |
| ce75 | — | `DownsampleResolver` | **VtResolve** (full-screen view) | Shader |
| be76 | — | Copies a 108×68 texture to a buffer | VtResolve: virtual-texture feedback readback | Order |
| re77 | BGRA8 3456×2160 (drawable) | `CombineUI` | **CombineUI** (full-screen view) | Shader |

The end of the frame follows the full-screen view's stage pack exactly:
GameUI → VtResolve → CombineUI.

## Render-pass attachments

These are the attachments of all 64 render encoders, with the 10 compute and
6 blit encoders in frame order among them. For a compute or blit encoder,
the attachment column lists the textures it writes. Load and store actions
are written load/store: C = clear, L = load, D = don't care, S = store. The
size is 1728×1080 unless the row says otherwise. Encoders are in cb2 unless
the row says otherwise. **Stage** is the render stage that records the
encoder, as matched in the [encoder mapping](#encoder-by-encoder-mapping).
**Step** is the pass within that stage; — means the stage records only one.

Two more columns follow each pass's data through the frame:

- **Samples:** frame-produced textures the pass's shaders read, each with the
  encoder that last wrote it. Material and UI assets and the atmosphere
  lookup tables are left out.
- **Sampled by:** later encoders that read this pass's outputs as textures,
  until the output is cleared or overwritten. Compute and blit readers are
  included.

Attachment loads by later passes aren't counted in either column; they show
in the attachment columns.

| Encoders | Stage | Step | Color attachments (compute, blit: writes) | Depth / stencil | Samples | Sampled by |
| --- | --- | --- | --- | --- | --- | --- |
| cb0/re0, cb1/re0 | Not identified | Pre-frame clears | tex451, tex452 RG11B10 (C/S) | — | — | ce36 writes lighting into both; then re38 (tex451) and re40 (tex452) |
| ce0 | VertexProcessing | 45 × `SkinningCompute`, 2 × `BlendShapeComputeNoMeshes` | Vertex buffers only | — | — | — |
| ce1 | ClusteredAssignment | `ClusterAssignment` | Cluster buffers only | — | — | — |
| re2 | DeferredBuffer | DepthFirstPass | — | tex418 D32S8 (C/S) | — | tex418 → re4 |
| re3 | DeferredBuffer | GBufferPass | tex420 RG16F, tex212, tex421, tex422, tex423 RGBA8 (all C/S) | tex418 (L/S) | — | tex418 → re4. tex420, tex421 → re5. tex423 → ce75, re74. The rest after re12 (see re12) |
| re4 | DeferredBuffer | LinearizeDepth | tex424 R32F (C/S) | — | tex418 (re3) | tex424 → ce11, re12, re13†, ce14, re15†, re16–re18, re20, re21, re26, re34, ce35, ce36, re38–re40, re42, re47 |
| re5 | DeferredBuffer | Decal normal extract, for the Decal stage | tex425 RG16F (C/S) | tex418 (L/S) | tex420\*, tex421\* (re3) | tex425 → ce11, re12, re13†, re15†, re17, re18 |
| re6–re9 | CascadedShadowBuffer, first instance | Cascades 0–3 | — | tex426 2048² Depth16, one slice each of a 4-slice array (C/S) | — | **None.** re29 clears tex426 first |
| re10 | CascadedShadowBuffer, first instance | Static layer | — | tex404 2048² Depth16, 2-slice array (L/S) | — | tex404 → re34, ce36, ce37†, after re33 updates it again |
| ce11 | Decal (start) | `PPKernel4` | A tile buffer only | — | tex424 (re4), tex425 (re5) | — |
| re12 | Decal | Deferred decals | tex420, tex212, tex421, tex422 (L/S) | tex418 (L/S) | tex424\* (re4), tex425\* (re5) | tex212 → re22–re25, ce36, re39. tex420 → re22–re25, ce36. tex421 → re34, ce35, ce36, re38, re39, re47. tex422 → re34, ce36, re38, re39, re42† |
| re13 | Sky | — | tex431 RG11B10 (C/S) | tex418 (L/S) | tex424† (re4), tex425† (re5) | tex431 → re40 |
| ce14 | VolumetricClouds | `VolumetricClouds_Downsample`, then `_Q0` | Downsample: tex432 864×540 R16F, tex433 432×270 R16F. Q0: tex435 432×270 RGBA16F | — | Downsample: tex424 (re4). Q0: tex433 (Downsample) | tex432 → re15, re16. tex433 → re15. tex435 → re15, and ce36's `ClusteredLighting_0`, which has it bound as GBuffer3 |
| re15 | VolumetricClouds | Upsample | tex434 864×540 RGBA16F (C/S) | — | tex424† (re4), tex425† (re5), tex432\*, tex433, tex435 (ce14) | tex434 → re16 |
| re16–re19 | VolumetricClouds (re16), Emissive (re17), SurfaceEmissive (re18), EmissiveGameDecal (re19) | Clouds blend (re16) | tex431 (L/S) | tex418 (L/S) | re16: tex424\* (re4), tex432 (ce14), tex434 (re15). re17, re18: tex424\* (re4), tex425\* (re5). re19: — | tex431 → re40 |
| re20 | Velocity | — | tex425 (D/S) | tex418 (L/S) | tex424\* (re4) | tex425 → re38†, re42†, re47 |
| re21 | SSAO | Deinterleave | tex436 864×540 R16F, 4 slices as 4 color attachments (D/S) | — | tex424 (re4) | tex436 → re22–re25, one slice view each (tex437–tex440) |
| re22–re25 | SSAO | AO, one slice per encoder | tex441 864×540 R8, one slice each of a 4-slice array (D/S) | — | tex437–tex440 (re21), tex212, tex420 (re12) | tex441 → re26 |
| re26 | SSAO | Reinterleave | tex447 RGB10A2 (C) | — | tex424\* (re4), tex441 (re22–re25) | tex447 → re27 |
| re27 | SSAO | Blur | tex446 RGB10A2 (C) | — | tex447 (re26) | tex446 → re28 |
| re28 | SSAO | Blur | tex447 (D) | — | tex446 (re27) | tex447 → ce36, re42† |
| re29–re32 | CascadedShadowBuffer, second instance | Cascades 0–3 | — | Same as re6–re9 | — | tex426 → re34, ce36, ce37†, re38†, re42 |
| re33 | CascadedShadowBuffer, second instance | Static layer | — | Same as re10 | — | tex404 → re34, ce36, ce37† |
| re34 | CascadedShadowMask | — | tex448 R8 (C/S) | — | tex404 (re33), tex426 (re32), tex421\*, tex422\* (re12), tex424\* (re4), tex407 (persistent) | tex448 → ce36, ce37†, re42† |
| ce35 | Lighting | `ClusteredClear`, `DepthMaxZx9`, `DilateMax2`, `ClusterLightingClassification` | ClusteredClear: tile counts (buffer). DepthMaxZx9: tex449 192×120 R8. DilateMax2: tex410 192×120 R8. Classification: tex450 216×135 R8 (hair mask) | — | DepthMaxZx9: tex424 (re4). DilateMax2: tex449 (DepthMaxZx9). Classification: tex421 (re12) | tex410 → ce36, ce37. tex450 → ce62 |
| ce36 | Lighting | `ClusteredLighting_0`–`_13`, then `VolumetricFogInitialize`, `VolumetricFogLighting` | Lighting: tex451, tex452 (diffuse, specular). FogInitialize: tex412 192×120×128 RGBA16F. FogLighting: tex414 192×120×128 RG11B10 | — | Lighting: tex424 (re4), tex420, tex212, tex421, tex422 (re12; `_0` has tex435 from ce14 in tex422's slot), tex447 (re28), tex448 (re34), tex426 (re32), tex417 (persistent). FogInitialize: tex410 (ce35), tex411, tex413 (previous frames). FogLighting: tex410 (ce35), tex411, tex415 (previous frames), tex404 (re33), tex426 (re32), tex407, tex417 (persistent) | tex451 → ce37†, re38. tex452 → ce37†, re40. tex412 → ce37. tex414 → ce37, re42 |
| ce37 | Lighting | `VolumetricFogGather` | tex453 192×120×128 RGBA16F | — | tex410 (ce35), tex412, tex414 (ce36), tex451†, tex452† (ce36), tex426† (re32), tex404† (re33), tex448† (re34), tex407†, tex417† (persistent) | tex453 → re40, re42 |
| re38 | LightingCombine | SSSS_H | tex454 RG11B10 (C/S) | tex418 (L/S) | tex451 (ce36), tex421, tex422\* (re12), tex424 (re4), tex425† (re20), tex426† (re32) | tex454 → re39 |
| re39 | LightingCombine | SSSS_V | tex451 (L/S) | tex418 (L/S) | tex454 (re38), tex212\*, tex421, tex422\* (re12), tex424 (re4) | tex451 → re40 |
| re40 | LightingCombine | DrawFog | tex454 (D/S) | — | tex431\* (re13–re19), tex451\* (re39), tex452\* (ce36), tex453 (ce37), tex424\* (re4) | tex454 → be41, ce43 |
| be41 | Before Alpha | Copy | tex431 (copy of tex454) | — | tex454 (re40) | tex431 → re42 |
| re42 | Alpha | — | tex454 (L/S) | tex418 (L/S) | tex431 (be41), tex414 (ce36), tex453 (ce37), tex426 (re32), tex447† (re28), tex448† (re34), tex422† (re12), tex424 (re4), tex425† (re20), tex417 (persistent) | tex454 → ce43 |
| ce43 | Post | `FadeBlending`, then ExposureOld (`OldPPCalculateEV64x64ComputeCS`, `OldPPExposureCompute_ProgressiveCS`) | FadeBlending: tex431. CalculateEV: tex456 64×64 R16F. ExposureCompute: the exposure buffer | — | FadeBlending: tex454 (re42), tex419 (stencil view of tex418). CalculateEV: tex431 (FadeBlending). ExposureCompute: tex456 | tex431 → re44 |
| re44 | Post | ReExpose | tex451 (D/S) | — | tex431\* (ce43) | tex451 → be45 |
| be45 | Post | Copy before TAA | tex431 (copy of tex451) | — | tex451 (re44) | tex431 → be46 |
| be46 | Post | Copy before TAA | tex451 (copy of tex431) | — | tex431 (be45) | tex451 → re47 |
| re47 | Post | TAA | tex431 (D/S) | — | tex451 (be46), tex416 (previous frame's be48), tex421\* (re12), tex424 (re4), tex425 (re20) | tex431 → be48, re49, re58 |
| be48 | Post | History | tex416 (copy of tex431) | — | tex431 (re47) | tex416 → the next frame's re47 |
| re49–re57 | Post | Bloom: 4 down, 4 up | tex457–tex465, 864×540 down to 54×34 | — | tex431 (re47), then each other's mips (re57's read of tex457\* is at its own pixel) | tex458 → re58 |
| re58 | Post | Bloom combine | tex451 (D/S) | — | tex431\* (re47), tex458 (re57) | tex451 → be59 |
| be59 | Post | Copy before ColorGrading | tex431 (copy of tex451) | — | tex451 (re58) | tex431 → re60 |
| re60 | Post | ColorGrading | tex451 (D/S) | — | tex431\* (be59), tex227 LUT (persistent) | tex451 → re61 |
| re61 | Post | FSR_Tonemap | tex431 (D/S) | — | tex451\* (re60) | tex431 → ce62 |
| ce62 | Post | FSR: `FSR`, then `FSR_RCAS` | FSR: tex466 3456×2160 RG11B10. RCAS: tex467 3456×2160 RG11B10 | — | FSR: tex431 (re61). RCAS: tex466 (FSR), tex450 (ce35) | tex467 → re63 |
| re63 | Post | ToneMap | tex468 3456×2160 RGB10A2 (D/S) | — | tex467\* (ce62), tex209 LUT (persistent) | tex468 → re77 |
| re64 | GameUI | — | tex215 RGBA8 3456×2160 (L/S) | Stencil tex214 (C/don't care) | UI assets only | tex215 → re66 |
| re65 | GameUI | — | tex217 (L/S) | Stencil tex214 (L/don't care) | — | tex217 → re74 |
| re66 | GameUI | — | tex211 (L/S) | Stencil tex214 (L/don't care) | tex215 (re64) | tex211 → re67, re74 |
| re67–re73 | GameUI | Blur chain | tex212, tex220–tex223, tex219, tex218 (L/S) | — | tex211 (re66), then each other's levels | tex218 → re74 |
| re74 | GameUI | Paths | tex216 3456×2160 (C/S) | Stencil tex210 (C/don't care) | tex211 (re66), tex217 (re65), tex218 (re73), tex423 (re3; bound by a `VirtualTextureBrush` draw) | tex216 → re77 |
| ce75 | VtResolve | `DownsampleResolver` | tex213 108×68 RGBA8 | — | tex423 (re3) | tex213 → be76 |
| be76 | VtResolve | Copy to a buffer (virtual-texture feedback readback) | A buffer | — | tex213 (ce75) | Read by the CPU |
| re77 | CombineUI | — | Drawable tex769 BGRA8 3456×2160 (D/S) | — | tex216\* (re74), tex468\* (re63) | Presented |

Notes on the two columns:

- **They list bound textures.** Metal keeps a binding until it's replaced, so
  a texture can appear for a draw that inherited it from an earlier one. In
  re74, for example, a `VirtualTextureBrush` draw binds tex423 and the later
  path draws keep it bound. Entries are checked against the shaders, and
  † marks a texture the pass only has bound: no shader in it declares the
  slot, or none reads it. The same † marks that pass in the writer's
  Sampled by. BG3 binds linear depth (tex424) at fragment slot 30 for every
  material draw, for example, but in re13 and re15 no shader declares that
  slot; in re17, re20 and re42 only some shaders read it
  (`build/evidence/linear-depth/`). Reads through a helper function or a
  stored texture reference count as reads (TAA's history, re42's shadow tile
  map).
- **\* marks a sample that could be a color attachment instead**, for
  consolidating render encoders: every read of it in that pass is at the
  pixel being shaded, and the texture is the size of the pass's targets, so
  the pass could read it with framebuffer fetch if both shared a render pass.
  A read counts when its coordinate is the fragment position, the position
  times PerRT's 1/size, or the full-screen texture coordinate from
  `PPDefaultVS` or `DefaultVS` (taken to map the viewport to the pixel
  centre). Reads at an offset, at another resolution, or of depth formats
  aren't marked. Each pass's shaders were checked draw by draw
  (`build/evidence/attachable-samples/`).
- **Compute rows are checked against the kernels.** Each dispatch's reads and
  writes are the textures its kernel declares at a bound slot, with the
  kernel's access (sample or read; write or read_write), so stale bindings
  get †. ce37 keeps the shadow textures and lighting targets bound, for
  example, but its fog kernel doesn't declare them. Blit rows come
  from each copy's source and destination.

For the encoders considered for merging below, every texture their draws
sample was also listed: re4, re5, re12, re13, re16–re18, re20, re34,
re38–re40, re42, re44, re47, re58, re60, re61, re63. **None of them samples
its own attachments.** ce14 (cloud compute) reads tex424 and writes tex432 and
tex433. It doesn't touch tex431 or tex418.

## Textures

The trace has no texture labels, so these roles are inferred from what
writes each texture, what reads it, and its format. Confidence:

- **High:** a named shader writes or reads it in a way that leaves little
  doubt.
- **Medium:** consistent with every use, but another reading is possible.
- **Low:** a guess.

Compute reads and writes come from each kernel's declared texture access (see
the [attachments notes](#render-pass-attachments)).

**Scene targets (1728×1080)**

| Texture | Format | Role | Evidence | Confidence |
| --- | --- | --- | --- | --- |
| tex418 | D32S8 | Hardware depth/stencil | Depth attachment from the prepass on | High |
| tex424 | R32F | Linear depth | Written by `LinearizeDepth` from tex418; read by nearly every later pass | High |
| tex420 | RG16F | G-buffer: normal, two-channel (octahedral) | `ExtractNormal` and SSAO read it | Medium |
| tex212 | RGBA8 | G-buffer: base color | Read by lighting, SSAO (multi-bounce AO) and `PPSSSS_V` (re-applies albedo after the skin blur). Reused later as the first UI blur target | Medium |
| tex421 | RGBA8 | G-buffer: material parameters and shading-model ID | Read by `ClusterLightingClassification`, `ExtractNormal`, shadow mask, SSSS and TAA | Medium |
| tex422 | RGBA8 | G-buffer: more material parameters (likely roughness, metalness, subsurface) | Read by lighting, shadow mask and SSSS | Low |
| tex423 | RGBA8 | G-buffer: virtual-texture feedback (page requests) | Only reader is `DownsampleResolver` (ce75), whose output is read back to the CPU (be76) | High |
| tex425 | RG16F | Two uses: decoded normals for decals (re5), then motion vectors (re20) | Written by `ExtractNormal` because decals can't sample tex420 while writing it. Then overwritten by Velocity and read by TAA | High |
| tex431 | RG11B10 | Scene color: sky, clouds and emissive; then the post-process ping-pong | Written by Sky, the clouds blend and Emissive. Read by Fog. Later the input and output of most post steps | High |
| tex451 | RG11B10 | Diffuse lighting, then a post-process ping-pong target | Cleared by cb0. Written by ce36 (`ClusteredLighting_*`'s OutDiffuse). SSSS blurs it (re38 → tex454 → re39 back to tex451). From ReExpose on, a post target | High |
| tex452 | RG11B10 | Specular lighting | Cleared by cb1, written by ce36 (`ClusteredLighting_*`'s OutSpecular), read only by Fog | High |
| tex454 | RG11B10 | Composite lit scene | SSSS temp, then Fog writes lighting + scene color + fog. Alpha draws on top. `FadeBlending` reads it | High |
| tex455 | R32F | Second linear-depth copy for transparents | Read only by Alpha | Low |
| tex416 | RG11B10 | TAA history | Read by TAA; be48 copies the TAA result into it | High |
| tex447 | RGB10A2 | Ambient occlusion (final); tex446 is the blur temp | Reinterleave and blur chain; read by lighting | High |
| tex448 | R8 | Sun shadow mask | Written by `DirLight_Cascaded_PCSS`; read only by clustered lighting (ce36) | High |

**Shadows, SSAO, clouds and fog intermediates**

| Texture | Format | Role | Confidence |
| --- | --- | --- | --- |
| tex426 | 2048² Depth16 ×4 | Sun cascades 0–3 | High |
| tex404 | 2048² Depth16 ×2 | Incrementally updated shadow layers (static or distant) | Medium |
| tex407 | 1024² Depth16 | Another shadow map read by the shadow mask and fog, not rendered this frame (probably static, or cloud/terrain shadow) | Low |
| tex417 | 8192² R16Unorm | Large static map read by lighting, fog and Alpha (heightmap or baked shadow) | Low |
| tex436, tex441 | 864×540 R16F ×4, R8 ×4 | SSAO deinterleaved depth and per-slice AO | High |
| tex432, tex433 | 864×540, 432×270 R16F | Cloud depth downsamples | High |
| tex435 | 432×270 RGBA16F | Cloud raymarch result | Medium |
| tex434 | 864×540 RGBA16F | Upsampled clouds, blended into tex431 by re16 | High |
| tex410, tex411, tex449 | 192×120 R8 | Fog depth-tile masks (`DepthMaxZx9`, `DilateMax2`) | Medium |
| tex412–tex415 | 192×120×128 RGBA16F / RG11B10 | Volumetric fog froxel volumes (current and history) | Medium |
| tex453 | 192×120×128 RGBA16F | Gathered fog volume, read by Fog and Alpha | High |
| tex399, tex397, tex206 | 256×128×32 RGBA16F, 256×64, 256×256 RG11B10 | Atmosphere lookup tables (aerial perspective, transmittance, sky) | Medium |

**Post-processing and output**

| Texture | Format | Role | Confidence |
| --- | --- | --- | --- |
| tex457–tex465 | 864×540 down to 54×34 | Bloom mip chain | High |
| tex227 | 32³ RGBA16F | Color-grading LUT | High |
| tex466 | 3456×2160 RG11B10 | FSR upscale output | High |
| tex467 | 3456×2160 RG11B10 | RCAS-sharpened output | High |
| tex209 | 64³ RGB10A2 | Tone-map LUT | High |
| tex468 | 3456×2160 RGB10A2 | Tone-mapped scene, read by `CombineUI` | High |
| tex216 | 3456×2160 RGBA8 | Final UI layer, read by `CombineUI` | High |
| tex211, tex215, tex217 | 3456×2160 RGBA8 | Offscreen UI layers rendered before the final UI pass (probably Noesis render-to-texture surfaces) | Medium |
| tex218–tex223 | 1728×1080 down to 248×167 | UI blur chain | High |
| tex210, tex214 | Stencil8 | UI clip-mask stencils | Medium |
| tex769 | 3456×2160 BGRA8 | Drawable | High |

Two things follow from this:

- **cb0 and cb1 clear the lighting targets, not scene color.** Clustered
  lighting accumulates into tex451 and tex452, and those two command buffers
  clear them first.
- **Scene color stays split until Fog.** Sky, clouds and emissive go into
  tex431. Diffuse and specular lighting go into tex451 and tex452. The fog
  pass (re40) combines all of them, plus the fog volume, into tex454. So
  "DrawFog" is also the lighting composite.

## Stages and steps with no GPU work in this frame

- **CPU-only, as expected:** FxRenderPrepare, Cull, FxRenderUpdate,
  ShadowTileAssignment, SurfaceCull, TextureCull. SurfaceMeshGeneration has no
  encoder of its own.
- **Present in the stage list but empty here:**
  - LocalLightShadow: no shadowed local lights in view.
  - SSR: no `SSSR*` work at all.
  - Outline and RegionRoom, and the Sight and Outline post steps: no active
    highlights or triggers.
  - Unlit and DebugWorld: no draws.
  - Early VtResolve: not enabled for this view.
- **Post steps disabled by settings or scene:** ClearRenderView, GodRays,
  DOF, LensFlare, DarkenEnvironment, RadialBlur, SMAA (TAA is selected),
  ChromaticAberration, ComputeLUTs (LUTs not rebuilt this frame),
  InjectTexture, CAS (off), Vignette, Calibration.
- **The 3D view has no CombineUI or early VtResolve.** The `"default"` view
  doesn't have the flag that adds `ADDITIONAL_STAGES` and
  `EARLY_VT_RESOLVE_STAGE` (see the [overview](README.md#how-the-stage-list-is-built)).
  The only `CombineUI` draw, at the end of the frame, belongs to the
  full-screen view.

## Findings

1. **The sun shadow cascades are rendered twice per frame.** The
   shadow-buffer pack is requested twice in `BaseApp::InitFrameStages`, and
   both requests run. re6–re10 render all four cascades into tex426 and update
   tex404. Then re29–re33 clear tex426 and render the same draws again
   (204/388/533/670/102). I checked every draw and dispatch between the two
   passes (ce11 to re28, 406 draws in the multi-draw encoders), and none binds
   tex426 or tex404. The first readers come after the second pass: the shadow
   mask (re34), clustered lighting and fog lighting (ce36) and forward
   transparents (re42). So **1,897 draws, about a third of the frame's 5,655,
   produce shadow maps that are overwritten before anything reads them.**
2. **The whole frame is one command buffer**, apart from two clear-only
   buffers. There is no early commit, and the GPU can't start until the
   render thread has replayed every stage.
3. **Render resolution is 1728×1080 up to post-processing.** FSR upscales to
   3456×2160 before tone mapping, then UI and composition run at output
   resolution.
4. **Scene color moves between textures by blits** (tex431, tex451, tex416)
   before Alpha and around TAA, History and Bloom (be41, be45, be46, be48,
   be59). That's five full-screen copies per frame. The sixth blit, be76, is
   the virtual-texture feedback readback.
5. **The UI stencil is loaded after a don't-care store.** re64 clears
   stencil tex214 and stores it as don't care, and then re65 and re66 load
   it. Its contents are undefined unless those passes clear it with their own
   draws first.
6. **be46 undoes be45.** be45 copies all of tex451 into tex431, and be46
   immediately copies all of tex431 back into tex451. Nothing runs between
   them, so be46 leaves tex451 unchanged, costing one full-screen copy for
   nothing.
7. **The first static-layer update (re10) is also wasted.** re33 loads tex404
   and draws the same 102 draws into it again. Nothing samples tex404
   between re10 and re33. This is part of finding 1, but re10 loads rather
   than clears, so it's easy to miss.

## Encoder merge opportunities

On Apple GPUs, every encoder boundary stores all attachments from tile memory
and the next encoder loads them again. tex431 (RG11B10) is about 7 MB and
tex418 (D32S8) about 9.4 MB at 1728×1080. These sizes are uncompressed upper
bounds, estimated rather than measured, because lossless compression usually
reduces the traffic. None of these merges has been prototyped.

Ranked by expected value:

1. **Sky through EmissiveGameDecal (re13, re16–re19) → one encoder.**
   - All five use tex431 + tex418, and none of them samples either one.
   - re16–re19 are already adjacent.
   - The only work between re13 and re16 is ce14 and re15. They touch neither
     attachment, so the clouds can run before Sky.
   - Merging removes four boundaries, up to about 125 MB of tile traffic.
   - It needs only encoder grouping and pass reordering, with no shader
     changes.
2. **Skip empty encoders.** re19 (EmissiveGameDecal) has 0 draws but still
   loads and stores tex431 + tex418. This applies if #1 isn't done.
3. **Bloom combine → ColorGrading → FSR_Tonemap (re58, be59, re60, re61).**
   - These form a ping-pong between tex451 and tex431, with a copy (be59) in
     the middle.
   - If each shader only reads its own pixel, they could be one encoder with
     three draws using framebuffer fetch. That removes be59 and two
     boundaries.
   - Per-pixel reads are likely for LUT grading and tone mapping, but the
     shaders haven't been checked.
4. **DepthFirstPass + GBufferPass (re2, re3).**
   - re3 loads the depth that re2 stored. Merging them saves one store and
     load of tex418.
   - The prepass pipelines would need the G-buffer's color formats with color
     writes masked off.
   - On a GPU that already removes hidden surfaces, the prepass itself is
     worth measuring.
   - **The decal normal extract (re5) can join them.** Its fragment shader,
     `DeferredDecal_ExtractNormal_PS`, reads only its own pixel. It calls
     `read()` at the integer `[[position]]` on `GBuffer0` (tex420, re3 color0)
     and `GBuffer2` (tex421, color2). If bit 3 of `round(GBuffer2.a * 255)`
     is clear, it discards. Otherwise it writes `GBuffer0.xy` to tex425, and
     its depth-stencil state (dss32: depth Always, no depth write, stencil
     Always/Replace, reference 64) marks the pixel in the stencil. A
     replacement that reads tex420 and tex421 with framebuffer fetch
     (`[[color(0)]]`, `[[color(2)]]`) and writes tex425 as a sixth color
     attachment does the same in the G-buffer encoder. Read from the AIR in
     `Core.metallib`
     ([shader libraries](#shader-libraries), local only).
   - LinearizeDepth (re4) can't join: it samples depth, which Metal has no
     framebuffer fetch for. It reads nothing re5 writes and re5 reads nothing it
     writes, so it can move after re5.
5. **Array-slice passes.** The shadow cascades (re6–re9) and SSAO (re22–re25)
   each render one slice per encoder. Layered rendering (`render_target_array_index`)
   could do each group in a single encoder. The GPU work is the same, so the
   saving is mostly CPU encoding. For shadows, removing the duplicate pass
   (finding 1) is worth far more.
6. **Pre-frame clears (cb0, cb1).** These are two command buffers with one
   clear-only encoder each. They could be one encoder with two attachments.
   The clears are probably needed: tex451 and tex452 are the lighting
   targets, and tile-classified clustered lighting probably skips tiles with
   no lit geometry, such as sky.

**Not mergeable as they stand:**

- **Separable blurs and ping-pongs** (SSSS re38/re39, the SSAO blurs, bloom,
  TAA, the UI blur chain) read neighbouring pixels of the previous pass.
- **Decal (re12)** shares the G-buffer targets, but it reads linear depth and
  normals produced after re3 (re4, re5, ce11).
- **DrawFog (re40) and Alpha (re42)** both write tex454, but Alpha samples the
  be41 copy of the fog result, and Fog itself reads tex431.

## Reproduction

```sh
# User, from their own Terminal with Steam running:
open --env MTL_CAPTURE_ENABLED=1 --env SteamAppId=1086940 --env SteamGameId=1086940 \
  -a "$HOME/Library/Application Support/Steam/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app" \
  --args -NoLauncher 1
# then enter the scene; agent:
gpucapture boundaries --pid <PID>        # pick the Layer boundary
gpucapture start --pid <PID> --boundary <LAYER_ID> --count 1 \
  --output build/analysis/baseline/scene-3-gpu-....gputrace
gpudebug -q -t <trace> --timeout 0       # creates a session
gpudebug -q -s <session> --json -c "go /commands/cb2" -c "list --all"
```

Encoder listings show "vertex / fragment" or kernel names for every
draw and dispatch. Attachment identity and load actions come from
`info depth` and `info color0` on each encoder. Binding checks list
`/commands/cb2/<encoder>/<call>/{vertex,fragment,compute}`.
