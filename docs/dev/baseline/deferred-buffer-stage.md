# DeferredBufferStage

`ls::DeferredBufferStage` (`rf::AppStageType` `0x0b`, First pack) records the
depth prepass, the G-buffer, LinearizeDepth and the decal normal extract: re2–re5
in the [frame capture](frame-capture.md). This page maps its vtables and how it
records, for overriding it. Addresses are from build 4.1.1.7631656 (ARM64).
Everything here was read from the disassembly (Read) unless marked.

## Object layout

The stage is a `ls::RenderStage` (primary base, `rf::IAppStage` interface) and a
`ls::WorkerThreadJob` (secondary base at `stage + 0x20`, offset-to-top -32). It
embeds its two passes, each a `WorkerThreadJob` with its own command list:

| Offset | What |
| --- | --- |
| +0x00 | vptr, primary vtable |
| +0x20 | vptr, `WorkerThreadJob` vtable (the stage's own job) |
| +0x2140 | `DepthFirstPass` object (a `WorkerThreadJob`) |
| +0x2160 | its command list (`MTLRendererCommandBuffer`, pass +0x20) |
| +0x4260 | `GBufferPass` object |
| +0x4280 | its command list |

`DepthFirstPass::OnWTCanceled` cancels the list at pass +0x20 when the byte at
pass +0xa0 is set, and clears the halfword at +0xa0.

## Vtables

`vtable for ls::DeferredBufferStage` at `0x10885dbf8` (0xd0 bytes). Slots count
from the address point, `vtable + 0x10`:

| Slot | Entry | Function |
| --- | --- | --- |
| 0 | +0x10 | `~DeferredBufferStage()` (complete) |
| 1 | +0x18 | `~DeferredBufferStage()` (deleting) |
| 2 | +0x20 | `DeferredBufferStage::GetType() const` |
| 3 | +0x28 | `DeferredBufferStage::Load()` (`0x105dd5ae4`) |
| 4 | +0x30 | `DeferredBufferStage::Unload()` (`0x105dd8710`) |
| 5 | +0x38 | `DeferredBufferStage::Submit()` (`0x105dd8c08`) |
| 6 | +0x40 | `DeferredBufferStage::UpdateIsRendering()` (`0x105dd8c38`) |
| 7 | +0x48 | `DeferredBufferStage::StartRecording()` (`0x105dd8cec`) |
| 8 | +0x50 | `RenderStage::DoWhileRecording()` |
| 9 | +0x58 | `RenderStage::FinishRecording()` |
| 10 | +0x60 | `RenderStage::Cancel()` |
| 11 | +0x68 | `IAppStage::OnStateChanged()` |
| 12 | +0x70 | `IAppStage::OnSizeChanged(int, int)` |
| 13 | +0x78 | `IAppStage::OnDisable()` |
| 14 | +0x80 | `RenderStage::GetQueueType() const` |
| 15 | +0x88 | `RenderStage::OnWTCompletion()` |
| 16 | +0x90 | `RenderStage::OnWTCanceled()` |
| 17 | +0x98 | `DeferredBufferStage::ExecuteWTKernel()` (`0x105dd8fc4`) |

The `WorkerThreadJob` vtable follows at `0x10885dc98` (offset-to-top -32,
type info, then slots at +0xb0): non-virtual thunks to `OnWTCompletion`,
`OnWTCanceled` and `ExecuteWTKernel` (`0x105dd8fc8`), then
`WorkerThreadJob::GetHeuristic() const`. The scheduler calls the thunks with
`this` = `stage + 0x20`, so overriding a job method means patching both its
primary slot and its thunk slot.

The passes have their own vtables, each a `WorkerThreadJob`:

| Slot | `DepthFirstPass` (`0x10885dcc8`) | `GBufferPass` (`0x10885dcf8`) |
| --- | --- | --- |
| 0 | `OnWTCompletion()` (`0x105dd8fcc`, empty) | `OnWTCompletion()` (`0x105dd986c`) |
| 1 | `OnWTCanceled()` (`0x105dd8fd0`) | `OnWTCanceled()` (`0x105dd9870`) |
| 2 | `ExecuteWTKernel()` (`0x105dd9000`) | `ExecuteWTKernel()` (`0x105dd9874`) |
| 3 | `WorkerThreadJob::GetHeuristic() const` | same |

Everything else the stage does is BG3's `RenderStage`/`IAppStage` default,
including `OnSizeChanged`.

## Load

`DeferredBufferStage::Load` (`0x105dd5ae4`, about 2,800 instructions, most
of it inlined descriptor building) creates, in order:

1. **One depth-stencil state**, with `GPUDevice::CreateDepthState`, stored in a
   static (`0x10896d580`) rather than the stage. The extract pipeline uses
   it, so it is presumably re5's dss32 (depth Always, stencil Replace).
2. **Four engine shaders** with `RenderStage::LoadEngineShader`, by file name:

   | Field | Shader |
   | --- | --- |
   | +0x63a8 | `FadePattern.bshd` |
   | +0x63b8 | `LinearizeDepth.bshd` |
   | +0x63c0 | `Orthographic/LinearizeDepth.bshd` |
   | +0x63c8 | `DeferredDecal_ExtractNormal.bshd` |

3. **Render targets in the scene graph**, by name hash. The depth buffer is
   only referenced (`SceneGraph::ReferenceRenderTarget`), so another owner
   creates it. The other seven are created here (`SceneGraph::AddRenderTarget`).
   Later stages find them by these hashes (`SceneGraph::GetTextureSRV`), which
   is how the G-buffer reaches Decal, Lighting and the rest. The texture column
   comes from the kernels' use of the hashes and the capture; the G-buffer rows
   marked * are matched only by creation order against re3's color0–4 (Named).

   | Hash | Call | Texture in the capture |
   | --- | --- | --- |
   | `0x22f3e110` | Reference | tex418 depth (prepass and G-buffer viewport) |
   | `0x4c0d1b61` | Add | tex420 RG16F, G-buffer color0, extract's `GBuffer0` |
   | `0x3b0a2bf7` | Add | tex212 RGBA8, color1 * |
   | `0xa2037a4d` | Add | tex421 RGBA8, color2, extract's `GBuffer2` |
   | `0xd5044adb` | Add | tex422 RGBA8, color3 * |
   | `0x1af4071a` | Add | tex423 RGBA8, color4 * |
   | `0xff193183` | Add | tex424 R32F, linear depth (LinearizeDepth viewport) |
   | `0x5be0fb7a` | Add | tex425 RG16F, normal extract (extract viewport) |

4. **Four render passes** with `IAppStage::AddRenderPass(TemplateRenderPassDesc&&)`.
   Each descriptor lists its render targets (`TemplateRenderPassDesc::RT`) and
   subpasses (`SubPass`). Their load/store and clear fields have not been
   decoded yet.

   | `ManagedRenderPass` | Raw `RenderPass*` | Pass |
   | --- | --- | --- |
   | +0x63d0 | +0x63f0 | Prepass |
   | +0x63d8 | +0x63f8 | G-buffer |
   | +0x6450 | via its +0x8 | LinearizeDepth |
   | +0x6470 | via its +0x8 | Normal extract |

5. **Four framebuffers** with `IAppStage::AddFramebuffer(pass, textures)`:
   +0x63e0 (prepass), +0x63e8 (G-buffer), +0x6458 (LinearizeDepth), +0x6478
   (extract). `StartRecording` refreshes the raw pass pointers (+0x63f0,
   +0x63f8) and the prepass and G-buffer framebuffer pointers (+0x6400,
   +0x6408) every frame.
6. **A one-off command list.** Load constructs a `MTLRendererCommandBuffer`,
   records a command with dynamic constant data, submits it and turns on
   rolling buffers. Its purpose hasn't been followed.
7. **Three pipelines** with `IAppStage::AddPipelineState`: +0x6460
   (LinearizeDepth), +0x6468 (orthographic LinearizeDepth) and +0x6480
   (extract). The prepass and G-buffer material pipelines are not stage
   pipelines: materials supply them through `RenderableObjectSet::Render`, and
   `GPUDevice` builds them for the current pass. `FadePattern`'s pipeline isn't
   created here either.

`TPipelineStateDescriptor<ManagedRenderPass*>`, as Load fills it. Shader,
pass, depth state and stencil reference are Read. The other fields are Named
from their values:

| Offset | LinearizeDepth | Extract | Field |
| --- | --- | --- | --- |
| +0x00 | +0x63b8 | +0x63c8 | `ShaderID` |
| +0x08 | `[[stage+0x2030]+0x1c8]` | same | vertex layout, presumably the full-screen triangle's |
| +0x10 | 1 | 1 | byte flag |
| +0x18 | `0x108af4258` | same | static state, probably blend |
| +0x20 | `0x10897a668` | `0x10896d580` | depth-stencil state |
| +0x28 | 0 | 0x40 | stencil reference (re5 uses 64) |
| +0x30 | `0x10897a598` | same | static state, probably rasterizer |
| +0x38 | -1 | -1 | |
| +0x40 | +0x6450 | +0x6470 | `ManagedRenderPass*` |
| +0x48 | 0 | 0 | presumably the subpass index |

## TemplateRenderPassDesc

A render pass is described by `rf::TemplateRenderPassDesc<T>`. Stages fill
`T = TypeWrap<unsigned, Texture*>`, which names targets by scene-graph hash.
`IAppStage::AddRenderPass` (`0x10640ef4c`) then:

1. Hashes the descriptor (every render target's fields and the subpasses) and
   looks the hash up, so identical descriptors share one render pass.
2. Converts names to formats with `SceneGraph::MakeRenderPassDesc`, giving a
   `TemplateRenderPassDesc<EFormat>`.
3. Calls `metal::GPUDevice::CreateRenderPass` (`0x10645b198`). That copies the
   descriptor into a 0x30-byte heap object: the `RenderPass` that replay reads
   at `MetalRenderer+0x2b70`. So the replay-time `RenderPass` has the
   descriptor's layout.
4. Copy-constructs the name-based descriptor again. It presumably keeps it in
   the `ManagedRenderPass` for recreation, but where hasn't been checked.

Field meanings below come from the copy loop in `AddRenderPass`, from
`BeginRenderSubPass`, which turns them into an `MTLRenderPassDescriptor`, and
from the 0x0f replay, which stores clear values. All are Read except where
marked.

**Descriptor (0x30 bytes):** three `ls::DynamicArray`s, each a pointer, a
capacity (u32 at +0x8) and a count (u32 at +0xc).

| Offset | Array |
| --- | --- |
| +0x00 | render targets (`RT`, 0x2c bytes each) |
| +0x10 | subpasses (`SubPass`, 0x28 bytes each) |
| +0x20 | a third array, hashed with the rest; element type unknown |

**`RT` (0x2c bytes):**

| Offset | Type | Meaning |
| --- | --- | --- |
| +0x00 | u32 | Target: scene-graph name hash (name-based) or `EFormat` (format-based) |
| +0x04 | u16, then a byte of two nibbles, then s8 | View selection; the G-buffer color entries hold `0x05410002` across +0x08..+0x0b (Named) |
| +0x08 | same packing | A second view selection (Named) |
| +0x0c | s32 | Color load action |
| +0x10 | s32 | Color store action |
| +0x14 | s32 | Depth load action |
| +0x18 | s32 | Depth store action |
| +0x1c | s32 | Stencil load action |
| +0x20 | s32 | Stencil store action |
| +0x24 | s32 | Unknown; 1 on G-buffer color0 |
| +0x28 | u8 | 1 for a depth-stencil target |
| +0x29 | u8 | Unknown; 0 in the G-buffer entries |

Action values:
- **Load (all three):** 0 = `DontCare`, 1 = `Clear`, 2 = `Load`. A `Clear`
  whose clear value `BeginRenderPass` didn't supply falls back to `Load`.
- **Color store:** 3 = `Store`; any other value = `DontCare`.
- **Depth and stencil store:** nonzero = `Store`.

The values of the other store codes (presumably resolve variants) haven't
been read.

**`SubPass` (0x28 bytes),** from its constructor
`SubPass(initializer_list<int> colors, int depth, bool, initializer_list<int>)`
(`0x105dd0118`):

| Offset | Meaning |
| --- | --- |
| +0x00 | `DynamicArray<int>`: color attachments, as indices into the RT array, in color-slot order (count at +0xc) |
| +0x10 | Depth-stencil RT index, -1 for none |
| +0x14 | bool, unknown |
| +0x18 | `DynamicArray<int>`, unknown, probably input attachments (count at +0x24) |

`BeginRenderSubPass`'s keep-the-encoder check compares exactly these fields.

**Framebuffer entries** (`[MetalRenderer+0x2b78]`, 0x18 bytes, indexed like
the RT array):

| Offset | Meaning |
| --- | --- |
| +0x00 | Texture object; its `id<MTLTexture>` is at +0x38 |
| +0x08 | s16 slice, -1 for none |
| +0x10 | s32 mip level, -1 for none |

**For the merged pass:** the descriptor would hold 7 RT entries: depth with
`Clear`/`Store`, the five G-buffer colors, and tex425's entry, each copied from
BG3's own entries. It would have one subpass with colors 1–6 and depth 0. A
stage override can build this in its `Load` with BG3's `SubPass` constructor
and `AddRenderPass`. The simplest source for the entries is BG3's own
descriptors, which means finding where the `ManagedRenderPass` keeps its copy.

## How it records and submits

- **`StartRecording`** schedules the two passes as separate worker jobs
  (`ScheduleJob(stage + 0x2140)`, `ScheduleJob(stage + 0x4260)`), so the prepass
  and the G-buffer record in parallel, each into its own list. The stage's own
  `ExecuteWTKernel` is an empty `ret`: the stage records nothing itself.
- **`DepthFirstPass::ExecuteWTKernel`** (re2): builds a `RenderContext` for its
  list, sorts the visible set by material and instancing hash and by fade
  opacity, updates instancing buffers, then `BeginRenderPass` +
  `BeginRenderSubPass(0)`, one draw (the `FadePattern` draw in the capture),
  4 samplers and a buffer, viewport, skinning buffer and per-target constant
  buffer, two `RenderableObjectSet::Render` calls, and the end-pass command.
- **`GBufferPass::ExecuteWTKernel`** records three passes into its list:
  1. G-buffer (re3): `RenderContext`, `OpaqueSet::Sort` twice, the same setup
     as the prepass, four `RenderableObjectSet::Render` calls, end pass.
  2. LinearizeDepth (re4): `ResizableFramebuffer::Create`, `BeginRenderPass`,
     `FullScreenTriangle::RenderFullScreen` with dynamic constants and one
     texture.
  3. Decal normal extract (re5): two `SceneGraph::GetTextureSRV` (tex420,
     tex421), `ResizableFramebuffer::Create`, `BeginRenderPass`,
     `RenderFullScreen`, two textures.
- **Four render passes, one subpass each.** Every pass calls
  `BeginRenderPass` with its own `RenderPass` and then
  `BeginRenderSubPass(0)`; none uses a second subpass. The pass and framebuffer
  pointers come from the stage's fields, which `Load` creates (see [Load](#load)):

  | Pass | Render pass | Framebuffer | Clear-value span |
  | --- | --- | --- | --- |
  | Prepass (re2) | +0x63f0 | +0x6400 | 1 entry |
  | G-buffer (re3) | +0x63f8 | +0x6408 | 6 entries |
  | LinearizeDepth (re4) | `ManagedRenderPass` at +0x6450 (its +0x8) | `ResizableFramebuffer` at +0x6458 | 1 entry |
  | Normal extract (re5) | `ManagedRenderPass` at +0x6470 (its +0x8) | `ResizableFramebuffer` at +0x6478 | 2 entries |

  LinearizeDepth's and the extract's framebuffers are created on first use
  (`ResizableFramebuffer::Create`) when the frame has none yet.
- **`Submit`** replays the prepass list, then the G-buffer list
  (`RendererCommandBuffer::Submit` on `stage + 0x2160`, then `stage + 0x4280`).

The kernels also contain inlined immediate-mode paths: direct `MetalRenderer`
calls and `drawPrimitives:` used when a list executes immediately (+0x82 in
the [command map](command-buffer.md#record-format)).

`UpdateIsRendering` sets the stage's rendering byte (+0x18) from the stage's
enabled byte (+0x19), the view's state and a `SceneSystem` flag.

## What this means for a merged prepass + G-buffer

- `BeginRenderPass` is a real call (`rf::RendererCommandBuffer::BeginRenderPass`),
  so a wrapper can substitute the render pass and framebuffer. The end-pass
  command is recorded inline (`AddCommand` and an opcode store), so it can't be
  intercepted by a call hook.
- The prepass and G-buffer draws live in different lists recorded on different
  threads, joined only at `Submit`. A merged encoder has to start in the prepass
  list and continue in the G-buffer list. The prepass list must not end its
  pass. The G-buffer list's own `BeginRenderPass` + `BeginRenderSubPass(0)` then
  keeps the encoder, with no change to replay:
  - **0x0f doesn't touch the subpass index.** Its replay
    (`0x10642a660`) opens the frame's command buffer if none is open, stores the
    pass (+0x2b70), the framebuffer (+0x2b78) and the clear values, and does
    nothing else. Only end pass (0x12, `0x10642a53c`) sets +0x2b80 to -1.
  - **0x11 keeps a matching encoder.** `BeginRenderSubPass(i)` compares
    subpass *i* with the current subpass +0x2b80, both taken from the
    **current** pass, which 0x0f has just replaced. It compares their
    attachment counts and index lists and the fields at +0x10, +0x14, +0x18
    and +0x24. On a match (`0x10645fd4c`) it stores *i* in +0x2b80 and
    returns: no `endEncoding`, no new encoder, and applied state kept.
  - **Nothing happens between lists.** `RendererCommandBuffer::Submit` does
    nothing to `MetalRenderer` between lists. It only calls `EndSubFrame` first
    for an immediate-mode list (+0x82), and afterwards
    `PostExecuteCommandBuffer` and clears the list's flags.

  So if the prepass list ends without 0x12, and the G-buffer list begins the
  same pass at subpass 0, the G-buffer draws continue the prepass encoder. The
  check never looks at the open encoder's real attachments, so keeping the
  encoder is only correct if both lists really name the same pass and
  framebuffer. The pipeline lookup reads the current pass (+0x2b70), so the
  G-buffer list must begin the merged pass, not BG3's G-buffer pass. The clear
  values in its 0x0f are stored but unused.
- LinearizeDepth and the extract are recorded by the G-buffer kernel after the
  G-buffer, in that order. Putting the extract inside the merged encoder and
  LinearizeDepth after it means overriding `GBufferPass::ExecuteWTKernel` (slot 2
  of its vtable) or reordering its recorded output. The hook points below do
  the second without scanning.

## Hook points for the merge

Recording and replay never overlap. `ls::RenderThread::Update` runs
`RenderFrame::StartRecording`, each view's `StartRecording`, then
`RenderFrame::FinishRecording`, which waits on the worker batches, and then
each view's `Submit`, all on the render thread. Each list has one dispatcher,
emptied after replay (see the [command map](command-buffer.md#record-format)).
So state kept in the stage between its kernels and its `Submit` needs no
locking beyond the two kernels running on different threads.

**The four `BeginRenderPass` calls** are direct `bl`s in the kernels, so each
can be redirected through its own island, the call-site pattern of
`DynamicResolution`'s StartRecording hook:

| Site | Kernel | Pass |
| --- | --- | --- |
| `0x105dd92a8` | DepthFirstPass | Prepass |
| `0x105dd9a18` | GBufferPass | G-buffer |
| `0x105dd9f4c` | GBufferPass | LinearizeDepth |
| `0x105dda400` | GBufferPass | Extract |

Each is followed by `BeginRenderSubPass(0)`, which is a call only in immediate
mode (list +0x82). Otherwise it is inline (`AddCommand(8,4)`, opcode 0x11), and
so is every end pass (`AddCommand(1,1)`, opcode 0x12). The header padding has
room for the four islands: it runs from `0x100004000` to `__text` at
`0x10000dc5c`, and the reserved islands end at +0xac0.

**Between LinearizeDepth and the extract**, the kernel calls virtual slot 22
(+0xb0) of the stage's `RenderView` (`stage+0x08`):
`GameRenderView::BindGlobalConstantBuffers(list, true, false)`, which
`ecl::EoCRenderView` overrides. It rebinds the per-view constant buffers.

**Full-screen draws.** `FullScreenTriangle::RenderFullScreen(list, pipeline)`
(`0x10640bdfc`) records a 0x2b `PrepareDraw` (0x88 bytes, align 8) for the
pipeline, then `SetVertexBuffer(0, triangle)`. It returns a `Wrapper`
(+0x00 triangle, +0x08 list) whose destructor (`0x10640bd50`) records the draw:
0x2e, 12 bytes, vertex start 0, count 3. In immediate mode both call
`MetalRenderer` directly. The extract's textures and viewport are set between
the two. The triangle is one object for the whole app:
`rf::details::RendererBase::s_Instance` (`0x108af4120`) + 0x1c8. Every render
stage and pass job keeps the renderer pointer `s_Instance` 0x2000 bytes after
its command list (stage+0x2030, job+0x2020). `BaseApp::InitFrameStages` stores
it when it builds a stage. The triangle's +0x00 is its vertex layout, which
`Load` copies into each full-screen pipeline descriptor's +0x08, and its +0x08
is the `VertexBuffer*` that `RenderFullScreen` binds.

**Shaders.** `LoadEngineShader` goes through
`ResourceManager::InstantiateShader`, which caches by path in
`ShaderManager::GetShader`. `DataLoader::CreateShader(Path const&)`
(`0x106419d50`, static) is uncached: it reads the `.bshd` with `bshd::Load` and
calls `GPUDevice::CreateShader` (device at `[0x108af4050]+0x2128`), which
returns a 64-bit handle (`0xffc0000000000000` is invalid). A `.bshd` holds
stage function **names**, not code. `GPUDevice::CreateShader` resolves each
name with `newFunctionWithName:` in `Shaders/Metal/Core.metallib`
(GPUDevice+0x840), then `Materials.metallib` (+0x848). `"none"` means no
function. It stores the results in the 0x50-byte `Shader` entry: +0x18 vertex,
+0x20 fragment, +0x28 a third stage (presumably compute). The handle resolves to
the entry through the container's salt and page tables (`0x10640d564`). So a
custom fragment shader is a second `Shader` made from the same `.bshd`, with
+0x20 replaced by a function from our own library before any pipeline is
built from it.

**Render passes.** `GPUDevice::CreateRenderPass` (`0x10645b198`) callocs 0x30
bytes and copies the format-resolved `TemplateRenderPassDesc<EFormat>` into
it: RTs at +0x00, SubPasses at +0x10, the third array at +0x20. The raw
`RenderPass*` is only this descriptor. Metal render pass descriptors are built
at replay from it and the framebuffer, so a merged pass has nothing else to
create.
