# Custom Menu

Technical name: `custom-menu`.

There is no flag of its own: it is enabled by the features that require it
(metal-hud and metalfx). It needs the supported ARM64 executable. It also
keeps BG3's Video options responsive after a fullscreen change (below).

## Behavior

Features add their options to Options → Video through custom-menu. Without a
feature that requires it, the Video options are BG3's own. If BG3's option
list is not what custom-menu expects, it reports `customMenuError` and shows
"bg3mfx options may be unavailable" once. BG3's own options keep working.

### Fullscreen focus repair

After a Video settings change in fullscreen, BG3's options sometimes needed a
second click before a control responded. BG3's `BindSurface` removes its render
view (`LSMTLView`) from the window and sets it back as the content view. That
leaves the window as first responder, so the next click only gave the view its
focus back.

## Implementation

[`CustomMenu.h`](CustomMenu.h) is the API. Features call it from their install:

- `BG3MFXMenuOnBuilt` registers a callback for when BG3 has built the Video
  options. Callbacks run in install order (requirements first, then by name).
- `BG3MFXMenuWrapApplyCombo` wraps the manager's ApplyCombo; each wrapper calls
  the rest of the chain, BG3's own last.
- Item calls add tick boxes and sliders, append combo values, move and dim
  items, and replace selection callbacks. Each uses BG3's observed ARM64 ABI.

[`CustomMenu.mm`](CustomMenu.mm) patches the Video options manager's Init and
ApplyCombo vtable slots at its activation. That runs after every install and
before BG3 builds a menu. It checks both slots first. Init calls BG3's own,
then validates the option list. It runs the callbacks only for the Video pass,
which it recognizes by the Upscaling Type combo (type 3, id 99); other passes
are recorded as `customMenuDeferred`.

[`RenderViewFocus.mm`](RenderViewFocus.mm), installed with custom-menu, is the
focus repair. It wraps `LSWindow`'s `setContentView:`. When the render view
that had focus is removed and the same view is set back, it makes that view
first responder again. It does this only for the active key window with no
sheet or modal window open. If a different view is set, it stops tracking the
old one without keeping it alive. The diagnostic runtime records
`renderViewFocusRepair`.

## Improvement

The menu API is not a speedup; it only adds options. The focus repair is a fix:
the Video menu stayed responsive after fullscreen settings changes
(user-confirmed October 16, 2026, BG3 4.1.1.7631656). The API move has not been
re-checked live.
