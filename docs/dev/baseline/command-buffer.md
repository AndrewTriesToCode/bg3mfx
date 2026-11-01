# BG3 command lists: the game's commands mapped to Metal

BG3 stages don't call Metal while they record. They append compact commands
to a CPU-side list, an `rf::RendererCommandBuffer`, and the render thread later
replays each list into the frame's `MTLCommandBuffer`. This page maps those
commands to the Metal calls they become. See the
[renderer overview](README.md#frame-lifecycle-and-threading) for where
recording and Submit sit in the frame.

Source: the ARM64 slice of build 4.1.1.7631656 (addresses are for that build
only), read with `llvm-objdump`. Confidence labels are the overview's: **Read**
from code, **Named** inferred from names or usage. The scripts and
disassembly used are in `build/evidence/command-buffer/` (local only).

## Record format

`rf::RendererCommandBuffer` (Read):

| Offset | Field |
| --- | --- |
| +0x08 | `ls::CommandDispatcherBuffer`: the command pages replayed by Submit |
| +0x20 | A second dispatcher of `{data, cleanup function}` pairs, e.g. freeing a copy's region array after replay |
| +0x38 | The `MetalRenderer` the list replays through |
| +0x80 | Set to cancel the list (`CancelCommandDispatcher` instead of replay) |
| +0x81 | The list holds commands |
| +0x82 | Immediate mode: recording methods call `MetalRenderer` directly (through `renderer+0x2d48`) instead of appending |

`CommandDispatcherBuffer::AddCommand(size, align)` (`0x1064a7018`) writes
the alignment as one byte at the current end of the page. It then returns a
pointer to the next `align`-aligned address after that byte, with `size`
bytes reserved. When the page is full it chains a new one. The caller writes
the **opcode byte** at offset 0 and the payload after it. So each record is:

```
[align byte][padding to align][opcode][payload ... size bytes from the opcode]
```

Opcodes that take one small argument store it with the opcode as a halfword,
e.g. `0x0113` is opcode 0x13 (`BeginBlitPass`) with argument 1 (Read).

`RendererCommandBuffer::Submit` (`0x106429f40`) walks the pages. For each
record it reads the alignment byte, aligns, reads the opcode and dispatches:
opcodes 3–0x42 through a halfword jump table at `0x10787ab20`, and 0–2
before it. Each case sets the record size so the loop can step to the next
one. The loop stops after each page's **record count**, not at its byte
count, so a record can be overwritten in place by one of the same size or
smaller (e.g. 0x12 `EndRenderPass` by the 1-byte no-op 0x04). Replacing
several records with one 0x00 skip would leave the count too high, and the
loop would read past the skip into stale bytes. (Read)

The dispatcher's pages (`CommandDispatcherBuffer+0x00` is the first,
`+0x08` the current one, `+0x10` the minimum page size) are 0x20-byte
`CMDPage`s (Read):

| Offset | Field |
| --- | --- |
| +0x00 | Data |
| +0x08 | Capacity (u32) |
| +0x0c | Bytes used (u32); the next record starts at data + used |
| +0x10 | Record count (u32) |
| +0x18 | Next page; reused if large enough, otherwise a new one is chained |

After replay, `PostExecuteCommandBuffer` (`0x1064a7194`) rewinds the current
page to the first and zeroes every page's used bytes and record count. If the
frame overflowed the first page, it frees the pages and allocates one first
page large enough for the whole frame. Each list has this one dispatcher, so
it is empty at the start of every frame's recording. (Read)

## Texture binding

Textures are bound by slot, from the `sb::Binding`, without consulting the
program (Read):

- `sb::Binding` is 9 bytes, passed by value (x1 and the low byte of x2). Each
  byte is one stage's slot, or -1 for none. `MetalRenderer::SetTexture` reads
  three: +0x01 vertex, +0x05 fragment, +0x06 compute. The other bytes are
  presumably buffer and sampler slots (Named).
