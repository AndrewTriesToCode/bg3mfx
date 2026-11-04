# Developing BG3MFX

Requires Apple Silicon, macOS 26 or newer, Xcode command-line tools with the
MetalFX SDK, and Python 3. A licensed Steam installation is required for live
game tests. Project rules for contributors and coding agents are in
[AGENTS.md](../../AGENTS.md).

## Build and test

```sh
make                # quiet runtime + bg3mfx launcher in build/bin/
make test           # Metal pixel and renderer-hook regressions
make test-python    # launcher and development-helper checks
make install PREFIX=/some/prefix   # what the Homebrew formula runs
```

`make test` checks synthetic Spatial/Temporal output, frame generation hooks
and renderer-hook behavior on Metal, for both the quiet runtime and the
diagnostic runtime (`build/bin/libBG3MetalFXTrace.dylib`). Synthetic results do not
establish gameplay image quality or performance.

## Development launches

Keep Steam running, quit BG3, and run:

```sh
python3 tools/launch/bg3mfx.py launch
```

This injects the quiet library from `build/bin/`, skips the Larian launcher with
`-NoLauncher 1`, enables the Metal HUD, and leaves the app bundle unchanged.
It enables no features unless you name them, so a live test exercises one at a
time: `--feature thread-idling`, repeatable, with any of `metal-hud`,
`metalfx`, `duplicate-shadow-fix`, `improved-shadows`,
`render-thread-optimizations`, `new-character-crash-fix`, `lua-jump-fix`,
`thread-idling`, `reduce-locking` and `ssao-blur-fix`. A feature brings the features it
requires (custom-menu for the menu options, custom-render-stages for the shadow
features). Shell `BG3MFX_FEATURE_*` variables are ignored. Run
it from your own Terminal: a process without access to `~/Documents` starts BG3
with a blank profile. To A/B a variant, build it to another path and set
`BG3MFX_RUNTIME=/path/to/libBG3MetalFX.dylib`; read frame rates from
`MTL_HUD_LOG_ENABLED=1` output rather than during `sample`, which itself costs
about a third of the frame rate. For a diagnostic session, use a new trace path:

```sh
make build/bin/libBG3MetalFXTrace.dylib
python3 tools/launch/bg3mfx.py launch-trace
# Or pass --output /absolute/path/to/new-trace.jsonl
```

The diagnostic runtime has one log: the JSONL event log, at `BG3MFX_TRACE` or
`$TMPDIR/bg3mfx-trace.jsonl`. Code writes to it with `BG3MFX_EVENT` (rare,
timestamped, always written) or `BG3MFX_TRACE_EVENT` (frequent, once per distinct
content, up to 20,000 lines), both in `src/common/EventLog.h`. In the quiet
runtime they compile to nothing. Writing an event serializes it on the calling
thread, so compare frame rates on the quiet runtime. Failures go through
`BG3MFXFail` in `src/common/Notice.h`: a `failure` event in the diagnostic runtime,
the system log (`com.bg3mfx`, category `failure`) in the quiet one, and the
player's dialog in both; with `BG3MFX_TEST_ERRORS_STDERR=1`, stderr and no dialog.

A diagnostic session records only what the enabled features report, plus any
opt-in probes. Set these before the launch command to add more:

- `BG3MFX_TRACE_RENDER_CALLS=1`: every Metal call (texture binds, pipelines,
  render passes, encoder ends, command buffers, presents, labels). BG3 binds
  about 30,000 texture slots a frame, so this makes the game slow, and the
  trace stops adding call events at 20,000 lines. `BG3MFX_TRACE_TEMPORAL_CHAIN`
  and `BG3MFX_CAPTURE_WATERFALL` turn it on too.
- `BG3MFX_TRACE_CONSTANTS=1`: camera shader constants and their reflection,
  for `tools/analysis/analyze_camera_trace.py`, and the SSAO blur's
  constants (`PPSAO_Blur_PS`), each snapshotted when its encoder ends.

