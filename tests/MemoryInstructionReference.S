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
