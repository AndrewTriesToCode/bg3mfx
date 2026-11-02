# Render Thread Optimizations

Technical name: `render-thread-optimizations`.

Opt-in with `BG3MFX_FEATURE_RENDER_THREAD_OPTIMIZATIONS=1` (the `bg3mfx` launcher sets it);
requires metal-hooks.
The renderer filters repeated fragment texture and pipeline binds.
metal-hooks' [`BindFilter.h`](../metal-hooks/BindFilter.h) holds the
per-encoder cache and forwarding rules.
[`RenderThreadOptimizations.mm`](RenderThreadOptimizations.mm) registers the
feature and turns the filter on; [`MetalHooks.mm`](../metal-hooks/MetalHooks.mm)
applies the rules inline at Metal's encoder hooks, since a call per bind would
cost more than the filter saves. Texture references are unretained because the
encoder owns its active bindings. Bulk texture binds forward only changed
runs, joining changes separated by at most two unchanged slots. A range that
does not fit the 64-slot cache is forwarded intact.

The focused regression executable is
[`bind_filter_smoke.mm`](../../../tests/features/metal-hooks/bind_filter_smoke.mm).
It covers repeated and nil binds, pipeline filtering, changed runs, mixed
single and bulk binds, cache boundaries, and overflow-safe fallback.

October 14 diagnostic counters found about 30,000 fragment texture slots and
1,130 texture-bind calls per frame, with 92% of slots already holding the same
texture; 12% of pipeline binds repeated the active pipeline. Live A/B on an
M5 Pro, Ultra, Upscaling Off, and windowed, with the duplicate-shadow fix and
depth-prepass trim (since removed) enabled, changed 83.1 to 84.0 fps at about 10.7 ms GPU time.
CPU samples showed render-thread driver time down about 25% per frame and
texture binds down 72%. The scene remained mostly GPU-limited, so the FPS
change is small and within scene noise; CPU-heavier scenes may benefit more,
but that gain has not been measured. See [current validation](../../../docs/dev/validation/README.md)
and [performance analysis](../../../docs/dev/performance.md).
