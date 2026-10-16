#!/usr/bin/env python3
"""Name each encoder of a gpudebug session by its shaders, and report texture
bindings that match a pattern (e.g. a shadow map), plus GPU cost when a profile
is loaded.

usage: pass_map.py SESSION_ID CB [--watch tex453 tex431] [--max-calls 3]
Writes a TSV to stdout: enc, label, calls, cost%, attachments, shaders, watched reads.
For encoders with more than --max-calls calls only the first call is inspected.
"""
import argparse
import re
import subprocess

ROW = re.compile(r"^(\S+)\s+(\".*?\"|\S+)\s+(.*?)\s{2,}(\S.*)?$")


def gd(session, *cmds):
    args = ["gpudebug", "-s", str(session)]
    for c in cmds:
        args += ["-c", c]
    return subprocess.run(args, capture_output=True, text=True).stdout


def rows(text):
    # `go` prints a listing before `list --all`; keep only the last table.
    if "\nName " in "\n" + text:
        text = text[text.rfind("Name ") if text.startswith("Name ") and text.count("Name ") == 1 else ("\n" + text).rfind("\nName "):]
    out = []
    for line in text.splitlines():
        if line.startswith("Links:"):
            break
        if not line or line.startswith(("Name", "─", "(")):
            continue
        parts = re.split(r"\s{2,}", line.strip())
        out.append(parts)
    return out


def entry_points(session, pso):
    txt = gd(session, f"info @{pso}")
    eps = re.findall(r"^(vertex|fragment|compute|kernel|mesh|object|tile):\s+(\S+)", txt, re.M)
    return " / ".join(f"{e}" for _, e in eps)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session")
    ap.add_argument("cb")
    ap.add_argument("--watch", nargs="*", default=[])
    ap.add_argument("--max-calls", type=int, default=3)
    args = ap.parse_args()

    costs = {}
    for r in rows(gd(args.session, "go /performance/encoders", "list --all")):
        if len(r) >= 3:
            costs[r[1].strip('"')] = r[2]

    pso_cache = {}
    encs = rows(gd(args.session, f"go /commands/{args.cb}", "list --all"))
    seen = set()
    print("enc\tlabel\tcalls\tcost\tattachments\tshaders\twatched")
    for e in encs:
        name, label = e[0], e[1].strip('"')
        if name in seen or not re.match(r"(re|ce|be)\d+$", name):
            continue
        seen.add(name)
        children = rows(gd(args.session, f"go /commands/{args.cb}/{name}", "list --all"))
        atts = [f"{c[0]}={c[2].split(' ', 1)[1] if ' ' in c[2] else c[2]}"
                for c in children if c[0].startswith(("color", "depth"))]
        calls = [c[0] for c in children if re.match(r"(draw|disp|blit)\d+$", c[0])]
        inspect = calls if len(calls) <= args.max_calls else calls[:1]
        shaders, watched = [], set()
        for call in inspect:
            if call.startswith("blit"):
                continue
            listing = rows(gd(args.session, f"go /commands/{args.cb}/{name}/{call}", "list --all"))
            pso = next((c[2].split()[0].lstrip("@") for c in listing if c[0] == "pipeline"), None)
            if pso:
                if pso not in pso_cache:
                    pso_cache[pso] = entry_points(args.session, pso)
                shaders.append(pso_cache[pso])
            for stage in ("vertex", "fragment", "compute"):
                if not any(c[0] == stage for c in listing):
                    continue
                b = gd(args.session, f"go /commands/{args.cb}/{name}/{call}/{stage}", "list --all")
                for w in args.watch:
                    if re.search(rf"@{w}\b", b):
                        watched.add(f"{w}@{stage}")
        uniq = list(dict.fromkeys(shaders))
        print("\t".join([name, label, str(len(calls)), costs.get(label, ""), " ".join(atts),
                         " | ".join(uniq), ",".join(sorted(watched))]), flush=True)


if __name__ == "__main__":
    main()
