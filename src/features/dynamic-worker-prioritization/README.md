# Dynamic Worker Prioritization

Technical name: `dynamic-worker-prioritization`.

Enabled by default; `BG3MFX_DYNAMIC_WORKER_PRIORITIZATION=0` retains BG3's original worker
placement. The feature places BG3's `WT/High` workers and scheduler in Darwin background
priority, favoring lower-power cores, when short alternating frame-rate trials
show no material loss. It returns them to normal priority if frame rate falls. Other
threads keep BG3's placement.

Implementation is in
[`DynamicWorkers.mm`](../../../src/features/dynamic-worker-prioritization/DynamicWorkers.mm),
installed by [`NativeMenu.mm`](../../../src/integration/menu/NativeMenu.mm).

Live on October 14 in Lower City on an M5 Pro, Ultra, Upscaling Off, Frame Cap
off, optimized idling already enabled, total CPU power fell from about 11 W to
7.4 W at 95–96 fps. In CPU-bound crowd scenes, trials kept workers at normal
priority when background placement cost 6–11% (108.7 vs 102.0 fps and 144.0
vs 128.7 fps). Those are trial comparisons, not extra gains over the 7.4 W
measurement. The behavior is not validated on Macs with fewer or slower cores.
See [performance analysis](../../../docs/dev/performance.md) and
[current validation](../../../docs/dev/validation/README.md).
