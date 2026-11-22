# Improved Draw Distance

Technical name: `improved-draw-distance`.

Opt-in with `BG3MFX_FEATURE_IMPROVED_DRAW_DISTANCE=1` (the `bg3mfx` launcher
sets it), for the supported BG3 build. It pushes back the distance at which small props (lamps,
sconces, clutter) and their shadows disappear.

## Behavior

BG3 removes small objects outright at about 40–48 m, with no lower-detail
version in between, and their shadows a few metres sooner. Video → Detail
Distance barely changes this. With improved-draw-distance, those cutoffs move out to
roughly 80–95 m. Objects bigger than about 1 m radius and HLOD (merged distant
structures) are unchanged.

## Implementation

Each frame, `CullSSEInternal` passes a size test to
`ls::sse::CullOnBoundSizeAndAABBs`, which culls an object of bounding radius
`r` at distance `d` from the camera when

```text
T × min(d / D, 1)^10  ≥  r / (d − r)
```

Detail Distance (graphic settings +0x3d, 0–2) picks `T` = 0.016, 0.018 or 0.020
from `ls::GlobalSwitches` +0x74 and `D` from +0x80. `D` is 50 m for every
value. Shadow views use 2`T`. `ls::VisualStreamSystem::Cull` and
`VisualStreamDataSystem` read the same pair for visual streaming.

Past `D` the cutoff is `r(1 + 1/T)`, so only objects larger than about 1 m see
Detail Distance. Inside `D` the tenth power collapses the threshold, which
pins small objects near `D` whatever `T` is.

`ls::GlobalSwitches::Reset`, run when BG3 creates its switches, writes `D` for
all three values: setting 0 from the last float of a 16-byte constant only it
loads, settings 1 and 2 from `mov w9, #0x42480000` (50.0). The feature replaces
both with 100 m at install, before BG3 creates its switches. Both sites are
checked against [`SupportedBuild.h`](../../common/native/SupportedBuild.h).

Implementation is in [`DrawDistance.mm`](DrawDistance.mm), installed by
[root](../root/README.md).

## Improvement

Estimated from the formula, `T` = 0.016:

| Radius | Cut at 50 m `D` | Cut at 100 m `D` | Shadow, 50 m | Shadow, 100 m |
|---|---|---|---|---|
| 0.25 m | 45 m | 84 m | 42 m | 79 m |
| 0.5 m | 48 m | 90 m | 45 m | 85 m |
| 1 m | 63 m | 96 m | 48 m | 90 m |
| 2 m | 127 m | 127 m | 64 m | 96 m |

A GPU capture of a town square (1,501 measured G-buffer instances) agreed with the
50 m column: props under 0.5 m radius stopped at 45 m, and a 0.52 m sconce was
cut between 45 and 48 m, its shadow first. With the feature, a capture near the
same spot drew that sconce mesh three times (once before) and its shadow again.
Against a capture near the same spot without it, the frame had 5.5% more draws (4,613
against 4,374) and 4.9% more triangles; the G-buffer had 9% more draws. The
camera differed slightly, so these are approximate.

Measured live (displayed, M5 Pro, all player features, same quicksave and still
camera, 30 s each, no GPU capture): 64.0 fps with the feature and 64.6 fps
without, minimums 63.1 and 63.4; the render thread used 41.2% and 41.1% of a
core, and the whole process 256% and 258%. The difference is about 1% of frame
rate, within what one run each can resolve.
