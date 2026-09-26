// Original fixture for native scalar/SIMD accesses to software-backed addresses.
.arch armv8.3-a
.text
.p2align 2
.globl _gm_sparse_probe_program
.globl _gm_sparse_probe_program_end
.globl _gm_sparse_address_probe
.globl _gm_sparse_casp_probe
.globl _gm_sparse_casp32_probe
.globl _gm_sparse_ldapr_probe
.globl _gm_sparse_exclusive_probe
.globl _gm_sparse_exclusive_increment
.globl _gm_sparse_exclusive_ordered
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
// A pointer, expected pair, desired pair, and output pair are passed in x0..x3.
// The operation's memory operand alone may be a software address.
_gm_sparse_casp_probe:
    ldp x4, x5, [x1]
    ldp x6, x7, [x2]
    caspal x4, x5, x6, x7, [x0]
    stp x4, x5, [x3]
    ret
_gm_sparse_casp32_probe:
    ldp w4, w5, [x1]
    ldp w6, w7, [x2]
    caspal w4, w5, w6, w7, [x0]
    stp w4, w5, [x3]
    ret
_gm_sparse_ldapr_probe:
    ldaprb w3, [x0]
    str x3, [x1]
    ldaprh w3, [x0]
    str x3, [x1, #8]
    ldapr w3, [x0]
    str x3, [x1, #16]
    ldapr x3, [x0]
    str x3, [x1, #24]
    ret
_gm_sparse_exclusive_probe:
    mov x7, x0
Lexclusive64:
    ldaxr x3, [x7]
    add x4, x3, x1
    stlxr w5, x4, [x7]
    cbnz w5, Lexclusive64
    str x3, [x2]
    ldr x6, [x7]
    str x6, [x2, #8]
Lexclusive8:
    ldaxrb w3, [x7]
    orr w4, w3, #0x80
    stlxrb w5, w4, [x7]
    cbnz w5, Lexclusive8
    str x3, [x2, #16]
    ldarb w6, [x7]
    str x6, [x2, #24]
Lexclusive16:
    ldaxrh w3, [x7]
    eor w4, w3, #0x1fe0
    stlxrh w5, w4, [x7]
    cbnz w5, Lexclusive16
    str x3, [x2, #32]
    ldarh w6, [x7]
    str x6, [x2, #40]
Lexclusive32:
    ldaxr w3, [x7]
    and w4, w3, #0xfffffffe
    stlxr w5, w4, [x7]
    cbnz w5, Lexclusive32
    str x3, [x2, #48]
    ldar w6, [x7]
    str x6, [x2, #56]
Lexclusive_pair:
    ldaxp x3, x4, [x7]
    add x3, x3, #1
    add x4, x4, #2
    stlxp w5, x3, x4, [x7]
    cbnz w5, Lexclusive_pair
    stp x3, x4, [x2, #64]
    ldaxr x3, [x7]
    add x4, x3, #17
    clrex
    stlxr w5, x4, [x7]
    str x5, [x2, #80]
    ldr x3, [x7]
    str x3, [x2, #88]
Lexclusive_select:
    ldaxr x3, [x7]
    cmp x3, #5
    csel x4, x3, x1, lt
    stlxr w5, x4, [x7]
    cbnz w5, Lexclusive_select
    mrs x6, nzcv
    str x6, [x2, #96]
    str x4, [x2, #104]
    ldaxrb w3, [x7]
    tbz w3, #0, Lexclusive_cancel
    mov w3, #128
    stlxrb w5, w3, [x7]
    b Lexclusive_return
Lexclusive_cancel:
    clrex
    mov w5, #1
Lexclusive_return:
    str x5, [x2, #112]
    ldarb w3, [x7]
    str x3, [x2, #120]
    ret
_gm_sparse_exclusive_increment:
Lexclusive_increment:
    ldaxr x1, [x0]
    add x1, x1, #1
    stlxr w2, x1, [x0]
    cbnz w2, Lexclusive_increment
    ret
_gm_sparse_exclusive_ordered:
    ldaxrb w2, [x0]
    orr w2, w2, #0x80
    stlrb w2, [x0]
    ldaxr x2, [x0]
    ldr x3, [x0, #8]
    add x2, x2, x3
    stlxr w4, x2, [x0]
    cbnz w4, _gm_sparse_exclusive_ordered
    ret
_gm_sparse_probe_program_end:
