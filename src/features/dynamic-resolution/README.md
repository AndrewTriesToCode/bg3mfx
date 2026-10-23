# Dynamic Resolution

Technical name: `dynamic-resolution`.

Adds **Dynamic** (quality 4) to BG3's Upscaling Quality menu. It is offered only
while MetalFX Temporal is the Upscaling Type, and changes the render resolution
each frame between native resolution and the smallest input MetalFX Temporal
accepts on this Mac. MetalFX then upscales that region to the output resolution.

- Dynamic treats the **Upscaler Target Minimum FPS** slider as a minimum: at
  or above it, it renders at native resolution, and it lowers the resolution
  only while the GPU keeps the frame rate below it.
- The **Dynamic Upscaler Thermal Guard** checkbox also lowers the resolution
  step by step while macOS reports the Mac warmer than nominal, then slowly
  gives it back once it is nominal again.

The range comes from the device, not from constants:

- `MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:` and
  `supportedInputContentMaxScaleForDevice:` give the scale range. Trace reads
  them when it creates the Dynamic Temporal scaler.
- The area per axis runs from output / max scale (plus one pixel of margin) to
  output / min scale, capped at the render targets. On the M5 Pro that is
  1.0×–3.0× per axis, an area from 1 down to about 0.111.
- Dynamic stays at native resolution until those limits are known.

Frame Generation interpolates the upscaled, output-size image, using depth and
motion at render size. Its interpolator has no content-region input, so with
Dynamic selected it converts depth and motion into its own textures every
frame, stretching the reduced region to full size and scaling motion vectors
and jitter to match. Dynamic's target counts rendered frames, as BG3's Max
Frame Rate does; Frame Generation shows twice as many. Dynamic keeps
native resolution for 60 frames after any change of size, Upscaling Type or
quality.
`BG3MFX_DYNAMIC_RESOLUTION=0` skips installation, and Dynamic is then not offered.

## Implementation

- [`DynamicResolution.mm`](DynamicResolution.mm) hooks both
  `rf::RenderFrame::StartRecording` calls in `ls::RenderThread::Update`. These
  run on the render thread before any view records.
- For an on-screen frame, the hook writes the chosen area to BG3's own render
  viewport reduction (`RenderFrame` +0x4368, otherwise always 1). It then runs
  `CalculateViewports` and each view's `RecalculateViewports`.
  - Render-resolution passes then draw a sub-rectangle of unchanged targets.
  - Output-resolution passes are unaffected.
