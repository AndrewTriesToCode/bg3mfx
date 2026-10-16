"""Verify build cleanup keeps retained captures and historical files intact."""

from pathlib import Path
import subprocess
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]


class BuildLayoutTests(unittest.TestCase):
    def run_cleanup(self, target, bin_dir, evidence_dir):
        return subprocess.run(
            ["make", "-C", str(PROJECT), target, f"BIN_DIR={bin_dir}",
             f"EVIDENCE_DIR={evidence_dir}"],
            capture_output=True, text=True,
        )

    def test_clean_targets_are_scoped_to_bins_or_evidence(self):
        with tempfile.TemporaryDirectory() as temporary:
            build = Path(temporary).resolve() / "build"
            binary = build / "bin" / "bg3mfx"
            evidence = build / "evidence" / "2026-10-15-diagnostic" / "trace.jsonl"
            legacy = build / "old-capture.jsonl"
            reference = build / "reference-tool"
            for path in (binary, evidence, legacy, reference):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("sentinel")

            result = self.run_cleanup("clean", build / "bin", build / "evidence")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertFalse(binary.exists())
            self.assertTrue(evidence.is_file())
            self.assertTrue(legacy.is_file())
            self.assertTrue(reference.is_file())

            binary.parent.mkdir(parents=True)
            binary.write_text("fresh binary")
            result = self.run_cleanup("clean-evidence", build / "bin", build / "evidence")
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertTrue(binary.is_file())
            self.assertFalse(evidence.exists())
            self.assertTrue(legacy.is_file())
            self.assertTrue(reference.is_file())

    def test_broad_cleanup_paths_are_rejected_without_deleting_sentinels(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            build = root / "build"
            binary = build / "bin" / "keep"
            evidence = build / "evidence" / "keep"
            for path in (binary, evidence):
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("sentinel")

            result = self.run_cleanup("clean", build, build / "evidence")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must end in 'bin'", result.stderr)
            result = self.run_cleanup("clean-evidence", build / "bin", build)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("must end in 'evidence'", result.stderr)
            self.assertTrue(binary.is_file())
            self.assertTrue(evidence.is_file())

    def test_overlapping_cleanup_paths_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            binary = root / "build" / "bin"
            evidence = binary / "evidence"
            sentinel = evidence / "keep"
            sentinel.parent.mkdir(parents=True)
            sentinel.write_text("sentinel")

            result = self.run_cleanup("clean", binary, evidence)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("overlap", result.stderr)
            self.assertTrue(sentinel.is_file())

    def test_symlink_components_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            outside = root / "outside"
            target = outside / "bin"
            target.mkdir(parents=True)
            sentinel = target / "keep"
            sentinel.write_text("sentinel")
            linked_parent = root / "linked"
            linked_parent.symlink_to(outside, target_is_directory=True)
            evidence = root / "build" / "evidence"
            evidence.mkdir(parents=True)

            result = self.run_cleanup("clean", linked_parent / "bin", evidence)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("contains a symlink", result.stderr)
            self.assertTrue(sentinel.is_file())

            linked_bin = root / "alias" / "bin"
            linked_bin.parent.mkdir()
            linked_bin.symlink_to(target, target_is_directory=True)
            result = self.run_cleanup("clean", linked_bin, evidence)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("contains a symlink", result.stderr)
            self.assertTrue(sentinel.is_file())


if __name__ == "__main__":
    unittest.main()
