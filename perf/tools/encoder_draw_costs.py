#!/usr/bin/env python3
"""Per-encoder draw cost breakdown by material group from a gpudebug profile.

usage: encoder_draw_costs.py SESSION FRAME_MS ENC[=LABEL] ...
  e.g. encoder_draw_costs.py 9 16.2617 re6=c0 re7=c1 re8=c2 re9=c3 re10=c0+
ENC is the profile encoder name (/performance/encoders/reN).
"""
import json
import re
import subprocess
import sys
from collections import defaultdict

GROUPS = [
    ("foliage (wind, alpha-test)", r"Atmosphere_ATM_Wind.*AlphaTest"),
    ("foliage (wind, other)", r"Atmosphere_ATM_Wind"),
    ("hair", r"CHAR_Hair"),
    ("characters", r"Characters_CHAR"),
    ("tileset alpha/cutout", r"ENV_Tileset"),
    ("HLOD", r"HLOD"),
    ("other alpha-test", r"AlphaTest"),
]


def listing(session, enc):
    out = subprocess.run(["gpudebug", "-s", str(session), "--json", "-c",
                          f"go /performance/encoders/{enc}/commands", "-c", "list --all"],
                         capture_output=True, text=True).stdout
    dec, i, docs = json.JSONDecoder(), 0, []
    while i < len(out):
        while i < len(out) and out[i].isspace():
            i += 1
        if i >= len(out):
            break
        obj, i = dec.raw_decode(out, i)
        docs.append(obj)
    return docs[-1]["children"] if docs else []


def main():
    session, frame_ms = sys.argv[1], float(sys.argv[2])
    cols = [a.split("=", 1) if "=" in a else (a, a) for a in sys.argv[3:]]
    table = defaultdict(dict)
    totals = {}
    for enc, label in cols:
        rows = listing(session, enc)
        sums = defaultdict(float)
        for r in rows:
            shader = r["values"][0]["value"]
            cost = r["values"][2]["value"] or 0.0
            group = next((g for g, rx in GROUPS if re.search(rx, shader)), "other")
            sums[group] += cost
        totals[label] = (sum(sums.values()), len(rows))
        for g, c in sums.items():
            table[g][label] = c
    labels = [l for _, l in cols]
    print(f"{'group':30}" + "".join(f"{l:>10}" for l in labels) + f"{'total':>10}")
    for g in [g for g, _ in GROUPS] + ["other"]:
        if g not in table:
            continue
        vals = [table[g].get(l, 0.0) * frame_ms / 100 for l in labels]
        print(f"{g:30}" + "".join(f"{v:10.3f}" for v in vals) + f"{sum(vals):10.3f}")
    vals = [totals[l][0] * frame_ms / 100 for l in labels]
    print(f"{'ALL (ms)':30}" + "".join(f"{v:10.3f}" for v in vals) + f"{sum(vals):10.3f}")
    print(f"{'draws':30}" + "".join(f"{totals[l][1]:10}" for l in labels))


if __name__ == "__main__":
    main()
