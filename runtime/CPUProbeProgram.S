// Our own benchmark program. Also copied as bytes into non-executable guest
// storage, then interpreted. Native execution is only a comparison baseline.
.text
.p2align 2
.globl _gc_probe_program
.globl _gc_probe_program_end
_gc_probe_program:
    movz x2, #0x660d
    movk x2, #0x19, lsl #16
    movz x3, #0xf35f
    movk x3, #0x3c6e, lsl #16
    cbz x0, 2f
1:
    madd x1, x1, x2, x3
    eor x1, x1, x1, lsr #13
    subs x0, x0, #1
    b.ne 1b
2:
    mov x0, x1
    ret
_gc_probe_program_end:

.p2align 2
.globl _gc_probe_memory_program
.globl _gc_probe_memory_program_end
_gc_probe_memory_program:
    cbz x0, 2f
1:
    str x1, [x2]
    ldr x3, [x2]
    add x1, x3, #1
    subs x0, x0, #1
    b.ne 1b
2:
    mov x0, x1
    ret
_gc_probe_memory_program_end:
