# BG3 frame lifecycle: threads, recording, commit and present

This page follows one frame of the unmodified game from the game thread's
tick to `presentDrawable`. It covers which thread does what, how stage
recording and replay overlap, when the frame's `MTLCommandBuffer` opens and
commits, how the drawable is acquired and presented, and how the CPU and GPU
stay in step. The command format and how each command replays into Metal are
in the [command map](command-buffer.md). Stage order is in the
[renderer overview](README.md).

Source: the ARM64 slice of build 4.1.1.7631656 (addresses are for that build
only), read with `llvm-objdump`, plus the API call list of the baseline
[frame capture](frame-capture.md). Confidence labels are the overview's:
**Read** from code, **Named** inferred from names or usage. Disassembly and
the exported call list are in `build/evidence/frame-lifecycle/` (local only).

## Threads

| Thread | Entry | Per-frame work |
| --- | --- | --- |
| Main (AppKit) | `-[AppDelegate launchGame]` (`0x100b8dd80`) | Its own event loop: drains `nextEventMatchingMask:…`/`sendEvent:`, then calls `App::OnIdle` (vtable +0xc8) and `IsStopRequested` (+0xf0). `BaseApp::OnIdle` (`0x105d0f2e4`) only calls `ls::RenderThread::Update` (`0x1060db3b8`). **The "render thread" is the main thread.** All replay into Metal, the commit and the present happen here. (Read) |
| Game | `ls::GameThread::DoWork` (`0x105f9072c`) | Client tick: `ClaimClientTickets`, `SyncGameJobs`, frame cap (`GameClock::CapFrame`), `Dispatcher::Process`, input, then the handoff described below. (Read) |
| Workers | `ls::WorkerThreadScheduler` | Stage `ExecuteWTKernel` jobs, which record command lists; culling; `PushRenderUpdatesBatch`; other engine batches. The main and game threads also run worker jobs while they wait (`WaitForEventAndDoWork`). (Read) |

`RenderThread::Update` is reached by a direct call only from `OnIdle`, and
`OnIdle` (vtable slot +0xc8 of `App`) is called only from the
`launchGame` loop. (Read)

## Game → render handoff

The two threads meet through `ls::ThreadEvent` doors. (Read for the calls;
that they pair up as below is Named.)

1. At the end of its tick the game thread opens two doors (`OpenDoor` on
   `[GameThread+0x28]+0x20` and `+0x30`). It then blocks in
   `WaitForEventAndDoWork` on `+0x10`, running worker jobs while it waits.
   (`0x105f9085c`–`0x105f90888`)
2. `RenderThread::Update` starts by waiting the same way on two events
   (`BaseApp::WaitForEventAndDoWork`, priority 2, twice). It then runs a
   window-manager update, `Dispatcher::Process`, a `ResourceManager` call,
   and `CommandManager::ExecuteCommands` under a lock. These are the commands
   the game queued for the renderer. (`0x1060db3b8`–`0x1060db4a0`)
3. Late in the frame, after the stages are recorded but before the main
   frame is replayed, `Update` schedules a
   `RenderThread::LeaveGameDrawScopeJob` (`0x1060dc360`–`0x1060dc388`). The
   job runs `PushRenderUpdatesBatch`, waits for it, walks an ECS query, and
   then opens `[[job+0x10]]+0x10` (`0x1060db1d0`). That door releases the
   game thread.
4. So the game thread's next tick runs while the main thread replays
   the current frame and commits it. `Update` waits for the job at the end
   (`WaitForCompletion` on `LeaveGameDrawScopeBatch`, `0x1060dc4ac`).

### Frame cap

