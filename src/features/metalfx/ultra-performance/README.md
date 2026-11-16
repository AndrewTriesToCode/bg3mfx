# Ultra Performance

Part of the [metalfx](../README.md) feature (`BG3MFX_FEATURE_METALFX`).

Adds **Ultra Performance** (quality 4) to BG3's Upscaling Quality menu, after its
four qualities. It is offered only while MetalFX Temporal is the Upscaling Type
and the device can reduce at all. BG3 renders the scene at 3× less per axis
(1/9 of the pixels on the M5 Pro, the same scale as DLSS's Ultra Performance),
sizing its own render targets, and MetalFX Temporal upscales it to the output
resolution. BG3's Performance renders 1/4 of the pixels (2×).

It replaces the earlier Dynamic quality, which changed the area every frame to
hold a minimum frame rate. That controller, its Upscaler Target Minimum FPS
slider and its Thermal Guard checkbox are gone. A saved Dynamic quality 4 now
means Ultra Performance, a large drop in image quality; the two old preferences
are removed.

## How BG3 sizes the render targets

BG3's FSR code turns the quality into a scale with a table of four floats
(1.3, 1.5, 1.7, 2.0) read inline in `rf::RenderFrame::Resize`,
`BaseApp::InitAPI` and `ls::PostProcessStep_FSR::ExecuteWTKernel`; any higher
quality gets scale 1.0. The render size is output / scale, truncated, and BG3
sizes its targets and every system that depends on the render size from it, as
for its own qualities.

[`UltraPerformance.mm`](UltraPerformance.mm) patches those three places so a
quality of 4 reads a fifth table entry. Each comparison against 3 becomes 4, and
each table load goes through a pointer in a header-padding island to a table in
the runtime. MetalFX AA (hidden quality 5) is above 4 and stays at 1.0.

The scale comes from the device, not from a constant:

- `MTLFXTemporalScalerDescriptor supportedInputContentMaxScaleForDevice:` is
  3.0 on the M5 Pro. The entry is that value × (1 − 1/300), 2.99.
- BG3 truncates the render size, so exactly 3.0 would give an output / input
  ratio just over the limit at some sizes (2560×1440 renders 853 wide, and
  2560 / 853 is 3.0012). At 2.99 the scaler accepted every size tried, 1280×720
  to 6016×3384. The scale range has not been checked on other chips.
- Quality 4 uses the entry only while MetalFX Temporal is selected and has not
  failed; otherwise it stays 1.0, because BG3's own FSR would stretch the small
  image. The renderer updates this every frame, and it takes effect when BG3
  next resizes.

Frame Generation interpolates the upscaled, output-size image, using BG3's depth
and motion at render size, as for BG3's own qualities.

## Implementation

- [`UltraPerformance.mm`](UltraPerformance.mm) installs the patch with metalfx,
  after Temporal's jitter, validating each instruction it replaces. It is
  optional: if it cannot install, metalfx reports it through `BG3MFXFail` and
  does not offer Ultra Performance.
- [`TemporalJitter.mm`](../../../../src/features/metalfx/temporal-upscaling/TemporalJitter.mm)
  uses ceil(8 × scale²) Halton phases (8–128), about eight samples per output
  pixel (72 at 2.99).
- [`MetalFXOptions.mm`](../MetalFXOptions.mm) does the following:
  - appends Ultra Performance (4) after BG3 rebuilds the quality list;
  - saves it with the other MetalFX qualities. BG3 starts with its own
    quality (at most Ultra Quality), so until Video options are first built,
    the saved quality is published to the renderer at startup the way the menu
    does it (BG3's `PublishSettings`, with a stand-in manager holding a copy of
    the render settings), which also resizes the render targets;
  - falls back to Balanced for Spatial.

  BG3 stores quality 4 in its native settings file.

## Improvement

Displayed, live (M5 Pro MacBook Pro, 3456×2234, MetalFX Temporal, measured
while the earlier Dynamic controller varied the area of full-size targets): GPU
time per frame in one scene fell from 24.6 ms at native resolution to 20.6 ms at
area 0.8, 16.2 ms at 0.5 and 15.4 ms at 0.4. About 12 ms of that was fixed cost
that did not shrink with the area, which may have been the full-size targets.
Ultra Performance now renders into render-size targets, but has not been
measured live. The cost is MetalFX reconstruction quality as the scale rises;
the jitter uses 72 Halton phases, about eight samples per output pixel.
