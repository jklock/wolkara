// Original synthetic frame that requires DWARF rather than compact unwind.
.text
.p2align 2
.globl _fixture_dwarf
_fixture_dwarf:
    .cfi_startproc
    sub sp, sp, #80
    .cfi_def_cfa_offset 80
    str x30, [sp, #40]
    .cfi_offset w30, -40
    blr x0
    ldr x30, [sp, #40]
    .cfi_restore w30
    add sp, sp, #80
    .cfi_def_cfa_offset 0
    ret
    .cfi_endproc
