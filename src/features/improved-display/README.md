# Improved Display

Technical name: `improved-display`.

Opt-in with `BG3MFX_FEATURE_IMPROVED_DISPLAY=1` (the `bg3mfx` launcher sets
it; development launches: `--feature improved-display`). Requires metal-hooks
and custom-menu. Native: it hooks BG3 functions, so it needs the supported
build.

## Behavior

Improved Display replaces BG3's Windows-style HDR with macOS-style EDR. It
also brings better color and brightness to screens that aren't sold as HDR.
BG3's HDR option in the launcher is ignored: a Display Mode option picks
bg3mfx's SDR or HDR look instead.

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

**Display Mode** (Options → Video, saved across launches) picks the look:

- **Improved SDR** is BG3's own SDR path: its SDR tone scale, colors and UI
  blend, so it looks like vanilla SDR. Two things change. Its BT.709 colors
  are shown as BT.709 (vanilla tags them Display P3, which stretches them on
  P3 screens), and it draws to a float drawable instead of an 8-bit one, so
  gradients do not band. It stays at SDR white, with no headroom.
- **Improved HDR** is BG3's HDR image brought to SDR's middle: shadows and
  mid grey as in SDR, with deeper blacks and highlights up to the screen's
  current headroom, and SDR's saturation. It is meant for HDR screens.

Until you pick a mode, BG3 uses Improved HDR where the window's screen
reports any potential headroom (Apple's XDR screens report 16; many other
Mac screens, such as a Studio Display or MacBook Air, report some below full
brightness), and Improved SDR where it reports none. The potential headroom
is fixed for a screen and its preset, so the look does not change with
brightness; until you pick a mode, it changes when the window moves to
another screen. A mode you pick is saved and used on every later launch.

Changing the mode takes effect at once; the display LUT rebuilds. BG3 builds
the Video options for its current path when Options opens: Gamma calibration
in Improved SDR, its HDR sliders and HDR calibration in Improved HDR. After a
mode change they follow when Options is reopened. The Max Nits slider is
dimmed, as the tone scale's peak is the screen's headroom.

With this feature, on any screen:

- **One tone map, to the real headroom.** BG3's own tone scale (ACES SSTS
  with ZCAM gamut mapping) is the only tone map. At the default settings the
  image peaks at SDR white times the screen's current headroom, so
  highlights use the brightness the screen has without clipping. Max Nits
  calibration no longer applies.
- **Improved SDR is BG3's SDR image.** BG3's HDR tone scale puts mid grey at
  20 nits where its SDR one puts it at 10, and its HDR display LUT renders
  colors about 1.4x as saturated, for a bright HDR screen. Rather than
  correct the HDR image toward SDR, Improved SDR reports HDR off, so BG3
  renders its SDR display LUT and SDR composite. BG3's gamma setting applies;
  its HDR contrast and paper white do not.
- **Improved HDR is not just brighter.** BG3's HDR lifts mid grey and
  shadows to about twice SDR's. Improved HDR keeps them at SDR's level
  (within 3% through mid grey) and spends the headroom on highlights. Its
  colors are scaled to SDR's saturation (1.01x in CIELAB for colors inside
  sRGB, from 1.42x). Contrast now works around mid grey: it deepens shadows
  and brightens highlights without moving mid grey. Below a contrast of
  about 0.77, mid grey brightens instead, so BG3's tone scale does not shift
  hues. Paper white scales the
  whole image (100 matches SDR). The peak stays at the headroom whatever the
  contrast and paper white; where BG3's LUT would clip its highlights flat
  (low headroom, or high contrast or paper white), they roll off smoothly
  into the headroom instead.
- **It follows the screen.** In Improved HDR the image re-tunes when the
  headroom changes:
  when you change brightness, move the window to another screen, or another
  app takes EDR. The headroom has to change by more than 1%. While macOS
  animates the change, BG3's display LUT rebuilds at most four times a
  second.
- **Better color and highlights on HDR screens.** Improved HDR shows BG3's P3
  output, and highlights brighter than SDR white up to the screen's headroom.
- **sRGB screens.** In Improved HDR, on a screen macOS reports can't show
  P3, BG3's P3 output is compressed into sRGB instead of clipped. A P3 screen set to an
  sRGB preset still reports P3, so macOS's color management fits the output
  to the preset instead.
- **The UI stays at SDR white,** as macOS draws its own UI.
- **Shorter HDR calibration.** BG3's calibration (on first run, or from the
  Video options) opens on its brightness and contrast page. These still
  apply: paper white sets the scene's brightness relative to SDR white
  (100 matches SDR), and contrast spreads shadows and highlights around mid
  grey in Improved HDR. The
  peak-luminance page ("adjust until the
  image is barely visible") is skipped, because the Max Nits it sets is
  replaced by the screen's live headroom.

## Implementation

[`ImprovedDisplay.mm`](ImprovedDisplay.mm) makes these changes:

- **Render view.** It replaces two `LSMTLView` methods (both encodings are
  checked):
  - `initWithFrame:device:display:hdr:vsync:` always requests HDR and sets
    the layer up for EDR: RGBA16Float, `wantsExtendedDynamicRangeContent`,
    and `kCGColorSpaceExtendedLinearITUR_2020`.
  - `updateHDRState:` (each frame, from `MetalRenderFrame::BeginFrame`, which
    stores the result in the frame) keeps that layer setup and returns YES
    in Improved HDR and NO in Improved SDR, so BG3 takes its HDR or SDR path
    from the next frame. It also reads the screen's
    `maximumExtendedDynamicRangeColorComponentValue` and whether the screen
    can show P3.
- **Tone scale.** An entry hook on `ampas::init_TsParams` changes the HDR
  arguments (BG3's SDR tone scale is left alone). BG3's HDR display LUT
  draws the tone scale through 200 × (t ÷ 200)^contrast × paper white ÷ 100,
  clamped at 1.2 × `maxNits`. The hook passes:
  - mid grey 200 × (8 ÷ 200)^(1 ÷ contrast) in place of 20: at contrast 1
    BG3's HDR curve then matches its SDR image through mid grey, and the
    power keeps mid grey there at higher contrasts. It is held at 3 nits or
    more (contrast below about 0.77 then brightens mid grey): with a lower
    mid, BG3's tone scale shifts hues (in CIELAB on BG3's LUT outside the
    game, yellows about 5° toward red and blues 7–11° toward purple at mid
    0.3–1, against under 2° at 3), which showed as a red and purple cast at
    low contrast;
  - a `maxNits` whose LUT peak is 100 × headroom. The LUT's peak before the
    clamp was measured on BG3's LUT for 16 `maxNits` from 50 to 10000 and
    contrasts 0.5 to 1.5 (the slider's range; contrast also shapes the tone
    scale itself), interpolated, and scaled by paper white, read from
    `GraphicSettings` + 0x80. The hook bisects it for the target.
  - Where that peak is clamped (below about 236 nits at contrast 1, or at
    high contrast or paper white), the smallest unclamped `maxNits` if it
    peaks within 1.5 × the target, or else one clamped at 1.5 × the target;
    the composite then rolls highlights off into the headroom.

  Checked on BG3's LUT outside the game (synthetic, before the 3-nit mid
  floor; the table was then rebuilt with the floor): unclamped peaks land
  within 0.5% of the target at headrooms 2.5 to 16 and contrasts 0.5 to 1.5,
  and at paper white 80.
- **LUT rebuild.** An entry hook on `ls::GameRenderView::Update` sets the
  view's state-changed flag once per headroom or mode change. BG3 then calls every
  stage's `OnStateChanged`, as it does for a settings change, and
  `PostProcessStep_ComputeLUTs` rebuilds the display LUT.
- **Pipelines** (metal-hooks):
  - A render-pipeline filter changes every BGR10A2Unorm attachment (BG3's HDR
    drawable format) to RGBA16Float.
  - It swaps the fragment functions of `CombineUI_HDR`,
    `CombineUINo_UI_HDR`, `CombineUI` and `CombineUI_NoUI` for bg3mfx's
    ([`ImprovedDisplayShader.h`](ImprovedDisplayShader.h), compiled once per
    device at runtime), and draws them to RGBA16Float.
  - A pipeline substitution builds variants of each HDR composite for every
    combination of sRGB compression and highlight roll-off (at 14 headroom
    steps from 1 to 16): 29 besides the base. It binds the one for the
    screen and the tone scale.

The HDR composites:

- decode BG3's PQ scene to nits / 100 (1.0 = SDR white);
- scale its chroma around its BT.2020 luminance by 0.70, which matches BG3's
  SDR LUT for colors inside sRGB;
- when the tone scale needs it, roll highlights off into the headroom step:
  above 0.7 × the step, the brightest channel approaches the step (slope 1
  at the knee), keeping hue;
- draw opaque UI as linear BT.2020 at 1.0;
- blend partly covered UI as BG3's SDR composite (`CombineUI`) does: the
  scene encoded as sRGB, times (1 − coverage), plus the premultiplied sRGB
  UI. BG3's HDR composite attenuates the scene twice in linear light, which
  turned warm translucent menus grey;
- for sRGB screens, apply ACES 1.3's reference gamut compression in BT.709
  (threshold 0.8, power 1.2), with limits that put P3's boundary on sRGB's.

The SDR composites do what BG3's do (the UI blended over the sRGB scene in
sRGB, then BG3's SDR gamma setting) and decode the result as sRGB BT.709 into
linear BT.2020. BG3's own composite writes the same values to a BGRA8Unorm
drawable tagged Display P3.

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

