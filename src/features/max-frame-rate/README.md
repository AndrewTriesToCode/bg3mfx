# max-frame-rate

Opt-in with `BG3MFX_FEATURE_MAX_FRAME_RATE=1` (the `bg3mfx` launcher sets it);
requires custom-menu and metal-hooks.

**Behavior.** Adds two checkboxes in Video options, under Max Frame Rate's
on/off checkbox and above its slider: Snap to Native FPS, then FPS Thermal
Guard. Both are available only while that checkbox is ticked, and follow it
the moment it changes.
Their labels start with two em spaces to line up with the slider: BG3
indents the slider in its own menu layout, and an option has no indent
setting (its view model carries only its id, type, text, description,
enabled state and value).

### Snap to Native FPS

The choice persists (`BG3MFXSnapNativeFPS`). Ticked, it does two things:

- **Snaps the cap.** The Max Frame Rate slider stays on rates the screen
  shows evenly: the divisors of its native refresh rates, down to 30 fps
  (or the refresh rate, if lower). That is, whole rates no faster than the
  screen whose frame interval is a whole number of its update steps (its
  `displayUpdateGranularity`, or its refresh interval when it reports none).
  The screen's values are read at runtime from the game window's `NSScreen`,
  not fixed:

  | Screen | Rates |
  |---|---|
  | ProMotion (4.167 ms steps, 24–120 Hz) | 120, 80, 60, 48, 40, 30 |
  | Fixed 60 Hz | 60, 30 |
  | Fixed 120 Hz | 120, 60, 40, 30 |
  | Fixed 144 Hz | 144, 72, 48, 36 |

  Below 30 a fixed screen repeats each frame three or more times, and
  ProMotion drops toward its 24 Hz floor, so those rates are left out. A drag snaps to the nearest (the lower on a
  tie), and a change of exactly one from the rate shown, as the slider's
  arrows and keys make, moves to the next rate that way; a drag that lands
  exactly one away also counts as an arrow step. BG3 applies the slider every
  UI frame while it is dragged, so the slider snaps during the drag. Ticking
  the box snaps the current cap.
- **Paces presents to the cap.** BG3's final
  `presentDrawable:afterMinimumDuration:` uses a minimum of 1/rate - 0.25 ms
  instead of BG3's 1/(refresh rate + 1), where the rate is the lowest the
  screen can show that is at least the cap (the cap itself once snapped).
  ProMotion shows frame intervals only in steps, and a minimum just past a
  step waits for the next one: 1/(112 + 1) held a 112 cap at 80 fps; 1/rate -
  0.25 ms sits just under the step. Frame Generation's own presents are
  unchanged.

An unsnapped cap could not be shown evenly anyway: BG3's limiter at 65 fps
missed the 12.5 ms step every frame and settled at 60, so pacing is offered
only together with snapping.

### FPS Thermal Guard

Independent of Snap, and of the Dynamic Upscaler Thermal Guard. The choice
persists (`BG3MFXFPSThermalGuard`). Ticked, while Max Frame Rate is on, it
watches `NSProcessInfo`'s `thermalState` (nominal, fair, serious, critical):

- After 10 s above nominal it lowers the frame rate one native rate (120 →
  80 → 60 → 48 → 40 → 30 on ProMotion, 60 → 30 on a fixed 60 Hz screen), and
  again every 10 s while still above nominal, down to the lowest native rate
  (30 fps, or the cap if lower).
- After 10 s at nominal it raises it one native rate, and again every 10 s,
  until it reaches the cap and no longer limits.
- A change of state restarts the 10 s.
- Snap need not be ticked. With an unsnapped cap the first step is from the
  highest native rate under the cap, which is what BG3 already runs at (a 65
  cap runs at 60, so the guard goes to 48); it stops limiting once rising
  passes the last native rate under the cap. Without Snap, BG3's own
  limiter still paces frames while the guard is not limiting.

The upscaler's guard cuts the resolution every 5 s and restores it every
15 s, so this one is slower to drop and quicker to rise: with both ticked the
resolution gives way first and the frame rate comes back first. The saved
cap and the slider are unchanged; the guard only lengthens the present
minimum to 1/rate - 0.25 ms of its rate (when that is longer than Snap's or
BG3's), so the frame rate falls through present back-pressure.

**Implementation.** BG3's cap is a tick box (id 0x53, BG3's settings +0x5b)
and a slider (id 0x54, settings +0x5c); both are found by id among the
non-combo items. In BG3 4.1.1, dragging the slider stores the value in its
view model (`gui::VMSliderSetting`), `DCOptionsBase::Update` calls
`VMSliderSetting::ApplyValue` each UI frame, which copies it to the option
item (+0xb8) and calls the item's callback; BG3's callback only marks the
manager changed, and `VideoOptionsManager::ApplySlider` later stores the
item's value, truncated, in the settings. `MaxFrameRate.mm` wraps the
slider's callback: with Snap ticked it shows the snapped rate (remembering
the last one shown, to tell an arrow step from a drag) on the item
(`BG3MFXMenuShowSliderValue`, which also updates the view model) before
calling BG3's. It wraps the tick box's callback to refresh both checkboxes.
Both wraps are reinstalled each time the menu is built.

The pacing reads the cap and its toggle from BG3's live settings on the
render thread, as a metal-hooks present-duration filter
(`BG3MFXMetalHooksFilterPresentDuration`, only for `afterMinimumDuration:`,
not `atTime:`), and the FPS Thermal Guard steps its rate there too, reading
`thermalState` and `CACurrentMediaTime`. custom-menu's borderless refresh repair filters the duration
first. The screen's `minimumRefreshInterval`, `maximumRefreshInterval` and
`displayUpdateGranularity` come from `src/common/ScreenTiming`, refreshed
when screens or the game window's screen change. If the cap's items are not
found, the checkbox stays at the end of Video options and a menu problem is
shown.

**Improvement.** Not measured yet; Snap is expected to even out frame pacing
when the cap is below the refresh rate, and FPS Thermal Guard to trade frame
rate for lower heat under sustained load.
