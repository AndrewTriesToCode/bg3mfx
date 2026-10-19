#!/usr/bin/env python3
"""Inspect and launch the BG3MFX development runtime."""

import argparse
import hashlib
from datetime import datetime
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys

DEFAULT_APP = (
    Path.home()
    / "Library/Application Support/Steam/steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app"
)
# The development helper runs from this source tree. Installed player builds
# compile these same definitions directly into the launcher.
_BUILD_HEADER = (Path(__file__).resolve().parents[2] / "src/common/native/SupportedBuild.h").read_text()


def supported_build_value(name):
    match = re.search(r'^#define ' + re.escape(name) + r' "([^"\n]+)"$', _BUILD_HEADER, re.MULTILINE)
    if not match:
        raise ValueError(f"Missing supported-build definition: {name}")
    return match.group(1)


SUPPORTED_EXECUTABLE_SHA256 = supported_build_value("BG3MFX_SUPPORTED_SHA256")
SUPPORTED_VERSION = supported_build_value("BG3MFX_SUPPORTED_VERSION")
HUD_MENU_WARNING = re.compile(
    rb"NSEventModifierFlagFunction specified to -setKeyEquivalentModifierMask: "
    rb"for item <NSMenuItem: 0x[0-9a-fA-F]+ .+>, "
    rb"but is only supported for system-provided menu items; will not be used\.?$"
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


def metal_hud_preference():
    """The in-game Show Metal HUD checkbox, saved in BG3's preferences."""
    result = subprocess.run(
        ["defaults", "read", "com.larian.bg3", "BG3MFXMetalHUD"],
        capture_output=True, text=True,
    )
    return result.returncode == 0 and result.stdout.strip() == "1"


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


def run_streaming(command, **kwargs):
    """Run a process while forwarding stderr, suppressing only the HUD menu warning."""
    process = subprocess.Popen(command, stderr=subprocess.PIPE, **kwargs)
    try:
        for line in iter(process.stderr.readline, b""):
            if HUD_MENU_WARNING.search(line.rstrip(b"\r\n")):
                continue
            sys.stderr.buffer.write(line)
            sys.stderr.buffer.flush()
    finally:
        process.stderr.close()
    return subprocess.CompletedProcess(command, process.wait())



def default_trace_output():
    """Return a fresh trace path in today's retained diagnostic evidence folder."""
    project = Path(__file__).resolve().parents[2]
    now = datetime.now()
    stamp = now.strftime("%H%M%S-%f")
    folder = now.strftime("%Y-%m-%d") + "-diagnostic"
    return project / "build" / "evidence" / folder / f"trace-{stamp}.jsonl"


def launch(app_arg, diagnostic_output=None):
    app, _, executable = bundle(app_arg)
    require_stopped(executable)
    if digest(executable) != SUPPORTED_EXECUTABLE_SHA256:
        raise ValueError(f"MetalFX menu integration is validated only on BG3 {SUPPORTED_VERSION}")

    project = Path(__file__).resolve().parents[2]
    runtime_name = "libBG3MetalFXTrace.dylib" if diagnostic_output else "libBG3MetalFX.dylib"
    runtime = project / "build" / "bin" / runtime_name
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
    # As the player launcher does: Metal loads its HUD only when MTL_HUD_ENABLED
    # is set at launch, so the in-game checkbox can toggle it. Start hidden
    # unless the checkbox was left on.
    hud = metal_hud_preference()
    if hud:
        env.pop("MTL_HUD_HIDDEN", None)
    else:
        env["MTL_HUD_HIDDEN"] = "1"

    shown = "shown" if hud else "hidden until enabled in Options"
    if output:
        print(f"Launching MetalFX with diagnostics; Metal HUD {shown}.", flush=True)
    else:
        print(f"Launching the quiet MetalFX runtime; Metal HUD {shown}.", flush=True)
    print("Skipping the Larian launcher with -NoLauncher 1; app bundle remains unchanged.", flush=True)
    result = run_streaming(
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
    trace.add_argument("--output", type=Path, help="Trace file path (defaults to build/evidence/<date>-diagnostic/)")
    args = parser.parse_args()

    try:
        if args.command == "inspect":
            inspect(args.app)
        elif args.command == "launch":
            launch(args.app)
        else:
            output = args.output or default_trace_output()
            launch(args.app, output)
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print("bg3mfx: " + str(error), file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError) and error.stderr:
            print(error.stderr, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
