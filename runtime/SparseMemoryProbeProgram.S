// Original fixture for native scalar/SIMD accesses to software-backed addresses.
.arch armv8.1-a
.text
.p2align 2
.globl _gm_sparse_probe_program
.globl _gm_sparse_probe_program_end
.globl _gm_sparse_address_probe
_gm_sparse_probe_program:
    str x1, [x0]
    ldrb w3, [x0]
    ldrh w4, [x0]
    ldr w5, [x0]
    ldr x6, [x0]
    ldrsb x7, [x0]
    add x9, x0, #16
    stp x1, x6, [x9], #16
    ldp x10, x11, [x9, #-16]!
    dup v0.2d, x1
    stp q0, q0, [x0, #64]
    ldp q1, q2, [x0, #64]
    stp q1, q2, [x2]
    // Return a checksum using every scalar load, including pair and sign extend.
    add x0, x3, x4
    add x0, x0, x5
    add x0, x0, x6
    add x0, x0, x7
    add x0, x0, x10
    add x0, x0, x11
    ret
// Exercise addressing modes and LSE atomics with observable output. The caller
// compares native execution and software execution of this same original code.
_gm_sparse_address_probe:
    str x1, [x0]
    add x9, x0, #32
    stur x1, [x9, #-8]
    ldur x3, [x9, #-8]
    str x3, [x2]
    str x1, [x9, #8]!
    ldr x3, [x9], #-8
    str x3, [x2, #8]
    mov x4, #1
    str x1, [x9, x4, lsl #3]
    ldr x3, [x9, x4, lsl #3]
    str x3, [x2, #16]
    mov w4, #-1
    ldr x3, [x9, w4, sxtw #3]
    str x3, [x2, #24]
    mov w4, #3
    ldr x3, [x0, w4, uxtw #3]
    str x3, [x2, #32]
    mov x4, #-8
    ldr x3, [x9, x4, sxtx]
    str x3, [x2, #40]
    dup v0.2d, x1
    stur q0, [x9, #16]
    ldur q1, [x9, #16]
    str q1, [x2, #48]
    mov x4, #4
    str q0, [x0, x4, lsl #4]
    ldr q1, [x0, x4, lsl #4]
    str q1, [x2, #64]
    stlr x1, [x0]
    ldar x3, [x0]
    str x3, [x2, #80]
    mov x4, #7
    ldaddal x4, x3, [x0]
    str x3, [x2, #88]
    swpal x1, x3, [x0]
    str x3, [x2, #96]
    mov x4, x1
    casal x4, xzr, [x0]
    str x4, [x2, #104]
    mov x4, #123
    casal x4, x1, [x0]
    str x4, [x2, #112]
    ldr x3, [x0]
    str x3, [x2, #120]
    ret
_gm_sparse_probe_program_end:
