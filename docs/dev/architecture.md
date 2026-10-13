# Rendering architecture

## User-visible settings

`NativeMenu.mm` adds a persistent Show Metal HUD checkbox at the top of General
and appends MetalFX Spatial and MetalFX Temporal to BG3's existing Upscaling Type
combo. The native Off and AMD FSR 1.0 entries remain owned by BG3. The native
quality combo supplies Ultra Quality, Quality, Balanced, and Performance.

BG3's settings code accepts only Off and FSR as upscaling types. Selecting a
MetalFX type temporarily invokes BG3's FSR setup callback to retain its quality
and render-resolution behavior, then restores the custom menu value and stores
the selected type separately. Startup and Options → Back use the same setup.
The quality state is independent of the custom type. This bridge is
build-specific and guarded by the executable's Mach-O UUID.

Spatial keeps the native anti-aliasing option enabled. Temporal keeps BG3's TAA
input production but skips the TAA draw only on exact targets previously seen
feeding the upscaling stage. Inventory and other auxiliary views retain native
TAA. A newly discovered upscaled target keeps native AA for its discovery frame;
Temporal history is reset before and after that frame so its filtered input is
not accumulated with later raw jittered inputs. Weak target identities avoid
retaining obsolete textures or matching a recycled address. Its output is
written where the game's upscaling result is expected, and the separate AA
control is disabled while Temporal is selected.

## Renderer flow

`Trace.mm` contains the Metal interception layer used by both runtime builds. It
tracks each command buffer's selected mode and associates exact BG3 textures
through TAA, post-processing, and the native FSR stage. Unknown or mismatched
resources fail closed instead of guessing from dimensions. Native FSR and RCAS
dispatches are skipped only for an active MetalFX mode. Off and FSR retain
BG3's callbacks and native rendering.

`SpatialUpscaler.mm` copies BG3's linear HDR scene color from RG11B10Float into
RGBA16Float, runs MetalFX Spatial in HDR mode, and copies the result into BG3's
FSR output target. The input is after bloom and color grading but before
`FSR_Tonemap`; BG3's tone mapping and UI composition remain downstream.

`Trace.mm` captures HDR scene color, device depth, motion, camera constants, and
BG3's original jitter at the TAA stage. It copies current color into the skipped
TAA output and tracks that color through native bloom, color grading, and outline
passes. `TemporalUpscaler.mm` receives the final tracked HDR color before
`FSR_Tonemap`, alongside the earlier scene inputs. MetalFX reads BG3's
RG11B10Float color, Depth32Float_Stencil8 depth and RG16Float motion in place
and writes straight into BG3's final upscaler target when that target has the
usage MetalFX requires (BG3's does); otherwise it writes a pooled output that is
copied into the target. The current motion scale is −1, −1 and depth is reversed, based
on inspected BG3 shader conventions. History is reset when the selected scaling
mode changes or input resources become invalid. `NativeJitter.mm` substitutes
Halton (2,3) samples at three guarded native loads: projection, camera constants,
and velocity history. Only Temporal views with an enabled native FSR stage use
14/18/24/32 phases for Ultra Quality/Quality/Balanced/Performance. A frame-local
choice keeps all three consumers consistent during settings changes. BG3's
previous projection/jitter storage remains responsible for motion compensation;
the shared eight-sample table is unchanged for other views and modes.
`BG3MFXApplyNativeJitter` converts BG3's sample displacement to MetalFX's
image displacement: X is negated and Y retains the native Y-up sign. The old
adapter supplied the opposite displacement in both framebuffer axes, preventing
correct temporal reconstruction. The analytic reconstruction test and captured
depth registration establish this conversion; see the
[quality diagnosis](validation/temporal-jitter-diagnosis.md).

Temporal uses `MTL4FXTemporalScaler` on devices reporting `supportsMetal4FX:`;
other devices retain `MTLFXTemporalScaler`. A dedicated Metal 4 queue waits on
an event signaled after BG3 produces the scaler inputs, then signals another
event that BG3's original Metal 3 buffer waits on before consuming the output.
Per-submission residency and feedback-owned resources preserve GPU lifetimes.
This does not convert BG3's renderer or presentation to Metal 4. See the
[Metal 4 audit](validation/metal4-temporal.md) for the API/model distinction and
validation limits.

`MetalFXPipeline.mm` owns only the MetalFX Spatial/Temporal scaler objects,
resource checks, output allocation, scaler encoding, and its cross-API GPU event bridge. It has no BG3 menu,
frame presentation, patching, or distribution responsibilities.

## Frame Generation

Frame Generation is Upscaling Type value 4, "MetalFX Temporal + Frame
Generation", appended only on supported devices. The menu stores values 0–4; the
renderer sees value 4 as Temporal plus a frame-generation flag, so every other
choice never enters the frame-generation path. Selecting another type releases
the interpolator and presentation worker. A saved Temporal selection with the
earlier checkbox enabled migrates to value 4.

Presentation follows Apple's present-thread model. While value 4 is selected, a
`CAMetalLayer nextDrawable` hook gives BG3 stand-in drawables backed by three
pooled textures; BG3 renders, composes UI, and "presents" into them unchanged,
and blocks like a real drawable when all three are in flight. BG3 presents before
encoding `CombineUI`, so the stand-in present is resolved at `commit`, which also
signals a shared event. The worker in `FrameInterpolation.*` acquires real
drawables itself, waits for that event on the GPU, shows the generated image
half a frame interval after the previous real frame, and then the real image
half an interval after the generated one was actually displayed
(`presentDrawable:atTime:`). Only the generated scene goes through an extra
`CombineUI` pass. The worker never blocks BG3's or Metal's threads. Devices
without Metal 4 FX use the Metal 3 effect. This implementation still needs
displayed/pacing validation and does not establish HDR support. See the
[frame-generation record](validation/frame-generation.md).

## Hook overhead

Every intercepted Metal call runs on BG3's render thread, which issues about
12,000 draws per frame. A `sample` of the quiet runtime showed about half of
that thread inside the hooks, in Temporal and in Frame Generation alike, when
binds built strings and dictionaries and every call took a global lock to find
the original method. Hooks now keep one `BG3MFXEncoderState` per encoder with
fixed binding slots. Pipelines are classified once, at creation, and draws with
unrecognized pipelines go straight to Metal. Original-method lookups are cached
per thread. An unrecognized draw's only effect, dropping a scene association for
the encoder's target, is applied once at `endEncoding`. A synthetic run of
20,000 draws and 80,000 binds took 5.5 ms without hooks, 50.2 ms with the
original hooks, and 7.2 ms after the first rewrite. In the live game the hooks'
own share of the render thread fell from 52-54% to 14-22%. A second round caches
the current encoder's state per thread (refreshed at encoder creation, cleared at
`endEncoding`). It also holds bound buffers, textures and the pipeline without
retaining them, since the encoder of a retained-references command buffer keeps
them alive. That halved the remaining synthetic overhead (about 4.5 ms to
2.3 ms per 20,000 draws). Encoder classes already hooked skip re-hooking, which
otherwise took the global lock about 25 times per new encoder. A third round
makes the per-call hooks take `self` and object arguments as non-owning, so ARC
does not retain and release them around each call to the original method. It
also keeps `setBytes` data in a lazy side table, so each encoder's state owns
nothing in its binding table and is free to destroy. Synthetic overhead for 150
encoders and about 20,000 draws went from about 1.9 ms (round 2) to about
0.9 ms. Measured live on
the quiet runtime before round 3, with the game in the foreground (samples
taken while BG3 is in the background measure its background frame throttle,
`GameClock::CapFrame`, instead): about 16-17% of the render thread. Diagnostic builds still inspect every draw,
so use the quiet runtime (with `MTL_HUD_LOG_ENABLED=1` and `sample`) for
performance comparisons.

## GPU resource reuse

`GPUResources.*` provides pooled textures, returned on command-buffer
completion, and a reusable Metal 4 bridge with recycled allocators, command
buffers, events and a persistent residency set. Spatial, Temporal and frame
interpolation intermediates come from these pools, so steady-state frames
allocate no textures and create no Metal 4 submission objects.

MetalFX consumes BG3's textures directly wherever it accepts their format and
usage, avoiding per-frame conversion passes (about 0.7 ms each for Temporal and
Frame Generation at 4K, measured with GPU timestamps). Frame Generation reads
the RGB10A2 scene in place only on macOS 27, where `requiresPrevColorTexture = NO`
lets the interpolator keep its own history; macOS 26 still copies the scene so a
retained copy can serve as the previous color. Inputs that do not qualify are
converted into pooled copies. Live, the saving is within HUD noise (about 1 fps
at 4K); it is kept because it removes passes and memory, not for frame rate.

## Failure and diagnostics

MetalFX initialization, resource, encoding, or GPU-completion failure presents
an AppKit error and closes BG3 with exit code 78. The runtime does not continue
through FSR after a failed MetalFX frame.

`libBG3MetalFX.dylib` is the quiet development runtime. `libBG3MetalFXTrace.dylib`
adds JSONL traces, shader reflection, and opt-in captures. Diagnostics are not
part of the rendering feature contract and are compiled out of the quiet build.
Both builds retain the interception and lifetime work required to integrate with
BG3. `tools/bg3mfx.py` supports only inspection and launch-time injection; it
does not alter the app bundle.

## Code map

- `src/NativeMenu.mm`: settings menu, custom mode persistence, HUD checkbox.
- `src/NativeJitter.*`: guarded Temporal sample selection and ARM64 preservation.
- `src/Trace.mm`: Metal hooks, exact texture association, pass replacement,
  diagnostic instrumentation.
- `src/SpatialUpscaler.*` and `src/TemporalUpscaler.*`: BG3-specific inputs,
  conversions, and destinations for each scaler.
- `src/MetalFXPipeline.*`: backend MetalFX scaler setup and encoding.
- `src/GPUResources.*`: texture pools and the reusable Metal 4 submission bridge.
- `src/FrameInterpolation.*`: frame interpolation, stand-in drawables, and the
  presentation worker.
- `tests/*_smoke.mm`: synthetic Metal pixel and hook regressions.
- `tools/bg3mfx.py`: guarded, bundle-preserving development launch.
- `docs/dev/validation/`: current status and dated evidence.
