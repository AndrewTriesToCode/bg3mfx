#!/usr/bin/env python3
"""Summarize `shadowPassStack` events from a diagnostic trace
(BG3MFX_TRACE_SHADOW_STACKS=1): per frame, the order of cascade shadow passes
and the distinct call stacks (symbolized with atos against the thin ARM64
executable) that opened them.

usage: shadow_stacks.py TRACE.jsonl [--binary PATH] [--frames 3]
       --binary defaults to this project’s build/bg3-arm64
"""
import argparse
import json
import subprocess
from pathlib import Path
from collections import Counter, OrderedDict, defaultdict


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace")
    ap.add_argument("--binary", default=str(Path(__file__).resolve().parents[2] / "build/bg3-arm64"))
    ap.add_argument("--frames", type=int, default=3)
    ap.add_argument("--depth", type=int, default=8)
    args = ap.parse_args()

    events = []
    for line in open(args.trace, errors="replace"):
        if '"shadowPassStack"' in line:
            try:
                events.append(json.loads(line))
            except json.JSONDecodeError:
                pass
    if not events:
        print("no shadowPassStack events")
        return

    addrs = sorted({a for e in events for a in e["stack"][: args.depth]})
    syms = subprocess.run(
        ["xcrun", "atos", "-o", args.binary, "-arch", "arm64", "-l", "0x100000000"] + addrs,
        capture_output=True, text=True).stdout.splitlines()
    name = {a: s.replace(" (in bg3-arm64)", "") for a, s in zip(addrs, syms)}

    by_frame = OrderedDict()
    for e in events:
        by_frame.setdefault(e["frame"], []).append(e)
    per_frame = Counter(len(v) for v in by_frame.values())
    print(f"{len(events)} shadow passes over {len(by_frame)} frames; passes per frame: {dict(per_frame)}\n")

    # The first frames are often loading/menu; show the last complete ones.
    frames = list(by_frame.items())[-(args.frames + 1):-1] or list(by_frame.items())
    stack_ids = {}
    for frame, evs in frames:
        print(f"frame {frame}:")
        for e in evs:
            key = tuple(e["stack"][: args.depth])
            sid = stack_ids.setdefault(key, f"S{len(stack_ids)}")
            extra = ""
            if "stage" in e:
                extra = f"  slot {e['slot']:#x} stage {e['stage']:#x} view {e['view']:#x}"
            print(f"  {e['width']}² slice {e['slice']} load {e['load']}  stack {sid}{extra}")
        print()
    for key, sid in stack_ids.items():
        print(f"{sid}:")
        for a in key:
            print(f"    {name.get(a, a)}")
        print()


if __name__ == "__main__":
    main()
