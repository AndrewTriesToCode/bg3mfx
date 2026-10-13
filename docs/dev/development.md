# Developing BG3 MetalFX

Requires Apple Silicon, macOS 26 or newer, Xcode command-line tools with the
MetalFX SDK, and Python 3. A licensed Steam installation is required for live
game tests. Project rules for contributors and coding agents are in
[AGENTS.md](../../AGENTS.md).

## Build and test

```sh
make                # quiet runtime + bg3mfx launcher
make test           # Metal pixel and renderer-hook regressions
make test-python    # launcher and development-helper checks
make install PREFIX=/some/prefix   # what the Homebrew formula runs
```

`make test` checks synthetic Spatial/Temporal output, frame generation hooks
and renderer-hook behavior on Metal, for both the quiet runtime and the
diagnostic runtime (`build/libBG3MetalFXTrace.dylib`). Synthetic results do not
establish gameplay image quality or performance.

## Development launches

Keep Steam running, quit BG3, and run:

```sh
python3 tools/bg3mfx.py launch
```

This injects the quiet library from `build/`, skips the Larian launcher with
`-NoLauncher 1`, enables the Metal HUD, and leaves the app bundle unchanged. Run
it from your own Terminal: a process without access to `~/Documents` starts BG3
with a blank profile. To A/B a variant, build it to another path and set
`BG3MFX_RUNTIME=/path/to/libBG3MetalFX.dylib`; read frame rates from
`MTL_HUD_LOG_ENABLED=1` output rather than during `sample`, which itself costs
about a third of the frame rate. For a diagnostic session, use a new trace path:

```sh
python3 tools/bg3mfx.py launch-trace --output /absolute/path/to/new-trace.jsonl
```

Add `MTL_HUD_LOG_ENABLED=1` to record the Metal HUD's per-second frame counts in
the unified log (`/usr/bin/log show --predicate 'category == "Logging"'`). Do
not combine `MTL_CAPTURE_ENABLED=1` with frame-rate comparisons: the capture
layer slows the whole session. Never rebuild a library while BG3 is using it.

The player launcher (`build/bg3mfx`, source in `src/launcher/`) can be checked
without starting the game: `BG3MFX_RUNTIME=$PWD/build/libBG3MetalFX.dylib
build/bg3mfx --dry-run`.

## Releasing

1. Update `SupportedSHA256`/`SupportedVersion` in `src/launcher/main.m` and the
   runtime's build guard together when a new BG3 build is supported.
2. Tag `vX.Y.Z` and push it.
3. `tools/update-formula.sh X.Y.Z ../homebrew-brews/Formula/bg3mfx.rb`, then
   commit and push the tap. `packaging/homebrew/bg3mfx.rb` is the template.

## Developer notes

- [Architecture and behavior contracts](architecture.md)
- [Current validation status and next checks](validation/README.md)
- [Temporal image-quality plan](temporal-quality-plan.md)
- [macOS renderer reference](reference/mac-renderer.md)
- [Windows DLSS research](reference/windows-dlss.md)