- For each stage with a slot, it stores the texture's `id<MTLTexture>`
  (chosen from the texture's views by `TextureBindingInfo`) in that stage's
  table: vertex `MetalRenderer+0x2248`, fragment +0x24a0, compute +0x26f8.
  It raises that stage's highest bound slot (+0x2ad0, +0x2ad1, +0x2ad2) and
  sets its dirty bit in +0x2ad8 (bits 0, 1, 2).
- `PreDraw` (`0x10645f680`) sends each dirty table as
  `set{Vertex,Fragment}Textures:withRange:` from slot 0 to the highest bound
  slot. It consults the pending program (+0x20e0) only to skip fragment
  textures when the program has no fragment function (entry +0x20). Nothing
  checks a slot against the program's binding information.
- `SetTextureSafe` and `SetTexture` look the texture up in the device's
  texture table. An unknown texture is replaced by a default texture
  (`[0x108af42b8]`).

So a stage, or a hook recording into its list, can bind any texture at any
slot with `RendererCommandBuffer::SetTextureSafe(list, binding, info)`. It
records 0x1f, or binds at once in immediate mode.

A subpass change resets the send range, not the tables. When
`BeginRenderSubPass` (0x11) opens a new encoder, it writes -1 over the
highest-slot bytes (+0x2ad0 and +0x2ad4, `0x10645fdec`), so `PreDraw` sends
none of the earlier textures until a bind raises the slot again; the table
entries stay, and the `03` reset clears only +0x2ae8..+0x2b68. A texture
bound before the subpass is sent if the stage binds a higher slot after it,
and dropped otherwise. BG3's stages bind after their subpass begins.
Improved shadows first bound at slot 40 right after `BeginRenderPass`,
before the subpass; the shadow mask kernel binds up to 36 after it, so the
bind held only on frames that kept the encoder (Read; displayed live). It
now binds at slot 6, below 36, at the head of the stage's list (Read).

## How replay applies state

`rf::metal::MetalRenderer` keeps **pending** state written by commands, and an
**applied** copy of what the open encoder has. Most state commands only
write pending fields. `AcquirePass` (`0x10645e044`) compares each pending field
with its applied copy and sends only the Metal calls for fields that
changed. `PreDraw` calls it before every draw, and `PrepareDraw` and the
vertex-buffer commands call it when a vertex buffer changes. That is why the
captured G-buffer pass has no redundant `setRenderPipelineState:` (Read;
capture counts below).

| Pending | Applied | State | Metal call in `AcquirePass` |
| --- | --- | --- | --- |
| +0x20e0 | +0x2bd0 | Shader program handle | (pipeline key) |
| +0x20f0, +0x2100 | +0x2be0 | Blend state handle and a 32-bit value (Named: sample mask or blend key) | (pipeline key) |
| +0x2110 | +0x2c00 | Vertex layout | (pipeline key) |
| program, blend, layout, current pass | | Render pipeline | `setRenderPipelineState:`. The state comes from `GPUDevice`'s cache by `HashPipelineDescriptor`. On a miss, `GPUDevice::CreatePipelineState` builds it synchronously on the render thread |
| +0x20e8 | +0x2bd8 | Rasterizer state pointer: byte 0 cull (0 none, 1 back, 2 front), 1 fill (1 lines), 3 scissor test, 4 depth bias, 5 depth clip | `setCullMode:`, `setTriangleFillMode:`, `setScissorRect:`, `setDepthBias:slopeScale:clamp:` (fixed 5.0, 2.5, 0), `setDepthClipMode:` |
| +0x20f8 | +0x2be8 | Depth-stencil state handle, looked up in the device's table | `setDepthStencilState:` |
| +0x2104 | +0x2bf4 | Stencil reference | `setStencilReferenceValue:` |
| +0x20a0 (6 doubles) | +0x2b90 | Viewport | `setViewport:` |
| +0x20d0 (4 ints) | +0x2bc0 | Scissor rect | `setScissorRect:`; the scissor commands also set it immediately |
| +0x2230, +0x2238, +0x2240 | | Index buffer, offset, index size (4 means UInt32) | Arguments to the indexed draws |
| +0x2241 | | Primitive topology | First argument of every draw, via the table at `0x107b22cd0`: 1 Triangle, 2 Point, 3 TriangleStrip, 5 Line, 6 LineStrip; others Point |
| +0x2ad8, +0x2ae0 | | Pending texture and sampler tables | `PreDraw` sends `setVertex/FragmentTextures:withRange:` and `setVertex/FragmentSamplerStates:withRange:` for the changed range before each draw |
| +0x2ca0.., +0x2ce0.. | | Vertex buffers bound per slot, and their offsets | `setVertexBuffer:offset:atIndex:` when the buffer changes, else `setVertexBufferOffset:atIndex:` |

Other renderer fields (Read): +0x28 the frame's `MTLCommandBuffer`. Commands
that need one call `BeginFrame`, which opens it lazily. +0x30 the open render
encoder, +0x38 the open compute encoder. +0x2b70/+0x2b78 the current
`RenderPass` and `Framebuffer`, +0x2b80 the subpass index. Per-attachment
clear values start at +0x2c08.

**Bindings.** An `rf::sb::Binding` holds one slot per stage: byte +1 vertex,
+5 fragment, +6 compute, with -1 meaning not bound in that stage. One bind
command can set the same resource in several stages. A buffer whose type byte
(`+0x1d`) is 4 is per-frame data: it resolves to the current frame's uniform
ring buffer, and its offset comes from the bump allocator. (Read)

**Encoders.**
- **Render.** An encoder stays open until the next command that needs a
  different one, and is never closed at the end of a pass.
- **Compute.** `BeginComputePass(concurrent)` keeps an open compute encoder
  whose `dispatchType` matches. Otherwise it ends the current encoder and
  calls `computeCommandEncoderWithDispatchType:`.
- **Subpasses.** `BeginRenderSubPass(i)` compares subpass *i* with the
  current subpass (+0x2b80), both from the current pass (+0x2b70). On a match
  it only stores *i* and keeps the encoder and its applied state. On a
  mismatch, or when +0x2b80 is -1 (set by end pass, 0x12), it ends the encoder
  and opens a new one. `BeginRenderPass` (0x0f) doesn't touch +0x2b80, so an
  encoder survives across lists or stages if nothing ends the pass. In the
  capture, no encoder spans two stages, so BG3's passes end before the next
  stage begins (Read; see [DeferredBufferStage](deferred-buffer-stage.md#what-this-means-for-a-merged-prepass--g-buffer)).
- **Resets.** Ending an encoder clears every applied field, so the next
  encoder resends all state.
- **Blit work.** Clears and copies end the open encoder and use a blit
  encoder.
- **Separate buffers.** Some copies run in their own
  `commandBufferWithUnretainedReferences` buffer, committed straight away:
  0x33, 0x39, 0x41, and 0x37 on one of its paths. (Read)

## Opcodes

"Recorded by" lists the recording method, or a few of the stages whose
inlined code stores the opcode (from the `AddCommand` call sites). Sizes
include the opcode byte. Opcodes the switch has no case for are listed at the
end.

### Render passes and encoders

| Op | Size | Recorded by | Replay → Metal |
| --- | --- | --- | --- |
| 0x0f | 0x20 + 16 per clear color | `BeginRenderPass(RenderPass, Framebuffer, clear colors, rect)` | Stores the pass, framebuffer and per-attachment clear values. Opens the frame's command buffer if none is open. No encoder yet. `BeginRenderPass` then records 0x28 for the rect, unless the rect is all -1 |
| 0x11 | 8 | Stages, e.g. `AlphaRenderStage`, Bink, outline | `BeginRenderSubPass(index)`: ends the previous encoder unless the attachments match. Fills an `MTLRenderPassDescriptor` from the `RenderPass` (texture, slice, level, load/store actions, clear color/depth/stencil). Then `renderCommandEncoderWithDescriptor:`, `setViewport:`, and rebinds the global vertex and fragment buffers |
| 0x12 | 1 | End of render stages (G-buffer, alpha, decals, bloom…) | Clears the current pass and subpass (+0x2b70 = 0, +0x2b80 = -1). The encoder stays open |
| 0x10 | 2 | Compute stages (clustered, SSR, CAS, FSR, tonemap…) | `BeginComputePass(concurrent)`: reuses or opens a compute encoder (above), then rebinds the global compute buffers |
| 0x13 | 2 | `ClusteredAssignmentStage` | `BeginBlitPass(bool)`: `endEncoding`, `blitCommandEncoder`. It can also open its own `commandBufferWithUnretainedReferences`; whether the bool selects that is not followed |
| 0x14 | 2 | `ClusteredAssignmentStage` | `EndBlitPass(bool)`: `endEncoding`, and `commit` (presumably for that separate buffer) |
| 0x09 | 0x30 | GameUI, clustered lighting, fog, offscreen frames | Sets a `RenderPass`'s color clear value (+0x60) and marks it dirty (Read). Named: set clear color |
| 0x0b | 0x20 | Shadow jobs, unlit, Noesis begin render | Sets a `RenderPass`'s depth clear (float) and stencil clear (byte) (Read) |

### Draw state

| Op | Size | Recorded by | Replay → Metal |
| --- | --- | --- | --- |
| 0x2b | 0x88 | `SetPipelineState(rf::PipelineState*)`, `FullScreenTriangle`, `QuadMesh` | `PrepareDraw`: copies a whole draw-state bundle into pending state (layout below) and binds its vertex buffers and index buffer. No Metal pipeline exists until `AcquirePass` |
| 0x18 | 0x10 | `DrawPlain3D`, surfaces, VT resolve | Sets the shader program (+0x20e0) |
| 0x15 | 0x18 | `CascadedShadowMaskStage` | Sets the blend handle (+0x20f0) and value (+0x2100) |
| 0x16 | 0x10 | `DrawPlain3D`, `ls::Shape` | Sets the rasterizer state (+0x20e8) |
| 0x17 | 0x18 | (not found) | Sets the depth-stencil handle (+0x20f8) and stencil reference (+0x2104) |
| 0x19 | 0x10 | (not found) | Sets the vertex layout (+0x2110) |
| 0x1e | 2 | `DrawPlain3D` | Sets the topology (+0x2241) |
| 0x28 | 0x14 | `BeginRenderPass`, `IAppStage::SetAndBindViewport*`, shadows, UI, clouds | Viewport from an integer rect (+0x20a0, as doubles). Applied as `setViewport:` |
| 0x29 | 0x14 | (not found) | Scissor from a rect: `setScissorRect:` now if an encoder is open, and stored |
| 0x2a | 1 | (not found) | Scissor = current viewport: `setScissorRect:` |
| 0x1a | 0x18 | `MTLRendererCommandBuffer::SetVertexBuffer(slot, VertexBuffer, offset)` | `AcquirePass` if the buffer changed, then `setVertexBuffer:offset:atIndex:` or `setVertexBufferOffset:atIndex:` |
| 0x1b | 0x18 | `QuadMesh::Render`, surface renderer | The same, from another payload layout |
| 0x1c | 0x18 | `RenderableObject::Render`, velocity, AI path | Index buffer from an `IndexBuffer` object: buffer, offset, index size |
| 0x1d | 0x18 | Surface renderer | Index buffer from raw fields |

`rf::PipelineState`, the 0x2b payload (`PrepareDrawData`), Read. The record
carries it from +0x08, so a field's record offset is 8 more: the program
handle at record +0x08, the depth-stencil handle at +0x10. Record +0x80 holds
the state's descriptor hash, not a program. The depth-stencil handle isn't part
of the pipeline cache key, so changing it builds no pipeline.

| Offset | Field → pending state |
| --- | --- |
| +0x00 | Program → +0x20e0 |
| +0x08, +0x10 | Depth-stencil handle, stencil ref → +0x20f8, +0x2104 |
| +0x18 | Rasterizer state → +0x20e8 |
| +0x20, +0x28 | Blend handle, value → +0x20f0, +0x2100 |
| +0x30 | Vertex layout → +0x2110 |
| +0x38/+0x40/+0x44 | Vertex buffer, slot, offset |
| +0x48/+0x50, +0x58/+0x60 | Vertex buffers for slots 1 and 2, offsets |
| +0x68/+0x70 | Index buffer, offset → +0x2230/+0x2238/+0x2240 |
| +0x74 | Topology → +0x2241 |

### Resources

| Op | Size | Recorded by | Replay → Metal |
| --- | --- | --- | --- |
| 0x1f | 0x28 | `SetTexture(Binding, TextureBindingInfo)`, `SetTextureSafe` (`0x10642c5c0`) | `MetalRenderer::SetTexture` (`0x10645e814`): writes the pending texture table. `PreDraw` or `Dispatch` sends it as `set{Vertex,Fragment,}Textures:withRange:`. Record: +0x01 the 9-byte `sb::Binding`, +0x10 `Texture*`, +0x18 the rest of `TextureBindingInfo`. If the texture is flagged for a first-use clear (+0x58 set and bit 3 of +0x24), it first clears it with a render pass in its own command buffer (`setRenderTargetArrayLength:`, `commit`). See [texture binding](#texture-binding) |
| 0x20 | 0x14 + 8 per texture | (not found) | `MetalRenderer::SetTexture(Texture* const*, count, …)`: the same, for a contiguous range |
| 0x26 | 0x20 | `AppliedMaterial::BindMaterialParameters`, post steps | `SetSamplerState(handle, Binding)`: pending sampler table, sent as `set*SamplerStates:withRange:` |
| 0x07 | 0x28 | Inlined `CompareSetAndBindConstantBuffer`, `BindViewport`, `SetCameraControllerBuffer` | `BindConstantBuffer(buffer, offset, Binding)`: `setVertexBuffer:offset:atIndex:`, `setFragmentBuffer:…` or `setBuffer:…` when the buffer changes, else the matching `…BufferOffset:atIndex:` |
| 0x08 | 0x28 | `RenderView::BindGlobalConstantBuffers`, SSAO | The same, with the buffer picked from the `DynamicCB`'s 4-entry ring (record +0x08) by its counter (+0x28) **at replay** (`0x10642a830`), not at recording. On unified memory, `CompareSetAndBindConstantBuffer` records this op after writing the next ring slot on the CPU (`SetDynamicConstantBufferData`), so every bind of one `DynamicCB` in a frame replays with its last write. The SSAO blur's two passes both get the vertical direction this way (Read; diagnostic trace October 31) |
| 0x06 | 0x28 | `SetDynamicConstantBufferData` | Copies data into a dynamic constant buffer. In one mode the update is queued under a lock in the renderer (+0x2078) and applied at commit |
| 0x22 | 0x20 | `BindSkinningBuffer`, `RenderStage::BindGlobalResources`, terrain, sky, exposure | `MetalRenderer::SetBuffer(Buffer, Binding)`: `setVertexBuffer:`, `setFragmentBuffer:`, `setBuffer:` (compute) at the binding's slots |
| 0x23, 0x24 | 0x20 | `VertexProcessingStage` | Compute `setBuffer:offset:atIndex:` directly |
| 0x21 | 0x18 | (not found) | Binds an object's buffer (+0x60) with `setFragmentBuffer:` plus `useResources:count:usage:stages:`, or compute `setBuffer:` plus `useResources:count:usage:`. Named: an argument buffer with its resource list |
| 0x05 | 0x20 | (not found) | Writes into a buffer's `contents`, then `didModifyRange:` |
| 0x27 | 0x18 | Compute stages, terrain, Granite | Writes a 32-bit value at offset 0 of a per-frame (type 4) buffer. Otherwise nothing. Named: counter reset |

### Draws and dispatches

| Op | Size | Recorded by | Replay → Metal |
| --- | --- | --- | --- |
| 0x2e | 0xc | `FullScreenTriangle`, depth prepass, post steps | `PreDraw`, then `drawPrimitives:vertexStart:vertexCount:` (+4 start, +8 count) |
| 0x2f | 0x10 | `rf::Model::Draw`, `QuadMesh` | `PreDraw`, then `drawIndexedPrimitives:indexCount:indexType:indexBuffer:indexBufferOffset:instanceCount:1 baseVertex:baseInstance:0` (+4 start index, +8 count, +0xc base vertex) |
| 0x30 | 0x18 | `rf::Model::DrawInstanced`, particles | `PreDraw`, then instanced `drawIndexedPrimitives:…` (+4 base instance, +8 instance count, +0xc start index, +0x10 index count, +0x14 base vertex) |
| 0x31 | 0x20 | Compute stages, CAS, FSR, exposure, SSR, fog, tonemap | `Dispatch(PipelineState, x, y, z)`: `setComputePipelineState:`, built on first use with `newComputePipelineStateWithFunction:error:`. Then `setSamplerStates:withRange:`, `setTextures:withRange:`, and `dispatchThreads:` or `dispatchThreadgroups:threadsPerThreadgroup:` |
| 0x32 | 0x18 | `SubStage_DrawClusteredLighting` | `setComputePipelineState:`, samplers, textures, `dispatchThreadgroupsWithIndirectBuffer:indirectBufferOffset:threadsPerThreadgroup:` |

### Clears and copies

| Op | Size | Recorded by | Replay → Metal |
| --- | --- | --- | --- |
| 0x0d | 0x28 | (not found) | `MetalRenderer::ClearTextures`: `endEncoding`, a render pass with Clear load actions, `renderCommandEncoderWithDescriptor:`, `setLabel:` "Clear Textures" (the only encoder label BG3 sets in captures) |
| 0x0a | 0x18 | `GameUIRenderStage` | Builds the arrays, then `ClearTextures` |
| 0x0e | 0x18 | `ClearBuffer` | `endEncoding`, `blitCommandEncoder`, `fillBuffer:range:value:` |
| 0x3a | 0x48 | `CopyTextureToTexture(descriptor)` | Frame blit encoder: per region `copyFromTexture:sourceSlice:sourceLevel:toTexture:destinationSlice:destinationLevel:sliceCount:levelCount:` (checks `textureType`) |
| 0x36 | 0x28 | (not found) | Frame blit encoder: the same slice/level copy |
| 0x35 | 0x18 | `RenderFrameSystem::RenderScreenshots` | `copyFromTexture:toTexture:` |
| 0x38 | variable | `CascadedShadowBufferStage`, `VtResolveRenderStage` | Readback: `copyFromTexture:…toBuffer:destinationOffset:destinationBytesPerRow:destinationBytesPerImage:` |
| 0x37 | 0x28 | `CopyBufferToBuffer` | `copyFromBuffer:sourceOffset:toBuffer:destinationOffset:size:`, in the frame's blit pass or in its own committed command buffer depending on `length`/`storageMode` (which path when is not followed) |
| 0x33 | 0x28 | (not found) | Own command buffer: blit `copyFromBuffer:…`, `commit` |
| 0x39 | 0x30 | `TextureStreamer::Reloader::DoWork` | Under a lock, own command buffer: texture slice copy |
| 0x41 | 0x40 | (not found) | Own command buffer: `copyFromTexture:…sourceOrigin:sourceSize:toTexture:…destinationOrigin:`, `commit` |

### Generic and no-op commands

| Op | Size | Replay |
| --- | --- | --- |
| 0x00 | `[+4]` + 0x10 | Skipped: inline data |
| 0x01 | Returned by the call | Calls `fn(+0x10, 1, 0)` from +0x08; the function returns the record's end. Named: the templated `ls::CommandDispatcher::AddCommand<RCB_…>` commands, of which only `RCB_ClearTextures` and `RCB_CopyTextureToTexture` keep symbols |
| 0x02 | 0x20 | Calls `fn(obj, byte)` (+0x10, +0x08, +0x18) |
| 0x42 | 0x10 | Calls virtual slot +0x40 of the object at +0x08. Recorded by `CombineUIRenderStage` (Named: the UI renderer's callback) |
| 0x03 | 8 | Unless the argument (+4) is 2, clears 128 bytes of renderer binding state at +0x2ae8. Recorded at the start of most stages and by `RenderFrame::BeginFrame`, `MetalAPI::Init` and offscreen frames (111 sites). Its name is not known |
| 0x3c | 0x20 | Nothing on Metal. Recorded next to compute dispatches (CAS, FSR, exposure, clustered lighting, VT resolve). Named: a resource barrier, which Metal tracks itself |
| 0x04, 0x2c | 1 | Nothing |
| 0x34 | 0x18 | Nothing (also the fall-through of 0x27) |
| 0x3b | 0x10 | Nothing |
| 0x0c, 0x25, 0x2d, 0x3d–0x40 | — | No case: the switch's default, the same as opcodes ≥ 0x43 |

## Checked against a capture

The G-buffer pass of the baseline capture (cb2/re3, see
[frame capture](frame-capture.md)) has 571 draws. Its Metal calls match this
replay:

- `setRenderPipelineState:` 73, none redundant, and `setDepthStencilState:`
  only 3, `setCullMode:` 22: `AcquirePass` sends only changed state.
- `setFragmentTextures:withRange:` 157 and no single-texture binds: textures
  are flushed as ranges by `PreDraw`.
- `setFragmentBufferOffset:atIndex:` 1,123 and `setVertexBufferOffset:atIndex:`
  876: constant buffers are rebound by offset into the per-frame ring (0x07,
  0x08).
- `setVertexBuffer:offset:atIndex:` 788: per-draw vertex buffers from
  `PrepareDraw` and 0x1a.

## What this means for bg3mfx

- One command can become several Metal calls, and many commands produce no
  call at all until a draw. Hooks on Metal methods see the result of
  `AcquirePass`'s diffing, not the game's own command order.
- A render pipeline can be created synchronously in the middle of a frame:
  `GPUDevice::CreatePipelineState` runs on the render thread on a cache miss.
  Compute pipelines are created on first `Dispatch`.
- Render encoders open lazily and close only when something else needs the
  command buffer. A pass's last draw is not followed by `endEncoding` right
  away.
- Clears, some copies and screenshot work end the open encoder, and some
  copies use their own command buffers. Those are the separate commits
  besides the frame's.
