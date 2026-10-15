// Darwin arm64 TLV ABI: x0 descriptor -> x0 storage. Preserve x1-x15
// and vector registers across the ordinary C helper. x16/x17 are scratch.
#if defined(__aarch64__)
.text
.p2align 2
.globl _guest_tlv_bootstrap
_guest_tlv_bootstrap:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    sub sp, sp, #640
    stp x1, x2, [sp, #0]
    stp x3, x4, [sp, #16]
    stp x5, x6, [sp, #32]
    stp x7, x8, [sp, #48]
    stp x9, x10, [sp, #64]
    stp x11, x12, [sp, #80]
    stp x13, x14, [sp, #96]
    stp x15, x16, [sp, #112]
    stp q0, q1, [sp, #128]
    stp q2, q3, [sp, #160]
    stp q4, q5, [sp, #192]
    stp q6, q7, [sp, #224]
    stp q8, q9, [sp, #256]
    stp q10, q11, [sp, #288]
    stp q12, q13, [sp, #320]
    stp q14, q15, [sp, #352]
    stp q16, q17, [sp, #384]
    stp q18, q19, [sp, #416]
    stp q20, q21, [sp, #448]
    stp q22, q23, [sp, #480]
    stp q24, q25, [sp, #512]
    stp q26, q27, [sp, #544]
    stp q28, q29, [sp, #576]
    stp q30, q31, [sp, #608]
    bl _guest_tlv_address
    ldp q0, q1, [sp, #128]
    ldp q2, q3, [sp, #160]
    ldp q4, q5, [sp, #192]
    ldp q6, q7, [sp, #224]
    ldp q8, q9, [sp, #256]
    ldp q10, q11, [sp, #288]
    ldp q12, q13, [sp, #320]
    ldp q14, q15, [sp, #352]
    ldp q16, q17, [sp, #384]
    ldp q18, q19, [sp, #416]
    ldp q20, q21, [sp, #448]
    ldp q22, q23, [sp, #480]
    ldp q24, q25, [sp, #512]
    ldp q26, q27, [sp, #544]
    ldp q28, q29, [sp, #576]
    ldp q30, q31, [sp, #608]
    ldp x1, x2, [sp, #0]
    ldp x3, x4, [sp, #16]
    ldp x5, x6, [sp, #32]
    ldp x7, x8, [sp, #48]
    ldp x9, x10, [sp, #64]
    ldp x11, x12, [sp, #80]
    ldp x13, x14, [sp, #96]
    ldp x15, x16, [sp, #112]
    add sp, sp, #640
    ldp x29, x30, [sp], #16
    ret
#endif
