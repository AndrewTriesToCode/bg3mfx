# Baseline capture procedure

Use this procedure to collect scene-matched GPU traces, CPU samples, Metal HUD
logs, and CPU/GPU power estimates for unmodded BG3 from Steam. Keep all files
directly in `build/analysis/baseline/`, using `scene-1-*`, `scene-2-*`, and so
on. The scene labels refer to the user's chosen scenes; record their names if
known.

## Shared setup

- Keep Steam running and launch the Steam-installed BG3 app without the bg3mfx
  runtime or other mods. The app bundle is
  `/Users/acw/Library/Application Support/Steam/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app`.
- If BG3 is already running without the environment variables for the intended
  capture, have the user quit it normally before launching again. `open --env`
  cannot add variables to an existing process.
- Use **Ultra**, **Windowed**, **1280×800**, **VSync Off**, and **Frame Rate Cap
  Off**. These are the CPU/HUD/power baseline settings. The settings used for
  the already captured GPU traces were not recorded.
- BG3 slows down in the background. The user operates the app and chooses each
  scene; do not navigate or change its controls. Keep the target scene
  foregrounded during sampling and return to it promptly after arming a capture
  from Terminal.
- Never write a new capture to an existing scene filename without checking its
  contents and confirming that overwriting is intended. A mistaken power-log
  output path previously replaced scene 1 data with a scene 2 capture.

## GPU trace: separate capture launch

`gpucapture` requires `MTL_CAPTURE_ENABLED=1` at app launch. That capture layer
adds substantial overhead, so collect GPU traces separately from CPU/HUD/power
metrics. Do not use trace-session frame rate as a performance baseline.

With Steam running, launch the unmodded app from Terminal:

```sh
open --env MTL_CAPTURE_ENABLED=1 \
  --env SteamAppId=1086940 \
  --env SteamGameId=1086940 \
  -a "/Users/acw/Library/Application Support/Steam/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app" \
  --args -NoLauncher 1
```

After the user has placed BG3 in the target scene, identify the game PID and
list its capture boundaries:

```sh
gpucapture list
game_pid=12345
gpucapture boundaries --pid "$game_pid"
```

Choose the BG3 main window's **Layer** boundary, then capture one frame. Replace
the boundary ID, scene number, and output path as needed:

```sh
game_pid=12345
layer_boundary_id=1
scene_number=1
gpucapture start --pid "$game_pid" --boundary "$layer_boundary_id" --count 1 \
  --output "$PWD/build/analysis/baseline/scene-${scene_number}.gputrace"
```

Confirm the `.gputrace` bundle exists and record its size. The required launch
environment cannot be added to an already running process; relaunch without
mods if it was started without `MTL_CAPTURE_ENABLED=1`. Do not enable that
variable during CPU/HUD/power sampling.

## CPU sample and matching Metal HUD log

For this separate launch, enable the Metal HUD and its logging, but do not set
`MTL_CAPTURE_ENABLED=1`. With Steam running:

```sh
env -u MTL_CAPTURE_ENABLED open --env MTL_HUD_ENABLED=1 \
  --env MTL_HUD_LOG_ENABLED=1 \
  --env SteamAppId=1086940 \
  --env SteamGameId=1086940 \
  -a "/Users/acw/Library/Application Support/Steam/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app" \
  --args -NoLauncher 1
```

Leave scene navigation to the user. Once the user signals `ready <scene>`,
wait **10 seconds**, then capture a 10-second CPU sample and the matching HUD
log. Record UTC times for the notes; use local wall-clock timestamps for the
`log show --start/--end` query. The HUD emits entries under category `Logging`
from process `Baldur's Gate 3`.

The normal workspace sandbox blocks process enumeration and unified-log access
(`pgrep` may report `sysmond service not found`; `log show` may say it cannot run
while sandboxed). Run process lookup, `sample`, and `log show` with approved
elevated execution. A 44-byte HUD file containing only the column header is an
empty query, not a successful capture. Use local timestamps for the query
window; a UTC timestamp passed without a timezone offset can return no entries.

Example shell steps after the 10-second wait; replace the scene number and PID:

```sh
scene_number=2
game_pid=12345
evidence_dir="$PWD/build/analysis/baseline"
capture_start_local=$(/bin/date '+%Y-%m-%d %H:%M:%S')
capture_start_utc=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
/usr/bin/sample "$game_pid" 10 \
  -file "$evidence_dir/scene-${scene_number}-cpu.sample.txt"
capture_end_local=$(/bin/date '+%Y-%m-%d %H:%M:%S')
capture_end_utc=$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')
/usr/bin/log show --start "$capture_start_local" --end "$capture_end_local" \
  --style compact \
  --predicate "processID == ${game_pid} AND category == \"Logging\"" \
  > "$evidence_dir/scene-${scene_number}-metal-hud.log"
printf 'CPU/HUD UTC interval: %s to %s\n' \
  "$capture_start_utc" "$capture_end_utc"
```

Verify the HUD log contains `metal-HUD:` entries and preserve the raw files.
The CPU sampler slows the game; HUD FPS during this sample reflects profiler
overhead, not baseline frame rate. Do not recapture the GPU trace in this run.

## CPU and GPU power estimates

`powermetrics` needs sudo authorization in an interactive Terminal. An
interactive `sudo -v` in the user's Terminal does not authorize a separate
sandboxed agent command. The user should launch the delayed logger from that
same Terminal after `sudo -v` succeeds, then return to BG3 promptly. The command
waits 10 seconds before sampling so the user can restore BG3 to the foreground.

Replace the scene number in **both** output paths. The guard prevents silently
overwriting an existing scene log:

```sh
cd /Users/acw/Dev/bg3mfx
sudo -v
scene_number=2
power_log="$PWD/build/analysis/baseline/scene-${scene_number}-power.log"
if test -e "$power_log"; then
  echo "Refusing to overwrite $power_log"
else
  ( /bin/sleep 10; /usr/bin/sudo -n /usr/bin/powermetrics \
      --samplers cpu_power,gpu_power --sample-rate 1000 --sample-count 12 \
      --output-file "$power_log" ) \
    > "/tmp/scene-${scene_number}-power-command.log" 2>&1 &
fi
```

The logger produces 12 samples at approximately 1-second intervals. Check the
first and last sample timestamps and confirm there are 12 `Sampled system
activity` headers plus CPU and GPU power fields before labeling it for a scene.
Record the measured interval in that scene's notes. Power values are system
estimates, not precision meter readings. If the file is missing, inspect
`/tmp/scene-<n>-power-command.log` for sudo or command errors.

## Files and notes

Keep traces, CPU samples, raw HUD logs, power logs, and capture notes directly
in `build/analysis/baseline/`. For each scene record its label, PID, capture
intervals, unmodded Steam build, graphics preset, display mode, resolution,
VSync, frame cap, and relevant in-game/foreground state. Keep CPU/HUD and power
intervals separate in the notes if they were not simultaneous. The ignored
local `build/analysis/baseline/capture-procedure.md` can link back to this
tracked procedure; retained traces and profiling data stay local under
`build/`.
