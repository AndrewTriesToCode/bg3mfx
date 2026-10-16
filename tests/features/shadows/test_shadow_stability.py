import base64
import importlib.util
import json
from pathlib import Path
import struct
import unittest

spec = importlib.util.spec_from_file_location(
    "shadow_stability", Path(__file__).resolve().parents[3] / "tools/analysis/shadow_stability.py")
shadow = importlib.util.module_from_spec(spec)
spec.loader.exec_module(shadow)


class ShadowStabilityTests(unittest.TestCase):
    def event(self, frame, near=1, slice=0, readable=True):
        data = base64.b64encode(struct.pack("<ff", near, 100)).decode() if readable else ""
        return json.dumps({"event": "shadowProbeSample", "frame": frame, "pass": frame,
                           "elapsed": frame / 60, "depth": {"id": "depth1"}, "slice": slice, "load": 2,
                           "samples": [{"stage": "vertex", "index": 11, "base64": data,
                                        "members": [{"name": "camera", "offset": 0, "members": [
                                            {"name": "g_NearPlane", "offset": 0},
                                            {"name": "g_FarPlane", "offset": 4}]}]}]})

    def test_repeats_changes_and_nested_offsets(self):
        summary, decoded = shadow.analyze([self.event(1), self.event(2), self.event(3, 2)])
        self.assertEqual((summary[0]["pairs"], summary[0]["identical"]), (2, 1))
        self.assertEqual(summary[0]["field_changes"]["camera.g_NearPlane"], 1)
        self.assertEqual(decoded[-1]["fields"]["camera.g_FarPlane"], [100])

    def test_gaps_unavailable_and_slices_are_isolated(self):
        summary, _ = shadow.analyze([self.event(1), self.event(3), self.event(4, readable=False),
                                    self.event(5), self.event(6, slice=1)])
        self.assertEqual(sum(group["pairs"] for group in summary), 0)
        self.assertEqual(sum(group["unavailable"] for group in summary), 1)

    def test_invalid_and_truncated_values_are_not_measurements(self):
        members = [{"name": "g_NearPlane", "offset": 0}]
        self.assertEqual(shadow.decode_fields(b"", members), {})
        self.assertEqual(shadow.decode_fields(struct.pack("<f", float("nan")), members), {})
