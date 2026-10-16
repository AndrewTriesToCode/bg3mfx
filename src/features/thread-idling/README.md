# CPU Thread Idling

Technical name: `cpu-thread-idling`.

Enabled by default; `BG3MFX_CPU_THREAD_IDLING=0` restores BG3's original idle
loops. The feature replaces busy waits in idle workers, the worker scheduler,
frame and server tick pacing, and batch completion waits with short sleeps or
blocking waits while retaining queued-job work and a short spin window.

The implementation is in
[`ThreadIdling.mm`](../../../src/features/thread-idling/ThreadIdling.mm),
installed through [`NativeMenu.mm`](../../../src/integration/menu/NativeMenu.mm).

Live on October 14 in Lower City, Ultra, Upscaling Off, Frame Cap off, on an
M5 Pro, CPU power fell from 23.7 W to about 11 W with optimized idling alone;
frame rate stayed 95–96 fps. BG3's server remained at 30 ticks/s, with a
33.4 ms worst measured interval. The power result is from `tools/analysis/procpower.c`;
the feature's changes were applied in steps at the same FPS. Fewer or slower
core configurations have not been validated. See [performance analysis](../../../docs/dev/performance.md)
and [current validation](../../../docs/dev/validation/README.md).
