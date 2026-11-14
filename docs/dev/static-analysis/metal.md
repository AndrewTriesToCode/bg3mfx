# Metal API usage

This is a static map of how `build/bg3-arm64` (BG3 4.1.1.7631656, ARM64) uses
Metal. It was built with REA (Hopper provider). Disputed or garbled decompiler
output was checked against `objdump`. Nothing here was observed at runtime.
Addresses are ARM64 virtual addresses in the thin slice.

## Summary

- **Metal level:** BG3 uses the classic Metal 2-era API: `MTLDevice`,
  `MTLCommandQueue`, command buffers with unretained references, and render,
  compute and blit encoders. The binary links `Metal.framework` and
  `QuartzCore.framework`. Its minimum OS is macOS 11.0 and it was built
  against SDK 14.2.
- **Not used at all:** Metal 3 and Metal 4 APIs, MetalFX, heaps, fences,
  events, argument encoders, indirect command buffers, mesh, tile and
  ray-tracing shaders, residency sets, binary archives, async pipeline
  compilation, GPU counters, MSAA resolve and memoryless storage. None of
  their selector names appear in the binary.
- **Device and queue:** One system-default device. One queue that allows up
  to 512 command buffers. A semaphore allows 3 frames in flight.
- **Layer:** A `CAMetalLayer` hosted in `LSMTLView`. SDR is BGRA8Unorm in
  Display P3. HDR is BGR10A2Unorm with EDR on, in the BT.2020 PQ colour space.
- **Presentation:** `presentDrawable:`, or `presentDrawable:afterMinimumDuration:`
  when the frame cap is on. `maximumDrawableCount` is 3.
- **Ownership:** All Metal calls live in two places. The `rf::metal` backend
  (about 88 KB of code) holds most of them. The `ls` render-stage kernels
  draw full-screen passes directly on an encoder that `rf` opened.

## Where the calls are

The selector cross-reference is in [metal-selector-callers.tsv](metal-selector-callers.tsv)
(150 Metal selectors, with call sites, calling functions and systems). C entry
points (`MTLCreateSystemDefaultDevice`, `MTLCopyAllDevices`, `CVDisplayLink*`)
are in [metal-import-callers.tsv](metal-import-callers.tsv).

| Owner | Role | Main functions |
| --- | --- | --- |
| `LSMTLView` (Objective-C) | `CAMetalLayer` setup, HDR, vsync, drawables | `initWithFrame:device:display:hdr:vsync:` `0x100bbaf9c`, `updateHDRState:` `0x100bbb4c0`, `setVsync:bufferCount:`, `getDrawable` |
| `rf::metal::MetalAPI` | Device, queue, libraries, displays | `Init` `0x106445d48`, `CollectDisplayAdaptersAndDisplays` |
| `rf::metal::GPUDevice` | Resource and pipeline creation (46 KB, 26 functions) | `CreateBufferInternal` `0x106455638`, `CreateBuffer` `0x10645cbc4`, `CreateTexture` `0x106456c88` / `0x106457f9c`, `CreateRenderPass` `0x10645b198`, `CreatePipelineState` `0x10645c0d8` |
| `rf::metal::MetalRenderer` | Encoders, binding, commit | `BeginRenderSubPass` `0x10645f808`, `BeginComputePass` `0x1064608d0`, `Dispatch`, `CommitCommandBuffer` `0x10645d788`, `ClearTextures`, `SetTexture` |
| `rf::metal::MetalRenderFrame` | Drawable and present | `GetDrawable` `0x10644c7e0`, `FlipBuffers` `0x10644c858`, `CreateFrameBufferSurfaces` `0x10644c8c0` |
| `rf::RenderFrame` | Frame begin and end | `BeginFrame` `0x10641a638`, `EndFrame` `0x10641c5fc` |
| `rf::RendererCommandBuffer` / `MTLRendererCommandBuffer` | Records commands, then replays them | `Submit` `0x106429f40` |
| `ls` render stages | Full-screen post-processing and lighting passes | `ExecuteWTKernel` of DOF, Bloom, LensFlare, LocalLightShadow, SSR, ComputeLUTs, ClusteredAssignment, VolumetricFog, VertexProcessing |

