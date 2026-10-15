// One trampoline per stub, eight bytes, index in x16.
#include "GuestStubs.h"
#if defined(__arm64__) || defined(__aarch64__)
.text
.p2align 2
.globl _gs_slot_table
_gs_slot_table:
.set gs_index, 0
.rept GS_SLOTS
    movz x16, #gs_index
    b _gs_trampoline
.set gs_index, gs_index + 1
.endr

.p2align 2
_gs_trampoline:
    mov x0, x16
    b _gs_called
#endif
