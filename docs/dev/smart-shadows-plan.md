# Shadow Rendering Optimizations: vista-shadow plan

## Current prototype

An opt-in half-resolution vista prototype is implemented behind
`BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS_VISTA=1`; it is disabled by default. The live native baseline
(`build/shadow-baseline-20261015-195731.jsonl`) establishes that the guarded
`CascadedShadowBufferStage::Submit` hook at stage+0x21a0 targets a two-slice
Depth16 atlas at 1024² or 2048². Its passes use partial 128² or 256² Load
regions, with occasional Clear passes. The separate four-slice 2048² cascade
array is outside this hook's scope, so its near cascade remains native. The
earlier association of saved capture replay `re30` and its four-slice Load
target with this vista submission was incorrect and is superseded by the live
baseline. No new live validation of the corrected reduced rendering path has
been done. Interleaving, temporal history, a player setting, and default-on
behavior are not part of this prototype.

The hook is tied to the supported executable UUID and checks the complete
seven-instruction call context, the native submit target prologue, branch
reach, and a zeroed 16-byte branch island before patching. A failed hook install
is a launch error. At runtime, exact descriptor checks gate redirection; if
preparation fails, BG3's original descriptor and submission continue
unchanged.

The pass renders into a private half-size `Depth16Unorm` texture. The viewport,
scissor and slope bias are halved. For Load, the selected slice is first seeded
from the native atlas by max-reducing each 2×2 source footprint; this carries
existing atlas contents into the reduced target. After the redirected pass,
only the rectangles covered by recorded draw viewport/scissor intersections
are replaced in the original slice. Each destination pixel takes the max depth
of its clamped 2×2 reduced footprint. The original pass descriptor retains its
Load/Clear and Store behavior, so untouched regions on Load and the sibling
slice remain native. The merge uses max reduction under the reversed-depth
assumption. The earlier saved capture's `GreaterEqual` state is not proof of
the corrected atlas target's native depth state; verify
`shadowProbeSample.depthState` (`compare` and `writes`) in a new live trace.
The corrected path supports two-slice Load and Clear descriptors. Pooled
textures are returned on command-buffer completion.

The diagnostic records startup values for `smartVista`, `vistaCompare` and
`vistaOnly`, plus metadata for rejected Depth16 array descriptors. Full
`supportsDescriptor` validation gates comparison and vista-only arming. The
baseline proves that the current stage and target descriptor can match the
supported two-slice atlas shape. It does not validate reduced rendering or
establish quality or performance. Keep the feature opt-in pending a new live
run with `smartVistaPass` and user-reviewed image results. In FULL/HALF
comparison mode, atlas tiles can persist across mode switches, so successive
10-second periods are not guaranteed to be clean, independent A/B references.
The comparison is diagnostic only and cannot establish a performance benefit.

## Vista-only diagnostic

`BG3MFX_SHADOWS_VISTA_ONLY=1` is a diagnostic-runtime-only view-isolation
mode. It waits for a native descriptor to pass the full support checks before
suppressing six direct primitive/indexed draw variants on non-vista depth-only
Depth16 maps, including cascades, local atlases and the separate mountain pass.
Until that match, normal shadows are preserved and the run is not isolated. The
runtime prints a waiting message and records `shadowProbeVistaOnlyEnabled` with
`suppressionArmed: false`; after a match it reports and records
`smartVistaIsolationArmed`. Frames before arming can still contain other
shadows. After arming, native clear/load/store actions remain intact; the vista
replay and internal reduced-vista merge are preserved. The native submit
context is installed for this flag even with `BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS_VISTA=0`, allowing a
full-resolution vista reference once a supported pass is found. The quiet
runtime compiles out the flag and suppression and ignores the setting.

### Automatic comparison

`BG3MFX_VISTA_COMPARE=1` is a diagnostic-only comparison. It overrides the
static `BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS_VISTA` value and alternates full resolution for 0–10
seconds, half resolution for 10–20 seconds, then repeats. Its epoch starts only
at a native pass that passes the full descriptor checks. The selected mode is
latched per presentation frame; already-open prepared encoders finish with
their original mode. Because atlas contents can persist across switches,
these periods are not guaranteed to be clean A/B references. This mode is for
image inspection, not performance measurement. The quiet runtime ignores the
comparison flag.

Restart BG3 once after installing the updated diagnostic runtime, then use the
same camera at Shadows High with Frame Generation off:

```sh
cd /Users/acw/Dev/bg3mfx
BG3MFX_VISTA_COMPARE=1 BG3MFX_SHADOWS_VISTA_ONLY=1 BG3MFX_TRACE_SHADOWS=1 \
  python3 tools/launch/bg3mfx.py launch-trace --output "build/evidence/$(date +%Y%m%d)-smart-shadows/vista-compare-$(date +%H%M%S).jsonl"
```

