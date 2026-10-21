# Reduced Locking

Technical name: `reduce-locking`.

Experimental. The `bg3mfx` launcher turns it off unless the player sets
`BG3MFX_REDUCE_LOCKING=1`; the runtime alone enables it when the variable is unset,
and `BG3MFX_REDUCE_LOCKING=0` disables it. BG3 allocates
every draw's uniforms from one per-frame bump offset on its `MetalRenderer`,
guarded by one `os_unfair_lock`, and the lock-and-bump is inlined at about 130
sites. Draw-recording jobs on every worker queue on it. The two hottest sites,
`AppliedMaterial::BindMaterialParameters` and
`RenderableObject::SetupEngineParameters`, now allocate from a per-thread slice
of the same buffer. A thread reserves each slice (16 KB) through BG3's own lock
and bump, so the other sites still see BG3's protocol, and the hook on
`MetalRenderer::BeginFrame`'s reset of the offset retires every slice. On
Apple Silicon BG3 binds the shared uniform buffer directly (no commit-time
copy), so slices only need the per-frame reset.

- `BG3MFX_UNIFORM_SLICE_BYTES` (default 16384; a multiple of 16 from 256 to
  1 MB): the slice size.
- The diagnostic runtime reports `uniformSlicesUsage`: slices taken and the
  largest offset a frame reached, against the 21 MiB buffer.

The implementation is in
[`UniformSlices.mm`](../../../src/features/reduce-locking/UniformSlices.mm),
installed through [`NativeMenu.mm`](../../../src/integration/menu/NativeMenu.mm).
It checks the replaced instructions at each site, the island space and branch
reach before patching.

Measured live on October 20 (Lower City, Ultra, Upscaling Off, Frame Cap 60,
M5 Pro, quiet runtime, two 10–30 s `procpower` windows per run, all at 60 fps):

| Dynamic Worker Prioritization | Slices | CPU | CPU power |
|---|---|--:|--:|
| on (default) | off | 257% | 5.6 W |
| on (default) | on | 238% | 4.9 W |
| off | off | 205% | 6.6 W |
| off | on | 162% | 5.8 W |

With Dynamic Worker Prioritization off, System Traces put 91% of lock samples in
the two patched functions; slices removed 98% of lock samples, the `WT/High`
workers fell from 1.02 to 0.61 cores, and the render thread's waiting on jobs
from 9.6% to 2.7% of its time. The remaining lock time is spread over many
other sites. No rendering errors in play with the diagnostic runtime (about
33,000 slices); the largest frame used 0.47 MB of the 21 MiB buffer.
Uncapped (CPU-bound) frame rate is not yet measured. See
[performance analysis](../../../docs/dev/performance.md).
