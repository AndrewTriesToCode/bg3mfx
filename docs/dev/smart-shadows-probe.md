# Shadow Rendering Optimizations: vista-shadow cascade probe

This page documents the read-only cascade probe and its original collection
procedure. A live baseline has since identified the guarded vista submit as a
two-slice Depth16 atlas at 1024² or 2048², with partial Load regions and
occasional Clear passes. The separate four-slice 2048² cascades are outside
that submit's scope. See the [Shadow Rendering Optimizations plan](smart-shadows-plan.md) for
the corrected implementation and remaining live validation. Older slice
observations and the saved-capture pass association do not override this live
mapping.

## Collect a trace

Keep Steam running and quit BG3 normally before launching. Run from your own
Terminal at nice 0 (`nice` without arguments prints the current priority). This
command skips the Larian launcher and leaves the game bundle unchanged:

```sh
cd /Users/acw/Dev/bg3mfx
BG3MFX_TRACE_SHADOWS=1 python3 tools/launch/bg3mfx.py launch-trace \
  --output "build/evidence/$(date +%Y%m%d)-smart-shadows/shadow-stability-$(date +%H%M%S).jsonl"
```

Use the rebuilt `build/bin/libBG3MetalFXTrace.dylib`; build it before launching,
never while it is loaded. Choose a new output filename for each run. Turn Frame
Generation off, load the Lower City save and retain the same shadow quality.
The probe records for three minutes starting at the first matching shadow pass,
which may occur before the save finishes loading. If loading consumes most of
that window, collect a second run with a faster-loading save.

Once loaded, spend roughly 15 seconds on each action:

1. Hold the camera still with characters and foliage visible.
2. Pan slowly, then rotate the camera.
3. Zoom in and out, then hold still again.
4. Move the party through the scene.

Quit normally. Tell the developer which save, shadow quality and action order
you used. Diagnostic tracing affects CPU performance; this run is for mapping,
not an FPS comparison. You operate the game; collection needs no app automation.

## Inspect the trace

```sh
python3 tools/analysis/shadow_stability.py \
  build/evidence/DATE-smart-shadows/shadow-stability-TIME.jsonl \
  --decoded build/evidence/DATE-smart-shadows/shadow-stability-decoded.json
```

The summary separates texture identities, slices, mip levels, load actions,
shader pairs and constant-buffer slots. It counts exact camera-field repeats
only across consecutive presentation frames. Missing/unreadable samples are
reported separately; gaps are not counted as repeats. The decoded file contains
reflected matrices and near/far fields at their declared offsets.

`shadowProbeReflection` records the reflected layouts. `shadowProbeSample`
records the first draw of each qualifying pass, even if its layout is missing.
Only reflected camera buffers containing `g_ViewMat` or
`g_OffsetViewProjectionMat` qualify. CPU-readable shared buffers and setBytes are
supported; private buffers are reported unavailable. There are no GPU readbacks
or waits. The snapshot is a CPU observation at encoding time, not proof of the
values a GPU-written buffer later contains.

## Gate before rendering changes

Use shader/disassembly or GPU-capture evidence to establish matrix packing and
whether the captured matrices are the actual light-camera transforms. Identify
the main view, each cascade and vista pass explicitly; dimensions alone are not
an implementation contract. Then derive relative transforms and measure:

- Whether camera movement is pure integer-texel translation at fixed scale.
- How often scale, rotation, near/far or depth mapping changes.
- How often each cascade is exactly unchanged.
- Whether all relevant passes have readable, consistent inputs.

The current analyzer reports exact stability only. It deliberately does not
claim texel snapping from raw matrix translation components. If reflection is
missing or buffers are private, extend capture instrumentation before drawing
conclusions. The local `gpudebug` CLI was used to inspect the saved capture.

All traces and decoded game data remain local under ignored `build/`. The live
baseline at `build/shadow-baseline-20261015-195731.jsonl` establishes the
native target and partial-region shape, but does not validate reduced
rendering or the target's depth compare/write state. A new live trace records
`shadowProbeSample.depthState` for that check. The corrected path still needs
a user-operated run. For that run, use the same save, Shadows High, resolution,
upscaler and camera, and leave Frame Generation off for timing. Confirm
`smartVistaPass`,
`nativeVistaReplay: true` and `reducedVista: true` in the enabled trace.
FULL/HALF periods can retain atlas tiles across switches, so they are not
guaranteed clean A/B references. See the [plan](smart-shadows-plan.md) for
commands and validation criteria. The game remains user-operated.
