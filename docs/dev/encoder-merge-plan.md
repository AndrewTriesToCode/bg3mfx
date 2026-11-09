# Plan: merge the prepass, G-buffer and normal extract into one encoder

Status: **implemented, measured and backed out** (October 30–31, 2026). The
merge worked in the game, but displayed HUD runs showed no GPU time
difference beyond the noise between runs (displayed, Ultra, upscaling off:
about 22–23.5 ms of GPU time with or without it), so it was removed. It was
part of the former improved-render-engine feature, which has since been split
into [duplicate-shadow-fix](../../src/features/duplicate-shadow-fix/README.md)
and [improved-shadows](../../src/features/improved-shadows/README.md). This
plan is kept for its design and native facts. Everything marked Read was read
from the disassembly of BG3 4.1.1.7631656 (ARM64). The evidence is in the
[command map](baseline/command-buffer.md).

## Goal

`DeferredBufferStage` (`AppStageType` 0x0b, First pack) records four render
passes, each in its own Metal render encoder (re2–re5 in the
[baseline capture](baseline/frame-capture.md)):

| Capture | Pass | Recorded by | List |
| --- | --- | --- | --- |
| re2 | Depth prepass | `DepthFirstPass` job (stage+0x2140) | stage+0x2160 |
| re3 | G-buffer (5 colors + depth) | `GBufferPass` job (stage+0x4260) | stage+0x4280 |
| re4 | LinearizeDepth (tex424) | `GBufferPass` job | stage+0x4280 |
| re5 | Decal normal extract (tex425) | `GBufferPass` job | stage+0x4280 |

The target order is:

1. **One encoder** for the prepass, the G-buffer and the extract. The extract
   becomes a full-screen draw that reads GBuffer0 and GBuffer2 with
   framebuffer fetch (`[[color(n)]]`) instead of sampling them, so the
   G-buffer never has to be stored and reloaded for it.
2. **LinearizeDepth stays its own encoder**, after the merged one. It can't
   join: Metal has no framebuffer fetch for depth.

Benefits: two fewer encoders, no load or store of the G-buffer between the
G-buffer and the extract, and tile memory reuse. Not measured yet.

## Decisions already made

- **This lived in improved-render-engine**, not a new feature. It requires
  custom-render-stages and custom-pipeline-bundles.
- **No per-frame scanning of command lists.** Only the tail record (the
  last byte written) and positions our own hooks note are touched.
- **Hooks:**
  - Method overrides on DeferredBufferStage's vtable for Load, StartRecording
    and Submit, through an extension of custom-render-stages (not built
    yet).
  - Call-site islands on the four `BeginRenderPass` calls in the two kernels.
- **The extract shader is a clone.** `BG3MFXCreateProgram` makes a copy of
  `DeferredDecal_ExtractNormal.bshd` with our fragment function. BG3's own
  extract program and pipeline stay intact, so a frame that doesn't merge
  renders exactly as BG3 does.
- **BG3's extract commands go to a scratch page** and are never replayed. They
  are not blanked with a skip record, because replay counts records per page.

## Hook inventory

### Stage method overrides

`vtable for ls::DeferredBufferStage` is at `0x10885dbf8`, with slots counted
from +0x10 (Read):

| Slot | Entry address | Method | Original |
| --- | --- | --- | --- |
| 3 | `0x10885dc20` | `Load()` | `0x105dd5ae4` |
| 5 | `0x10885dc30` | `Submit()` | `0x105dd8c08` |
| 7 | `0x10885dc40` | `StartRecording()` | `0x105dd8cec` |

The vtable is shared by every view's DeferredBufferStage (game, player,
offscreen). Keep per-stage state in a side table keyed by the stage pointer.
`Unload` (slot 4, `0x105dd8710`) is the place to drop an entry.

custom-render-stages provides this:
`BG3MFXOverrideStageMethod(0x0b, BG3MFXStageMethod::Load, …)` and so on, from
the feature's install. `Load` returns a bool; the others return nothing.

### `BeginRenderPass` call sites

`rf::RendererCommandBuffer::BeginRenderPass(RenderPass*, Framebuffer*,
Span<Vector4f const> const& clears, Vector4i const& rect)` is at
`0x10642bef8`. In each kernel it's a direct `bl`, followed by
`BeginRenderSubPass(0)`, which is a real call only in immediate mode and
otherwise inline (`AddCommand(8,4)`, opcode 0x11):

