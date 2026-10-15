// Original native reference functions: one atomic operation followed by ret.
.arch armv8.1-a
.text
.p2align 2
.globl _gm_memory_atomic_references
.globl _gm_memory_atomic_references_end
_gm_memory_atomic_references:
    ldaddalb w1, w0, [x0]
    ret
    ldclralb w1, w0, [x0]
    ret
    ldeoralb w1, w0, [x0]
    ret
    ldsetalb w1, w0, [x0]
    ret
    ldsmaxalb w1, w0, [x0]
    ret
    ldsminalb w1, w0, [x0]
    ret
    ldumaxalb w1, w0, [x0]
    ret
    lduminalb w1, w0, [x0]
    ret
    swpalb w1, w0, [x0]
    ret
    ldaddalh w1, w0, [x0]
    ret
    ldclralh w1, w0, [x0]
    ret
    ldeoralh w1, w0, [x0]
    ret
    ldsetalh w1, w0, [x0]
    ret
    ldsmaxalh w1, w0, [x0]
    ret
    ldsminalh w1, w0, [x0]
    ret
    ldumaxalh w1, w0, [x0]
    ret
    lduminalh w1, w0, [x0]
    ret
    swpalh w1, w0, [x0]
    ret
    ldaddal w1, w0, [x0]
    ret
    ldclral w1, w0, [x0]
    ret
    ldeoral w1, w0, [x0]
    ret
    ldsetal w1, w0, [x0]
    ret
    ldsmaxal w1, w0, [x0]
    ret
    ldsminal w1, w0, [x0]
    ret
    ldumaxal w1, w0, [x0]
    ret
    lduminal w1, w0, [x0]
    ret
    swpal w1, w0, [x0]
    ret
    ldaddal x1, x0, [x0]
    ret
    ldclral x1, x0, [x0]
    ret
    ldeoral x1, x0, [x0]
    ret
    ldsetal x1, x0, [x0]
    ret
    ldsmaxal x1, x0, [x0]
    ret
    ldsminal x1, x0, [x0]
    ret
    ldumaxal x1, x0, [x0]
    ret
    lduminal x1, x0, [x0]
    ret
    swpal x1, x0, [x0]
    ret
_gm_memory_atomic_references_end:

// Caller-saved SIMD register harness for our one-instruction structure fixtures.
.globl _gm_memory_structure_call
_gm_memory_structure_call:
    stp x29, x30, [sp, #-32]!
    stp x19, x20, [sp, #16]
    mov x19, x3
    mov x20, x0
    mov x0, x1
    mov x1, x2
    ldp q0, q1, [x19]
    ldp q2, q3, [x19, #32]
    ldp q30, q31, [x19, #64]
    blr x20
    stp q0, q1, [x19]
    stp q2, q3, [x19, #32]
    stp q30, q31, [x19, #64]
    ldp x19, x20, [sp, #16]
    ldp x29, x30, [sp], #32
    ret

.macro structure_multiple arr, bytes
    ld1 {v0.\arr}, [x0]
    ret
    st1 {v0.\arr}, [x0]
    ret
    ld1 {v0.\arr, v1.\arr}, [x0]
    ret
    st1 {v0.\arr, v1.\arr}, [x0]
    ret
    ld1 {v0.\arr, v1.\arr, v2.\arr}, [x0]
    ret
    st1 {v0.\arr, v1.\arr, v2.\arr}, [x0]
    ret
    ld1 {v30.\arr, v31.\arr, v0.\arr, v1.\arr}, [x0], x1
    ret
    st1 {v30.\arr, v31.\arr, v0.\arr, v1.\arr}, [x0], #(4*\bytes)
    ret
    ld2 {v0.\arr, v1.\arr}, [x0]
    ret
    st2 {v0.\arr, v1.\arr}, [x0], x1
    ret
    ld3 {v0.\arr, v1.\arr, v2.\arr}, [x0], #(3*\bytes)
    ret
    st3 {v0.\arr, v1.\arr, v2.\arr}, [x0]
    ret
    ld4 {v30.\arr, v31.\arr, v0.\arr, v1.\arr}, [x0], x1
    ret
    st4 {v0.\arr, v1.\arr, v2.\arr, v3.\arr}, [x0], #(4*\bytes)
    ret
.endm
.macro structure_lane kind, last, bytes
    ld1 {v0.\kind}[0], [x0]
    ret
    st1 {v0.\kind}[\last], [x0], x1
    ret
    ld2 {v0.\kind, v1.\kind}[\last], [x0], #(2*\bytes)
    ret
    st2 {v0.\kind, v1.\kind}[0], [x0]
    ret
    ld3 {v0.\kind, v1.\kind, v2.\kind}[0], [x0], x1
    ret
    st3 {v0.\kind, v1.\kind, v2.\kind}[\last], [x0], #(3*\bytes)
    ret
    ld4 {v30.\kind, v31.\kind, v0.\kind, v1.\kind}[\last], [x0]
    ret
    st4 {v30.\kind, v31.\kind, v0.\kind, v1.\kind}[0], [x0], x1
    ret
.endm
.macro structure_replicate arr, bytes
    ld1r {v0.\arr}, [x0]
    ret
    ld2r {v0.\arr, v1.\arr}, [x0], x1
    ret
    ld3r {v0.\arr, v1.\arr, v2.\arr}, [x0], #(3*\bytes)
    ret
    ld4r {v30.\arr, v31.\arr, v0.\arr, v1.\arr}, [x0]
    ret
.endm
.globl _gm_memory_structure_references
.globl _gm_memory_structure_references_end
_gm_memory_structure_references:
    structure_multiple 8b, 8
    structure_multiple 16b, 16
    structure_multiple 4h, 8
    structure_multiple 8h, 16
    structure_multiple 2s, 8
    structure_multiple 4s, 16
    structure_multiple 2d, 16
    ld1 {v0.1d, v1.1d, v2.1d, v3.1d}, [x0], #32
    ret
    st1 {v0.1d, v1.1d, v2.1d}, [x0], x1
    ret
    structure_lane b, 15, 1
    structure_lane h, 7, 2
    structure_lane s, 3, 4
    structure_lane d, 1, 8
    structure_replicate 8b, 1
    structure_replicate 16b, 1
    structure_replicate 4h, 2
    structure_replicate 8h, 2
    structure_replicate 2s, 4
    structure_replicate 4s, 4
    structure_replicate 1d, 8
    structure_replicate 2d, 8
_gm_memory_structure_references_end:
