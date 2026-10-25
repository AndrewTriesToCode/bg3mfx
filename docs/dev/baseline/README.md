# BG3 default renderer: high-level overview

This describes how the unmodified Mac build of Baldur's Gate 3 renders a frame.
It is derived **only from the shipped app**, with no other project docs or
captures used. Sources:

- the ARM64 slice of the executable (symbols are not stripped: about 765,000
  defined symbols), read with `nm`, `c++filt` and `llvm-objdump`
- the function names in `Contents/Data/Shaders/Metal/Core.metallib` (about 670
  names) and `Materials.metallib` (30,706 material entry points)
- `Contents/Resources/granite.metallib`

Build: 4.1.1.7631656, executable SHA-256
`d81e0420d9158e6e58c55af62e8490366768d7376a92868d3bf55d05d561519b`.
All addresses are ARM64 VM addresses for this build only.

Confidence labels used below:

- **Read**: taken directly from code or data, such as a constructor call, a
  vtable store, a constant table or a selector call site.
- **Named**: inferred from class, shader or permutation names. It is
  plausible, but the code has not been followed.

The stage analysis itself uses nothing from a running game. For a captured
frame mapped encoder-by-encoder to these stages, with render-target formats
and command-buffer layout, see [frame capture](frame-capture.md).

## Layers

| Namespace | Role |
| --- | --- |
| `ls::` | Larian engine core: render stages, post-process steps, culling, worker-thread scheduler, `GameRenderView` |
| `rf::` | Render framework: `RenderView`, `StageGroup`, `IAppStage`, `SceneGraph`, the backend-neutral `RendererCommandBuffer` |
| `rf::metal::` | Metal backend: `MetalAPI`, `MetalRenderer`, `MetalRenderFrame`, `GPUDevice`, `MTLRendererCommandBuffer` |
| `ecl::` | BG3 game client. It adds game-specific stages and post steps (surfaces, outlines, sight, region/room triggers) |
| `LSMTLView` | `NSView` that owns the `CAMetalLayer` |
| Noesis (`*31_PS/VS` shaders) | UI renderer |
| Granite (`granite.metallib`) | Virtual texturing (`_VT_` material variants, `VtResolveRenderStage`) |

## Frame lifecycle and threading

The renderer records commands in parallel and then replays them on one thread
into Metal. (Read)

1. **Stages.** Every render stage is an `rf::IAppStage`. Its interface has
   `Load`/`Unload`, `OnSizeChanged`, `OnStateChanged`, `UpdateIsRendering`,
   `GetQueueType`, and resource registration (`AddBuffer`, `AddFramebuffer`,
   `AddRenderPass`, `AddPipelineState`). Stages belong to an `rf::StageGroup`
   for each `RenderView`.
2. **Recording.** Each stage has its own `MTLRendererCommandBuffer`, made when
   the stage is constructed. In `ExecuteWTKernel` ("worker-thread kernel"),
   stages run as `ls::WorkerThreadScheduler` jobs. They don't call Metal there:
   they append compact commands with `CommandDispatcherBuffer::AddCommand`.
   `GameRenderView::StartRecording` uploads the per-view and per-camera
   constant buffers.
3. **Submit.** On the render thread (`ls::RenderThread::Update`),
   `rf::RendererCommandBuffer::Submit` replays each stage's command list
   through `MetalRenderer`. This is where encoders are opened, state is set,
   draws and dispatches are issued, and `useResources:count:usage:` and
   `commit` are called.
4. **Present.** `MetalRenderFrame::FlipBuffers` calls `presentDrawable:`, or
   `presentDrawable:afterMinimumDuration:` when a `GraphicSettings` flag
   (+0x28) is set. That interval comes from two settings fields (+0x18 and
   +0x1c) and is presumably the frame limiter (Named).

CPU-side visibility runs on the worker threads: `CullStage` (render objects,
lights and light probes), shadow culling, and texture/streaming culling. It is
helped by a software **Masked Occlusion Culling** rasterizer that the
`GameRenderView` constructor creates (Intel MOC, compiled from its SSE
sources). (Read)

## How the stage list is built

