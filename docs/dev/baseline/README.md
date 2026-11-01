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

The stage and step descriptions use nothing from a running game. The
**Captured frame** columns come from one frame of the unmodified game (Ultra,
TAA, FSR 1 Performance, 3456×2160 output, 1728×1080 render, M5 Pro). Encoder
names refer to that frame's main command buffer, cb2: `re` is a render encoder,
`ce` a compute encoder and `be` a blit encoder. For per-encoder targets,
formats and the reasoning behind each match, see
[frame capture](frame-capture.md).

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

1. **Render views.** A `RenderView` (here an `ls::GameRenderView`, or the
   game's `ecl::EoCRenderView` subclass) is one camera and viewport rendered
   into a `RenderFrame`. `BaseApp::InitAPI` creates two views in the main
   window's frame: `"default"`, the 3D game view (`BaseApp+0x88`), and
   `"Fullscreen"`, the UI and final-output view (`BaseApp+0x90`). Each
   `ecl::BasicGameObjectRenderer` creates its own offscreen frame
   (`"BasicGameObjectRenderer"`) with one view. Its callers are the inventory
   paperdoll (`gui::LSPaperdoll`) and character icons
   (`ecl::CharacterIconRenderSystem`). `ecl::PlayerManager::CreateRenderView`
   also creates a view for each player, probably for split screen; where those
   views get their stages has not been traced. (Read)

   Views and their stage lists are built once, not every frame. `InitAPI`
   creates the two main views at startup, `BaseApp::Start` builds their stage
   lists through `InitFrameStages`, and `App::ExitGame` releases them. An
   offscreen view lasts as long as its `BasicGameObjectRenderer`. No rebuild
   path for the main views was found in the app and render code, but other
   code has not been searched. (Read)
2. **Stages.** Every render stage is an `rf::IAppStage`. Its interface has
   `Load`/`Unload`, `OnSizeChanged`, `OnStateChanged`, `UpdateIsRendering`,
   `GetQueueType`, and resource registration (`AddBuffer`, `AddFramebuffer`,
   `AddRenderPass`, `AddPipelineState`). Each `RenderView` holds exactly one
   `rf::StageGroup` (at `RenderView+0x10`), the ordered list of that view's
   stages. The group adds stages (`AddAppStage`, `AddAppStageBefore`), finds
   them by type (`GetStage`), shares buffers between them (`MapBuffer`) and
   forwards state changes to them (`OnStateChanged`). Changes don't rebuild
   the list: `OnSizeChanged` lets stages reallocate targets on resize,
   `OnStateChanged` passes settings changes on, and `UpdateIsRendering` (or a
   post step's enabled byte) skips a stage for a frame without removing it.
3. **Recording.** Each stage owns a **command list**, an
   `rf::RendererCommandBuffer` made when the stage is constructed. This is a
   CPU-side list of the game's own commands, not a Metal command buffer.
   Stages record through the backend-neutral interface (`BeginRenderPass`,
   `SetPipelineState`, `SetTexture`, `CompareSetAndBindConstantBuffer`,
   `CopyTextureToTexture` and so on). On Mac the concrete class is the
   subclass `rf::metal::MTLRendererCommandBuffer`, which overrides only
   `CreateTexture`, `LockTexture` and `SetVertexBuffer`. In `ExecuteWTKernel`
   ("worker-thread kernel"), stages run as `ls::WorkerThreadScheduler` jobs.
   They don't call Metal there: they append compact commands to an
   `ls::CommandDispatcherBuffer` with `AddCommand`. The
   [command map](command-buffer.md) lists every command and the Metal calls
   it replays to.
   `GameRenderView::StartRecording` uploads the per-view and per-camera
   constant buffers.

   The command-list objects persist, but their contents are recorded fresh
   every frame. Nothing is cached from one frame's commands to the next.
   There is no double buffering: the list's second `CommandDispatcherBuffer`
   holds cleanup callbacks, not commands. `ls::RenderThread::Update` runs
   `RenderFrame::StartRecording`, each view's `StartRecording` (which
   schedules the stage jobs), then `RenderFrame::FinishRecording`. That walks
   the stages in order: `RenderStage::FinishRecording` waits for one stage's
   batch and then calls its `Submit`. So a stage's replay overlaps the
   recording of later stages. The "render thread" is the main (AppKit)
   thread. See [frame lifecycle](frame-lifecycle.md). (Read)
4. **Submit.** On the render thread (`ls::RenderThread::Update`),
   `GameRenderView::Submit` walks its `StageGroup` in order and calls each
   stage's `Submit`. For most stages that's `ls::RenderStage::Submit`, which
   calls `rf::RendererCommandBuffer::Submit` on the stage's command list. That
   replays the list through `MetalRenderer` into **the Metal command buffer**
   (`MTLCommandBuffer`). This is where encoders are opened, state is set,
   draws and dispatches are issued, and `useResources:count:usage:` is called.
   Each command list reaches the renderer through a pointer stored at
   construction (`MTLRendererCommandBuffer+0x38`): the `MetalRenderer` at
   `rf::details::RendererBase::s_Instance + 0x1f0`, the one renderer for the
   whole app. `MetalRenderer::BeginFrame` makes a new
   `commandBufferWithUnretainedReferences` buffer only when none is open
   (`MetalRenderer+0x28`). So every stage of every view in a render frame
   replays into the same Metal command buffer. `RenderThread::Update`
   commits it after adding a completion handler that releases one of three
   frames-in-flight slots. After replay,
   `CommandDispatcherBuffer::PostExecuteCommandBuffer` resets the list's
   pages (freeing them only if the frame overflowed the first page), so the
   list starts empty for the next frame. (Read)
5. **Present.** `MetalRenderFrame::FlipBuffers` calls `presentDrawable:`, or
   `presentDrawable:afterMinimumDuration:` when a `GraphicSettings` flag
   (+0x28) is set. The interval is `1 / (rate + 1)`, where the rate comes
   from two settings fields (+0x18 and +0x1c). The captured 1/121 s matches a
   120 Hz display, so this is refresh pacing. The frame-rate cap runs on the
   game thread (`GameClock::CapFrame`). The drawable is fetched late, when
   CombineUI is replayed. See [frame lifecycle](frame-lifecycle.md). (Read;
   refresh pacing is Named)

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
`THIRD_PACK` = 41 03 1b 1a 00 21 3e 3f; `ADDITIONAL_STAGES` = 07. The
byte after `ADDITIONAL_STAGES` (0x43) is the start of an unrelated string,
not a stage type: the code passes that pack with a length of one.

A pack is used only while the stage list is built. The pack builder loops over
the pack's bytes and appends each new stage to the view's single `StageGroup`
with `AddAppStage`. The one exception is VertexProcessing, which goes in with
`AddAppStageBefore` ahead of Cull. Before building, it looks up stages that
earlier packs already created (Cull, CascadedShadowBuffer, Lighting, SSAO and
others) so it can wire new stages to them. Nothing records which pack a stage
came from. (Read)

Each call passes one pack as a `Span` of `{begin, end}` pointers built on the
stack; the end comes from a length immediate in the caller (`add x9, x8,
#len`). The pack builder doesn't know which pack it was given. It handles one
code at a time: look up existing stages, construct the stage, register it as
an event listener, then `AddAppStage`. That loads the stage and appends it
before the next code is read. The lookups return the first match by type, and
some constructors keep the result. For example, Alpha (`+0x2140`), Lighting
(`+0x2148`) and CascadedShadowMask (`+0x2150`) each store the first
CascadedShadowBuffer stage. Codes above 0x48 are skipped. (Read)

`StageGroup` is a member of the view (at `RenderView+0x10`), so adding to the
group is adding to the view. It holds the scene graph (+0x00), its view
(+0x08), the stage array (+0x10) and the count (+0x1c). It has no remove
method; only `~StageGroup` unloads and deletes stages. (Read)

### Views and their stage lists

bg3mfx can replace a view kind's packs with its own list
(`src/features/custom-render-stages/CustomRenderStages.h`). With `BG3MFX_TRACE_STAGE_LIST=1`, the
diagnostic runtime records every pack call described here.

Which packs a view gets is hard-coded as branches in
`BaseApp::InitFrameStages(RenderView*)`, based on three checks:

- **Is it the `"Fullscreen"` view (`BaseApp+0x90`)?** If so, it gets only
  `FULL_SCREEN_STAGES`.
- **Is the frame flag set?** `RenderView+0x8` is the view's `RenderFrame`.
  Frame `+0x38` is field `+0x28` of the `RenderFrameDesc` the frame was
  created from. When this flag is set, the view also gets
  `EARLY_VT_RESOLVE_STAGE` after `FIRST_PACK` and `ADDITIONAL_STAGES` at the
  end.
- **Is it the `"default"` view (`BaseApp+0x88`)?** If so, DebugWorld is built
  inline and added after `THIRD_PACK`.

(Read)

| View | Frame (flag) | Built by | Packs, in order | Game stages added afterwards |
| --- | --- | --- | --- | --- |
| `"default"`, the 3D game view (`BaseApp+0x88`) | Window `MetalRenderFrame` (flag clear) | `BaseApp::Start` → `App::InitFrameStages` (vtable slot 0x2c0) → `BaseApp::InitFrameStages` | `FIRST_PACK`, `SHADOW_BUFFER_PACK`, `SECOND_PACK`, `SHADOW_BUFFER_PACK`, `THIRD_PACK`, then DebugWorld | Yes |
| `"Fullscreen"`, UI and final output (`BaseApp+0x90`) | Same window frame (flag clear) | Same path as `"default"` | `FULL_SCREEN_STAGES` | No: `App` returns early because the anchor stages are missing |
| Player view, one per player (see below) | Window `MetalRenderFrame` (flag clear) | `ls::PlayerManager::CreateRenderView(short)` → `App::InitFrameStages` (slot 0x2c0) → `BaseApp::InitFrameStages` | Same as `"default"`, without DebugWorld | Yes |
| Offscreen object view: one per `ecl::BasicGameObjectRenderer`, for the inventory paperdoll and character icons | Its own `"BasicGameObjectRenderer"` frame (flag set: the renderer builds the desc with `+0x28` = 2) | `BasicGameObjectRenderer::InitRenderData` → `BaseApp::InitFrameStages` directly, not `App`'s override | `FIRST_PACK`, `EARLY_VT_RESOLVE_STAGE`, `SHADOW_BUFFER_PACK`, `SECOND_PACK`, `SHADOW_BUFFER_PACK`, `THIRD_PACK`, `ADDITIONAL_STAGES` | No |

`App::InitFrameStages` first looks up ClusteredAssignment, Decal,
EmissiveGameDecal, PostProcess and Cull (0x05, 0x46, 0x17, 0x21, 0x08). If
they are missing it returns, which is why the Fullscreen view gets no game
stages. Otherwise it builds each game stage inline and inserts it with
`AddAppStageBefore`:

| Game stage | Inserted before |
| --- | --- |
| `ecl::SurfaceCullStage` | ClusteredAssignment |
| `ecl::SurfaceMeshGenerationStage` | Decal |
| `ecl::SurfaceEmissiveRenderStage` | EmissiveGameDecal |
| `ecl::OutlineRenderStage` | PostProcess |
| `ecl::RegionRoomRenderStage` | PostProcess |

It also attaches sub-stages to existing stages, not to the group:
`ecl::SurfaceDecalRenderSubStage` to Decal, and a sub-stage on PostProcess,
probably the Sight and Outline post steps. (Read for the inserts; the
PostProcess sub-stage vtable wasn't resolved.)

#### Stage lists by view

In these tables:

- **Order** is the final list order: the order stages record and submit in.
- **Type** is the `rf::AppStageType` that the stage's `GetType()` returns.
- **Pack** is the source of the stage. "App" means `App::InitFrameStages`
  inserted it with `AddAppStageBefore`. "Inline" means `BaseApp` built it
  outside any pack.

**Game views:** the `"default"` view (31 stages) and each player view (the
same list, minus DebugWorld). The [next section](#3d-game-view-stage-order)
maps the default view's stages to the captured frame.

| Order | Type | Pack | Description |
| --- | --- | --- | --- |
| 1 | `0x47` FxRenderPrepare | FIRST_PACK | Prepares particle/VFX render data |
| 2 | `0x41` VertexProcessing | THIRD_PACK, inserted before Cull | GPU skinning and blend shapes |
| 3 | `0x08` Cull | FIRST_PACK | Visible objects, lights and light probes |
| 4 | `0x48` FxRenderUpdate | FIRST_PACK | VFX update |
| 5 | `0x35` ShadowTileAssignment | FIRST_PACK | Assigns local-light shadows to atlas tiles |
| 6 | `0x1e` LocalLightShadow | FIRST_PACK | Local-light shadow maps |
| 7 | `0x3a` SurfaceCull | App, before ClusteredAssignment | Culls ground surfaces (fire, water, blood and so on) |
| 8 | `0x05` ClusteredAssignment | FIRST_PACK | Assigns lights to view clusters |
| 9 | `0x0b` DeferredBuffer | FIRST_PACK | Depth prepass, G-buffer, linear depth |
| 10 | `0x02` CascadedShadowBuffer | SHADOW_BUFFER_PACK (first call) | Sun cascades. Redrawn by #21 before anything reads them |
| 11 | `0x3d` SurfaceMeshGeneration | App, before Decal | Builds surface meshes |
| 12 | `0x46` Decal | SECOND_PACK | Deferred decals into the G-buffer. The game attaches `SurfaceDecalRenderSubStage` to it |
| 13 | `0x36` Sky | SECOND_PACK | Skydome and atmosphere |
| 14 | `0x44` VolumetricClouds | SECOND_PACK | Volumetric clouds |
| 15 | `0x18` Emissive | SECOND_PACK | Emissive geometry |
| 16 | `0x3c` SurfaceEmissive | App, before EmissiveGameDecal | Emissive surfaces |
| 17 | `0x17` EmissiveGameDecal | SECOND_PACK | Emissive decals |
| 18 | `0x40` Velocity | SECOND_PACK | Motion vectors |
| 19 | `0x37` SSAO | SECOND_PACK | Screen-space ambient occlusion |
| 20 | `0x38` SSR | SECOND_PACK | Screen-space reflections |
| 21 | `0x02` CascadedShadowBuffer | SHADOW_BUFFER_PACK (second call) | Sun cascades again: the maps later stages read |
| 22 | `0x03` CascadedShadowMask | THIRD_PACK | Sun shadow mask |
| 23 | `0x1b` Lighting | THIRD_PACK | Clustered deferred lighting and volumetric fog |
| 24 | `0x1a` LightingCombine | THIRD_PACK | Subsurface scattering and fog composite |
| 25 | `0x00` Alpha | THIRD_PACK | Forward-lit transparents |
| 26 | `0x1f` Outline | App, before PostProcess | Character and object outline mask |
| 27 | `0x33` RegionRoom | App, before PostProcess | Region and room trigger masks |
| 28 | `0x21` PostProcess | THIRD_PACK | Post-process chain. The game attaches a sub-stage to it, probably Sight and Outline |
| 29 | `0x3e` TextureCull | THIRD_PACK | Texture streaming requests |
| 30 | `0x3f` Unlit | THIRD_PACK | Unlit geometry |
| 31 | `0x0a` DebugWorld | Inline, `"default"` view only | Debug drawing |

**`"Fullscreen"` view** (3 stages; see
[Full-screen (UI) view](#full-screen-ui-view)):

| Order | Type | Pack | Description |
| --- | --- | --- | --- |
| 1 | `0x19` GameUI | FULL_SCREEN_STAGES | Noesis UI rendering at output resolution |
| 2 | `0x45` VtResolve | FULL_SCREEN_STAGES | Virtual-texture feedback resolve and readback |
| 3 | `0x07` CombineUI | FULL_SCREEN_STAGES | Composites UI over the tone-mapped scene into the drawable |

**Offscreen object view** (27 stages, all engine stages). It has no surfaces,
outlines, region masks or DebugWorld, adds its own early VtResolve and
CombineUI, and, like the game views, renders the sun shadows twice:

| Order | Type | Pack | Description |
| --- | --- | --- | --- |
| 1 | `0x47` FxRenderPrepare | FIRST_PACK | Prepares particle/VFX render data |
| 2 | `0x41` VertexProcessing | THIRD_PACK, inserted before Cull | GPU skinning and blend shapes |
| 3 | `0x08` Cull | FIRST_PACK | Visible objects, lights and light probes |
| 4 | `0x48` FxRenderUpdate | FIRST_PACK | VFX update |
| 5 | `0x35` ShadowTileAssignment | FIRST_PACK | Assigns local-light shadows to atlas tiles |
| 6 | `0x1e` LocalLightShadow | FIRST_PACK | Local-light shadow maps |
| 7 | `0x05` ClusteredAssignment | FIRST_PACK | Assigns lights to view clusters |
| 8 | `0x0b` DeferredBuffer | FIRST_PACK | Depth prepass, G-buffer, linear depth |
| 9 | `0x45` VtResolve | EARLY_VT_RESOLVE_STAGE | Virtual-texture feedback for this view |
| 10 | `0x02` CascadedShadowBuffer | SHADOW_BUFFER_PACK (first call) | Sun cascades, redrawn by #19 |
| 11 | `0x46` Decal | SECOND_PACK | Deferred decals into the G-buffer |
| 12 | `0x36` Sky | SECOND_PACK | Skydome and atmosphere |
| 13 | `0x44` VolumetricClouds | SECOND_PACK | Volumetric clouds |
| 14 | `0x18` Emissive | SECOND_PACK | Emissive geometry |
| 15 | `0x17` EmissiveGameDecal | SECOND_PACK | Emissive decals |
| 16 | `0x40` Velocity | SECOND_PACK | Motion vectors |
| 17 | `0x37` SSAO | SECOND_PACK | Screen-space ambient occlusion |
| 18 | `0x38` SSR | SECOND_PACK | Screen-space reflections |
| 19 | `0x02` CascadedShadowBuffer | SHADOW_BUFFER_PACK (second call) | Sun cascades again |
| 20 | `0x03` CascadedShadowMask | THIRD_PACK | Sun shadow mask |
| 21 | `0x1b` Lighting | THIRD_PACK | Clustered deferred lighting and volumetric fog |
| 22 | `0x1a` LightingCombine | THIRD_PACK | Subsurface scattering and fog composite |
| 23 | `0x00` Alpha | THIRD_PACK | Forward-lit transparents |
| 24 | `0x21` PostProcess | THIRD_PACK | Post-process chain, without the game's Sight and Outline steps |
| 25 | `0x3e` TextureCull | THIRD_PACK | Texture streaming requests |
| 26 | `0x3f` Unlit | THIRD_PACK | Unlit geometry |
| 27 | `0x07` CombineUI | ADDITIONAL_STAGES | Composites this view's output |

The offscreen order is derived from the pack sequence and the
VertexProcessing insert, not from a capture of an offscreen view. The game
stages' type values come from their `GetType()`.

Player views are a fourth kind. `ecl::PlayerManager::CreatePlayer` calls
`ls::PlayerManager::CreateRenderView(short)`, which does three things:

1. It creates an `ecl::EoCRenderView` in the window frame, through
   `ecl::PlayerManager::CreateRenderView(RenderFrame&)`.
2. It sets a byte at view `+0x2268`, and clears it again unless the view
   belongs to the player that the manager's list reaches first. This is
   probably an "active" flag that keeps split-screen views from rendering
   until they're needed (Named).
3. It calls the app's `InitFrameStages` through vtable slot 0x2c0.

Slot 0x2c0 is `App`'s override, and a player view is neither `"default"` nor
`"Fullscreen"`, and its frame flag is clear. So a player view gets the same
packs and game stages as the `"default"` view, minus DebugWorld. (Read for
the calls.) Whether single-player creates one of these views for player 1
hasn't been checked. The capture shows one 3D view rendering.

## 3D game view: stage order

This is the order of the stage list after all insertions. The `StageGroup`
records and submits in this list order (Read for list order; actual GPU
overlap is not established). Stages marked † are inserted by the game layer
(`ecl::`) with `AddAppStageBefore`.

| # | Stage | What it does | Captured frame |
| --- | --- | --- | --- |
| 1 | FxRenderPrepare | Prepares particle/VFX render data (Named) | CPU only: no encoder |
| 2 | VertexProcessing | Inserted before Cull. GPU skinning and blend shapes: `SkinningCompute`, `BlendShapeCompute` (Named) | ce0: 45 `SkinningCompute`, 2 `BlendShapeComputeNoMeshes`. Runs first on the GPU, although Cull precedes it in recording |
| 3 | Cull | Visible objects, lights and light probes; assigns probes to forward objects (Read) | CPU only: no encoder |
| 4 | FxRenderUpdate | VFX update (Named) | CPU only: no encoder |
| 5 | ShadowTileAssignment | Assigns local-light shadows to atlas tiles (Named) | CPU only: no encoder |
| 6 | LocalLightShadow | Renders local-light shadow maps; uses tetrahedron projections for point lights (Read: `TetrahedronShadowHelper`) | Empty: no shadowed local lights in view |
| 7 | SurfaceCull † | Culls BG3 ground surfaces (fire, water, blood and so on) | CPU only: no encoder |
| 8 | ClusteredAssignment | Assigns lights to view clusters (`ClusterAssignment` shader) | ce1: `ClusterAssignment` |
| 9 | DeferredBuffer | `DepthFirstPass` depth prepass, then `GBufferPass` (Read: nested classes, each recorded by its own worker job; see [DeferredBufferStage](deferred-buffer-stage.md)) | re2: depth prepass, 569 draws. re3: G-buffer (RG16F + 4 × RGBA8), 571 draws. re4: `LinearizeDepth`. re5: decal normal extract |
| 10 | CascadedShadowBuffer | Sun cascaded shadow maps. Owns `ShadowCullStage`, `VistaShadowCullStage` and `PreVertexProcessingCullStage` (Read). `SHADOW_BUFFER_PACK` is passed twice, so the view has two of these stages (see #21) | re6–re10: 4 cascades into a 2048² Depth16 array plus an incrementally updated layer, 1,897 draws. Nothing reads them before #21 overwrites them ([finding 1](frame-capture.md#findings)) |
| 11 | SurfaceMeshGeneration † | Builds surface meshes | No encoder of its own |
| 12 | Decal | Deferred decals into the G-buffer: `DeferredDecalRenderSubStage`, `DeferredGameDecalRenderSubStage`, game `SurfaceDecalRenderSubStage` (Read) | ce11: `PPKernel4`, unidentified, matched by order. re12: 65 `_DEF` decals |
| 13 | Sky | Skydome and atmosphere (`PPEmissiveSkydome_*`, precomputed `Inscatter*`/`Transmittance`/`Irradiance`) | re13: `PPEmissiveSkydome_Procedural_PS` |
| 14 | VolumetricClouds | `VolumetricClouds_Q0–Q3`, downsample, upsample-and-blend, compose | ce14: downsample and `Q0`. re15–re16: upsample-and-blend at 864×540, then into the scene |
| 15 | Emissive | Emissive geometry (`_EMI` material variants) | re17: 46 `_EMI` |
| 16 | SurfaceEmissive † | Emissive surfaces | re18: 9 `_EMI`, matched by order |
| 17 | EmissiveGameDecal | Emissive decals | re19: encoder opened with 0 draws |
| 18 | Velocity | Motion vectors: camera pass `VelocityBufferCamera_PS` and object `_VEL` variants (Named) | re20: 285 `_VEL` + camera pass |
| 19 | SSAO | `PPSAO_*` with deinterleave/reinterleave, blur, orthographic variant | re21–re28: deinterleave, 4 × `PPSAO_PS` at 864×540, reinterleave, 2 blurs |
| 20 | SSR | Stochastic screen-space reflections: `SSSRClassifyTiles`, `Intersect`, `ResolveSpatial`, `ResolveTemporal`, `BlurReflections` | Empty: no `SSSR*` work |
| 21 | CascadedShadowBuffer (second) | Second instance from the repeated `SHADOW_BUFFER_PACK`, between `SECOND_PACK` and `THIRD_PACK` (Read) | re29–re33: clears and redraws the same 1,897 draws as #10. These are the maps the later stages read |
| 22 | CascadedShadowMask | Builds the sun shadow mask from cascades: `DirLight_Cascaded_PCF_{1–4}x1024`, `PCSS_{1–4}x{1024,2048}` | re34: `DirLight_Cascaded_PCSS_4x2048`. First reader of the shadow maps |
| 23 | Lighting | Clustered deferred lighting. Sub-stages (Read): clear tile counts, tile classification, `DrawClusteredLighting` (`ClusteredLighting_0–13`, with `_SSR` variants), volumetric fog depth tiles, dilate, initialize, lighting and gather | ce35: clear, depth tiles, dilate, classification. ce36: `ClusteredLighting_0–13`, fog initialize and lighting. ce37: fog gather |
| 24 | LightingCombine | Combines lighting; sub-stages `SubStage_SSSS` (separable subsurface scattering, `PPSSSS_H/V`) and `SubStage_DrawFog` (Read) | re38–re39: `PPSSSS_H/V`. re40: `DeferredFog_Cubic_PS` |
| 25 | Alpha | Forward-lit transparent geometry (`_FOR` variants); instancing hash and back-to-front sort (Read) | be41: scene-color copy, probably for refraction. re42: 83 `_FOR` |
| 26 | Outline † | Character/object outline mask (`EoCOutline*`) | Empty: no highlights |
| 27 | RegionRoom † | Region and room trigger masks (`EoCRegionTrigger*`, `EoCRoomTrigger*`) | Empty: no triggers |
| 28 | PostProcess | Ordered post-process chain (next section) | ce43–re63, mapped in the next section |
| 29 | TextureCull | Texture streaming requests (Named) | CPU only: no encoder |
| 30 | Unlit | Unlit geometry, sorted back to front (Read) | No draws |
| 31 | DebugWorld | Debug drawing, created inline by `BaseApp` for the `"default"` view only | No draws |

Views whose frame has the flag set (the offscreen object views) also get an
early VtResolve after DeferredBuffer and a CombineUI at the end (`CombineUI`,
`_HDR` and `_NoUI` variants). The `"default"` view has neither, which matches
the capture: its only `CombineUI` draw belongs to the full-screen view.

Two clear-only command buffers, cb0 and cb1, precede the frame. They clear
the diffuse and specular lighting targets that clustered lighting accumulates
into (see [textures](frame-capture.md#textures)). Which code issues them
hasn't been traced. Everything else is in cb2: 78 encoders,
5,655 draws, 78 dispatches and 6 blits. The sun shadow passes are a third of
those draws (2 × 1,897).

## Post-process chain

`PostProcessStage::Load` (`0x10608f598`) constructs the steps in the order
below. A step whose "supported" byte (+0x19) is clear after construction is
dropped. `ExecuteWTKernel` then runs the list in order and skips steps whose
enabled byte (+0x18) is clear. The game layer inserts Sight and Outline
directly after ColorGrading. FSR is created right after ColorGrading too, when
a render-view setting is clear. (Read)

| # | Step | What it does | Captured frame |
| --- | --- | --- | --- |
| 1 | ClearRenderView | | Off |
| 2 | GodRays | | Off |
| 3 | DOF | Circular/Gaussian bokeh at half or quarter resolution, CoC near/far composite | Off |
| 4 | FadeBlending | | ce43: `FadeBlending` |
| 5 | Exposure *or* ExposureOld | Histogram and EV | ce43: ExposureOld (`OldPPCalculateEV64x64ComputeCS`, `OldPPExposureCompute_ProgressiveCS`) |
| 6 | ReExpose | | re44: `PPRexpose_PS` |
| 7 | LensFlare | | Off |
| 8 | DarkenEnvironment | | Off |
| 9 | RadialBlur | | Off |
| 10 | SMAA | | Off: TAA selected |
| 11 | TAA | `PPTAA_PS` | be45–be46: input/history copies. re47: `PPTAA_PS` |
| 12 | History | | be48: history copy |
| 13 | Bloom | Downsample/upsample blur chain | re49–re58: 864×540 down to 54×34 and back. be59: scene-color copy after it |
| 14 | ChromaticAberration | | Off |
| 15 | ComputeLUTs | ACES v1 tonemapping LUT; ZCAM display LUT; grading and fade LUTs | Not run: LUTs not rebuilt this frame |
| 16 | ColorGrading | `PPColorGradingApplyLUTPS` | re60 |
| 17 | Sight † | `EoCSight`, the stealth/vision overlay | Empty |
| 18 | Outline † | Outline blur and combine | Empty |
| 19 | FSR | `FSR_Tonemap` full-screen draw, then compute `FSR` and `FSR_RCAS` (Read: `PostProcessStep_FSR::ExecuteWTKernel`). Only when FSR upscaling is selected (Named) | re61: `FSR_Tonemap`. ce62: `FSR` upscale to 3456×2160, `FSR_RCAS` |
| 20 | InjectTexture | | Off |
| 21 | ToneMap | `PPToneMap_LUT` | re63: RGB10A2 at 3456×2160 |
| 22 | CAS | FidelityFX contrast-adaptive sharpening | Off in settings |
| 23 | Vignette | | Off |
| 24 | Calibration | Brightness and gamma calibration | Off |

Four blits move scene color between textures in this chain (be45, be46, be48,
be59). With be41 before Alpha, the frame makes five full-screen copies of
scene color.

So anti-aliasing (SMAA or TAA), bloom and grading all run at render resolution
in linear HDR. FSR 1 upscales before tone mapping, and UI composition comes
last. The library also contains `PPFXAA_*`, but no FXAA step class exists.

## Full-screen (UI) view

The app's dedicated full-screen view (`BaseApp+0x90`) gets only
`FULL_SCREEN_STAGES`: **GameUI** (Noesis UI rendering) → **VtResolve** →
**CombineUI**. (Read)

In the captured frame these are the last encoders in cb2, in this order:
GameUI is re64–re74 (Noesis paths, SDF text and a blur chain at output
resolution), VtResolve is ce75 (`DownsampleResolver`) plus be76 (a 108×68
feedback readback), and CombineUI is re77, which draws into the drawable.

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
   command-buffer count and commit points. Done: the
   [command map](command-buffer.md) covers the command format and replay, and
   [frame lifecycle](frame-lifecycle.md) covers threads, handoff, recording
   and replay overlap, commit, frames in flight and present
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