| Site | Kernel | Pass |
| --- | --- | --- |
| `0x105dd92a8` | `DepthFirstPass::ExecuteWTKernel` (`0x105dd9000`) | Prepass |
| `0x105dd9a18` | `GBufferPass::ExecuteWTKernel` (`0x105dd9874`) | G-buffer |
| `0x105dd9f4c` | `GBufferPass` | LinearizeDepth |
| `0x105dda400` | `GBufferPass` | Extract |

Redirect each `bl` through a 24-byte island to our function, which calls the
original by address. This is the pattern of `DynamicResolution`'s
StartRecording hook (`nop; ldr x16, #12; br x16; nop; .quad hook`). Reserve
4 × 24 bytes in `SupportedBuild.h`'s `Islands` after `SSRValid` (which ends
at +0xac0). The header padding runs to `__text` at `0x10000dc5c`. Arguments
are passed through unchanged (x0 list, x1 pass, x2 framebuffer, x3 clears,
x4 rect). The hook can find its job from the list: list − 0x20.

## Step by step

### At Load (once per stage)

After the original `Load`:

1. **Merged render pass.** Build a `TemplateRenderPassDesc` with 7 RTs:
   depth/stencil (`0x22f3e110`), the five G-buffer colors (`0x4c0d1b61`,
   `0x3b0a2bf7`, `0xa2037a4d`, `0xd5044adb`, `0x1af4071a`) and the extract
   target (`0x5be0fb7a`, tex425 RG16F). Use one subpass with colors 1–6 and
   depth 0, built with BG3's `SubPass(initializer_list<int>, int, bool,
   initializer_list<int>)` constructor (`0x105dd0118`). Add it with
   `IAppStage::AddRenderPass` (`0x10640ef4c`).
   - Copy load/store actions from BG3's descriptors. The raw `RenderPass*`
     (stage+0x63f8 for the G-buffer; `[stage+0x6470]+0x8` for the extract) is
     a plain 0x30-byte copy of the format-resolved descriptor: RTs at +0x00,
     SubPasses at +0x10. **Open:** that copy has `EFormat`s, but
     `AddRenderPass` takes name hashes. Either build the RT entries from the
     hashes above with the actions copied, or find a name-based copy in the
     `ManagedRenderPass`.
   - Actions: depth Clear/Store and stencil Store. G-buffer colors Clear (or
     as BG3 has them)/Store. tex425 Clear/Store. Load action 1 is Clear, and
     falls back to Load with no clear value. Color store 3 is Store; a
     nonzero depth or stencil store is Store. The extract's pass also loads
     stencil, so check that the merged pass keeps the stencil BG3 expects
     after re5.
   - The 8-target limit counts depth: 7 is fine.
2. **Merged framebuffer.** Call `IAppStage::AddFramebuffer(mergedPass,
   textures)` (`0x10641026c`) with the 7 textures in RT order. Framebuffer
   entries are 0x18 bytes: texture object, s16 slice, s32 level.
3. **Extract program.** `BG3MFXFunctionLibrary("improved-render-engine")`, then
   `BG3MFXCreateProgram("DeferredDecal_ExtractNormal.bshd", {.fragment =
   ExtractNormalFetch_PS})`.
4. **Extract pipeline.** Copy BG3's extract descriptor (the one that built
   +0x6480), then:
   - set `ShaderID` (+0x00) to the clone and `ManagedRenderPass*` (+0x40) to
     the merged pass;
   - keep the vertex layout (+0x08 = the full-screen triangle's +0x00),
     depth-stencil dss32 (`0x10896d580`, depth Always, no write, stencil
     Always/Replace) and the stencil reference 0x40;
   - set a blend state (+0x18) whose write masks disable every color but
     tex425's, or have the shader write the fetched values back. **Open:**
     the layout of BG3's blend-state object.

   Call `IAppStage::AddPipelineState` (`0x106410cf0`) and keep the result.
5. If any step fails, mark the stage as "never merge" and leave BG3's path
   alone.

### At StartRecording (each frame)

Call the original, which refreshes BG3's raw pass and framebuffer pointers
(+0x63f0/+0x63f8, +0x6400/+0x6408). Then do the same for ours: the raw
`RenderPass*` from the merged `ManagedRenderPass` +0x8, and the current
framebuffer for the frame's size. Decide whether to merge this frame:
- not if Load failed;
- not if either list is in immediate mode (list+0x82, prepass list
  stage+0x2160, G-buffer list stage+0x4280);
- not if anything else is off.

Store the decision where both kernels can read it. Recording happens after
StartRecording schedules the jobs, so this needs no lock.

### Prepass `BeginRenderPass` (`0x105dd92a8`, prepass worker thread)

If merging: forward with the merged pass, the merged framebuffer and 7 clear
values in RT order. The prepass passes 1 (depth) and the G-buffer 6; take the
values from those. Otherwise forward unchanged.

### G-buffer `BeginRenderPass` (`0x105dd9a18`, G-buffer worker thread)

If merging: forward with the merged pass and the merged framebuffer (the same
pointers as the prepass hook), and the original clears, which replay stores
but doesn't use. Replay keeps the encoder, because:
- 0x0f doesn't reset the subpass index;
- the inline 0x11 for subpass 0 matches the current subpass of the same pass,
  so `BeginRenderSubPass` returns at `0x10645fd4c` without `endEncoding`.

The pipeline lookup reads the current pass (+0x2b70), so the G-buffer must
begin the merged pass, not its own.

### LinearizeDepth `BeginRenderPass` (`0x105dd9f4c`, G-buffer worker thread)

The kernel has just recorded the G-buffer's inline end pass (`AddCommand(1,1)`
+ opcode 0x12). If merging:

1. Check that the list's last record is that 0x12. The current page is
   `[dispatcher+0x08]`, where the dispatcher is list+0x08; the record is
   `data[used-1]`, with page data at +0x00 and used bytes at +0x0c. If it
   isn't 0x12, give up on this frame: forward unchanged, and tell the
   extract hook and the Submit shim (see below for what an aborted frame
   still needs).
2. Overwrite it with 0x04, a 1-byte no-op. The record count is unchanged.
3. Record our extract: `RenderFullScreen(triangle, list, ourPipeline)`
   (`0x10640bdfc`), then `~Wrapper` (`0x10640bd50`), which records the draw
   (0x2e, start 0, count 3). The triangle is `[RendererBase::s_Instance
   (0x108af4120)] + 0x1c8`, equal to `[job+0x2020]+0x1c8`. The G-buffer's
   viewport is still current. **Open:** check that tex425 is the G-buffer's
   size, so the viewport needs no change.
4. Record the end of the merged pass: `AddCommand(1,1)` on the dispatcher,
   store 0x12, and set list+0x81 = 1, as the kernel does.
5. Forward the call unchanged.

`RenderFullScreen`'s calling convention: x0 = the Wrapper to fill (+0x00
triangle, +0x08 list), x1 = triangle, x2 = list, x3 = `PipelineState*`, as at
`0x105dd9fe4`.

### Extract `BeginRenderPass` (`0x105dda400`, G-buffer worker thread)

If merging: save the dispatcher's current page (`[list+0x08+0x08]`), reset our
scratch page (used and count = 0), point the dispatcher's current page at it,
and **don't forward**. Everything BG3 records for the extract lands in the
scratch page: 0x11, PrepareDraw, textures, draw, 0x12. The scratch page is a
0x20-byte `CMDPage` (+0x00 data, +0x08 capacity, +0x0c used, +0x10 count,
+0x18 next) with a few KB of data; size it so AddCommand never chains a new
page.

**Open:** in between, the kernel calls the view's
`BindGlobalConstantBuffers(list, true, false)` (RenderView vtable slot 22) and
`SceneGraph::GetTextureSRV`. Both run before this call, so they land in the
real list, which is harmless. Check that nothing after the `bl` writes
through a pointer the kernel computed before it.

### At Submit (render thread, all recording done)

1. **If the extract was redirected**, put the saved page back in
   `[dispatcher+0x08]`.
2. **If merging**, overwrite the prepass list's tail 0x12 with 0x04, using the
   same check as the LinearizeDepth hook. This can't be done in a hook,
   because the prepass may still be recording on its own thread then. In the
   non-immediate path the prepass kernel always ends with its inline 0x12, so
   the check should only fail if the build or the kernel changed. If it does,
   the G-buffer list has already begun the merged pass, so the frame needs an
   abort path. **Open:** design it. One option: the G-buffer hook notes where
   its 0x0f record starts (the write position before forwarding), and an
   abort writes BG3's G-buffer pass and framebuffer back into that record
   (+0x08 `RenderPass*`, +0x10 `Framebuffer*`). Our extract's records would
   then be overwritten in place with skip records of the same size, so the
   record count doesn't change.
3. Call the original Submit, which replays the prepass list, then the
   G-buffer list. Nothing happens between lists, so the encoder spans both.

After replay, `PostExecuteCommandBuffer` rewinds and zeroes every page of
each list. The scratch page is ours; reset it in the extract hook.

## Facts relied on (all Read)

- **Frame order:** `RenderThread::Update` runs `RenderFrame::StartRecording`,
  each view's `StartRecording`, `RenderFrame::FinishRecording` (which waits
  on the worker batches), then each view's `Submit`, on the render thread.
  Recording never overlaps replay.
- **Lists:** each list has one command dispatcher (list+0x08). Its second
  dispatcher (+0x20) holds cleanup callbacks. Records are `[align byte]
  [padding][opcode][payload]`. Replay steps by each page's record count, so
  in-place overwrites must not change the count.
- **Opcodes:**
  - 0x04: 1-byte no-op.
  - 0x0f: begin pass. Stores pass +0x2b70, framebuffer +0x2b78 and clears;
    leaves the subpass index +0x2b80 alone.
  - 0x11: begin subpass.
  - 0x12: end pass. Sets +0x2b80 to -1.
  - 0x2b: PrepareDraw.
  - 0x2e: draw.
  - 0x00 (skip) and 0x01 (callback) make byte scanning unsafe.
- **Replay between lists:** `RendererCommandBuffer::Submit` does nothing to
  `MetalRenderer` between lists, except `EndSubFrame` for an immediate-mode
  list.
- **Extract shader:** `DeferredDecal_ExtractNormal_PS` reads only its own
  pixel:
  - GBuffer0 = tex420 (color0); GBuffer2 = tex421 (color2);
  - discards unless bit 3 of `round(GBuffer2.a * 255)` is set;
  - otherwise writes GBuffer0.xy to tex425.

  The disassembly is in `build/analysis/baseline/shaders-4.1.1.7631656/`.
- **Shader programs:** a ShaderID names a whole program: stage functions
  plus binding information. See [custom-pipeline-bundles](../../src/features/custom-pipeline-bundles/README.md).

## Open items

1. ~~Extend custom-render-stages with stage-method overrides.~~ Done:
   `BG3MFXOverrideStageMethod`.
2. Building the merged pass's RT entries: name hashes or a name-based copy;
   check actions, especially stencil after re5.
3. The blend-state object's layout, for the write masks.
4. tex425 size versus the G-buffer viewport.
5. The abort path when a tail check fails after the G-buffer list has already
   begun the merged pass.
6. Our fragment shader, `ExtractNormalFetch_PS`: reads `[[color(1)]]` and
   `[[color(3)]]` in the merged pass's color numbering. Add a `make` rule
   for `improved-render-engine.metallib` and install it next to the runtime
   (Makefile `install`, Homebrew formula).
7. The cloned program's binding information still lists the two textures;
   check BG3 binds nothing harmful for them.
8. Islands and every new address go in `SupportedBuild.h`, with the
   instruction words at each call site checked before patching.

## How to test

- **Synthetic:** a smoke test in `tests/features/improved-render-engine/`
  with stand-in lists and dispatcher pages:
  - the tail flip;
  - the scratch-page redirect and restore;
  - record counts unchanged;
  - that replaying the stand-in lists yields one begin/end pair.
- **Displayed, live:** a GPU capture (gpucapture skill) of the same save and
  camera as the baseline. Expect re2, re3 and re5 as one encoder with 7
  attachments, then LinearizeDepth. Compare tex425 and the G-buffer contents
  with the baseline capture. Keep synthetic and displayed results apart in
  reports.
- **Performance:** HUD GPU time and fps against the baseline, as the README's
  Improvement section measures.