With `BG3MFX_TRACE_STAGE_LIST=1` set, a diagnostic session records each pack
`BaseApp::InitFrameStages` passes (`stageListCall`: view, kind, pack, and
whether it was forwarded, replaced or skipped).

The unmodded Steam app bundle is at
`/Users/acw/Library/Application Support/Steam/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app`.
The parent folder is spelled `Baldurs` (no apostrophe); the `.app` filename has
one. To launch that bundle with Metal HUD logging enabled while Steam is
running, use:

```sh
open --env MTL_HUD_ENABLED=1 \
  --env MTL_HUD_LOG_ENABLED=1 \
  --env SteamAppId=1086940 \
  --env SteamGameId=1086940 \
  -a "/Users/acw/Library/Application Support/Steam/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app" \
  --args -NoLauncher 1
```

This launches the Steam-installed bundle without injecting the bg3mfx runtime.
Keep live scene navigation under user control.
See the [baseline capture procedure](baseline-captures.md) for collecting
GPU traces, CPU samples, Metal HUD logs, and power estimates.

Add `BG3MFX_FRAME_LOG=1` to the diagnostic runtime to record a `frameStats` event
every 2 s with BG3's actual rendered rate, the real and generated images that reached the display, drops,
the presentation method, the gaps between shown images, and Frame Generation's
sampled refresh rate, source interval, scheduled minimum durations, app active
state, screen maximum refresh rate, stand-in wait/work time, and overflow-slot
use. Follow it with `tail -f <trace> | grep frameStats`. With Frame Generation on,
the Metal HUD's "rendered" figure is unreliable (a trace showed about 19
rendered fps while the HUD showed about 10); use this log instead. The real and
generated cadence fields report the measured interval between successive
presented images of each type.

Add `MTL_HUD_LOG_ENABLED=1` to record the Metal HUD's per-second frame counts in
the unified log (`/usr/bin/log show --predicate 'category == "Logging"'`). Do
not combine `MTL_CAPTURE_ENABLED=1` with frame-rate comparisons: the capture
layer slows the whole session. Never rebuild a library while BG3 is using it.

The player launcher (`build/bin/bg3mfx`, source in `src/launcher/`) can be checked
without starting the game: `BG3MFX_RUNTIME=$PWD/build/bin/libBG3MetalFX.dylib
build/bin/bg3mfx --dry-run`.

## Releasing

1. Update `src/common/native/SupportedBuild.h` only after validating a new Steam
   executable: version, universal-executable SHA-256, ARM64 UUID, feature
   addresses/layouts, and island reservations. Revalidate each installer's
   instruction guards and the independent native fixtures as part of that update.
   The player launcher, runtime, and Python helper consume this one manifest.
2. Tag `vX.Y.Z` and push it.
3. `tools/release/update-formula.sh X.Y.Z ../homebrew-brews/Formula/bg3mfx.rb`, then
   commit and push the tap. `packaging/homebrew/bg3mfx.rb` is the template.

## Developer notes

- [Architecture and behavior contracts](architecture.md)
- [Current validation status and next checks](validation/README.md)
- [macOS renderer reference](reference/mac-renderer.md)
- [Windows DLSS research](reference/windows-dlss.md)

## Build files and retained evidence

Compiled launchers, libraries, probes, and smoke executables live in
`build/bin/`. Diagnostic launches without `--output` write a fresh trace under
`build/evidence/<date>-diagnostic/`; the temporal quality regression also writes
under a dated `build/evidence/` folder. Existing files elsewhere under `build/`
are treated as retained or historical data. Review them individually before any
manual move; `make clean` removes only `build/bin/`, and the explicit
`make clean-evidence` permanently deletes only `build/evidence/`. Neither command migrates or
removes legacy root captures, profiling folders, or reference tools.

The cleanup helper (`tools/build/cleanup.py`) rejects broad paths, overlapping
binary/evidence paths, and symlinked components. Overrides must end in `bin` and
`evidence`, respectively. `make clean` is the routine rebuild command;
`make clean-evidence` is an explicit deletion of retained evidence and should be
used only after reviewing those files. No evidence is deleted by build or test.
