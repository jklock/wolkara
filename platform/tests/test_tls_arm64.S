.text
.p2align 2
.globl _test_tlv_registers
_test_tlv_registers:
    stp x29, x30, [sp, #-16]!
    mov x29, sp
    mov x1, #17
    mov x8, #31
    mov x15, #47
    movi v0.16b, #19
    movi v31.16b, #37
    bl _guest_tlv_bootstrap
    cbz x0, Lbad
    cmp x1, #17
    b.ne Lbad
    cmp x8, #31
    b.ne Lbad
    cmp x15, #47
    b.ne Lbad
    umov w16, v0.b[15]
    cmp w16, #19
    b.ne Lbad
    umov w16, v31.b[15]
    cmp w16, #37
    b.ne Lbad
    mov w0, #1
    b Ldone
Lbad:
    mov w0, #0
Ldone:
    ldp x29, x30, [sp], #16
    ret
