.text
.p2align 2
.globl _BG3MFXTestJitterProjection
_BG3MFXTestJitterProjection:
sub sp, sp, #128
stp x29, x30, [sp]
stp x19, x20, [sp, #16]
stp d8, d9, [sp, #32]
stp d10, d11, [sp, #48]
stp d12, d13, [sp, #64]
stp d14, d15, [sp, #80]
mov x20, x1
mov x19, x1
mov x9, x2
mov w8, #0
mov x16, #0x1234
mov x17, #0x5678
movi v0.16b, #0x5a
movi v1.16b, #0x5a
movi v2.16b, #0x5a
movi v3.16b, #0x5a
movi v4.16b, #0x5a
movi v5.16b, #0x5a
movi v6.16b, #0x5a
movi v7.16b, #0x5a
movi v8.16b, #0x5a
movi v9.16b, #0x5a
movi v10.16b, #0x5a
movi v11.16b, #0x5a
movi v12.16b, #0x5a
movi v13.16b, #0x5a
movi v14.16b, #0x5a
movi v15.16b, #0x5a
movi v16.16b, #0x5a
movi v17.16b, #0x5a
movi v18.16b, #0x5a
movi v19.16b, #0x5a
movi v20.16b, #0x5a
movi v21.16b, #0x5a
movi v22.16b, #0x5a
movi v23.16b, #0x5a
movi v24.16b, #0x5a
movi v25.16b, #0x5a
movi v26.16b, #0x5a
movi v27.16b, #0x5a
movi v28.16b, #0x5a
movi v29.16b, #0x5a
movi v30.16b, #0x5a
movi v31.16b, #0x5a
cmp x16, x17
stp x0, x1, [x0, #0]
stp x2, x3, [x0, #16]
stp x4, x5, [x0, #32]
stp x6, x7, [x0, #48]
stp x8, x9, [x0, #64]
stp x10, x11, [x0, #80]
stp x12, x13, [x0, #96]
stp x14, x15, [x0, #112]
stp x16, x17, [x0, #128]
stp x18, x19, [x0, #144]
stp x20, x21, [x0, #160]
stp x22, x23, [x0, #176]
stp x24, x25, [x0, #192]
stp x26, x27, [x0, #208]
stp x28, x29, [x0, #224]
str x30, [x0, #240]
mrs x16, nzcv
str x16, [x0, #248]
ldr x16, [x0, #128]
str x16, [sp, #96]
add x16, x0, #256
stp q0, q1, [x16, #0]
stp q2, q3, [x16, #32]
stp q4, q5, [x16, #64]
stp q6, q7, [x16, #96]
stp q8, q9, [x16, #128]
stp q10, q11, [x16, #160]
stp q12, q13, [x16, #192]
stp q14, q15, [x16, #224]
stp q16, q17, [x16, #256]
stp q18, q19, [x16, #288]
stp q20, q21, [x16, #320]
stp q22, q23, [x16, #352]
stp q24, q25, [x16, #384]
stp q26, q27, [x16, #416]
stp q28, q29, [x16, #448]
stp q30, q31, [x16, #480]
ldr x16, [sp, #96]
br x3
.globl _BG3MFXTestJitterProjectionResume
_BG3MFXTestJitterProjectionResume:
add x0, x0, #800
stp x0, x1, [x0, #0]
stp x2, x3, [x0, #16]
stp x4, x5, [x0, #32]
stp x6, x7, [x0, #48]
stp x8, x9, [x0, #64]
stp x10, x11, [x0, #80]
stp x12, x13, [x0, #96]
stp x14, x15, [x0, #112]
stp x16, x17, [x0, #128]
stp x18, x19, [x0, #144]
stp x20, x21, [x0, #160]
stp x22, x23, [x0, #176]
stp x24, x25, [x0, #192]
stp x26, x27, [x0, #208]
stp x28, x29, [x0, #224]
str x30, [x0, #240]
mrs x16, nzcv
str x16, [x0, #248]
ldr x16, [x0, #128]
str x16, [sp, #96]
add x16, x0, #256
stp q0, q1, [x16, #0]
stp q2, q3, [x16, #32]
stp q4, q5, [x16, #64]
stp q6, q7, [x16, #96]
stp q8, q9, [x16, #128]
stp q10, q11, [x16, #160]
stp q12, q13, [x16, #192]
stp q14, q15, [x16, #224]
stp q16, q17, [x16, #256]
stp q18, q19, [x16, #288]
stp q20, q21, [x16, #320]
stp q22, q23, [x16, #352]
stp q24, q25, [x16, #384]
stp q26, q27, [x16, #416]
stp q28, q29, [x16, #448]
stp q30, q31, [x16, #480]
ldr x16, [sp, #96]
sub x0, x0, #800
str x0, [x0, #800]
ldp d8, d9, [sp, #32]
ldp d10, d11, [sp, #48]
ldp d12, d13, [sp, #64]
ldp d14, d15, [sp, #80]
ldp x19, x20, [sp, #16]
ldp x29, x30, [sp]
add sp, sp, #128
ret
.globl _BG3MFXTestJitterCamera
_BG3MFXTestJitterCamera:
sub sp, sp, #128
stp x29, x30, [sp]
stp x19, x20, [sp, #16]
stp d8, d9, [sp, #32]
stp d10, d11, [sp, #48]
stp d12, d13, [sp, #64]
stp d14, d15, [sp, #80]
mov x20, x1
mov x19, x1
mov x9, x2
mov w8, #0
mov x16, #0x1234
mov x17, #0x5678
movi v0.16b, #0x5a
movi v1.16b, #0x5a
movi v2.16b, #0x5a
movi v3.16b, #0x5a
movi v4.16b, #0x5a
movi v5.16b, #0x5a
movi v6.16b, #0x5a
movi v7.16b, #0x5a
movi v8.16b, #0x5a
movi v9.16b, #0x5a
movi v10.16b, #0x5a
movi v11.16b, #0x5a
movi v12.16b, #0x5a
movi v13.16b, #0x5a
movi v14.16b, #0x5a
movi v15.16b, #0x5a
movi v16.16b, #0x5a
movi v17.16b, #0x5a
movi v18.16b, #0x5a
movi v19.16b, #0x5a
movi v20.16b, #0x5a
movi v21.16b, #0x5a
movi v22.16b, #0x5a
movi v23.16b, #0x5a
movi v24.16b, #0x5a
movi v25.16b, #0x5a
movi v26.16b, #0x5a
movi v27.16b, #0x5a
movi v28.16b, #0x5a
movi v29.16b, #0x5a
movi v30.16b, #0x5a
movi v31.16b, #0x5a
cmp x16, x17
stp x0, x1, [x0, #0]
stp x2, x3, [x0, #16]
stp x4, x5, [x0, #32]
stp x6, x7, [x0, #48]
stp x8, x9, [x0, #64]
stp x10, x11, [x0, #80]
stp x12, x13, [x0, #96]
stp x14, x15, [x0, #112]
stp x16, x17, [x0, #128]
stp x18, x19, [x0, #144]
stp x20, x21, [x0, #160]
stp x22, x23, [x0, #176]
stp x24, x25, [x0, #192]
stp x26, x27, [x0, #208]
stp x28, x29, [x0, #224]
str x30, [x0, #240]
mrs x16, nzcv
str x16, [x0, #248]
ldr x16, [x0, #128]
str x16, [sp, #96]
add x16, x0, #256
stp q0, q1, [x16, #0]
stp q2, q3, [x16, #32]
stp q4, q5, [x16, #64]
stp q6, q7, [x16, #96]
stp q8, q9, [x16, #128]
stp q10, q11, [x16, #160]
stp q12, q13, [x16, #192]
stp q14, q15, [x16, #224]
stp q16, q17, [x16, #256]
stp q18, q19, [x16, #288]
stp q20, q21, [x16, #320]
stp q22, q23, [x16, #352]
stp q24, q25, [x16, #384]
stp q26, q27, [x16, #416]
stp q28, q29, [x16, #448]
stp q30, q31, [x16, #480]
ldr x16, [sp, #96]
br x3
.globl _BG3MFXTestJitterCameraResume
_BG3MFXTestJitterCameraResume:
add x0, x0, #800
stp x0, x1, [x0, #0]
stp x2, x3, [x0, #16]
stp x4, x5, [x0, #32]
stp x6, x7, [x0, #48]
stp x8, x9, [x0, #64]
stp x10, x11, [x0, #80]
stp x12, x13, [x0, #96]
stp x14, x15, [x0, #112]
stp x16, x17, [x0, #128]
stp x18, x19, [x0, #144]
stp x20, x21, [x0, #160]
stp x22, x23, [x0, #176]
stp x24, x25, [x0, #192]
stp x26, x27, [x0, #208]
stp x28, x29, [x0, #224]
str x30, [x0, #240]
mrs x16, nzcv
str x16, [x0, #248]
ldr x16, [x0, #128]
str x16, [sp, #96]
add x16, x0, #256
stp q0, q1, [x16, #0]
stp q2, q3, [x16, #32]
stp q4, q5, [x16, #64]
stp q6, q7, [x16, #96]
stp q8, q9, [x16, #128]
stp q10, q11, [x16, #160]
stp q12, q13, [x16, #192]
stp q14, q15, [x16, #224]
stp q16, q17, [x16, #256]
stp q18, q19, [x16, #288]
stp q20, q21, [x16, #320]
stp q22, q23, [x16, #352]
stp q24, q25, [x16, #384]
stp q26, q27, [x16, #416]
stp q28, q29, [x16, #448]
stp q30, q31, [x16, #480]
ldr x16, [sp, #96]
sub x0, x0, #800
str x0, [x0, #800]
ldp d8, d9, [sp, #32]
ldp d10, d11, [sp, #48]
ldp d12, d13, [sp, #64]
ldp d14, d15, [sp, #80]
ldp x19, x20, [sp, #16]
ldp x29, x30, [sp]
add sp, sp, #128
ret
.globl _BG3MFXTestJitterVelocity
_BG3MFXTestJitterVelocity:
sub sp, sp, #128
stp x29, x30, [sp]
stp x19, x20, [sp, #16]
stp d8, d9, [sp, #32]
stp d10, d11, [sp, #48]
stp d12, d13, [sp, #64]
stp d14, d15, [sp, #80]
mov x20, x1
mov x19, x1
mov x9, x2
mov w8, #0
mov x16, #0x1234
mov x17, #0x5678
movi v0.16b, #0x5a
movi v1.16b, #0x5a
movi v2.16b, #0x5a
movi v3.16b, #0x5a
movi v4.16b, #0x5a
movi v5.16b, #0x5a
movi v6.16b, #0x5a
movi v7.16b, #0x5a
movi v8.16b, #0x5a
movi v9.16b, #0x5a
movi v10.16b, #0x5a
movi v11.16b, #0x5a
movi v12.16b, #0x5a
movi v13.16b, #0x5a
movi v14.16b, #0x5a
movi v15.16b, #0x5a
movi v16.16b, #0x5a
movi v17.16b, #0x5a
movi v18.16b, #0x5a
movi v19.16b, #0x5a
movi v20.16b, #0x5a
movi v21.16b, #0x5a
movi v22.16b, #0x5a
movi v23.16b, #0x5a
movi v24.16b, #0x5a
movi v25.16b, #0x5a
movi v26.16b, #0x5a
movi v27.16b, #0x5a
movi v28.16b, #0x5a
movi v29.16b, #0x5a
movi v30.16b, #0x5a
movi v31.16b, #0x5a
cmp x16, x17
stp x0, x1, [x0, #0]
stp x2, x3, [x0, #16]
stp x4, x5, [x0, #32]
stp x6, x7, [x0, #48]
stp x8, x9, [x0, #64]
stp x10, x11, [x0, #80]
stp x12, x13, [x0, #96]
stp x14, x15, [x0, #112]
stp x16, x17, [x0, #128]
stp x18, x19, [x0, #144]
stp x20, x21, [x0, #160]
stp x22, x23, [x0, #176]
stp x24, x25, [x0, #192]
stp x26, x27, [x0, #208]
stp x28, x29, [x0, #224]
str x30, [x0, #240]
mrs x16, nzcv
str x16, [x0, #248]
ldr x16, [x0, #128]
str x16, [sp, #96]
add x16, x0, #256
stp q0, q1, [x16, #0]
stp q2, q3, [x16, #32]
stp q4, q5, [x16, #64]
stp q6, q7, [x16, #96]
stp q8, q9, [x16, #128]
stp q10, q11, [x16, #160]
stp q12, q13, [x16, #192]
stp q14, q15, [x16, #224]
stp q16, q17, [x16, #256]
stp q18, q19, [x16, #288]
stp q20, q21, [x16, #320]
stp q22, q23, [x16, #352]
stp q24, q25, [x16, #384]
stp q26, q27, [x16, #416]
stp q28, q29, [x16, #448]
stp q30, q31, [x16, #480]
ldr x16, [sp, #96]
br x3
.globl _BG3MFXTestJitterVelocityResume
_BG3MFXTestJitterVelocityResume:
add x0, x0, #800
stp x0, x1, [x0, #0]
stp x2, x3, [x0, #16]
stp x4, x5, [x0, #32]
stp x6, x7, [x0, #48]
stp x8, x9, [x0, #64]
stp x10, x11, [x0, #80]
stp x12, x13, [x0, #96]
stp x14, x15, [x0, #112]
stp x16, x17, [x0, #128]
stp x18, x19, [x0, #144]
stp x20, x21, [x0, #160]
stp x22, x23, [x0, #176]
stp x24, x25, [x0, #192]
stp x26, x27, [x0, #208]
stp x28, x29, [x0, #224]
str x30, [x0, #240]
mrs x16, nzcv
str x16, [x0, #248]
ldr x16, [x0, #128]
str x16, [sp, #96]
add x16, x0, #256
stp q0, q1, [x16, #0]
stp q2, q3, [x16, #32]
stp q4, q5, [x16, #64]
stp q6, q7, [x16, #96]
stp q8, q9, [x16, #128]
stp q10, q11, [x16, #160]
stp q12, q13, [x16, #192]
stp q14, q15, [x16, #224]
stp q16, q17, [x16, #256]
stp q18, q19, [x16, #288]
stp q20, q21, [x16, #320]
stp q22, q23, [x16, #352]
stp q24, q25, [x16, #384]
stp q26, q27, [x16, #416]
stp q28, q29, [x16, #448]
stp q30, q31, [x16, #480]
ldr x16, [sp, #96]
sub x0, x0, #800
str x0, [x0, #800]
ldp d8, d9, [sp, #32]
ldp d10, d11, [sp, #48]
ldp d12, d13, [sp, #64]
ldp d14, d15, [sp, #80]
ldp x19, x20, [sp, #16]
ldp x29, x30, [sp]
add sp, sp, #128
ret