There are 183 `contents` call sites, mostly in `ls` stages that write
constants or vertices straight into shared buffers. There are 99
`drawPrimitives:vertexStart:vertexCount:` sites, mostly in `ls`. Only 3
indexed draw sites exist, all in `rf`.

## Device, queue and libraries

`rf::metal::MetalAPI::Init` (`0x106445d48`, 8.8 KB) does the following:

1. Calls `MTLCreateSystemDefaultDevice`. `MTLCopyAllDevices` is used only to
   list adapters in `CollectDisplayAdaptersAndDisplays`.
2. Checks whether the device name `hasPrefix:@"Intel"` and sets a flag bit if
   so.
3. Caches `hasUnifiedMemory` once (a function-local static behind
   `__cxa_guard`). It is read as `GPUDevice::HasUnifiedMemory`, and that flag
   picks between the two upload paths below.
4. Calls `newCommandQueueWithMaxCommandBufferCount:512`.
5. Calls `dispatch_semaphore_create(3)` to create the frame-in-flight
   semaphore.
6. Loads two precompiled libraries with `newLibraryWithFile:error:`:
   `Shaders/Metal/Core.metallib` and `Shaders/Metal/Materials.metallib`.
   Shaders are never compiled from source at runtime (no
   `newLibraryWithSource` or `newLibraryWithData`). Functions come from
   `newFunctionWithName:`, without function constants.
7. Calls `setVsync:bufferCount:3` on the view.
8. Identifies displays by `NSScreenNumber`. The `CVDisplayLink*` calls are in
   the `MetalAPI` display-mode code, which reads refresh rates. Frames are not
   paced by a display link.

`recommendedMaxWorkingSetSize` is read for memory budgeting.

## Layer, HDR and vsync

`-[LSMTLView initWithFrame:device:display:hdr:vsync:]` does the following:

- Creates the `CAMetalLayer` with `setDevice:`, `setFramebufferOnly:YES` and
  `setDrawableSize:`.
- Sets `pixelFormat` to 80 (`BGRA8Unorm`) for SDR, or 94 (`BGR10A2Unorm`)
  for HDR.
- Calls `updateHDRState:hdr` and `setDisplaySyncEnabled:vsync`.
- Reads two user defaults. `LSWindowShowDock` controls the Dock.
  `DisablePopups` picks the window level: `CGShieldingWindowLevel`, or level
  25.

`-[LSMTLView updateHDRState:]` turns HDR on only when HDR is requested and
the screen's `maximumPotentialExtendedDynamicRangeColorComponentValue` is
above 1.0. In that case it calls `setWantsExtendedDynamicRangeContent:YES` and
uses `kCGColorSpaceITUR_2020_PQ_EOTF`. Otherwise it turns EDR off and uses
Display P3. HDR output is therefore HDR10/PQ in a 10-bit drawable, not
extended-linear float.

`-[LSMTLView setVsync:bufferCount:]` sets `displaySyncEnabled`. It then sets
`maximumDrawableCount` to `bufferCount` when vsync is on, or to 3 when it is
off. The `objdump` check shows `csel x2, bufferCount, 3`; Hopper's
pseudocode for this method was mis-decoded. `MetalAPI::Init` passes 3, so the
layer always has 3 drawables.

## Frame lifecycle

