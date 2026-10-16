#!/usr/bin/env python3
"""Decode reflected shadow-camera fields; summarize exact repeats per pass stream.

This deliberately does not infer matrix packing or claim texel snapping from
translation components alone. Decoded matrices support that next investigation.
"""
import argparse
import base64
from collections import defaultdict
import json
import math
from pathlib import Path
import struct

FIELDS = {"g_ViewMat": 16, "g_ProjectionMat": 16,
          "g_OffsetViewProjectionMat": 16, "g_NearPlane": 1, "g_FarPlane": 1}


def decode_fields(data, members, base=0, prefix=""):
    result = {}
    for member in members:
        offset = base + member["offset"]
        name = member["name"]
        path = prefix + name
        if name in FIELDS:
            count = FIELDS[name]
            if offset + count * 4 <= len(data):
                values = struct.unpack_from("<" + "f" * count, data, offset)
                if all(math.isfinite(value) for value in values):
                    result[path] = list(values)
        result.update(decode_fields(data, member.get("members", []), offset, path + "."))
    return result


def analyze(lines):
    groups = defaultdict(lambda: {"samples": 0, "unavailable": 0, "pairs": 0,
                                  "identical": 0, "field_changes": defaultdict(int)})
    previous = {}
    decoded = []
    for line in lines:
        if not line.strip():
            continue
        event = json.loads(line)
        if event.get("event") != "shadowProbeSample":
            continue
        pipeline = event.get("pipeline", {})
        stream = (event["depth"]["id"], event["slice"], event["load"],
                  event.get("level", 0), pipeline.get("vertex", ""), pipeline.get("fragment", ""))
        samples = event.get("samples", [])
        if not samples:
            groups[stream + ("missing-reflection",)]["unavailable"] += 1
        for sample in samples:
            key = stream + (sample["stage"], sample["index"])
            group = groups[key]
            data = base64.b64decode(sample.get("base64", ""), validate=True)
            fields = decode_fields(data, sample.get("members", []))
            if not fields:
                group["unavailable"] += 1
                previous.pop(key, None)
                continue
            group["samples"] += 1
            # Compare only adjacent captured frames. Never bridge unreadable
            # samples, scene changes or frame gaps as evidence of stability.
            old = previous.get(key)
            if old and event["frame"] == old[0] + 1:
                group["pairs"] += 1
                group["identical"] += fields == old[1]
                for field in fields.keys() | old[1].keys():
                    group["field_changes"][field] += fields.get(field) != old[1].get(field)
            previous[key] = (event["frame"], fields)
            decoded.append({"stream": key, "frame": event["frame"], "pass": event["pass"],
                            "elapsed": event["elapsed"], "viewport": event.get("viewport"), "fields": fields})
    return [{"stream": key, **value} for key, value in groups.items()], decoded


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--decoded", type=Path, help="Write decoded frame-by-frame matrices to ignored build/")
    args = parser.parse_args()
    with args.trace.open() as trace:
        summary, decoded = analyze(trace)
    print(json.dumps(summary, indent=2))
    if args.decoded:
        args.decoded.write_text(json.dumps(decoded, indent=2) + "\n")
    if not decoded:
        raise SystemExit("No readable reflected camera fields; inspect shadowProbeReflection and shadowProbeSample events.")
    print("Exact repeats are observations, not proof of texel snapping or safe history reuse.")


if __name__ == "__main__":
    main()
