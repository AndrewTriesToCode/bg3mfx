import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools/launch"))
import bg3mfx


class LaunchTests(unittest.TestCase):
    def run_launch(self, returncode=0, executable_hash=None, hud=False):
        executable = Path("/test/BG3.app/Contents/MacOS/BG3")
        runtime = Path(bg3mfx.__file__).resolve().parents[2] / "build/bin/libBG3MetalFX.dylib"
        with patch.dict(os.environ, {
            "BG3MFX_TRACE": "/test/should-not-open.jsonl",
            "BG3MFX_TRACE_CONSTANTS": "1",
            "BG3MFX_SCENE_PROBE": "1",
        }, clear=True), \
                patch.object(bg3mfx, "bundle", return_value=(Path("/test/BG3.app"), {}, executable)), \
                patch.object(bg3mfx, "require_stopped"), \
                patch.object(bg3mfx, "metal_hud_preference", return_value=hud), \
                patch.object(bg3mfx, "digest", return_value=executable_hash or bg3mfx.SUPPORTED_EXECUTABLE_SHA256), \
                patch.object(Path, "is_file", return_value=True), \
                patch.object(bg3mfx, "run_streaming", return_value=subprocess.CompletedProcess([], returncode)) as run, \
                contextlib.redirect_stdout(io.StringIO()):
            bg3mfx.launch(Path("/test/BG3.app"))
            self.assertEqual(run.call_args.args[0], [str(executable), "-NoLauncher", "1"])
            env = run.call_args.kwargs["env"]
            self.assertEqual(env["DYLD_INSERT_LIBRARIES"], str(runtime))
            self.assertEqual(env["MTL_HUD_ENABLED"], "1")
            self.assertEqual(env.get("MTL_HUD_HIDDEN"), None if hud else "1")
            self.assertEqual(env["BG3MFX_ENABLE_METALFX"], "1")
            self.assertFalse({"BG3MFX_TRACE", "BG3MFX_TRACE_CONSTANTS", "BG3MFX_SCENE_PROBE"} & env.keys())
            return run

    def test_stderr_filter_is_narrow_streaming_and_preserves_exit_status(self):
        warning = (
            b"2026-10-15 12:34:56.789 BG3[123:456] "
            b"NSEventModifierFlagFunction specified to -setKeyEquivalentModifierMask: "
            b"for item <NSMenuItem: 0x1234abcd Copy HUD Configuration, action: copyConfig:>, "
            b"but is only supported for system-provided menu items; will not be used\n"
        )
        panel_warning = (
            b"2026-10-15 20:13:51.891 Baldur's Gate 3[8799:102704] "
            b"NSEventModifierFlagFunction specified to -setKeyEquivalentModifierMask: "
            b"for item <NSMenuItem: 0x7bdf162440 Show Configuration Panel, "
            b"ke='Command-F12', action: showConfigurationPanel:>, "
            b"but is only supported for system-provided menu items; will not be used\n"
        )
        enable_hud_warning = (
            b"2026-10-15 20:13:51.891 Baldur's Gate 3[8799:102704] "
            b"NSEventModifierFlagFunction specified to -setKeyEquivalentModifierMask: "
            b"for item <NSMenuItem: 0x796bc99220 Enable HUD, "
            b"ke='Command-F9', action: toggleEnabled:>, "
            b"but is only supported for system-provided menu items; will not be used\n"
        )
        other_menu_warning = (
            b"NSEventModifierFlagFunction specified to -setKeyEquivalentModifierMask: "
            b"for item <NSMenuItem: 0x1234abcd Other Item, ke='Option-X', action: arbitraryAction:>, "
            b"but is only supported for system-provided menu items; will not be used.\n"
        )
        unrelated_warning = b"An unrelated warning that should remain visible.\n"
        punctuated_warning = warning.rstrip(b"\n") + b".\n"

        class StderrCapture:
            def __init__(self):
                self.wrote = threading.Event()
                self.buffer = self
                self.data = bytearray()

            def write(self, value):
                self.data.extend(value)
                if b"early\n" in value:
                    self.wrote.set()
                return len(value)

            def flush(self):
                pass

            def getvalue(self):
                return bytes(self.data)

        captured = StderrCapture()
        result_box = []

        with tempfile.TemporaryDirectory() as temporary:
            gate = Path(temporary) / "continue"
            script = (
                "import os, sys, time; "
                f"os.write(2, {warning!r}); "
                f"os.write(2, {panel_warning!r}); "
                f"os.write(2, {enable_hud_warning!r}); "
                f"os.write(2, {other_menu_warning!r}); "
                f"os.write(2, {punctuated_warning!r}); "
                f"os.write(2, {unrelated_warning!r}); "
                "os.write(2, b'BG3MFX FULL live\\nBG3MFX HALF live\\n'); "
                "os.write(2, b'early\\n'); "
                f"gate = {str(gate)!r}; "
                "exec(\"while not os.path.exists(gate): time.sleep(0.01)\"); "
                "os.write(2, b'late\\xff\\n'); raise SystemExit(7)"
            )

            def run_child():
                with patch.object(bg3mfx.sys, "stderr", captured):
                    result_box.append(bg3mfx.run_streaming([sys.executable, "-c", script]))

            worker = threading.Thread(target=run_child)
            worker.start()
            try:
                self.assertTrue(captured.wrote.wait(2), "stderr should be forwarded before the child continues")
                self.assertTrue(worker.is_alive(), "the child should wait after early stderr arrives")
            finally:
                gate.touch()
                worker.join(3)
            self.assertFalse(worker.is_alive())
        self.assertEqual(result_box[0].returncode, 7)
        forwarded = captured.getvalue()
        self.assertNotIn(warning, forwarded)
        self.assertNotIn(panel_warning, forwarded)
        self.assertNotIn(enable_hud_warning, forwarded)
        self.assertNotIn(other_menu_warning, forwarded)
        self.assertNotIn(b"Copy HUD Configuration", forwarded)
        self.assertIn(unrelated_warning, forwarded)
        self.assertIn(b"BG3MFX FULL live\nBG3MFX HALF live\n", forwarded)
        self.assertIn(b"early\n", forwarded)
        self.assertIn(b"late\xff\n", forwarded)

    def test_default_trace_path_is_dated_diagnostic_evidence(self):
        output = bg3mfx.default_trace_output()
        self.assertEqual(output.parts[-3:-1], ("evidence", output.parent.name))
        self.assertRegex(output.parent.name, r"^\d{4}-\d{2}-\d{2}-diagnostic$")
        self.assertRegex(output.name, r"^trace-\d{6}-\d{6}\.jsonl$")

    def test_quiet_launch_enables_features_hud_and_launcher_bypass(self):
        self.run_launch()

    def test_hud_starts_shown_only_when_the_checkbox_was_left_on(self):
        self.run_launch(hud=True)

    def test_metal_failure_is_reported_without_a_trace_requirement(self):
        with self.assertRaisesRegex(ValueError, "after displaying an error"):
            self.run_launch(returncode=78)

    def test_launch_refuses_an_unvalidated_executable(self):
        with self.assertRaisesRegex(ValueError, "validated only"):
            self.run_launch(executable_hash="unsupported")


if __name__ == "__main__":
    unittest.main()
