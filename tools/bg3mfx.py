#!/usr/bin/env python3
"""Inspect and launch the BG3 MetalFX development runtime."""

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import sys

DEFAULT_APP = (
    Path.home()
    / "Library/Application Support/Steam/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app"
)
SUPPORTED_EXECUTABLE_SHA256 = (
    "d81e0420d9158e6e58c55af62e8490366768d7376a92868d3bf55d05d561519b"
)


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as executable:
        for chunk in iter(lambda: executable.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def bundle(path):
    path = path.expanduser().resolve()
    with (path / "Contents/Info.plist").open("rb") as plist_file:
        info = plistlib.load(plist_file)
    if info.get("CFBundleIdentifier") != "com.larian.bg3":
        raise ValueError("This is not a Baldur's Gate 3 app bundle")
    name = info["CFBundleExecutable"]
    if Path(name).name != name:
        raise ValueError("Invalid bundle executable name")
    executable = path / "Contents/MacOS" / name
    if executable.is_symlink() or not executable.is_file():
        raise ValueError("Expected a regular game executable")
    return path, info, executable


def require_stopped(executable):
    listing = subprocess.check_output(["ps", "-ww", "-axo", "pid=,comm="], text=True)
    for line in listing.splitlines():
        fields = line.strip().split(None, 1)
        if len(fields) == 2 and (
            fields[1] == str(executable) or Path(fields[1]).name == executable.name
        ):
            raise ValueError("Quit BG3 before launching a development runtime")


def inspect(app_arg):
    app, info, executable = bundle(app_arg)
    checksum = digest(executable)
    print(
        f"App: {app}\nVersion: {info['CFBundleVersion']}\n"
        f"Executable SHA-256: {checksum}\n"
        f"Supported build: {'yes' if checksum == SUPPORTED_EXECUTABLE_SHA256 else 'no'}"
    )


def launch(app_arg, diagnostic_output=None):
    app, _, executable = bundle(app_arg)
    require_stopped(executable)
    if digest(executable) != SUPPORTED_EXECUTABLE_SHA256:
        raise ValueError("MetalFX menu integration is validated only on BG3 4.1.1.7631656")

    project = Path(__file__).resolve().parent.parent
    runtime_name = "libBG3MetalFXTrace.dylib" if diagnostic_output else "libBG3MetalFX.dylib"
    runtime = project / "build" / runtime_name
    if os.environ.get("BG3MFX_RUNTIME"):
        runtime = Path(os.environ["BG3MFX_RUNTIME"]).expanduser().resolve()
    if not runtime.is_file():
        raise ValueError("Runtime is missing; run make first")

    output = diagnostic_output.expanduser().resolve() if diagnostic_output else None
    env = os.environ.copy()
    if env.get("DYLD_INSERT_LIBRARIES"):
        raise ValueError("An injected library is already configured; use a clean launch environment")
    if output:
        if output.exists():
            raise ValueError("Trace file already exists; choose a new output path")
        output.parent.mkdir(parents=True, exist_ok=True)
        env["BG3MFX_TRACE"] = str(output)
    else:
        for key in ("BG3MFX_TRACE", "BG3MFX_TRACE_CONSTANTS", "BG3MFX_SCENE_PROBE"):
            env.pop(key, None)
    env.update(
        DYLD_INSERT_LIBRARIES=str(runtime),
        SteamAppId="1086940",
        SteamGameId="1086940",
        MTL_HUD_ENABLED="1",
        BG3MFX_ENABLE_METALFX="1",
    )

    if output:
        print("Launching MetalFX with diagnostics and the Metal HUD enabled.", flush=True)
    else:
        print("Launching the quiet MetalFX runtime with the Metal HUD enabled.", flush=True)
    print("Skipping the Larian launcher with -NoLauncher 1; app bundle remains unchanged.", flush=True)
    result = subprocess.run(
        [str(executable), "-NoLauncher", "1"], cwd=executable.parent, env=env
    )

    if output and not output.exists():
        raise ValueError("Diagnostic runtime did not create the trace file")
    if result.returncode == 78:
        detail = f"; trace: {output}" if output else ""
        raise ValueError("MetalFX stopped after displaying an error" + detail)
    if result.returncode:
        raise ValueError(f"Game exited with code {result.returncode}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    check = commands.add_parser("inspect", help="Report the installed game build")
    check.add_argument("--app", type=Path, default=DEFAULT_APP)
    quiet = commands.add_parser("launch", help="Run the quiet development runtime")
    quiet.add_argument("--app", type=Path, default=DEFAULT_APP)
    trace = commands.add_parser("launch-trace", help="Run with diagnostic tracing enabled")
    trace.add_argument("--app", type=Path, default=DEFAULT_APP)
    trace.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    try:
        if args.command == "inspect":
            inspect(args.app)
        elif args.command == "launch":
            launch(args.app)
        else:
            launch(args.app, args.output)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print("bg3mfx: " + str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
