# SSAO Blur Fix

Technical name: `ssao-blur-fix`.

Opt-in with `BG3MFX_FEATURE_SSAO_BLUR_FIX=1` (the `bg3mfx` launcher sets
it; development launches: `--feature ssao-blur-fix`).

## Behavior

BG3 smooths its screen-space ambient occlusion with a depth-aware 5-tap blur
in two passes (`PPSAO_Blur_PS`): horizontal, then vertical. On Macs, both
passes blur vertically, so the AO is never smoothed horizontally and the
2×2 interleave pattern and sampling noise are left in that direction. With
this fix, the first pass blurs horizontally again, as the shader intends.

## Cause

Read from BG3 4.1.1.7631656 (ARM64), and seen in a capture and a diagnostic
trace on October 31, 2026. The blur's direction lives in an
`rf::DynamicCB`, a constant buffer with four ring slots and a counter.
`CompareSetAndBindConstantBuffer<PPSAO_Blur::blur>` writes each new value to
the next slot right away, then records a bind command. With unified memory
(every Apple Silicon Mac) that command (op 0x08) holds the `DynamicCB` itself,
and replay binds the slot its counter names at replay time. By then both
passes are recorded, so both bind the second write: the vertical direction.
Without unified memory BG3 records op 0x07 with a fixed buffer, which works.
See op 0x08 in the [command map](../../../docs/dev/baseline/command-buffer.md).

## Implementation

[`SSAOBlurFix.mm`](SSAOBlurFix.mm) checks the 13 instructions of the
unified-memory branch and patches two of them in memory (the app bundle is
unchanged). The op becomes 0x07, and the record's buffer store becomes a
call to a 20-byte island in the header padding. The island stores
`ring[counter & 3]`, the slot just written. Replay then binds each pass's
own slot, as op 0x07 does for GPUs without unified memory. Only this
function is patched: it is the blur's own copy of the template.

Frames write two values to a four-slot ring, so each slot is reused two
frames later. BG3's vertical pass already relies on that today; the fix makes
the horizontal pass rely on it too.

`ssao_blur_fix_smoke.cpp` runs the island on the CPU against a modelled
`DynamicCB` and checks the patched words (synthetic, CPU only).

## Improvement

Image quality, not speed: the AO gets the horizontal half of its blur. The
cost is one more load per blur bind, recorded twice per frame.

Validated in the game on October 31, 2026 (diagnostic runtime, displayed,
3456×2160): the fix installed, and the constant snapshots
(`BG3MFX_TRACE_CONSTANTS=1`) showed each frame's first blur pass binding
(1/3456, 0) and its second (0, 1/2160), each in its own ring slot, where
both had been (0, 1/2160). The image looked normal. No before/after image
comparison was made.
