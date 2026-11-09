# max-frame-rate

Opt-in with `BG3MFX_FEATURE_MAX_FRAME_RATE=1` (the `bg3mfx` launcher sets it);
requires custom-menu and metal-hooks.

**Behavior.** Adds a Snap to Native FPS checkbox in Video options, under Max
Frame Rate's on/off checkbox and above its slider. It is available only while
that checkbox is ticked, and follows it the moment it changes.
Its label starts with two em spaces to line up with the slider: BG3
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
  `presentDrawable:afterMinimumDuration:` uses a different minimum from
  BG3's 1/(refresh rate + 1), where the rate is the lowest the screen can
  show that is at least the cap (the cap itself once snapped):
  - At the screen's highest rate (120 on ProMotion), 0: the screen paces
    presents itself.
  - Below it, 1/rate less half the screen's update step (its
    `displayUpdateGranularity`, or its refresh interval when it reports
    none): 60 fps on ProMotion is 16.667 - 2.083 = 14.583 ms, halfway
    between the 60 and 80 fps intervals.

  ProMotion shows frame intervals only in steps, and a minimum just past a
  step waits for the next one: 1/(112 + 1) held a 112 cap at 80 fps. Half a
  step keeps the minimum clear of both neighbouring steps. While the screen
  is unknown, BG3's refresh rate setting stands in for its refresh interval
  (0 at or above that rate, else 1/cap less half the interval); without
  that setting BG3's minimum is kept. With Frame Generation, BG3's present
  is handed to the presenter with this minimum: each generated/real pair
  spans at least the minimum rounded up to whole screen steps, split between
  the two images (40 fps on ProMotion: two images three steps apart, 80 shown
  per second).

An unsnapped cap could not be shown evenly anyway: BG3's limiter at 65 fps
missed the 12.5 ms step every frame and settled at 60, so pacing is offered
only together with snapping.

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
calling BG3's. It wraps the tick box's callback to refresh the checkbox.
Both wraps are reinstalled each time the menu is built.

The pacing reads the cap and its toggle from BG3's live settings on the
render thread, as a metal-hooks present-duration filter
(`BG3MFXMetalHooksFilterPresentDuration`, only for `afterMinimumDuration:`,
not `atTime:`). custom-menu's borderless refresh repair filters the duration
first. The screen's `minimumRefreshInterval`, `maximumRefreshInterval` and
`displayUpdateGranularity` come from `src/common/ScreenTiming`, refreshed
when screens or the game window's screen change. If the cap's items are not
found, the checkbox stays at the end of Video options and a menu problem is
shown.

**Improvement.** Not measured yet; Snap is expected to even out frame pacing
when the cap is below the refresh rate.