`App::InitFrameStages(RenderView*)` (`0x100bd6f30`) calls the engine's
`BaseApp::InitFrameStages(RenderView*)` (`0x105d1a738`) and then inserts the
game's own stages. The engine passes byte arrays of `rf::AppStageType` values
("packs") to `BaseApp::InitFrameStages(RenderView*, Span<AppStageType>)`
(`0x105d1aa80`). That function is a 73-way switch (jump table at
`0x10787a46c`) that constructs one stage class per type value. (Read)

The type values are almost alphabetical by class name, which supports the
mapping below. Post-process step types share the same enum
(`GetType()` returns 0x22–0x34).

| Value | Stage | Value | Stage |
| --- | --- | --- | --- |
| 0x00 | AlphaRenderStage | 0x21 | PostProcessStage |
| 0x02 | CascadedShadowBufferStage | 0x35 | ShadowTileAssignmentStage |
| 0x03 | CascadedShadowMaskStage | 0x36 | SkyRenderStage |
| 0x05 | ClusteredAssignmentStage | 0x37 | SSAOStage |
| 0x07 | CombineUIRenderStage | 0x38 | SSRStage |
| 0x08 | CullStage | 0x3e | TextureCullStage |
| 0x0b | DeferredBufferStage | 0x3f | UnlitRenderStage |
| 0x17 | EmissiveGameDecalRenderStage | 0x40 | VelocityRenderStage |
| 0x18 | EmissiveRenderStage | 0x41 | VertexProcessingStage |
| 0x19 | GameUIRenderStage | 0x44 | VolumetricCloudsRenderStage |
| 0x1a | LightingCombineRenderStage | 0x45 | VtResolveRenderStage |
| 0x1b | LightingRenderStage | 0x46 | DecalRenderStage |
| 0x1e | LocalLightShadowStage | 0x47 | FxRenderPrepareStage |
| | | 0x48 | FxRenderUpdateStage |

Packs (`0x10789ffc0`): `FULL_SCREEN_STAGES` = 19 45 07;
`SHADOW_BUFFER_PACK` = 02; `FIRST_PACK` = 47 08 48 35 1e 05 0b;
`EARLY_VT_RESOLVE_STAGE` = 45; `SECOND_PACK` = 46 36 44 18 17 40 37 38;
`THIRD_PACK` = 41 03 1b 1a 00 21 3e 3f; `ADDITIONAL_STAGES` = 07 43.
Value 0x43 falls into the switch's default branch and has not been identified.

## 3D game view: stage order

This is the order of the stage list after all insertions. The `StageGroup`
records and submits in this list order (Read for list order; actual GPU
overlap is not established). Stages marked † are inserted by the game layer
(`ecl::`) with `AddAppStageBefore`.

