#!/usr/bin/env python3
"""Per render-pass attachment audit: storage mode, load/store actions, size.
usage: attachments.py SESSION CB"""
import re, subprocess, sys
s, cb = sys.argv[1], sys.argv[2]
def gd(*c):
    a = ["gpudebug", "-s", s]
    for x in c: a += ["-c", x]
    return subprocess.run(a, capture_output=True, text=True).stdout
def last_table(t):
    i = t.rfind("\nName ")
    return t[i:] if i >= 0 else t
encs = [l.split()[0] for l in last_table(gd(f"go /commands/{cb}", "list --all")).splitlines() if re.match(r"re\d+\s", l)]
print("enc\tatt\ttexture\tformat\tload\tstore\tstorage\tMiB")
for e in encs:
    rows = [l.split() for l in last_table(gd(f"go /commands/{cb}/{e}", "list --all")).splitlines()
            if re.match(r"(color\d+|depth|stencil)\s", l)]
    for r in rows:
        info = gd(f"go /commands/{cb}/{e}", f"info {r[0]}")
        g = lambda k: (re.search(rf"^{k}:\s+(.*)$", info, re.M) or [None, "?"])[1].strip()
        tex = next((x for x in r if x.startswith("@tex")), "?")
        print("\t".join([e, r[0], tex, g("pixelFormat"), g("loadAction"), g("storeAction"),
                         g("storageMode"), g("allocatedSize").replace(" MiB", "")]), flush=True)
