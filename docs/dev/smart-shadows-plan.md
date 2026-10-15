# Smart Shadows plan (not started)

Idea from 2026-10-15: render the cascade shadow maps at quarter resolution
with a 4-frame sub-texel offset pattern, and scatter each frame's samples into
the full-resolution maps. Static content converges to the full-resolution
result exactly; only moving content lags. Exposed to players as a "Smart
Shadows" setting.

## Why

GPU-bound capture (`build/lowercity.gputrace`, Lower City crowd, Temporal
Performance at 640x400, branch `submit-opcode-probe`): 9.09 ms GPU frame, 118
fps fullscreen with FG off. Shadows are the largest stage at 3.09 ms (34%).

| Shadow pass | Vertex | Fragment |
| --- | --- | --- |
| c0 | 0.09 ms | 0.21 ms |
| c1 | 0.22 ms | 0.60 ms |
| c2 | 0.14 ms | 0.84 ms |
| c3 | 0.17 ms | 0.36 ms |
| 5th pass (static draws, loads an existing slice) | 0.10 ms | 0.35 ms |
| Total | 0.73 ms | 2.37 ms |

The map is one `Depth16Unorm` 2048x2048 2D array with 4 slices. Foliage
alpha-test (`Shared_Atmosphere_ATM_Wind_..._DEPS_fragmentMain`) is about half
of the shadow cost. Its fragment shader is already minimal: a Granite
virtual-texture page-table read, one alpha sample with discard below 0.2, and
a distance-fade dither discard. The cost is overdraw: c1 rasterized 26M pixels
on a 4.2M-pixel slice. Limiters are all below 50%, so it is latency bound and
rewriting the shader would save 0.1–0.2 ms at most.

Shadow cost is mostly fragment work, so it scales with pixel count.

## Estimate (not measured)

- Fragment work at quarter resolution: 25–35% of today (small triangles keep
  some fixed cost). Vertex work is unchanged.
- Scatter pass: about 0.05–0.1 ms.
- All cascades: save about 1.5–1.7 ms of 9.1 ms (~17–18%), roughly 118 → 140
  fps in this scene if it stays GPU-bound.
- Recommended scope, c1 and later passes (c0 at full resolution): about
  1.4–1.6 ms. c0 holds close-up moving characters (player hair and face
  self-shadowing), where 4-frame staleness would show, and it only costs 0.3 ms.

## Why not MetalFX or plain lower resolution

- MetalFX upscales color and filters across samples. Averaged depth at an edge
  matches neither surface, causing light leaks and acne.
- A plain lower-resolution shadow map was rejected earlier as a quality loss.
- Interleaving never blends: every texel is a real depth from some frame.

## Risks

- Moving content (characters, wind foliage) updates every 4th frame, so
  moving shadow edges stipple. PCSS filtering hides some of it.
- Camera movement shifts the cascades:
  - If BG3 moves them in whole-texel steps, the history shifts by an integer
    offset, which is cheap.
  - A cascade scale change (zoom) discards the history, and that frame
    renders at full resolution.
  - Without texel snapping, old shadow edges ghost. That would kill the idea.

## Plan

1. **Probe (diagnostic runtime only).** Log each cascade's light
   view-projection every frame. The user plays a couple of minutes, mixing
   still camera, panning and zooming, launched from their own Terminal at
   nice 0. Answer:
   - Do cascades move in whole-texel steps?
   - How often does scale change?
   - How often are c2/c3 identical frame to frame? This also answers the
     static-cache alternative.
2. **Interleaved rendering behind an env var**, for c1 onward:
   - Redirect the cascade's depth attachment to a quarter-resolution texture
     and shrink its viewport.
   - Add the sub-texel offset to the cascade matrix in its constants, as
     MetalFX Temporal already does for camera jitter.
   - Compute pass scatters into the full-resolution slice and shifts the
     history on cascade moves; resets on scale change.
   - The 5th pass loads an existing slice, so its quarter-resolution target
     must keep that slice's samples.
   - Validate with a GPU capture plus a side-by-side shadow comparison, and
     live fps from the user's HUD.
3. **"Smart Shadows" setting.** Prefer a checkbox under the Shadows dropdown
   so it combines with every shadow quality, like Frame Generation does with
   Upscaling Type. A dropdown entry would have to imply a fixed base quality.
   - Persistent across restarts.
   - Tied to the supported-build guard.
   - `=0` env off switch for A/B.
   - Add a line to AGENTS.md "Active scope", which today covers only the HUD
     and MetalFX features.

## Alternatives considered

- **Static cache for far cascades.** Freezing wind there makes caching
  possible, but it only pays off with a still camera. Moving draws would need
  splitting out by shader name, and distant trees would sway while their
  shadows stay still. The user declined static caching earlier; the probe in
  step 1 would show how often it could hit.
- **Dropping foliage or the 5th (vista) pass from far cascades.** Saves
  0.24–0.8 ms; a visible quality tradeoff, declined.
