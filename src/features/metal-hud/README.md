# Metal Performance Overlay

Technical name: `metal-performance-overlay`.

Shows or hides Apple's Metal performance overlay from a persistent checkbox at
the top of BG3's General settings. It is a display aid; it does not change
rendering. The initial value follows `MTL_HUD_ENABLED=1` unless a saved
`BG3MFXMetalHUD` choice exists. No performance improvement is claimed or
measured for this setting.

The player-facing menu checkbox is named “Show Metal HUD.” The menu and preference bridge is in
[`NativeMenu.mm`](../../../src/integration/menu/NativeMenu.mm); overlay changes
are handled by the shared renderer integration in
[`Trace.mm`](../../../src/integration/renderer/Trace.mm).

The checkbox ordering and HUD on/off were visually checked in BG3 4.1.1.7631656.
See [architecture](../../../docs/dev/architecture.md) and
[current validation](../../../docs/dev/validation/README.md).
