# Ultra Performance

Part of the [metalfx](../README.md) feature (`BG3MFX_FEATURE_METALFX`).

Adds **Ultra Performance** (quality 4) to BG3's Upscaling Quality menu, after its
four qualities. It is offered only while MetalFX Temporal is the Upscaling Type
and the device can reduce at all. It renders a fixed, smaller region of the
render targets every frame, and MetalFX Temporal upscales it to the output
resolution: the smallest input MetalFX Temporal accepts on this Mac, 3× less per
axis and 1/9 of the pixels on the M5 Pro, the same scale as DLSS's Ultra
Performance. BG3's Performance renders 1/4 of the pixels (2×).

It replaces the earlier Dynamic quality, which changed the area every frame to
hold a minimum frame rate. That controller, its Upscaler Target Minimum FPS
slider and its Thermal Guard checkbox are gone. A saved Dynamic quality 4 now
means Ultra Performance, a large drop in image quality; the two old preferences
are removed.

The range comes from the device, not from constants:

- `MTLFXTemporalScalerDescriptor supportedInputContentMinScaleForDevice:` and
  `supportedInputContentMaxScaleForDevice:` give the scale range. The
  renderer reads them when it creates the Temporal scaler.
- The area per axis is output / the largest scale plus one pixel of margin,
  capped at the render targets: about 0.111 on the M5 Pro. The scale range has
  not been checked on other chips.
- It stays at native resolution until those limits are known, and for 60
  frames after any change of size or Upscaling Type, or when switching to or from
  these qualities (switching between the two changes the area at once).

Frame Generation interpolates the upscaled, output-size image, using depth and
motion at render size. Its interpolator has no content-region input, so with
these qualities selected it converts depth and motion into its own textures
every frame, stretching the reduced region to full size and scaling motion
vectors and jitter to match.

metalfx's install puts it in after Temporal's jitter. It is optional: if it
cannot install, metalfx reports it through `BG3MFXFail` and does not offer
Ultra Performance.

## Implementation

- [`UltraPerformance.mm`](UltraPerformance.mm) hooks both
  `rf::RenderFrame::StartRecording` calls in `ls::RenderThread::Update`. These
  run on the render thread before any view records.
- For an on-screen frame, the hook writes the fixed area to BG3's own render
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
- [`MetalFXRenderer.mm`](../renderer/MetalFXRenderer.mm) does the following:
  - accepts the reduced TAA viewport as the Temporal content region;
  - creates Ultra Performance's Temporal scaler with `inputContentPropertiesEnabled`, so it accepts a smaller region of full-size inputs. MetalFX AA (hidden quality 5) renders at full size and uses a plain 1:1 scaler instead;
  - gives the fog composite a viewport-mapped vertex shader;
  - corrects surface grid (blood, water) and subsurface scattering draws while
    reducing.
- [`TemporalJitter.mm`](../../../../src/features/metalfx/temporal-upscaling/TemporalJitter.mm)
  uses ceil(8 / area) Halton phases (8–128), about eight samples per output pixel.
- [`MetalFXOptions.mm`](../MetalFXOptions.mm) does the following:
  - appends Ultra Performance (4) after BG3 rebuilds the quality list;
  - saves it with the other MetalFX qualities. BG3 starts with its own
    quality (at most Ultra Quality), so until Video options are first built,
    the saved quality is published to the renderer at startup the way the menu
    does it (BG3's `PublishSettings`, with a stand-in manager holding a copy of
    the render settings), which also resizes the render targets;
  - falls back to Balanced for Spatial.

  BG3 renders any quality above 3 at scale 1.0, so the native settings file can
  store it.

## Improvement

Displayed, live (M5 Pro MacBook Pro, 3456×2234, MetalFX Temporal, measured
while the earlier Dynamic controller varied the area): GPU time per frame in
one scene fell from 24.6 ms at native resolution to 20.6 ms at area 0.8,
16.2 ms at 0.5 and 15.4 ms at 0.4. About 12 ms of that is fixed cost that does
not shrink with the area. Ultra Performance has not yet been measured live. The
cost is MetalFX reconstruction quality as the area falls; the jitter uses
ceil(8 / area) Halton phases (72 at 3×), about eight samples per output pixel.
