# BG3MFX project instructions

## Product behavior

- Players install with Homebrew (`packaging/homebrew/bg3mfx.rb`, published in
  the `AndrewTriesToCode/homebrew-brews` tap) and start the game with the
  `bg3mfx` launcher (`src/launcher/`), which supports the Steam build only and
  never modifies the game. Keep README.md player-facing; developer material goes
  in `docs/dev/`.

## Repository layout

- `src/features/<feature>/` contains feature-specific runtime code. Keep shared
  MetalFX/GPU utilities in `src/common/` and renderer, menu, and presentation
  integration in `src/integration/`.
- `src/launcher/` contains the Homebrew-installed player launcher.
- `tests/features/`, `tests/integration/`, `tests/common/`, and
  `tests/launcher/` follow the code boundaries. `tools/analysis/`, `tools/launch/`,
  `tools/probes/`, `tools/reference/`, `tools/release/`, and `tools/build/`
  contain developer tools; they are not installed by Homebrew.
- Feature folders should include a README describing behavior, implementation,
  and measured or estimated improvement. Keep the source map in
  [architecture](docs/dev/architecture.md) and active findings in
  [validation](docs/dev/validation/README.md) current when implementations move.
- Build outputs go in `build/bin/`; new traces, captures, and other diagnostic
  evidence go under `build/evidence/`. Keep profiling data and downloaded
  references under ignored `build/` paths. Do not distribute game executables,
  extracted assets, captures, or credentials.

## Development and tests

- Never edit README.md without first checking with the user.
- Use available skills and capabilities such as gpucapture and gputrace.
- `make` builds the quiet runtime and the `bg3mfx` launcher. `make test` runs
  Metal pixel and renderer-hook regressions on both quiet and diagnostic
  libraries. `make test-python` checks the player launcher and the development
  launch helper. Keep synthetic, offscreen, and displayed results
  distinct in reports.
- `make clean` removes only `build/bin/`; `make clean-evidence` removes only
  `build/evidence/`. Neither command migrates or removes older data elsewhere
  under `build/`.
- The diagnostic runtime may record traces, shader reflection, and captures.
  The quiet runtime compiles those diagnostics out but still has integration
  hooks; do not claim zero overhead.
- Do not distribute BG3 executables, extracted game shaders/assets, or user
  credentials. Local captures and downloaded references stay in ignored
  `build/`.
- Fix the supported-build guard when changing native menu or renderer offsets.
  Current local target: BG3 4.1.1.7631656, universal ARM64/x86_64 executable,
  SHA-256 `d81e0420d9158e6e58c55af62e8490366768d7376a92868d3bf55d05d561519b`;
  ARM64 runtime UUID `3B6F6492-114E-3EA2-BC64-DFDDBD361434`.
- Read [architecture](docs/dev/architecture.md) and
  [current validation](docs/dev/validation/README.md) before changing the
  renderer. Historical experiments are under
  `docs/dev/validation/history/` and may have been superseded.

## Live BG3 tests

- Keep Steam running.
- Skip the launcher and intro if possible.
- Give user instructions on how to interface with app to get the data you need. Do not control the app.

## Local installation

The Steam app is
`/Users/acw/Library/Application Support/Steam/steamapps/common/Baldur's Gate 3/Baldur's Gate 3.app`.
Do not modify its bytes for this development phase; the launch helper leaves the
bundle unchanged. The previous authorization for app-bundle patching is retained
for a future patcher phase, but this cleanup removes that implementation from
the active codebase.
