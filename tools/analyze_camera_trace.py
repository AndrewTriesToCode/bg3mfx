#!/usr/bin/env python3
"""Summarize captured camera constants using Metal's reflected field offsets."""
import argparse
import base64
import json
import math
import struct
from pathlib import Path


def decode_fields(layout, binding):
    data = base64.b64decode(binding.get("base64", ""), validate=True)
    fields = {}
    formats = {3: "f", 4: "2f", 5: "3f", 6: "4f", 15: "16f", 33: "I", 34: "2I"}
    for member in layout.get("members", []):
        fmt = formats.get(member["type"])
        offset = member["offset"]
        if fmt is None or offset < 0 or offset + struct.calcsize("<" + fmt) > len(data):
            continue
        values = struct.unpack_from("<" + fmt, data, offset)
        if not all(math.isfinite(v) for v in values):
            continue
        fields[member["name"]] = values[0] if len(values) == 1 else list(values)
    return fields


def summarize(path):
    layouts = {}
    results = []
    for line in path.read_text().splitlines():
        event = json.loads(line)
        if event["event"] == "shaderReflection":
            layouts[event["fragment"]] = event
        if event["event"] != "shaderConstants":
            continue
        fragment = event["pipeline"]["fragment"]
        layout = layouts.get(fragment)
        if not layout:
            continue
        fields = {}
        for buffer in layout["buffers"]:
            binding = event["bindings"].get(f"fragment:{buffer['index']}")
            if binding:
                fields.update(decode_fields(buffer, binding))
        sample = {"shader": fragment, "sample": event["sample"], "fields": {
            k: fields[k] for k in ("g_Jitter", "g_PreviousJitter", "g_NearPlane", "g_FarPlane",
                                  "g_CurrentTime_prev", "g_ViewportSize") if k in fields}}
        projection = fields.get("g_ProjectionMat")
        if projection and projection[5] > 0:
            sample["verticalFovRadians"] = 2 * math.atan(1 / projection[5])
            near, far = fields.get("g_NearPlane"), fields.get("g_FarPlane")
            # The observed perspective layout is column-major, clip W = view Z.
            if near and far and far > near and abs(projection[11]-1) < 1e-5:
                a, b = projection[10], projection[14]
                zn, zf = a + b/near, a + b/far
                sample["projectedDepthAtNearFar"] = [zn, zf]
                sample["projectionHasReverseDepth"] = abs(zn-1) < 1e-4 and abs(zf) < 1e-4
        results.append(sample)
    return {"samples": results, "shaderTextures": {k: v.get("textures", []) for k,v in layouts.items()},
            "limitation": "Projection convention does not establish the encoding of any bound depth or motion texture."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    args = parser.parse_args()
    print(json.dumps(summarize(args.trace), indent=2, allow_nan=False))
