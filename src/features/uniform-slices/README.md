# Uniform Allocation Slices

Technical name: `uniform-slices`.

Opt-in for measurement: `BG3MFX_UNIFORM_SLICES=1` enables it. BG3 allocates
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
[`UniformSlices.mm`](../../../src/features/uniform-slices/UniformSlices.mm),
installed through [`NativeMenu.mm`](../../../src/integration/menu/NativeMenu.mm).
It checks the replaced instructions at each site, the island space and branch
reach before patching.

Estimated improvement: in thread-state traces the lock costs about 0.65 cores
at a 60 fps cap and 0.9 cores uncapped. In a synthetic model of the allocator
(`tools/probes/uniform_lock_sim.cpp`), slices came within 2–5% of no allocator
and cut the model's capped worker CPU by about 35%. Not yet measured live; the
other inlined sites keep the lock. See [performance analysis](../../../docs/dev/performance.md).
