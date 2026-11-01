.text
.p2align 2
// void *BG3MFXTestSSAOBlurIsland(void *cb, void *record, const void *code)
// Calls `code` with the registers CompareSetAndBindConstantBuffer<blur> holds
// at the patched call: x20 = the DynamicCB, x0 = the new record. Returns x20
// as the island left it.
.globl _BG3MFXTestSSAOBlurIsland
_BG3MFXTestSSAOBlurIsland:
stp x20, x30, [sp, #-16]!
mov x20, x0
mov x0, x1
blr x2
mov x0, x20
ldp x20, x30, [sp], #16
ret
