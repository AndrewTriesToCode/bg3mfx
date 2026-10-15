#!/usr/bin/env python3
"""Foliage in the cascade shadow passes of a gpudebug session.

For each encoder pair (debug-tree encoder, profile encoder): where foliage draws
sit in submission order relative to other casters, and the costliest foliage
draws with their geometry. Optionally fetches each top draw's fragment textures
to identify the plant.

usage: foliage_shadows.py SESSION FRAME_MS CB TREE_ENC=PROFILE_ENC[=LABEL] ...
       [--top N] [--fetch DIR]
"""
import argparse
import json
import re
import subprocess

FOLIAGE = re.compile(r"Atmosphere_ATM_Wind")
ALPHA = re.compile(r"AlphaTest|Hair|Tileset")


def gd(session, *cmds, js=True):
    args = ["gpudebug", "-s", str(session)] + (["--json"] if js else [])
    for c in cmds:
        args += ["-c", c]
    out = subprocess.run(args, capture_output=True, text=True).stdout
    if not js:
        return out
    dec, i, docs = json.JSONDecoder(), 0, []
    while i < len(out):
        while i < len(out) and out[i].isspace():
            i += 1
        if i >= len(out):
            break
        try:
            obj, i = dec.raw_decode(out, i)
            docs.append(obj)
        except json.JSONDecodeError:
            break
    return docs


def children(docs):
    return docs[-1].get("children", []) if docs else []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("session")
    ap.add_argument("frame_ms", type=float)
    ap.add_argument("cb")
    ap.add_argument("pairs", nargs="+")
    ap.add_argument("--top", type=int, default=4)
    ap.add_argument("--fetch")
    args = ap.parse_args()

    for pair in args.pairs:
        parts = pair.split("=")
        tree, prof = parts[0], parts[1]
        label = parts[2] if len(parts) > 2 else tree
        cost = {}
        for r in children(gd(args.session, f"go /performance/encoders/{prof}/commands", "list --all")):
            cost[r["name"]] = (r["values"][2]["value"] or 0.0) * args.frame_ms / 100
        draws = []
        for r in children(gd(args.session, f"go /commands/{args.cb}/{tree}", "list --all")):
            if not r["name"].startswith("draw"):
                continue
            shader = r["values"][0]["value"].strip('"')
            tris = r["values"][1]["value"] if len(r["values"]) > 1 else ""
            kind = "foliage" if FOLIAGE.search(shader) else ("alpha" if ALPHA.search(shader) else "opaque")
            draws.append((int(r["name"][4:]), r["name"], kind, shader, tris, cost.get(r["name"], 0.0)))
        draws.sort()
        n = len(draws)
        fol = [d for d in draws if d[2] == "foliage"]
        opq = [d for d in draws if d[2] == "opaque"]
        fol_ms = sum(d[5] for d in fol)
        after = sum(1 for f in fol for o in opq if o[0] > f[0])
        pairs_total = len(fol) * len(opq) or 1
        print(f"== {label} ({tree}): {n} draws, foliage {len(fol)} ({fol_ms:.3f} ms), "
              f"opaque {len(opq)}, alpha-other {n - len(fol) - len(opq)}")
        if fol:
            pos = [d[0] for d in fol]
            print(f"   foliage submission positions: first {pos[0]}, median {pos[len(pos)//2]}, last {pos[-1]} of {n}; "
                  f"{100 * after / pairs_total:.0f}% of (foliage, opaque) pairs have the opaque draw later")
        for d in sorted(fol, key=lambda d: -d[5])[: args.top]:
            info = gd(args.session, f"go /commands/{args.cb}/{tree}/{d[1]}", "info", js=False)
            idx = re.search(r"indexCount:\s+(\d+)", info)
            inst = re.search(r"instanceCount:\s+(\d+)", info)
            print(f"   {d[1]:8} {d[5]:.3f} ms  {d[4]:>16}  indices {idx.group(1) if idx else '?'} "
                  f"instances {inst.group(1) if inst else '1'}  {d[3].split(' / ')[0][:70]}")
            if args.fetch:
                for r in children(gd(args.session, f"go /commands/{args.cb}/{tree}/{d[1]}/fragment", "list --all")):
                    if r["name"].startswith("tex") and "sRGB" in json.dumps(r):
                        out = f"{args.fetch}/{label}-{d[1]}-{r['name'].strip('[]').replace('[', '')}.png"
                        gd(args.session, f"go /commands/{args.cb}/{tree}/{d[1]}/fragment",
                           f"fetch {r['name']} --out {out}", js=False)
                        print(f"      fetched {r['name']} -> {out}")


if __name__ == "__main__":
    main()