| # | Stage | What it does |
| --- | --- | --- |
| 1 | FxRenderPrepare | Prepares particle/VFX render data (Named) |
| 2 | VertexProcessing | Inserted before Cull. GPU skinning and blend shapes: `SkinningCompute`, `BlendShapeCompute` (Named) |
| 3 | Cull | Visible objects, lights and light probes; assigns probes to forward objects (Read) |
| 4 | FxRenderUpdate | VFX update (Named) |
| 5 | ShadowTileAssignment | Assigns local-light shadows to atlas tiles (Named) |
| 6 | LocalLightShadow | Renders local-light shadow maps; uses tetrahedron projections for point lights (Read: `TetrahedronShadowHelper`) |
| 7 | SurfaceCull † | Culls BG3 ground surfaces (fire, water, blood and so on) |
| 8 | ClusteredAssignment | Assigns lights to view clusters (`ClusterAssignment` shader) |
| 9 | DeferredBuffer | `DepthFirstPass` depth prepass, then `GBufferPass` (Read: nested classes) |
| 10 | VtResolve (only some views) | Early virtual-texture feedback resolve; added when a render-view setting is set |
| 11 | CascadedShadowBuffer | Sun cascaded shadow maps. Owns `ShadowCullStage`, `VistaShadowCullStage` and `PreVertexProcessingCullStage` (Read). The shadow pack is requested twice, and [the capture](frame-capture.md#findings) shows both requests run: the first set of maps is overwritten before anything reads it |
| 12 | SurfaceMeshGeneration † | Builds surface meshes |
| 13 | Decal | Deferred decals into the G-buffer: `DeferredDecalRenderSubStage`, `DeferredGameDecalRenderSubStage`, game `SurfaceDecalRenderSubStage` (Read) |
| 14 | Sky | Skydome and atmosphere (`PPEmissiveSkydome_*`, precomputed `Inscatter*`/`Transmittance`/`Irradiance`) |
| 15 | VolumetricClouds | `VolumetricClouds_Q0–Q3`, downsample, upsample-and-blend, compose |
| 16 | Emissive | Emissive geometry (`_EMI` material variants) |
| 17 | SurfaceEmissive † | Emissive surfaces |
| 18 | EmissiveGameDecal | Emissive decals |
| 19 | Velocity | Motion vectors: camera pass `VelocityBufferCamera_PS` and object `_VEL` variants (Named) |
| 20 | SSAO | `PPSAO_*` with deinterleave/reinterleave, blur, orthographic variant |
| 21 | SSR | Stochastic screen-space reflections: `SSSRClassifyTiles`, `Intersect`, `ResolveSpatial`, `ResolveTemporal`, `BlurReflections` |
| 22 | CascadedShadowMask | Builds the sun shadow mask from cascades: `DirLight_Cascaded_PCF_{1–4}x1024`, `PCSS_{1–4}x{1024,2048}` |
| 23 | Lighting | Clustered deferred lighting. Sub-stages (Read): clear tile counts, tile classification, `DrawClusteredLighting` (`ClusteredLighting_0–13`, with `_SSR` variants), volumetric fog depth tiles, dilate, initialize, lighting and gather |
| 24 | LightingCombine | Combines lighting; sub-stages `SubStage_SSSS` (separable subsurface scattering, `PPSSSS_H/V`) and `SubStage_DrawFog` (Read) |
| 25 | Alpha | Forward-lit transparent geometry (`_FOR` variants); instancing hash and back-to-front sort (Read) |
| 26 | Outline † | Character/object outline mask (`EoCOutline*`) |
| 27 | RegionRoom † | Region and room trigger masks (`EoCRegionTrigger*`, `EoCRoomTrigger*`) |
| 28 | PostProcess | Ordered post-process chain (next section) |
| 29 | TextureCull | Texture streaming requests (Named) |
| 30 | Unlit | Unlit geometry, sorted back to front (Read) |
| 31 | DebugWorld | Debug drawing (added directly by `BaseApp`) |
| 32 | CombineUI | Composes scene and UI into the output (`CombineUI`, `_HDR`, `_NoUI` variants) |
| 33 | type 0x43 | Not identified |

## Post-process chain

`PostProcessStage::Load` (`0x10608f598`) constructs the steps in the order
below. A step whose "supported" byte (+0x19) is clear after construction is
dropped. `ExecuteWTKernel` then runs the list in order and skips steps whose
enabled byte (+0x18) is clear. The game layer inserts Sight and Outline
directly after ColorGrading. FSR is created right after ColorGrading too, when
a render-view setting is clear. (Read)

1. ClearRenderView
2. GodRays
3. DOF (circular/Gaussian bokeh at half or quarter resolution, CoC near/far composite)
4. FadeBlending
5. Exposure *or* ExposureOld (histogram and EV)
6. ReExpose
7. LensFlare
8. DarkenEnvironment
9. RadialBlur
10. SMAA
11. TAA (`PPTAA_PS`)
12. History
13. Bloom (downsample/upsample blur chain)
14. ChromaticAberration
15. ComputeLUTs (ACES v1 tonemapping LUT; ZCAM display LUT; grading and fade LUTs)
16. ColorGrading (`PPColorGradingApplyLUTPS`)
17. Sight † (`EoCSight`, the stealth/vision overlay)
18. Outline † (outline blur and combine)
19. FSR: `FSR_Tonemap` full-screen draw, then compute `FSR` and `FSR_RCAS` (Read: `PostProcessStep_FSR::ExecuteWTKernel`). Only when FSR upscaling is selected (Named)
20. InjectTexture
21. ToneMap (`PPToneMap_LUT`)
22. CAS (FidelityFX contrast-adaptive sharpening)
23. Vignette
24. Calibration (brightness and gamma calibration)

So anti-aliasing (SMAA or TAA), bloom and grading all run at render resolution
in linear HDR. FSR 1 upscales before tone mapping, and UI composition comes
last. The library also contains `PPFXAA_*`, but no FXAA step class exists.

## Full-screen (UI) view

The app's dedicated full-screen view (`BaseApp+0x90`) gets only
`FULL_SCREEN_STAGES`: **GameUI** (Noesis UI rendering) → **VtResolve** →
**CombineUI**. (Read)

## Shading model and materials

The renderer is **deferred with clustered lighting** for opaque geometry and
**forward** for transparent geometry. (Named, consistent with the stage graph)

`Materials.metallib` holds pre-built permutations for each material, with one
vertex/fragment pair per pass suffix:

| Suffix | Count | Pass |
| --- | --- | --- |
| `_DEP` | 2,810 | Depth prepass (DeferredBuffer `DepthFirstPass`) |
| `_DEPS`, `_DEPST` | 2,810 each | Depth variants, probably shadow-map rendering (Named, unverified) |
| `_DEF` | 3,068 | G-buffer (`GBufferPass`) |
| `_VEL` | 3,068 | Object motion vectors |
| `_EMI` | 3,068 | Emissive |
| `_FOR` | 3,068 | Forward lighting (Alpha stage) |

These are combined with geometry variants (`_ST` static, `_STI` static
instanced, `_VT` virtual-textured, skinned and character variants) and feature
flags (`_WPO`, `_2S`, `_SSS`, `_VAT` and others). Terrain has its own shaders
(`Terrain_PS4–64` by layer count, bindless variants, `DEP`, `SHA`, `VEL` and
`EMI` passes). `Core.metallib` holds the engine passes listed above. Both
libraries are loaded with `newLibraryWithFile:error:` (`MetalAPI::Init`).

## Metal backend usage

All of the following was Read from Objective-C selector stubs and their call
sites.

- **Device and queue:** `newCommandQueueWithMaxCommandBufferCount:`.
- **Command buffers:** `commandBufferWithUnretainedReferences` in
  `MetalRenderer::BeginFrame`, `BeginBlitPass` and `CommitCommandBuffer`. The
  game manages resource lifetimes itself.
- **Encoders:** render, compute (`computeCommandEncoderWithDispatchType:`) and
  blit. There are no parallel render encoders.
- **Pipelines:** synchronous `newRenderPipelineStateWithDescriptor:error:`
  (`GPUDevice::CreatePipelineState`). No binary archives are used.
- **Small constants:** `setFragmentBytes`/`setBytes` in post steps; larger ones
  come from a uniform bump allocator (`MetalRenderer::AllocUniformsBuffer`).
- **Selectors with no stub at all**, so they are never called through normal
  messaging: heaps, argument encoders, `useHeap:`, fences, events, memory
  barriers, indirect indexed draws, rasterization rate maps and binary archives.
  Resource residency is declared per encoder with `useResources:count:usage:`.
- **Presentation:** `LSMTLView` configures the `CAMetalLayer` (device, pixel
  format, `framebufferOnly`, `drawableSize`, EDR through `updateHDRState:`).
  `setVsync:bufferCount:` sets `displaySyncEnabled` and
  `maximumDrawableCount`. `getDrawable` calls `nextDrawable`. Present is
  described in the frame lifecycle above.

## Candidate deep dives

Each of these can become its own page in this folder:

1. Frame lifecycle: worker-thread recording, command dispatcher format, Submit,
   command-buffer count and commit points
2. Culling: CPU culling, Masked Occlusion Culling, shadow and vista culls
3. Depth prepass and G-buffer: layout and formats
4. Shadows: cascades, PCF/PCSS selection, local-light atlas, tetrahedron
   projection
5. Clustered lighting, tile classification and volumetric fog
6. Sky, atmosphere and volumetric clouds
7. SSAO and SSR
8. Transparency, VFX and decals
9. Velocity, TAA/SMAA, jitter and history
10. Post-process chain and FSR/RCAS/CAS
11. Tone mapping, LUTs, HDR/EDR output and UI composition
12. Metal backend: pipelines, uniforms, residency and presentation
13. Virtual texturing (Granite)
