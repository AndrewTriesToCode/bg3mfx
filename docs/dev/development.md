# Developing BG3MFX

Requires Apple Silicon, macOS 26 or newer, Xcode command-line tools with the
MetalFX SDK, and Python 3. A licensed Steam installation is required for live
game tests. Project rules for contributors and coding agents are in
[AGENTS.md](../../AGENTS.md).

## Build and test

```sh
make                # runtime + bg3mfx launcher in build/bin/
make test           # Metal pixel and renderer-hook regressions
make test-python    # launcher and development-helper checks
make install PREFIX=/some/prefix   # what the Homebrew formula runs
```

`make test` checks synthetic Spatial/Temporal output, frame generation hooks
and renderer-hook behavior on Metal, using the runtime's test build
(`build/bin/libBG3MetalFXTest.dylib`, the same runtime plus exports for the
standalone tests). Synthetic results do not establish gameplay image quality or
performance.

## Development launches

Keep Steam running, quit BG3, and run:

```sh
python3 tools/launch/bg3mfx.py launch
```

This injects the runtime library from `build/bin/`, skips the Larian launcher with
`-NoLauncher 1`, enables the Metal HUD, and leaves the app bundle unchanged.
It enables no features unless you name them, so a live test exercises one at a
time: `--feature thread-idling`, repeatable, with any of `metal-hud`,
`metalfx`, `duplicate-shadow-fix`, `improved-shadows`,
`render-thread-optimizations`, `new-character-crash-fix`, `lua-jump-fix`,
`thread-idling`, `reduce-locking`, `ssao-blur-fix` and `animation-optimizations`. A feature brings the features it
requires (custom-menu for the menu options, custom-render-stages for the shadow
features). Shell `BG3MFX_FEATURE_*` variables are ignored. Run
it from your own Terminal: a process without access to `~/Documents` starts BG3
with a blank profile. To A/B a variant, build it to another path and set
`BG3MFX_RUNTIME=/path/to/libBG3MetalFX.dylib`; read frame rates from
`MTL_HUD_LOG_ENABLED=1` output rather than during `sample`, which itself costs
about a third of the frame rate.

## Diagnostics and failures

The runtime has no diagnostics. While developing a feature, add whatever
temporary logging, counters or probes it needs, and remove them before
committing it. First check whether a GPU capture, Metal logging, the Metal HUD or
CPU sampling already has the data.

Failures go through `BG3MFXFail` in `src/common/Notice.h`: the system log
(`com.bg3mfx`, category `failure`) and, with a title, the player's dialog; in the
test build with `BG3MFX_TEST_ERRORS_STDERR=1`, stderr and no dialog. An enabled feature that is
skipped reports why the same way. To read them:

```sh
/usr/bin/log show --last 1h --predicate 'subsystem == "com.bg3mfx"'
```

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

With Frame Generation on, the Metal HUD's "rendered" figure is unreliable (a
trace showed about 19 rendered fps while the HUD showed about 10), so count
BG3's presents with a temporary diagnostic when that number matters.

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
- [BG3's default renderer](baseline/README.md)

## Build files and retained evidence

Compiled launchers, libraries, probes, and smoke executables live in
`build/bin/`. The temporal quality regression writes under a dated `build/evidence/` folder. Existing files elsewhere under `build/`
are treated as retained or historical data. Review them individually before any
manual move; `make clean` removes only `build/bin/`, and the explicit
`make clean-evidence` permanently deletes only `build/evidence/`. Neither command migrates or
removes legacy root captures, profiling folders, or reference tools.

The cleanup helper (`tools/build/cleanup.py`) rejects broad paths, overlapping
binary/evidence paths, and symlinked components. Overrides must end in `bin` and
`evidence`, respectively. `make clean` is the routine rebuild command;
`make clean-evidence` is an explicit deletion of retained evidence and should be
used only after reviewing those files. No evidence is deleted by build or test.