`GameThread::DoWork` measures the tick with `gettimeofday`. If the elapsed
time is below a target held in the app at +0xd0, it calls
`GameClock::CapFrame(target)` (`0x105f90974`). `CapFrame` (`0x1064d1b8c`)
never sleeps. While more than 1 ms remains, it pops jobs from the worker
queues and runs them inline (`ExecuteWTKernel`, `NotifyJobCompletion`).
Otherwise it spins on `mach_absolute_time` with `pthread_yield_np`. (Read)
That the app +0xd0 target is the in-game frame-rate cap is Named. The
present interval below does not carry the 30 fps cap.

## The render frame, step by step

`RenderThread::Update` in order, for the build's frame types. Every render
frame has a type at `RenderFrame+0x38`, copied from `RenderFrameDesc+0x28`.
Type 2 builds an `rf::OffscreenRenderFrame`
(`RenderFrameSystem::AddRenderFrame`, `0x1060d4560`). Other types go to
`MetalAPI::CreateRenderFrame`. `BaseApp::InitAPI` creates the main window's
frame with type 0 (`0x105d18e70`). (Read) Type 1 was not traced to a creator.

| # | Step | Where |
| --- | --- | --- |
| 1 | Wait for the game thread, process dispatchers and queued commands (above) | `0x1060db3b8` |
| 2 | Submit a few engine command lists. `BeginBlitPass`, `FxGenericGlobalVertexBuffersProvider::CommitRenderDataChanges` ×3, `EndBlitPass`. `SetUseRollingBuffers`, then deferred `SwapTextures`/`DestroyTexture` | `0x1060db6b0`–`0x1060dbc00` |
| 3 | **`MetalRenderer::BeginFrame`**: wait on the frames-in-flight semaphore and create the frame's `MTLCommandBuffer` (below) | `0x1060dbc0c` |
| 4 | `RenderFrameSystem::RenderScreenshots` (does work only on request), a renderer sub-object's begin hook (`s_Instance+0x1d8`, vtable +0x30), `DataLoader::SubmitCommandBuffers`, `TerrainRenderer::ProcessRequests` | `0x1060dbc38`–`0x1060dbc78` |
| 5 | **Offscreen frames (type 2)**, one at a time: `BeginFrame`, `StartRecording`, each visible view's `DoWhileRecording`, `FinishRecording`, `EndFrame(CanPresent())`. `OffscreenRenderFrame::CanPresent` returns false, so each offscreen frame that renders commits the frame's command buffer early and opens a new one ([below](#when-a-frame-cant-present)). The captured frame has none | `0x1060dbc7c`–`0x1060dbe3c` |
| 6 | **Other frames**: `BeginFrame` then `StartRecording` for each. Visible views get `DoWhileRecording`. Then the main thread schedules further engine batches (PhysX and others) with `TryScheduleBatch`/`OpenDoor`, and opens a blit pass | `0x1060dbe40`–`0x1060dc21c` |
| 7 | Type 1 frames: `FinishRecording`, `Submit` of the frame's list, `Submit` of each visible view, `EndFrame(CanPresent())` | `0x1060dc240`–`0x1060dc324` |
| 8 | Schedule `LeaveGameDrawScopeJob` (releases the game thread when done) | `0x1060dc32c`–`0x1060dc410` |
| 9 | **Type 0 frames (the main window)**: `FinishRecording`, which replays every stage ([below](#recording-and-replay-overlap)), then `EndFrame(CanPresent())`. `RenderFrame::CanPresent` returns true, so EndFrame presents ([below](#drawable-and-present)) | `0x1060dc414`–`0x1060dc488` |
| 10 | The `s_Instance+0x1d8` end hook (vtable +0x38), wait for `LeaveGameDrawScopeBatch`, `EndBlitPass`, `endEncoding` on any open encoder | `0x1060dc48c`–`0x1060dc580` |
| 11 | Deferred destruction: `setPurgeableState:`/`release` of retired buffers and textures, `ObjectContainer<Shader>::Destroy` | `0x1060dc69c`–`0x1060dd370` |
| 12 | **`addCompletedHandler:`** on the frame's command buffer, then **`MetalRenderer::CommitCommandBuffer(false)`**, then clear the renderer's command-buffer pointer | `0x1060dd5c8`–`0x1060dd5d8` |

All steps are Read. That the type 2 frames are the paperdoll and character
icons follows from the overview's list of offscreen frames (Named).

## Recording and replay overlap

`RenderFrame::StartRecording` (`0x10641ec98`) walks the frame's views
(array at +0x42f0, count at +0x42fc). For each view that passes
`RenderView::IsVisible` (vtable +0x70) and two enable bytes
(`view+0x2158`, `[view+8]+0x4300`), it:

1. stores the view index at `view+0x2270`;
2. calls the view's `StartRecording` (vtable +0x10, e.g.
   `ecl::EoCRenderView::StartRecording`), which uploads per-view constants;
3. schedules the view's worker batches. These are held in the object at
   `[view+0x38]` (offsets 0x08–0x80, about 16 per view). Each is scheduled
   with `WorkerThreadScheduler::TryScheduleBatch`, and the door is opened with
   `ThreadEvent::OpenDoor`. The stage `ExecuteWTKernel` jobs then record in
   parallel. (Read)

`RenderFrame::FinishRecording` (`0x10641f770`) replays in stage order
while later stages are still recording (Read):

1. It submits the frame's own list (`frame+0x40`).
2. For each visible view, `GameRenderView::FinishRecording` (`0x105f7d304`)
   submits the view's list (`view+0x50`, if flagged). It then calls every
   stage's `FinishRecording` in stage-list order.
3. `ls::RenderStage::FinishRecording` (`0x1060d91fc`) handles each stage. If
   the stage is rendering (+0x18), it waits for that stage's own batch
   (`WaitForCompletion` on `+0x2138`) and then tail-calls the stage's
   `Submit` (vtable +0x28). `RenderStage::Submit` (`0x1060d9144`) is
   `RendererCommandBuffer::Submit` on the stage's list (`+0x30`). A stage
   that is not rendering has its list cancelled instead
   (`CancelCommandDispatcher`).
4. Finally it waits on the view's remaining batches.

So replay of stage *n* into Metal on the main thread overlaps recording of
stages *n+1…* on the workers. The main thread stalls only when the next stage
in order hasn't finished recording. Several stages override
`FinishRecording` and submit their list themselves: PostProcess, Lighting,
LightingCombine and FxRenderUpdate (direct callers of
`RendererCommandBuffer::Submit`). (Read)

## The frame's Metal command buffer

`MetalRenderer` lives at `RendererBase::s_Instance + 0x1f0`. Its fields:

| Field | Contents |
| --- | --- |
| +0x00 | `dispatch_semaphore_t`, created with a count of 3 in `MetalAPI::Init` (`0x106446a90`) |
| +0x20 | The `MTLCommandQueue` |
| +0x28 | The frame's command buffer |
| +0x30, +0x38 | The open render and blit encoders |

(Read)

- **Open.** `MetalRenderer::BeginFrame` (`0x10645da1c`) returns at once if
  +0x28 is set. Otherwise, under the renderer lock, it calls
  `dispatch_semaphore_wait(+0x00, FOREVER)` and then
  `commandBufferWithUnretainedReferences` on the queue. `Update` calls it at
  step 3. `RendererCommandBuffer::Submit`, `BeginRenderPass` and
  `BeginComputePass` also call it, so any replay reopens a buffer if none is
  open. (Read)
- **Frames in flight: 3.** The completion block that `Update` adds at step
  12 (`invocation function for block in MetalRenderer::EndFrame`,
  `0x106460cf4`) is just `dispatch_semaphore_signal`. A fourth frame's
  `BeginFrame` blocks the main thread until the GPU finishes the frame three
  back. `LSMTLView setVsync:bufferCount:` is called with 3 and sets
  `maximumDrawableCount` to 3 whether VSync is on or off. It also sets
  `displaySyncEnabled` from a settings byte (Read). That byte is VSync
  (Named).
- **Commit.** `MetalRenderer::CommitCommandBuffer(bool wait)`
  (`0x10645d788`) runs under the renderer lock in two parts:
  1. If upload data is pending (the ring range +0x2098…+0x2090, or queued
     copies and fills counted at +0x2078) **and the device lacks unified
     memory**, it creates a separate `commandBufferWithUnretainedReferences`.
     It `enqueue`s that buffer, then blits the staging ring and the queued
     copies and fills (`fillBuffer:range:value:`) into it, and commits it.
     On Apple silicon `hasUnifiedMemory` is true, so this is skipped.
  2. It commits +0x28 and, if `wait`, calls `waitUntilCompleted`. It does
     not clear +0x28; `Update` does that after the call. (Read)
- **One commit per presented frame.** On the normal path the only commit of
  the frame's buffer is at step 12, with `wait = false`. (Read)

### Other command buffers in a frame

Some work commits its own small buffers outside the frame's buffer (Read):

- `MetalRenderer::SetTexture` first-use clears: a `commandBuffer` with one
  render pass and a `commit`. See [command map](command-buffer.md) opcode
  0x1f.
- `SceneGraph::AddRenderTarget`, `RenderFrame::BeginFrame` and
  `GPUDevice::CreateBufferInternal`/`CreateTexture`: `commandBuffer` + a blit
  copy (some add a completion handler) + `commit`. These are for initial
  contents.
- Opcode 0x37 `CopyBufferToBuffer`, on one path. See the command map.

These use `commandBuffer` (retained references), not the unretained variant,
and they never wait on the frames-in-flight semaphore.

### When a frame can't present

`RenderFrame::EndFrame(bool present)` (`0x10641c5fc`) gets the frame's
`CanPresent()`: true for `RenderFrame`, false for `OffscreenRenderFrame`. When it is false, EndFrame first ends the open render and
blit encoders and resets the cached binding state. It then commits the
frame's buffer early, in one of two ways depending on a ring-position test
on `MetalRenderer+0x2090`:

- `CommitCommandBuffer(true)` (waits), then `dispatch_semaphore_signal` and
  `BeginFrame`;
- or `CommitCommandBuffer(false)`.

It then installs a fresh `commandBufferWithUnretainedReferences` at
+0x28. When `present` is true none of this happens. In both cases it then
runs the frame's end hooks (vtable +0x70, empty in the base class), submits
the frame's end-of-frame list (`frame+0x2140`), and calls `FlipBuffers`
(vtable +0x58). `MetalRenderFrame::EndFrame` (`0x10644c780`) first records
opcode 0x03 into that list. (Read)

## Drawable and present

- **Acquire, late.** Nothing fetches a drawable at frame start.
  `CombineUIRenderStage::ExecuteWTKernel` records **opcode 0x42** with the
  `RenderFrame*` at +0x08 (`0x105d98e3c`–`0x105d98e54`), unless the frame is
  offscreen (type 2) or has a temporary back buffer (`+0x42e8`). Replaying
  0x42 (in `Submit`, `0x10642a138`) calls the frame's vtable +0x40. For a Metal
  frame that is `MetalRenderFrame::GetDrawable` (`0x10644c7e0`):
  `-[LSMTLView getDrawable]` → `CAMetalLayer nextDrawable`. GetDrawable
  stores the drawable at `frame+0x43d8` and its `texture` in the back-buffer
  texture's native slot. So the main thread blocks on `nextDrawable` only
  when CombineUI, the last stage, is replayed. Every earlier stage of the
  frame is already encoded by then. (Read; the command map names 0x42 only
  as a UI callback.)
- **Present.** `MetalRenderFrame::FlipBuffers(bool)` (`0x10644c858`) returns
  if `present` is false or no drawable is held. Otherwise it schedules the
  present on the frame's command buffer (`[frame+0x43a8]+0x28`):
  - `presentDrawable:afterMinimumDuration:` when `GraphicSettings+0x28` is
    set. The duration is `1 / (num/den + 1)`, with `num`/`den` the
    `GraphicSettings` words at +0x18 and +0x1c (1 s if `den` is 0).
  - `presentDrawable:` otherwise. (Read)
- **Interval in the capture.** The captured frame presents with
  `afterMinimumDuration:0.008264` = 1/121, so `num/den` = 120: the display's
  refresh rate. That is one refresh on the 120 Hz display, minus a margin. It
  keeps presents from landing more than once per refresh (Named), and it is
  not the 30 fps cap set in the game, which the game thread applies.
- **Order.** Present is encoded before the completion handler and the
  commit, so the drawable is shown when that command buffer completes on the
  GPU.

## Check against the capture

The baseline capture's API list (32,957 calls) has these frame-level calls
(`build/evidence/frame-lifecycle/capture/frame-calls.txt`):

| Index | Call | Source in the binary |
| --- | --- | --- |
| 0–6 | 7 × `didModifyRange:` (buf68/buf69 three times, buf1518) | Step 2's three `CommitRenderDataChanges` on two ring vertex buffers (Named) |
| 7–10 | `commandBuffer`, render encoder, `endEncoding`, `commit` | `SetTexture` first-use clear (cb0) |
| 11–14 | The same | `SetTexture` first-use clear (cb1) |
| 15 | `MTLLayer nextDrawable` | Opcode 0x42 during CombineUI replay |
| 16 | `commandBufferWithUnretainedReferences` | `MetalRenderer::BeginFrame` (cb2) |
| 17–32953 | 78 encoders of cb2, ending with `CombineUI` into the drawable | Stage replay |
| 32954 | `presentDrawable:afterMinimumDuration:0.008264` | `FlipBuffers` from `EndFrame(true)` |
| 32955 | `addCompletedHandler:` | Step 12 (semaphore signal) |
| 32956 | `commit` | Step 12 `CommitCommandBuffer(false)` |

Each call matches the code above: one unretained frame buffer, two
retained first-use-clear buffers, one drawable, one present on the frame
buffer, and a completion handler right before the single commit.

The list isn't in time order, though. The binary opens cb2 at step 3,
before any replay. The first-use clears and `nextDrawable` happen during
replay, and cb2 is committed last. The list seems to group calls by command
buffer in commit order and put calls on other objects first, so it can't
show interleaving in time. A Metal System Trace would show that. (Read for
the binary order; the list ordering rule is Named.)

## Consequences for bg3mfx

- The main thread is the AppKit thread. Anything a hook does inside replay,
  commit or present runs between `sendEvent:` calls.
- The frame has one long command buffer, encoded stage by stage while
  workers still record. The GPU can start only after step 12, when replay
  of the whole frame (including CombineUI) has finished. That is about
  33,000 API calls in the capture.
- `nextDrawable` is called at the end of replay, so drawable starvation
  shows up as a stall right before the last encoder, not at frame start.
- With up to 3 frames in flight and `maximumDrawableCount` 3, CPU-to-display
  latency can reach three frames. The frame cap, on the game thread, is
  what normally keeps the queue short.
- `CommitCommandBuffer`'s discrete-GPU upload path is dead code on Apple
  silicon. Per-frame dynamic data is written in place in shared or managed
  buffers (`didModifyRange:`).

## Open questions

- Which frames are type 1, and why their views get an extra `Submit` after
  `FinishRecording` has already replayed each stage.
- What the `s_Instance+0x1d8` object is. It is stored by `BaseApp::InitAPI`
  and gets begin and end calls around the frame.
- The pairing of the two door sets in the game ↔ render handoff, checked
  live (for example with a Metal System Trace or a thread-state sample).
- The exact meaning of the `GraphicSettings` fields +0x18, +0x1c and +0x28,
  and of the app's +0xd0 frame target.
