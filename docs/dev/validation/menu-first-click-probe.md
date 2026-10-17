# Video menu first-click probe

This diagnostic observes the report that fullscreen Video settings sometimes
needed an extra click before the controls responded. Static inspection identified
the focus-loss path and the runtime repair. The user confirmed the Video menu
stayed responsive after changing settings in fullscreen on October 16, 2026.

## Reproduction

Keep Steam running. Quit BG3 normally before building or starting a new runtime.
The user performs all game interactions; do not automate or control the app.
The app bundle is unchanged by this development launch.

From the repository root:

```sh
make build/libBG3MetalFXTrace.dylib
BG3MFX_MENU_PROBE=1 python3 tools/bg3mfx.py launch-trace \
  --app "/Users/acw/Library/Application Support/Steam/steamapps/common/Baldur's Gate 3/Baldur's Gate 3.app" \
  --output "build/menu-first-click-$(date +%Y%m%d-%H%M%S).jsonl"
```

The timestamp creates a fresh output path (the helper rejects existing files).
The helper skips the Larian launcher with `-NoLauncher 1`. Skip the intro if
possible and remain at the main menu.

1. Open Options, then Video. Pause for two seconds before clicking a setting.
2. Click one named native setting once, such as Display Mode. Pause again.
   Record whether its popup opened or its value changed. If it did not respond,
   click the same control again and record what happens. Avoid accepting an
   unwanted display-mode change.
3. Close and reopen Video and repeat. State whether the extra click is needed
   only once after launch or on every visit, and whether clicking blank menu
   space first also makes the controls work.
4. Record the selected Upscaling Type and Frame Generation state. If useful,
   repeat with Off + Frame Generation off, then the original settings, and
   restore those settings afterward. The user chooses and changes settings.
5. Quit normally. Share the probe events and the observations together.

An observer can read just the probe while the user interacts in another terminal:

```sh
tail -f build/menu-first-click-TIMESTAMP.jsonl | rg --line-buffered 'nativeMenuProbe'
```

Replace `TIMESTAMP` with the actual generated filename. Other diagnostic renderer
events share this file; no GPU capture is needed for this input/UI investigation.

## Events and limits

`BG3MFX_MENU_PROBE=1` is required; other values and an unset variable disable it.
The probe and NSEvent monitor are compiled out of the quiet runtime, even if the
variable is set. Use `launch-trace`, not the player launcher, for this test.

`nativeMenuProbeCallback` records callback entry and exit for Init, ApplyCombo
(including native controls), Upscaling Type, Quality, forced AA selection, and
AA enabled-state changes. `originalInitReturned` and `initializationComplete`
identify the native and injected initialization boundaries. Init entry reads
only the manager pointer because its item list may not yet be initialized.
Early/deferred returns have an exit event but no `initializationComplete` event.
`context` identifies the enclosing callback at entry and the current callback at
exit, so an init-time restoration can be distinguished from a later selection.

Snapshots include pointer identities, item type/ID, enabled state and enabled
observer count; combos include selected value, choice count and selected observer
count. Relevant IDs are AA 98, Upscaling Type 99, Quality 100, HUD 0x7f01 and Frame
Generation 0x7f02. The first native combo is also included as
`role:firstNativeCombo` (Display Mode in the validated build). The probe uses the
same guarded native layouts as the integration; it does not inspect unknown
focus fields or traverse observer objects.

`nativeMenuProbeInput` records mouse down/up and key down/up through a local
NSEvent monitor installed asynchronously on the main thread. It returns the exact
input event unchanged. It records event type, application-active state, event
window identity and key/main state, and the first responder's class. It records
no typed text, key codes, coordinates or screenshots. The monitor observes all
such events delivered to BG3 while enabled, including outside Video, until quit.
It sees events before normal dispatch, so the next input or callback snapshot
can show the resulting state. It cannot expose BG3's internal game-UI focus.

Both event kinds carry a shared monotonic sequence and `monotonicSeconds` clock;
callback events also indicate whether they run on the main thread. Existing
trace output adds PID and wall-clock time. Concurrent callback output can arrive
out of sequence; use sequence/time and context together. Events with this prefix
remain eligible after the general renderer trace cap. As with any diagnostic
runtime, observation adds work and is not a performance comparison.

An input with no corresponding selection callback establishes that the setting
callback did not run; it does not alone establish why. Check whether native Init
or Apply occurs on that first click, whether relevant enabled values change,
and whether the event window was already key and the app active. If native
states stay enabled and focused, internal UI binding/focus needs further native
inspection. These logs cannot establish the absence of an uninstrumented native
callback.

## Focused checks

```sh
make build/native-menu-probe-smoke build/native-menu-probe-quiet-smoke
./build/native-menu-probe-smoke
./build/native-menu-probe-quiet-smoke
```

The fixtures use synthetic native-layout storage, not BG3 or its UI. They check
environment gating, JSON schema, callback boundaries and native delegation,
quiet-runtime exclusion, and identical-event return without recording synthetic
key text. Both fixtures, both runtime builds, and the ten Python launcher tests
passed on October 16, 2026. They do not establish live first-click behavior or
AppKit monitor delivery. Live reproduction remains required.

## Fullscreen surface rebind and focus repair

For BG3 4.1.1.7631656, static disassembly confirms that VSync and upscaler
quality changes both enqueue `StartApplyGraphicSettings`, which calls
`MetalAPI::ResizeRenderFrameWindow` even when display mode is unchanged. Its
common tail calls `CocoaWindow::BindSurface(bool)`. The windowed path passes
false; the fake-fullscreen path passes true, which detaches and reattaches the
same `LSMTLView` with `setContentView:nil` followed by `setContentView:view`.
That path does not explicitly call `makeFirstResponder:`. Addresses and branch
details are recorded in `docs/dev/reference/mac-renderer.md`.

The runtime now hooks `LSWindow`'s `setContentView:` only after the supported
ARM64 UUID check. If the focused `LSMTLView` is detached and that exact view is
reattached, it restores first responder only while BG3 is active, the window is
key, no sheet or modal window is present, and no other responder has taken
focus. The quiet build performs the same guarded repair; the diagnostic build
also emits `nativeMenuFocusRepair` with the attempt/result. The hook does not
intercept input or alter BG3's menu callbacks.

The synthetic menu tests verify callback behavior and probe gating, not this
AppKit lifecycle. The user changed settings in fullscreen and confirmed the
Video menu remained responsive. Windowed mode and modal/dialog interaction have
not been separately checked. If the issue recurs, capture a diagnostic trace
with `BG3MFX_MENU_PROBE=1` and check whether `nativeMenuFocusRepair` reports a
successful restore for each setting change.
