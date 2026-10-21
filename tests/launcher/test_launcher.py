"""Checks the installed bg3mfx launcher with fake game bundles (never starts a game)."""

import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest

LAUNCHER = Path(__file__).resolve().parents[2] / "build/bin/bg3mfx"


def fake_game(root, bundle_id="com.larian.bg3", payload=b"not the real game", app_store=False, gog=False):
    app = Path(root) / "steamapps/common/Baldurs Gate 3/Baldur's Gate 3.app"
    if gog:
        app = Path(root) / "Baldur's Gate 3.app"
        (Path(root) / "goggame-1456460669.info").write_text("{}")
    (app / "Contents/MacOS").mkdir(parents=True)
    with (app / "Contents/Info.plist").open("wb") as info:
        plistlib.dump({"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "Baldur's Gate 3",
                       "CFBundleVersion": "9.9.9"}, info)
    (app / "Contents/MacOS/Baldur's Gate 3").write_bytes(payload)
    if app_store:
        (app / "Contents/_MASReceipt").mkdir()
        (app / "Contents/_MASReceipt/receipt").write_bytes(b"receipt")
    return app


class LauncherTests(unittest.TestCase):
    def run_launcher(self, *args, env=None):
        environment = {key: value for key, value in os.environ.items()
                       if not key.startswith("BG3MFX_") and key != "__CFBundleIdentifier"}
        environment.update(env or {})
        return subprocess.run([str(LAUNCHER), *args], capture_output=True, text=True, env=environment)

    def test_version_and_help(self):
        self.assertRegex(self.run_launcher("--version").stdout, r"^bg3mfx \S+")
        self.assertIn("install-app", self.run_launcher("--help").stdout)

    def test_unsupported_build_is_refused_with_its_version(self):
        with tempfile.TemporaryDirectory() as root:
            result = self.run_launcher("--dry-run", "--game", str(fake_game(root)))
            self.assertEqual(result.returncode, 1)
            self.assertIn("isn't supported yet", result.stderr)
            self.assertIn("9.9.9", result.stderr)

    def test_supported_build_prepares_injection_without_starting(self):
        with tempfile.TemporaryDirectory() as root:
            payload = b"pretend supported build"
            game = fake_game(root, payload=payload)
            runtime = Path(root) / "libBG3MetalFX.dylib"
            runtime.write_bytes(b"runtime")
            result = self.run_launcher("--dry-run", "--game", str(game), env={
                "BG3MFX_TEST_SUPPORTED_SHA256": hashlib.sha256(payload).hexdigest(),
                "BG3MFX_RUNTIME": str(runtime)})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn(f"DYLD_INSERT_LIBRARIES={runtime}", result.stdout)
            self.assertIn("BG3MFX_ENABLE_METALFX=1", result.stdout)
            self.assertIn("SteamAppId=1086940", result.stdout)
            # The HUD is always loaded so the in-game checkbox can toggle it.
            self.assertIn("MTL_HUD_ENABLED=1", result.stdout)
            self.assertIn("Arguments: -NoLauncher 1", result.stdout)
            self.assertIn("was not started", result.stdout)
            # Held-back features are off unless the player opts in.
            self.assertIn("BG3MFX_CHARACTER_CREATION_CRASH_FIX=0", result.stdout)
            self.assertIn("BG3MFX_REDUCE_LOCKING=0", result.stdout)

    def test_held_back_features_can_be_opted_in(self):
        with tempfile.TemporaryDirectory() as root:
            payload = b"pretend supported build"
            game = fake_game(root, payload=payload)
            runtime = Path(root) / "libBG3MetalFX.dylib"
            runtime.write_bytes(b"runtime")
            result = self.run_launcher("--dry-run", "--game", str(game), env={
                "BG3MFX_TEST_SUPPORTED_SHA256": hashlib.sha256(payload).hexdigest(),
                "BG3MFX_RUNTIME": str(runtime),
                "BG3MFX_REDUCE_LOCKING": "1"})
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("BG3MFX_REDUCE_LOCKING=1", result.stdout)
            self.assertIn("BG3MFX_CHARACTER_CREATION_CRASH_FIX=0", result.stdout)

    def test_test_hash_override_only_applies_to_dry_runs(self):
        with tempfile.TemporaryDirectory() as root:
            payload = b"pretend supported build"
            env = {"BG3MFX_TEST_SUPPORTED_SHA256": hashlib.sha256(payload).hexdigest()}
            result = self.run_launcher("--game", str(fake_game(root, payload=payload)), env=env)
            self.assertEqual(result.returncode, 1)
            self.assertIn("isn't supported yet", result.stderr)

    def test_other_stores_and_other_apps_are_refused(self):
        with tempfile.TemporaryDirectory() as root:
            result = self.run_launcher("--dry-run", "--game", str(fake_game(root, app_store=True)))
            self.assertIn("Mac App Store", result.stderr)
        with tempfile.TemporaryDirectory() as root:
            result = self.run_launcher("--dry-run", "--game", str(fake_game(root, gog=True)))
            self.assertIn("GOG", result.stderr)
        with tempfile.TemporaryDirectory() as root:
            result = self.run_launcher("--dry-run", "--game", str(fake_game(root, bundle_id="com.example.other")))
            self.assertIn("isn't Baldur's Gate 3", result.stderr)

    def test_install_app_links_the_installed_command(self):
        with tempfile.TemporaryDirectory() as folder:
            result = self.run_launcher("install-app", "--to", folder)
            self.assertEqual(result.returncode, 0, result.stderr)
            app = Path(folder) / "BG3MFX.app"
            with (app / "Contents/Info.plist").open("rb") as info:
                plist = plistlib.load(info)
            self.assertEqual(plist["CFBundleExecutable"], "bg3mfx")
            self.assertTrue(plist["LSUIElement"])
            executable = app / "Contents/MacOS/bg3mfx"
            self.assertTrue(executable.is_symlink())
            self.assertEqual(Path(os.readlink(executable)), LAUNCHER.resolve())

    def test_homebrew_layout_finds_runtime_and_links_the_opt_path(self):
        project = LAUNCHER.parents[2]
        with tempfile.TemporaryDirectory() as root:
            prefix = Path(root).resolve() / "Cellar/bg3mfx/0.1.0"
            subprocess.run(["make", "-C", str(project), "install", f"PREFIX={prefix}"],
                           check=True, capture_output=True)
            installed = prefix / "bin/bg3mfx"
            self.assertTrue((prefix / "lib/bg3mfx/libBG3MetalFX.dylib").is_file())
            game = fake_game(root, payload=b"pretend supported build")
            result = subprocess.run([str(installed), "--dry-run", "--game", str(game)], capture_output=True, text=True,
                                    env={**os.environ, "BG3MFX_TEST_SUPPORTED_SHA256":
                                         hashlib.sha256(b"pretend supported build").hexdigest()})
            self.assertIn(f"Runtime: {prefix}/lib/bg3mfx/libBG3MetalFX.dylib", result.stdout)
            subprocess.run([str(installed), "install-app", "--to", root], check=True, capture_output=True)
            link = os.readlink(Path(root) / "BG3MFX.app/Contents/MacOS/bg3mfx")
            self.assertEqual(Path(link), Path(root).resolve() / "opt/bg3mfx/bin/bg3mfx")

if __name__ == "__main__":
    unittest.main()
