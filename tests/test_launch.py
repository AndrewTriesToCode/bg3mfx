import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))
import bg3mfx


class LaunchTests(unittest.TestCase):
    def run_launch(self, returncode=0, executable_hash=None):
        executable = Path("/test/BG3.app/Contents/MacOS/BG3")
        runtime = Path(bg3mfx.__file__).resolve().parents[1] / "build/libBG3MetalFX.dylib"
        with patch.dict(os.environ, {
            "BG3MFX_TRACE": "/test/should-not-open.jsonl",
            "BG3MFX_TRACE_CONSTANTS": "1",
            "BG3MFX_SCENE_PROBE": "1",
        }, clear=True), \
                patch.object(bg3mfx, "bundle", return_value=(Path("/test/BG3.app"), {}, executable)), \
                patch.object(bg3mfx, "require_stopped"), \
                patch.object(bg3mfx, "digest", return_value=executable_hash or bg3mfx.SUPPORTED_EXECUTABLE_SHA256), \
                patch.object(Path, "is_file", return_value=True), \
                patch.object(bg3mfx.subprocess, "run", return_value=subprocess.CompletedProcess([], returncode)) as run, \
                contextlib.redirect_stdout(io.StringIO()):
            bg3mfx.launch(Path("/test/BG3.app"))
            self.assertEqual(run.call_args.args[0], [str(executable), "-NoLauncher", "1"])
            env = run.call_args.kwargs["env"]
            self.assertEqual(env["DYLD_INSERT_LIBRARIES"], str(runtime))
            self.assertEqual(env["MTL_HUD_ENABLED"], "1")
            self.assertEqual(env["BG3MFX_ENABLE_METALFX"], "1")
            self.assertFalse({"BG3MFX_TRACE", "BG3MFX_TRACE_CONSTANTS", "BG3MFX_SCENE_PROBE"} & env.keys())
            return run

    def test_quiet_launch_enables_features_hud_and_launcher_bypass(self):
        self.run_launch()

    def test_metal_failure_is_reported_without_a_trace_requirement(self):
        with self.assertRaisesRegex(ValueError, "after displaying an error"):
            self.run_launch(returncode=78)

    def test_launch_refuses_an_unvalidated_executable(self):
        with self.assertRaisesRegex(ValueError, "validated only"):
            self.run_launch(executable_hash="unsupported")


if __name__ == "__main__":
    unittest.main()