Image quality. HDR screens get BG3's tone map to the screen's real headroom
instead of a PQ image tone-mapped twice, and P3 color. Improved SDR is
vanilla SDR without the Display P3 mis-tagging (on P3 screens vanilla's
colors are stretched to P3 primaries) and without 8-bit banding.

Validated in the game on November 14, 2026, on a Studio Display (displayed,
2560×1440):

- the image looked right;
- brightness changes were tracked live, with no hitch (peak 100.8 to
  178.3 nits);
- sRGB presets looked like normal SDR (through macOS's color management:
  the variants were not bound then, see below);
- Frame Generation still doubled the frame rate, with no flicker.

On November 20, 2026, with the Studio Display's sRGB (500-nit) preset, macOS
still reported the screen as able to show P3 and up to 2.0 headroom, so the
sRGB variants were not bound; macOS's color management fitted the P3 output
to the preset. Compared with vanilla SDR (displayed, by eye and screenshot),
the image was too dark and translucent menu UI was greyer and cooler; the
shadow curve and SDR UI blend addressed those.

A GPU capture then showed that no variant had ever been bound: the claim
recognized bg3mfx's composition functions by their function constants, and
Metal lists none for a specialized function. Every frame drew the base
pipeline (no shadow curve, full saturation, no sRGB compression). The
functions are now marked when made; a capture of the fixed build has the
three variants, and Improved SDR on a MacBook Pro (displayed, headroom 1)
looked much closer to vanilla SDR. On the same MacBook Pro (displayed), the
Auto mode (now the default before a mode is picked) matched Improved SDR
under the sRGB preset (potential headroom 1.0, no P3, so the sRGB variant)
and gave Improved HDR under the XDR preset, which looked right. GPU captures
record BG3's pipeline argument, not the bound substitute, so which variant
reaches the GPU was judged by eye.

On November 20 to 22, 2026, on a MacBook Pro XDR screen (displayed, Metal
API validation on), the Display Mode menu with Improved SDR and Improved HDR
switched looks at once, Max Nits stayed dimmed, and a saved Improved SDR
was used on the next launch. With mid grey held at 3 nits or more, low
contrast in HDR calibration no longer turned the image red and purple.
These runs logged no validation errors. One earlier run with Frame
Generation on aborted under validation when its stand-in drawable wait
timed out and BG3 drew to no target; that is a Frame Generation issue, not
this feature's.

Cost, measured with GPU profiling of one captured frame per build of the same
scene (M5 Pro, 2560×1440, Studio Display P3, so no sRGB compression):

- composite encoder fragment time: 0.097 ms for BG3's PQ composite into
  BGR10A2, and 0.122 ms for this one into RGBA16Float;
- that is +0.026 ms a frame, about 0.3% of the frame's GPU time. The two
  frames' totals (8.37 ms and 7.51 ms) differ by more than that, because
  scene content and timing vary between captures.

The LUT rebuild runs only when the headroom, mode or a setting changes. The
variants are 29 extra pipeline builds per HDR composite function, at its
creation.

Improved HDR's colors are scaled in the composite rather than in BG3's LUT
shader. A patched copy of `PPComputeDisplayLUT_ZCAM` (its IR rebuilt with
SDR's viewing conditions; synthetic) took chroma only from 1.32x to 1.25x
SDR's, and with every SDR/HDR selection but its gamut mapping and output set
to SDR's, to 1.10x: most of the difference is the LUT rendering into P3
primaries. With the composite's scale both reach about 5 ΔE, so the patch
was not worth shipping a modified shader.

Earlier versions drew Improved SDR on BG3's HDR path, with BG3's SDR tone
scale arguments, a luminance remap and a 0.77 chroma scale. Run outside the
game on BG3's LUT shader (synthetic), that matched SDR's neutral axis within
3.8% but left a median 5.3 ΔE in color: the LUT's ZCAM viewing conditions
and gamut target (BT.709 or P3) follow its HDR/SDR mode, which is not an
`init_TsParams` argument. Using BG3's SDR path removes that difference.

## Tests

[`improved_display_smoke.mm`](../../../tests/features/improved-display/improved_display_smoke.mm)
(synthetic, offscreen) draws the HDR replacements from a PQ scene and the
SDR replacements from an sRGB scene, each with an sRGB UI, into RGBA16Float.
It checks:

- SDR white, an opaque UI, BG3's SDR partial-coverage blend and a 1000-nit
  highlight;
- the 16-byte constants;
- that Improved HDR scales chroma by 0.70 around luminance;
- that the sRGB variant brings BT.2020 green inside sRGB and leaves neutral
  colors alone;
- that the roll-off leaves values below its knee alone and brings a 10x
  highlight under a 2x headroom;
- that the SDR composites match BG3's SDR blend decoded as sRGB, keep BT.709
  red on BT.709's primary and stay within SDR white.