Terminal stderr reports the initial waiting state, arming when a supported
native target is found, each FULL/HALF transition and elapsed time. The trace
records startup flags, rejected descriptor metadata,
`smartVistaIsolationArmed`, and `smartVistaComparison` with `period`, `elapsed`,
`requestedHalf`, `reducedVista` and `width`. If half-resolution preparation
fails, stderr says `FULL half setup unavailable`, and `reducedVista` reports
the actual state as false. There is no onscreen overlay. Verify that the trace
contains `smartVistaIsolationArmed` before treating frames as isolated; frames
before arming may contain other shadows. Ambient occlusion and baked lighting
remain visible.

### Static reference

For a fixed full-resolution or half-resolution reference, disable automatic
comparison and set `BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS_VISTA=0` or `=1` on a fresh diagnostic launch.
With vista-only suppression enabled, use the same camera and scene for each
launch at Shadows High with Frame Generation off:

```sh
cd /Users/acw/Dev/bg3mfx
BG3MFX_SHADOWS_VISTA_ONLY=1 BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS_VISTA=0 BG3MFX_TRACE_SHADOWS=1 \
  python3 tools/launch/bg3mfx.py launch-trace --output "build/evidence/$(date +%Y%m%d)-smart-shadows/vista-native-$(date +%H%M%S).jsonl"
BG3MFX_SHADOWS_VISTA_ONLY=1 BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS_VISTA=1 BG3MFX_TRACE_SHADOWS=1 \
  python3 tools/launch/bg3mfx.py launch-trace --output "build/evidence/$(date +%Y%m%d)-smart-shadows/vista-only-$(date +%H%M%S).jsonl"
```

The two diagnostic launches supply native full-resolution and reduced
vista-only references only after each run records `smartVistaIsolationArmed`.
Quit normally between runs and preserve the same camera and scene. Check the
startup flags, `smartVistaRejectedPass` metadata, `smartVistaIsolationArmed`,
`shadowProbeHiddenPass`, and `shadowProbeSample.vistaOnlySuppressed` to confirm
which descriptor matched and when suppression took effect. Frames before
arming are not isolated references. Inspect partial atlas regions, shadow
coverage and edges while holding the view and moving through the scene. This
is not a performance baseline; diagnostic timing is not a quiet-runtime
measurement.

## Verified native mapping

The earlier saved reference capture
`.claude/worktrees/submit-opcode-probe/build/lowercity.gputrace` (local,
ignored data) was misassociated: replay `re30`, its 394 draws, and resource
491's four-slice 2048² `Depth16Unorm` array were incorrectly labeled as the
vista target. That association is superseded and must not guide
implementation. The live baseline establishes the native call site as
`CascadedShadowBufferStage::Submit` at stage+0x21a0, calling
`rf::RendererCommandBuffer::Submit` at `0x106429f40` from `0x105d41154`.
The stage+0x2670 submission remains a separate mountain submission.

The reflected vertex IR uses a column-major `OffsetVP` transform multiplied by
camera-relative world position. The full history transform remains unverified;
that work is not needed for this no-history prototype. Historical probe tables
below retain their original context and should not be treated as an
implementation contract.

## Historical proposal, superseded

The initial idea was quarter-resolution, four-frame interleaving across
cascades, with sub-texel offsets and history scattered into full-resolution
maps. That proposal relied on assumptions about c0, min-depth merging and
verified texel snapping that were later corrected. It is retained here only as
project history; no renderer implementation should follow it. The current
prototype has no history or jitter.

## Live validation

The user operates BG3; do not control the app. The baseline has established the
native target shape and partial-region behavior, but the corrected reduced
path still needs user-operated validation. Keep Steam running and use the
launch helper's default app path, which points to the Steam app under
`Baldurs Gate 3` (the app itself is `Baldur's Gate 3.app`):

```sh
cd /Users/acw/Dev/bg3mfx
BG3MFX_TRACE_SHADOWS=1 python3 tools/launch/bg3mfx.py launch-trace \
  --output "build/evidence/$(date +%Y%m%d)-smart-shadows/shadow-native-$(date +%H%M%S).jsonl"
```

For native references, leave `BG3MFX_SHADOWS_VISTA_ONLY`,
`BG3MFX_SHADOW_RENDERING_OPTIMIZATIONS_VISTA` and `BG3MFX_VISTA_COMPARE` unset. For a later reduced
comparison, build the diagnostic runtime before launching it, never while
loaded, and confirm `smartVistaPass`, `nativeVistaReplay: true` and
`reducedVista: true`. Also inspect `shadowProbeSample.depthState` to verify the
native atlas compare function and depth-write state before accepting the max
merge direction. Vista-only references additionally require
`smartVistaIsolationArmed`; frames before that event may contain other shadows.
Use the same save, Shadows High, resolution, upscaler and camera, with Frame
Generation off for timing. Inspect partial atlas regions, shadow coverage,
edges and camera movement. Treat FULL/HALF periods as potentially contaminated
by cached tiles across switches. Record image observations separately from
timing; diagnostic timing is not a quiet-runtime performance measurement.
Default-on behavior or a player setting requires accepted live quality and
performance results.
