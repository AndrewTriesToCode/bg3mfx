# BG3MFX project instructions

## Product behavior

- Players install with Homebrew (`packaging/homebrew/bg3mfx.rb`, published in
  the `AndrewTriesToCode/homebrew-brews` tap) and start the game with the
  `bg3mfx` launcher (`src/launcher/`), which supports the Steam build only and
  never modifies the game. Keep README.md player-facing; developer material goes
  in `docs/dev/`.

## Repository layout

- `src/features/<feature>/` contains each feature's runtime code, including
  infrastructure features such as metal-hooks; every feature registers with
  root. Keep shared MetalFX/GPU utilities in `src/common/`.
- `src/launcher/` contains the Homebrew-installed player launcher.
- `tests/features/`, `tests/integration/`, `tests/common/`, and
  `tests/launcher/` follow the code boundaries. `tools/analysis/`, `tools/launch/`,
  `tools/probes/`, `tools/reference/`, `tools/release/`, and `tools/build/`
  contain developer tools; they are not installed by Homebrew.
- Feature folders should include a README describing behavior, implementation,
  and measured or estimated improvement. Keep the source map in [architecture](docs/dev/architecture.md) up to date.
- Build outputs go in `build/bin/`; new transient traces, captures, and other
  diagnostic evidence go under `build/evidence/`. Store retained baseline
  evidence for any feature directly under `build/analysis/baseline/`. Put
  feature-specific investigation artifacts that are not baseline evidence in
  sibling folders under `build/analysis/` matching `src/features/` names. Put
  generated current-analysis artifacts under the sibling
  `build/analysis/current/`; every generation there must cover all features,
  not just the feature currently being investigated. Keep downloaded
  references under ignored `build/` paths.

## Development and tests

- Never push commits upstream without first checkign with the user.
- Never edit README.md without first checking with the user.
- Use available skills and capabilities such as gpucapture and gputrace.
- `make` builds the runtime and the `bg3mfx` launcher. `make test` runs
  Metal pixel and renderer-hook regressions on the runtime's test build. `make test-python` checks the player launcher and the development
  launch helper. Keep synthetic, offscreen, and displayed results
  distinct in reports.
- `make clean` removes only `build/bin/`; `make clean-evidence` removes only
  `build/evidence/`. Neither command migrates or removes older data elsewhere
  under `build/`.
- The runtime has no diagnostics: no event logs, traces, counters or diagnostic build. Temporary diagnostics are allowed while developing a feature, but must be removed before the feature is committed. Do not add custom diagnostics for data that can be obtained from other tools like gpu capture, Metal logging, or cpu sampling.
- Probes (opt-in checks, captures, forced failures and overrides) are development-time tools. Keep them temporary or under `build/`; do not add them to the runtime or commit them. The only exceptions are the standalone programs in `tools/probes/`, which are never part of the runtime.
- Failures are not diagnostics: report them through `BG3MFXFail` (`src/common/Notice.h`).
- Do not distribute BG3 executables, extracted game assets, or user
  credentials. Modified shaders are acceptable. Local captures and downloaded references stay in ignored
  `build/`.
- Fix the supported-build guard when changing native menu or renderer offsets.
  Current local target: BG3 4.1.1.7631656, universal ARM64/x86_64 executable,
  SHA-256 `d81e0420d9158e6e58c55af62e8490366768d7376a92868d3bf55d05d561519b`;
  ARM64 runtime UUID `3B6F6492-114E-3EA2-BC64-DFDDBD361434`.
- Read [architecture](docs/dev/architecture.md) when planning implementations.
- Keep feature test lightweight. Any probing or testing needed to determine development issues should be ephemerial or in the build directory.
- Try to build new features taking advantage of other existing features such as custom-render-stages. If a new feature has functionality that might be useful to other existing or future features ask the user if it should be factored out into its own feature.

## Live BG3 tests

- Keep Steam running.
- Skip the launcher and intro if possible.
- Give user instructions on how to interface with app to get the data you need. Do not control the app.
- When starting from your own process the game might get a niceness penalty impacting performance.

## Local installation

- The Steam app is
`/Users/acw/Library/Application Support/Steam/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app`.
- Do not modify its bytes for development; the launch helper leaves the bundle unchanged.
