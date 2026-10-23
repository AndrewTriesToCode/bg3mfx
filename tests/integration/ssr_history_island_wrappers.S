.text
.p2align 2
// void BG3MFXTestSSRHistory(void *view, void *state, const void *code, float2 size)
// Runs `code` with the registers ls::SSRStage::ExecuteWTKernel holds at the
// history save: x9 = view, x26 = SSR state, v0 = texture size.
.globl _BG3MFXTestSSRHistory
_BG3MFXTestSSRHistory:
stp x26, x30, [sp, #-16]!
mov x9, x0
mov x26, x1
blr x2
ldp x26, x30, [sp], #16
ret

.p2align 2
// uint32_t BG3MFXTestSSRValid(const void *base, const void *code)
// Runs `code` with x27 = base, as ls::SSRStage::ExecuteWTKernel holds it at the
// history-valid load, and returns the loaded w11.
.globl _BG3MFXTestSSRValid
_BG3MFXTestSSRValid:
stp x27, x30, [sp, #-16]!
mov x27, x0
blr x1
mov w0, w11
ldp x27, x30, [sp], #16
ret
