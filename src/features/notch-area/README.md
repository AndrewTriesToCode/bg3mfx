# Notch Area

Technical name: `notch-area`.

Opt-in with `BG3MFX_FEATURE_NOTCH_AREA=1` (the `bg3mfx` launcher sets it;
development launches: `--feature notch-area`). Requires custom-menu. Not
native: the window part is AppKit on BG3's `LSWindow`; the turn-order part
hooks BG3 and Noesis functions and is installed only on the supported build
(`SupportedBuild.h`, `NotchArea`).

## Behavior

On a MacBook with a notch, BG3's Borderless mode leaves a black bar across
the top of the screen: the strip beside the camera notch is not used. With
this feature the game is drawn into that strip too, so it covers the whole
panel (1280×832 pt instead of 1280×800 pt on a 13-inch MacBook Air). The
notch itself hides the part of the picture behind it. The combat turn order,
at the top center, is moved down below the notch; the rest of the HUD,
menus and loading screens keep their place.

**Use Notch Area** (Options → Video, after Display Mode, saved across
launches as `BG3MFXNotchArea`) is on by default. It is listed only when a
screen has a notch, and takes effect at once: unticked, the window goes
back to macOS full screen below the notch; ticked, it covers the strip again.

Fullscreen gets the same treatment at a 20:13 resolution (1280×832 or
2560×1664), where the display mode keeps the strip on. Its 16:10
resolutions turn the strip off in the display mode itself; the screen then
reports no notch and the game keeps macOS full screen. With the game's
"Scale to fit below built-in camera" on, the screen also reports no notch,
so that choice is kept.

## Implementation

BG3 creates the Borderless and Fullscreen window as a borderless `LSWindow`
(style mask 0), and `cocoa::CocoaWindow::Show` calls `toggleFullScreen:`
while the style mask is 0. macOS places a native full-screen window below
the notch and paints the strip beside it black, and no API lets it into the
strip.

[`NotchArea.mm`](NotchArea.mm) wraps `LSWindow`'s `toggleFullScreen:`. When
the option is on and the window's screen has a notch (`safeAreaInsets.top`),
it does not enter native full screen. Instead it:

- calls the window delegate's (`LSMTLView`)
  `window:willUseFullScreenPresentationOptions:`, which records the cursor
  capture, display and display rect native full screen would;
- hides the menu bar and Dock (`NSApp.presentationOptions`);
- gives the window the screen's whole frame.

BG3 already raises an `LSWindow` above the menu bar (level 25) while it is
key and lowers it when it resigns key, so the window stays over the strip
only while the game is in front. The style mask stays 0, so BG3's later
`Show` calls toggle again; the window just gets the frame again. BG3 never
toggles back: a Display Mode change closes the window and creates a new one,
and the presentation options are restored when the window closes. A screen
change re-applies the frame. The tick box moves the current window between
the two: unticked, it restores the options and enters native full screen;
ticked, it leaves native full screen and covers the screen once BG3's
`windowDidExitFullScreen:` has run.

### Turn order

BG3's UI is one Noesis view: `CanvasRoot`, then `ViewboxRoot` (scaling a
3323×2160-unit design to the screen), then `ContentRoot`, a grid of widgets.
The turn order is the `CombatantsOverlay` widget: `HudRoot`, then
`HudRootPresenter`, then `CombatState`, a full-screen border around a
top-anchored panel of portraits, and nothing else.

Two entry hooks (islands in `Islands::NotchArea`) move it:

- `ui::NoesisUIManager::Render` records the view BG3 renders (its `IView` at
  +0x70, 0x10 into the `Noesis::View`).
- `Noesis::View::Update`, on the thread that may change the view's tree, finds
  `CombatState` by name along that path for BG3's view, and sets its top
  margin to its original one plus the notch's share of the UI's height
  (`safeAreaInsets.top / frame height`, 73 of 2160 units on a 13-inch MacBook
  Air) while the window is beside the notch, and back otherwise. A new widget
  (combat starting again) is found the next frame.

Noesis hit-tests in its own layout, so hover and clicks follow the portraits.
Moving BG3's whole UI root instead was tried and dropped: full-screen panels
and loading art then sat below a strip of game world.

custom-menu's Borderless fit repair only acts on native full-screen windows,
so it applies only when this feature is off or the screen has no notch.

## Improvement

Not a speedup: it uses the 32 pt strip beside the notch (4% more of the
panel). In native full screen the 1280×832 pt surface was shown in a
1280×800 pt window; here window, view and drawable match.
The Borderless fill, clicks at the top and bottom edges, and the tick box
switching both ways were user-confirmed November 26, 2026 (13-inch MacBook
Air, BG3 4.1.1.7631656), as was the fill with MetalFX upscaling and every
other feature on, started from the bg3mfx launcher, and the turn order below the
notch with hover and clicks working. Fullscreen at 20:13 got the
full-screen frame, from the window list, but was not checked by eye.
