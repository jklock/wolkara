// Host-owned immutable sample pages, covered by the ordinary app signature.
// No guest bytes and no generated executable memory in this experiment.
.section __TEXT,__text,regular,pure_instructions
.p2align 14
.globl _HostSignedPageA
_HostSignedPageA:
    mov w0, #42
    ret
.space 16384 - 8
.p2align 14
.globl _HostSignedPageB
_HostSignedPageB:
    mov w0, #1337
    ret
.space 16384 - 8