```text
RenderFrame::BeginFrame ─ starts the frame on the unretained command buffer
  │                        that the previous EndFrame created
  ▼
encoding (render thread + ls stage kernels)
  │   MetalRenderer::BeginRenderSubPass / BeginComputePass / blits
  ▼
MetalRenderFrame::GetDrawable ─ [LSMTLView getDrawable], kept at +0x43d8;
  │                             drawable.texture wrapped as the back buffer
  ▼
MetalRenderFrame::FlipBuffers ─ presentDrawable: or
  │                             presentDrawable:afterMinimumDuration:
  ▼
RenderFrame::EndFrame ─ ends open encoders → CommitCommandBuffer →
                        dispatch_semaphore_signal → MetalRenderer::BeginFrame
                        (dispatch_semaphore_wait: 3 in flight) → new command
                        buffer → RendererCommandBuffer::Submit
```

- **Command buffers:** Every frame's command buffers come from
  `commandBufferWithUnretainedReferences` (9 sites). The engine keeps
  resources alive itself, which is why it tracks 4 rotating upload buffers
  (below). Plain `commandBuffer` is used for one-off uploads in
  `GPUDevice::CreateBufferInternal` and `CreateTexture`, and in
  `SceneGraph::AddRenderTarget` and `ls::RenderThread::Update`.
- **Getting the drawable:** `GetDrawable` asks for the drawable late, after
  the frame's encoding.
- **Present** (`FlipBuffers(bool)`, `0x10644c858`): the command buffer at
  `+0x43a8 → +0x28` presents the drawable. If the frame-limit setting
  (`GraphicSettings+0x28`) is on, it calls
  `presentDrawable:afterMinimumDuration:` with a duration of
  `1 / (settings[+0x18] / settings[+0x1c] + 1)`, or 1.0 when `+0x1c` is 0.
  Otherwise it calls `presentDrawable:`. No `presentAtTime:` or
  `CAMetalDisplayLink` exists.
- **End of frame** (`EndFrame(bool)`, `0x10641c5fc`): ends the render
  encoder at `RendererBase+0x44` and the other encoder at `+0x45`, then resets
  cached state. Normally it commits, signals the frame semaphore and calls
  `MetalRenderer::BeginFrame`. When the counter at `[0x450]` is above
  `0x10fffff`, it only commits. It then makes the next unretained command
  buffer, replays the recorded commands through `RendererCommandBuffer::Submit`,
  and times the frame with `mach_absolute_time`.
- **Completion:** 7 `addCompletedHandler:` sites (`RenderFrame::BeginFrame`,
  `SceneGraph::AddRenderTarget`, `ls::RenderThread::Update`,
  `GPUDevice::CreateBufferInternal`, `GPUDevice::CreateTexture`) release
  staging resources and track completion. 4 functions call
  `waitUntilCompleted`. No `GPUStartTime` or `GPUEndTime` is read.

## Commit and upload paths

`MetalRenderer::CommitCommandBuffer(bool wait)` (`0x10645d788`) runs under a
lock.

- **Discrete GPU** (`hasUnifiedMemory == NO`, which means older Intel Macs
  with AMD GPUs):
  1. Creates a separate unretained command buffer and calls `enqueue` on it
     so it runs first.
  2. Opens a blit encoder and copies the frame's dirty range out of the
     current upload ring buffer into a private GPU buffer.
  3. Runs any queued `fillBuffer:range:value:` and `copyFromBuffer:…`
     operations.
  4. Calls `endEncoding` and `commit`, and waits if asked to.
- **Every GPU:** then commits the main command buffer, optionally calls
  `waitUntilCompleted`, and signals a Mach semaphore.

The upload ring has 4 slots, picked by `frame index & 3`. With unified memory
(Apple silicon) the shaders read the ring slot directly. Without it they read
the fixed private copy. `BeginRenderSubPass` and `BeginComputePass` both make
this choice when they rebind the saved per-pass buffers. A binding value with
bit `0x10000` set means "offset into the ring". On rebind:

- Render passes bind vertex and fragment buffer slots 6 to 11.
- Compute passes bind buffer slots 6 to 15.