- The patches the probe found necessary are installed with the hook:
  - fog and SSR history viewports, plus an SSR history discard for two frames
    after each area change;
  - auto-exposure scene UVs;
  - the render-rectangle loads for forward lighting clamps, bloom and DOF radii,
    and the projection jitter divisor.

  See [validation](../../../docs/dev/validation/README.md#dynamic-resolution-probe-october-21-2026).
- [`Trace.mm`](../../../src/integration/renderer/Trace.mm) does the following:
  - accepts the reduced TAA viewport as the Temporal content region;
  - creates Dynamic Temporal scalers with `inputContentPropertiesEnabled`;
  - gives the fog composite a viewport-mapped vertex shader;
  - corrects surface grid (blood, water) and subsurface scattering draws while
    reducing;
  - reports the GPU start and end of each of BG3's command buffers while the
    controller measures.
- [`TemporalJitter.mm`](../../../src/features/metalfx-temporal-upscaling/TemporalJitter.mm)
  uses ceil(8 / area) Halton phases (8–128), about eight samples per output pixel.
- [`NativeMenu.mm`](../../../src/integration/menu/NativeMenu.mm) does the following:
  - appends Dynamic (4) after BG3 rebuilds the quality list;
  - saves it with the other MetalFX qualities. BG3 starts with its own
    quality (at most Ultra Quality), so until Video options are first built,
    the saved Dynamic quality is published to the renderer at startup the way
    the menu does it (BG3's `PublishSettings`, with a stand-in manager holding
    a copy of the render settings), which also resizes the render targets;
  - falls back to Balanced for Spatial;
  - adds the Upscaler Target Minimum FPS slider (BG3's `AddSliderOption`, id
    `0x7f03`, the Max Frame Rate slider's 10–240 range) below Upscaling
    Quality, then the Dynamic Upscaler Thermal Guard checkbox (`AddTickBoxOption`,
    id `0x7f05`) below it. Both are enabled only while Dynamic is selected and
    are saved. A saved quality 5 (the earlier "Dynamic (Thermal Guarded)"
    quality) becomes Dynamic with the checkbox on.

  BG3 renders any quality above 3 at scale 1.0, so the native settings file can
  store it.

### Controller

The controller measures how busy the GPU is: the merged GPU intervals of
BG3's command buffers divided by wall time, over 0.25 s windows. It also counts
the frame rate. The target is the "Upscaler Target Minimum FPS" slider
under Upscaling Quality (rendered frames per second like Max Frame Rate,
10–240, 60 until set, enabled only with Dynamic), unless BG3's live Video
options make it unreachable: the Max Frame Rate when it is on, or the refresh
rate (half of it with Frame Generation, which shows two frames per rendered
frame). Windows while BG3 is in the background (where it slows to 30 fps) are
skipped.

The target is a minimum. Busy time and frame rate are each averaged over two
windows.

- When the frame rate is below 98% of the target and the GPU is more than 95%
  busy (the GPU is the limit), the area is multiplied by
  max(0.80, 0.97 × frame rate / target), to land on the target rather than
  just under it.
- Otherwise (at or above the target, or with the GPU not the limit) the area
  grows by 15% per window back toward native resolution. For 10 s after a
  miss, growth stops at 95% of the area that missed. Where native resolution
  misses the target, the area therefore rises toward it about every 10 s and
  steps back down.

Windows with fewer than three frames, or with frames longer than 0.1 s, are
skipped (loading screens, menus, hitches).

- Dynamic keeps native resolution while the game reaches its target, and
  otherwise lowers resolution only as far as reaching it needs, down to the
  floor. A CPU-limited frame rate (GPU not fully busy) does not lower it.
- Before 2026-10-23 the target was a set point: the area also shrank to keep
  the GPU at about 96% busy, and grew only above 105% of the target.

Thermal Guard adds a ceiling on the area, from `NSProcessInfo`'s
`thermalState` (nominal, fair, serious, critical):

- Above nominal (fair, serious or critical), the ceiling falls to 80% of the
  current area every 5 s, down to the floor. Lowering the area only raises
  the frame rate, so the target still holds.
- At nominal, it rises by 10% every 15 s until it no longer limits.
- This is deliberately harsh. Live on 2026-10-22 (M5 Pro MacBook Pro,
  3456×2160, target 30) the Mac reached fair about 3 minutes into play and
  stayed there even at the floor (0.111), apart from 40 s at nominal, so with
  sustained load Thermal Guard usually runs near the floor.
- Developer logs record each ceiling change (`thermal <state> ceiling <area>`).

Live, 2026-10-22, quiet runtime, 60 Hz with VSync: a scene that ran 52–54 fps at
native (GPU fully busy) held 60 fps at area 0.72 with the earlier
busy-only rule (target 94%).

## Diagnostics

The diagnostic runtime logs area changes to the `com.bg3mfx` `resolution`
category and records `dynamicResolutionStep` events.
`BG3MFX_DYNAMIC_RESOLUTION_AREA` replaces the controller with a fixed area
(`0.5`) or a triangle wave (`min,max,seconds`), with any Temporal quality.

## Improvement

Displayed results so far are from the diagnostic probe at a fixed area 0.5 or
an oscillating area (see validation). The controller and the quiet-runtime
Dynamic presets are not yet measured live. The expected gain is GPU time roughly
in proportion to the rendered area in render-resolution passes, at the cost of
MetalFX reconstruction quality as the area falls.
