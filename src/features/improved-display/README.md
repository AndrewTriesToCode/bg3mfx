# Improved Display

Technical name: `improved-display`.

Opt-in with `BG3MFX_FEATURE_IMPROVED_DISPLAY=1` (the `bg3mfx` launcher sets
it; development launches: `--feature improved-display`). Requires metal-hooks. Native: it hooks BG3
functions, so it needs the supported build.

## Behavior

Improved Display replaces BG3's Windows-style HDR with macOS-style EDR. It
also brings better color and brightness to screens that aren't sold as HDR.
BG3's HDR option in the launcher is ignored: every screen gets the same path.

BG3's HDR is the Windows model. The game writes BT.2020 PQ in absolute nits,
tone-mapped to a Max Nits you calibrate, and the HDR option is on or off. On
a Mac, macOS then maps that PQ image onto what the screen can show right now:
a second, heavy tone map. Off, the game is sRGB, limited to BT.709 colors,
and capped at SDR white even on P3 screens with brightness to spare.

macOS's model is EDR. A screen reports its current headroom, how far above
SDR white it can go right now. This depends on the panel and its brightness
setting, so it changes as you change brightness. Content is drawn relative to
SDR white and should stay within that headroom. Many Macs' screens that
aren't HDR displays still report headroom when their brightness is below
maximum: an Apple Studio Display gave about 2x SDR white in testing, and
MacBook Air screens behave the same way. They are also P3 panels.

With this feature, on any screen:

- **One tone map, to the real headroom.** BG3's own tone scale (ACES SSTS
  with ZCAM gamut mapping) is the only tone map. Its peak is SDR white times
  the screen's current headroom, so highlights use exactly the brightness the
  screen has. Max Nits calibration no longer applies.
- **It follows the screen.** The image re-tunes when the headroom changes:
  when you change brightness, move the window to another screen, or another
  app takes EDR. The headroom has to change by more than 1%. While macOS
  animates the change, BG3's display LUT rebuilds at most four times a
  second.
- **Better color and highlights on screens that aren't HDR.** On a P3 screen
  such as a Studio Display or a MacBook Air, the game shows P3 color instead
  of sRGB, and highlights brighter than SDR white where the screen reports
  headroom.
- **No special SDR handling.** A screen with no headroom is just headroom 1.0
  on the same path, and gives a normal SDR image.
- **sRGB screens and presets.** On a screen that can't show P3, BG3's P3
  output is compressed into sRGB instead of clipped.
- **The UI stays at SDR white,** as macOS draws its own UI.
- **Shorter HDR calibration.** BG3's calibration (on first run, or from the
  Video options) opens on its brightness and contrast page. These still
  apply: paper white sets the scene's brightness relative to SDR white, and
  contrast sets BG3's HDR gamma. The peak-luminance page ("adjust until the
  image is barely visible") is skipped, because the Max Nits it sets is
  replaced by the screen's live headroom.

## Implementation

[`ImprovedDisplay.mm`](ImprovedDisplay.mm) makes these changes:

- **Render view.** It replaces two `LSMTLView` methods (both encodings are
  checked):
  - `initWithFrame:device:display:hdr:vsync:` always requests HDR and sets
    the layer up for EDR: RGBA16Float, `wantsExtendedDynamicRangeContent`,
    and `kCGColorSpaceExtendedLinearITUR_2020`.
  - `updateHDRState:` (each frame, from `MetalRenderFrame::BeginFrame`) keeps
    that layer setup and returns YES. It also reads the screen's
    `maximumExtendedDynamicRangeColorComponentValue` and whether the screen
    can show P3.
- **Tone scale.** An entry hook on `ampas::init_TsParams` replaces the HDR
  `maxNits` with 100 × headroom, capped at 10,000.
- **LUT rebuild.** An entry hook on `ls::GameRenderView::Update` sets the
  view's state-changed flag once per headroom change. BG3 then calls every
  stage's `OnStateChanged`, as it does for a settings change, and
  `PostProcessStep_ComputeLUTs` rebuilds the display LUT.
- **Pipelines** (metal-hooks):
  - A render-pipeline filter changes every BGR10A2Unorm attachment (BG3's HDR
    drawable format) to RGBA16Float.
  - It swaps the fragment functions of `CombineUI_HDR` and
    `CombineUINo_UI_HDR` for bg3mfx's
    ([`ImprovedDisplayShader.h`](ImprovedDisplayShader.h), compiled once per device
    at runtime).
  - A pipeline substitution builds an sRGB-compressing variant of each and
    binds it while the screen can't show P3.

The replacement composite:

- decodes BG3's PQ scene to nits / 100 (1.0 = SDR white);
- draws the UI as linear BT.2020 at 1.0;
- keeps BG3's blend, which attenuates the scene by the UI's coverage twice;
- for sRGB screens, applies ACES 1.3's reference gamut compression in BT.709
  (threshold 0.8, power 1.2), with limits that put P3's boundary on sRGB's.

The shaders keep BG3's names, bindings and 16-byte constants, so metalfx's
Frame Generation still recognizes and replays the composite.

- **Calibration.** One instruction in `gui::DCHDRCalibration`'s
  constructor is patched (`mov w8, #1` becomes `#2`), so its first Phase is
  2 (paper white and contrast) instead of 1 (peak luminance). Phases then run
  2 → 3 (done) through BG3's own `OnChangePhase`.

The two native hooks share a 48-byte island in the header padding
(`SupportedBuild.h`, `Islands::ImprovedDisplay`) through `BG3MFXHookEntry`
(`src/common/native/CodePatch.h`).

## Improvement

Image quality. Every screen gets the HDR path's P3 color and BG3's tone map
to the screen's real headroom. HDR screens no longer get a PQ image
tone-mapped twice, and screens that aren't HDR displays no longer get sRGB
capped at SDR white.

Validated in the game on November 14, 2026, on a Studio Display (displayed,
2560×1440):

- the image looked right;
- brightness changes were tracked live, with no hitch (peak 100.8 to
  178.3 nits);
- sRGB presets looked like normal SDR, and P3 colors were compressed cleanly;
- Frame Generation still doubled the frame rate, with no flicker.

Cost, measured with GPU profiling of one captured frame per build of the same
scene (M5 Pro, 2560×1440, Studio Display P3, so no sRGB compression):

- composite encoder fragment time: 0.097 ms for BG3's PQ composite into
  BGR10A2, and 0.122 ms for this one into RGBA16Float;
- that is +0.026 ms a frame, about 0.3% of the frame's GPU time. The two
  frames' totals (8.37 ms and 7.51 ms) differ by more than that, because
  scene content and timing vary between captures.

The LUT rebuild runs only when the headroom changes.

## Tests

[`improved_display_smoke.mm`](../../../tests/features/improved-display/improved_display_smoke.mm)
(synthetic, offscreen) draws both replacement shaders from a PQ scene and an
sRGB UI into RGBA16Float. It checks:

- SDR white, an opaque UI, BG3's partial-coverage blend and a 1000-nit
  highlight;
- the 16-byte constants;
- that the sRGB variant brings P3 green inside sRGB and leaves neutral colors
  alone.