The discrete path also uses `didModifyRange:` (managed buffers) and
`setPurgeableState:` (10 sites, 8 of them in `ls`).

## Resources

### Buffers

`GPUDevice::CreateBufferInternal(size, EResourceUsage, data)` decides storage
from the engine's `EResourceUsage`. The `objdump` check confirms the table at
`0x107b22850`.

| `EResourceUsage` | Creation | `MTLResourceOptions` |
| --- | --- | --- |
| 0 | `newBufferWithLength:` on a private buffer. When there is initial data, it is copied into a temporary shared buffer, blitted across on its own command buffer, and released in a completion handler | `0x20` Private (staging `0x0` Shared) |
| 1 | `newBufferWithBytes:` or `newBufferWithLength:` | `0x21` Private + WriteCombined |
| 2 | same | `0x11` Managed + WriteCombined |
| 3 | same | `0x01` Shared + WriteCombined |
| 4 | same | `0x21` Private + WriteCombined |
| 5 | not created (returns nil) | — |
| 6 | same | `0x01` Shared + WriteCombined |

Write-combined CPU cache mode is set on every CPU-visible buffer. Metal
ignores it for private storage. `CreateBuffer` (`0x10645cbc4`) wraps this
call and builds an `rf::Buffer` with an array of `BufferView`s (offset, size,
format). There are no sub-allocations from `MTLHeap`.
`newBufferWithBytesNoCopy:length:options:deallocator:` appears at one site,
used to wrap memory the engine already owns.

### Textures

- **Creation:** `newTextureWithDescriptor:`, with
  `texture2DDescriptorWithPixelFormat:width:height:mipmapped:` or a manually
  filled descriptor (`setTextureType:`, `setWidth/Height/Depth:`,
  `setMipmapLevelCount:`, `setArrayLength:`, `setUsage:`, `setStorageMode:`,
  `setCpuCacheMode:`).
- **Views:** `newTextureViewWithPixelFormat:` and
  `newTextureViewWithPixelFormat:textureType:levels:slices:`.
- **Uploads:** `replaceRegion:…` (9 sites, 5 in `ecl` UI code) or a blit from
  a staging buffer (`copyFromBuffer:…toTexture:`). Mipmaps are generated with
  `generateMipmapsForTexture:`.
- **Readbacks:** `copyFromTexture:…toBuffer:` (3 sites) and
  `saveTextureWithBytes:` helpers.
- **Not decoded:** the exact storage mode for each texture class in
  `CreateTexture`.

### Samplers and depth/stencil state

Samplers and depth/stencil state are built once each, through
`newSamplerStateWithDescriptor:` (filters, address modes, anisotropy, compare
function) and `newDepthStencilStateWithDescriptor:` (depth compare and write,
plus front and back stencil operations).

## Pipelines

`GPUDevice::CreatePipelineState` (`0x10645c0d8`) handles both pipeline kinds.

**Compute:**

- Calls `newComputePipelineStateWithFunction:error:` synchronously.
- Checks the requested threadgroup size (x·y·z) against
  `maxTotalThreadsPerThreadgroup`. If it is too large, it sets a flag and
  rewrites the size to `threadExecutionWidth × (maxTotal / width)`.

**Render:**

- Hashes the descriptor with `GPUDevice::HashPipelineDescriptor` and looks
  for an existing state in a per-shader hash map. When none is found, it
  fills a fresh `MTLRenderPipelineDescriptor`:
  - Vertex and fragment functions, plus an optional vertex descriptor.
  - For each colour attachment: pixel format (looked up in the table at
    `0x107b224c8`), whether blending is on, the 4 blend factors (table at
    `0x107b22c08`), the RGB and alpha blend operations, and the write mask
    (table at `0x107b22c58`).
  - Depth and stencil formats, with these fix-ups:
    - A Stencil8 depth format becomes depth = Invalid.
    - Depth16 and Depth32Float get no stencil attachment.
    - `Depth24Unorm_Stencil8` is replaced with `Depth32Float_Stencil8` when a
      device flag (`GPUDevice+0x348` bit 0) is set. Apple GPUs lack D24S8, so
      that flag is almost certainly "no D24S8".
