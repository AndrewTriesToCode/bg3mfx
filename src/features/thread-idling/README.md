# CPU Thread Idling

Technical name: `cpu-thread-idling`.

Enabled by default; `BG3MFX_CPU_THREAD_IDLING=0` restores BG3's original idle
loops. The feature replaces busy waits in idle workers, the worker scheduler,
and frame and server tick pacing with sleeps. Idle workers and the scheduler
sleep at once; `CapFrame` sleeps in 250 µs steps, still running queued jobs
between them, then sleeps until 200 µs before its deadline. Batch completion
waits keep BG3's yield: their completion event holds one semaphore that each
blocking waiter resets, so sending more waiters to block could strand one or
leak the semaphore.

For measurement, each part can be tuned at launch:

- `BG3MFX_WORKER_POLL_US` (default 0, BG3's own is 500): how long an idle
  worker polls the job queues before it sleeps.
- `BG3MFX_SCHEDULER_POLL_US` (default 0, BG3's own is 101, at most 1000): the
  scheduler's yield window after each wake.
- `BG3MFX_CAPFRAME_POLL_US` (default 250, at most 1000): `CapFrame`'s sleep
  between its checks for queued jobs to run.
- `BG3MFX_CAPFRAME_MARGIN_US` (default 200): `CapFrame` keeps its poll steps
  until the next one would land in BG3's final 1 ms, then sleeps until this
  margin before its deadline, so its tail spins only the margin. With a poll of
  0 it sleeps there at once and no longer runs jobs while it waits. The
  diagnostic runtime reports how late those sleeps wake (`capFrameWakeLateness`).

The implementation is in
[`ThreadIdling.mm`](../../../src/features/thread-idling/ThreadIdling.mm),
installed through [`NativeMenu.mm`](../../../src/integration/menu/NativeMenu.mm).

Live on October 14 in Lower City, Ultra, Upscaling Off, Frame Cap off, on an
M5 Pro, CPU power fell from 23.7 W to about 11 W with optimized idling alone;
frame rate stayed 95–96 fps. BG3's server remained at 30 ticks/s, with a
33.4 ms worst measured interval. The power result is from `tools/analysis/procpower.c`;
the feature's changes were applied in steps at the same FPS. Fewer or slower
core configurations have not been validated.

On October 20 (Low, Upscaling Off, Frame Cap off, CPU-bound at about 186 fps,
other features off), the current defaults used 596% CPU against stock's 727%
at the same frame rate. A 50 µs worker poll (643%) or BG3's 101 µs scheduler
window (662%, the scheduler then never sleeps) added CPU without measurable
fps; BG3's own polls with the `CapFrame` sleep used 939%, as `CapFrame` no longer
spins and its work moves to spinning workers. See [performance analysis](../../../docs/dev/performance.md)
and [current validation](../../../docs/dev/validation/README.md).
