# Notch Area

Technical name: `notch-area`.

Opt-in with `BG3MFX_FEATURE_NOTCH_AREA=1` (the `bg3mfx` launcher sets it;
development launches: `--feature notch-area`). Requires custom-menu. Not
native: it uses no executable offsets, only AppKit on BG3's `LSWindow`.

## Behavior

On a MacBook with a notch, BG3's Borderless mode leaves a black bar across
the top of the screen: the strip beside the camera notch is not used. With
this feature the game is drawn into that strip too, so it covers the whole
panel (1280×832 pt instead of 1280×800 pt on a 13-inch MacBook Air). The
notch itself hides the part of the picture behind it, including part of the
HUD at the top center (the combat turn order).

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

custom-menu's Borderless fit repair only acts on native full-screen windows,
so it applies only when this feature is off or the screen has no notch.

## Improvement

Not a speedup: it uses the 32 pt strip beside the notch (4% more of the
panel). In native full screen the 1280×832 pt surface was shown in a
1280×800 pt window; here window, view and drawable match.
The Borderless fill, clicks at the top and bottom edges, and the tick box
switching both ways were user-confirmed November 26, 2026 (13-inch MacBook
Air, BG3 4.1.1.7631656), as was the fill with MetalFX upscaling and every
other feature on, started from BG3MFX Fast.app. Fullscreen at 20:13 got the
full-screen frame, from the window list, but was not checked by eye.