- Then calls `newRenderPipelineStateWithDescriptor:error:` synchronously and
  caches the result.

The build has no binary archives, no async compile and no pipeline
reflection. A new pipeline compiles on whichever thread asks for it, which
could cause hitches the first time a material appears.

## Encoders and binding

**Render** (`MetalRenderer::BeginRenderSubPass`, `0x10645f808`, about 7,000
lines of pseudocode):

- `renderCommandEncoderWithDescriptor:` is called only here and in
  `ClearTextures` and `SetTexture`. The function ends whatever encoder is open
  first.
- Each colour attachment gets a texture, slice and level, and a load action:
  - Clear (`0x2`, 84 sites) when the attachment's clear flag is set. A clear
    bitmask on the render target is consumed so each clear happens only once.
  - Load (`0x1`) otherwise.
  - DontCare (`0x0`) in a few cases.
- Depth and stencil follow the same pattern with `setClearDepth:` and
  `setClearStencil:`. Stencil is attached only when the format has a stencil
  aspect (not Depth16 or Depth32Float).
- Store actions are chosen per attachment: Store, or DontCare when the
  contents are not needed afterwards.
- No resolve textures are set, so the build has no MSAA.
- It then sets the viewport and rebinds the saved vertex and fragment buffers
  in slots 6 to 11.

**Compute** (`BeginComputePass(bool)`, `0x1064608d0`):

- Calls `computeCommandEncoderWithDispatchType:`, either serial or
  concurrent.
- Reuses the open compute encoder when the dispatch type matches.
- Rebinds buffer slots 6 to 15.
- `Dispatch` uses `dispatchThreads:threadsPerThreadgroup:` and
  `dispatchThreadgroups:threadsPerThreadgroup:`. One indirect dispatch site
  exists (`dispatchThreadgroupsWithIndirectBuffer:`).
- No explicit `memoryBarrier` calls are made. Ordering comes from encoder
  boundaries and Metal's automatic hazard tracking.

**Blit:** 22 `blitCommandEncoder` sites (20 in `rf`) handle uploads,
copies, `fillBuffer` and mip generation.

**Binding style:**

- Classic per-slot binding: `setVertexBuffer/Bytes`, `setFragmentBuffer/Bytes`,
  `setBuffer/Bytes`.
- Ranged texture and sampler calls (`set*Textures:withRange:`,
  `set*SamplerStates:withRange:`).
- `set*BufferOffset:atIndex:` for cheap rebinding within the ring.
- Small constants go through `setFragmentBytes`, `setVertexBytes` and
  `setBytes`, mostly from `ls` stages.
- `useResources:count:usage:` and `…stages:` appear once each in `rf`. That
  is the only hint of indirectly referenced resources, and there is no
  argument encoder. The `rf` side probably passes plain GPU-address tables.
  This is not confirmed.

**Two encoding paths:**

1. **Recorded:** `rf` code records commands into a
   `MTLRendererCommandBuffer`, a `ls::CommandDispatcherBuffer` made of
   chunks. `RendererCommandBuffer::Submit` (`0x106429f40`) replays them
   through a jump table of about 64 command types (`0x10787ab20`). The
   commands include indexed draws, indirect dispatch, blits and
   `useResources`. After the replay it runs
   `CommandDispatcherBuffer::PostExecuteCommandBuffer`. When the frame is
   cancelled, it calls `CancelCommandDispatcher`.
2. **Direct:** the `ls` render-stage `ExecuteWTKernel` functions run on worker
   threads during the frame-stage graph. They encode `drawPrimitives` with
   `setFragmentBytes` and `setBytes` straight onto the encoder `rf` opened.
   Their uniforms and vertices are written through `contents`.

