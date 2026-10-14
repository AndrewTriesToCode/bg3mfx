#!/usr/bin/env python3
"""Group pass_map.py TSV rows into renderer categories and convert cost% to ms."""
import sys, re
tsv, frame_ms = sys.argv[1], float(sys.argv[2])
rules = [
    ("Cascade shadows, set 1 (unused)", lambda e,s,a,i: "Depth16" in a and i < 30),
    ("Cascade shadows, set 2 (used)",   lambda e,s,a,i: "Depth16" in a),
    ("Shadow mask (PCSS)",              lambda e,s,a,i: "PCSS" in s),
    ("Depth prepass",                   lambda e,s,a,i: "FadePattern" in s),
    ("G-buffer",                        lambda e,s,a,i: "color4=" in a),
    ("Velocity",                        lambda e,s,a,i: "VelocityBuffer" in s),
    ("Clustered lighting",              lambda e,s,a,i: "Cluster" in s),
    ("SSAO",                            lambda e,s,a,i: "SAO" in s),
    ("Fog (volumetric + deferred)",     lambda e,s,a,i: "Fog" in s),
    ("Decals",                          lambda e,s,a,i: "Decal" in s),
    ("Clouds/sky",                      lambda e,s,a,i: "Cloud" in s or "Skydome" in s),
    ("Water/forward/VFX",               lambda e,s,a,i: re.search(r"Fluid|Water|Billboard|Helper", s)),
    ("Room-trigger mask (fade)",        lambda e,s,a,i: "RoomTrigger" in s or "FadeBlending" in s),
    ("TAA",                             lambda e,s,a,i: "TAA" in s),
    ("SSS",                             lambda e,s,a,i: "SSSS" in s),
    ("Post (bloom/godrays/tonemap/CAS/exposure)", lambda e,s,a,i: re.search(r"Bloom|GodRays|ToneMap|ColorGrading|CAS|Rexpose|Exposure|PPKernel", s)),
    ("Skinning/blendshapes",            lambda e,s,a,i: "BlendShape" in s),
    ("UI",                              lambda e,s,a,i: re.search(r"Clear31|Downsample31|Upsample31|PathP31|CombineUI|DownsampleResolver", s)),
]
tot = {}
for i, line in enumerate(open(tsv)):
    f = line.rstrip("\n").split("\t")
    if i == 0 or len(f) < 6 or not f[3].endswith("%"):
        continue
    idx = int(re.sub(r"\D", "", f[0]))
    cost = float(f[3][:-1])
    cat = next((n for n, r in rules if r(f[0], f[5], f[4], idx)), "Other (blits, misc)")
    tot[cat] = tot.get(cat, 0) + cost
for k, v in sorted(tot.items(), key=lambda x: -x[1]):
    print(f"{v:6.2f}%  {v*frame_ms/100:5.2f} ms  {k}")
print(f"{sum(tot.values()):6.2f}%  {sum(tot.values())*frame_ms/100:5.2f} ms  total")
