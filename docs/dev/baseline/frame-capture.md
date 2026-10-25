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
| cb0/re0, cb1/re0 | RG11B10 1728×1080 | Clear only | Probably render-target initialization for scene color ping-pong (tex451/tex452) | Order |
| ce0 | — | 45 × `SkinningCompute`, 2 × `BlendShapeComputeNoMeshes` | **VertexProcessing** | Shader |
| ce1 | — | `ClusterAssignment` | **ClusteredAssignment** | Shader |
| re2 | Depth 1728×1080 | 1 `FadePattern` + 568 material `_DEP` | **DeferredBuffer: DepthFirstPass** | Shader |
| re3 | RG16F + 4 × RGBA8, depth | 563 material `_DEF`, 8 terrain | **DeferredBuffer: GBufferPass** | Shader |
| re4 | R32Float | `LinearizeDepth` | DeferredBuffer, end of stage | Order |
| re5 | RG16F, depth | `DeferredDecal_ExtractNormal_PS` | DeferredBuffer → Decal prep | Shader / Order |
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
| ce37 | — | `VolumetricFogGather`. Reads tex426 and tex404 | **Lighting**: fog gather | Shader |
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
- **The 3D view's own CombineUI** (from its `ADDITIONAL_STAGES` pack) shows
  no separate encoder. Only one `CombineUI` draw exists, at the end of the
  frame.

## Findings

1. **The sun shadow cascades are rendered twice per frame.** The
   shadow-buffer pack is requested twice in `BaseApp::InitFrameStages`, and
   both requests run. re6–re10 render all four cascades into tex426 and update
   tex404. Then re29–re33 clear tex426 and render the same draws again
   (204/388/533/670/102). I checked every draw and dispatch between the two
   passes (ce11 to re28, 406 draws in the multi-draw encoders), and none binds
   tex426 or tex404. The first readers come after the second pass: the shadow
   mask (re34), clustered lighting (ce36), fog gather (ce37) and forward
   transparents (re42). So **1,897 draws, about a third of the frame's 5,655,
   produce shadow maps that are overwritten before anything reads them.**
2. **The whole frame is one command buffer**, apart from two clear-only
   buffers. There is no early commit, and the GPU can't start until the
   render thread has replayed every stage.
3. **Render resolution is 1728×1080 up to post-processing.** FSR upscales to
   3456×2160 before tone mapping, then UI and composition run at output
   resolution.
4. **Scene color moves between textures by blits** (tex431, tex451, tex416)
   around TAA, History and Bloom. That's six full-screen copies per frame.

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