## Synchronization

| Mechanism | Use |
| --- | --- |
| `dispatch_semaphore` (3) | CPU frame-in-flight limit. It is signalled in `RenderFrame::EndFrame`, then waited on in `MetalRenderer::BeginFrame` (the only `dispatch_semaphore_wait` call site in the binary, at `0x10645da1c`) |
| Mach semaphore | Signalled after each commit, in `CommitCommandBuffer` |
| `enqueue` ordering | Makes the discrete-GPU upload buffer run before the frame's main buffer |
| `addCompletedHandler:` | Frees staging memory and tracks completion |
| `waitUntilCompleted` | Synchronous paths: loading, readback, and `CommitCommandBuffer(wait=true)` |
| Hazard tracking | Automatic (default). No `MTLFence`, `MTLEvent`, `MTLSharedEvent` or `memoryBarrier` |

## Relevance to bg3mfx

- **Feature gaps:** BG3 has no MetalFX, no Metal 3 or 4 features, no async
  pipeline compile and no binary archives. The 3-drawable, 3-frame-in-flight
  pacing is a fixed design, and no display link drives it.
- **Hook points:**
  - Presentation runs through one place, `MetalRenderFrame::FlipBuffers`.
  - The drawable is fetched late, in `MetalRenderFrame::GetDrawable`.
  - Encoders open in only a few places (`BeginRenderSubPass`,
    `BeginComputePass`, the blit helpers).
- **Ring buffer hazards:** the frame's uniforms live in the 4-slot ring.
  Command buffers don't retain their resources, so extra work must keep its
  own resources alive. It must also not touch a ring slot the GPU may still
  be reading.

## Evidence and limitations

- **Data files:** the selector call sites in
  [metal-selector-callers.tsv](metal-selector-callers.tsv) come from the
  local `objc_msgSend$…` stub map, attributed to the calling function. Calls
  through plain `objc_msgSend` with a selector loaded at runtime are not
  counted.
- **What was decompiled with REA `procedure_pseudo_code`:**
  - `LSMTLView`: `initWithFrame:…`, `updateHDRState:`, `setVsync:bufferCount:`.
  - `MetalAPI::Init`.
  - `MetalRenderFrame`: `GetDrawable`, `FlipBuffers`.
  - `MetalRenderer`: `CommitCommandBuffer`, `BeginRenderSubPass`,
    `BeginComputePass`.
  - `RenderFrame::EndFrame`.
  - `GPUDevice`: `CreateBufferInternal`, `CreateBuffer`, `CreatePipelineState`.
  - `RendererCommandBuffer::Submit`.
- **What was checked with `objdump`:** `setVsync:bufferCount:` and the
  buffer-options table.
- **How absence was checked:** a selector counts as absent when its name is
  missing from the binary's strings (`strings -a`). That includes
  `newHeapWithDescriptor`, `newFence`, `newEvent`, `newSharedEvent`,
  `newArgumentEncoder`, `newBinaryArchive`, `newIndirectCommandBuffer`,
  `drawMeshThreadgroups`, `setTileBytes`, `accelerationStructure`,
  `newResidencySet`, `MTL4`, `MTLFX`, `setResolveTexture`, `memoryBarrier`,
  `presentAtTime`, `newLibraryWithSource`, `newLibraryWithData` and
  `setFunctionConstant`. The only `completionHandler:` selectors present
  belong to WebKit and AppKit.
- **Known decompiler faults:** Hopper's pseudocode garbles some branches
  (`setVsync:bufferCount:`, the buffer-option selection, and some
  store-action values in `BeginRenderSubPass`). Treat field offsets such as
  `+0x43d8` and `GraphicSettings+0x28` as specific to this build.
- **Static only:** frame timing, pipeline-compile hitches and how much time
  each upload path costs were not measured. A GPU capture would confirm the
  encoder layout and the load and store actions for each pass.
