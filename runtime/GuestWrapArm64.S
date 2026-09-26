// One trampoline per wrapped call, eight bytes, index in x16.
#include "GuestWrap.h"
#if defined(__arm64__) || defined(__aarch64__)
.text
.p2align 2
.globl _gw_slot_table
_gw_slot_table:
.set gw_index, 0
.rept GW_SLOTS
    movz x16, #gw_index
    b _gw_trampoline
.set gw_index, gw_index + 1
.endr

// Logs the entry, calls the wrapped function, logs the result and returns.
// The frame lives across the call, so an argument passed on the stack (none
// in the C interfaces this wraps) would sit at the wrong offset.
// Layout: x0-x7 at 0, x8 and the caller's return address at 64, the slot at
// 80, q0-q7 at 96.
.p2align 2
_gw_trampoline:
    sub sp, sp, #224
    stp x0, x1, [sp, #0]
    stp x2, x3, [sp, #16]
    stp x4, x5, [sp, #32]
    stp x6, x7, [sp, #48]
    stp x8, x30, [sp, #64]
    str x16, [sp, #80]
    stp q0, q1, [sp, #96]
    stp q2, q3, [sp, #128]
    stp q4, q5, [sp, #160]
    stp q6, q7, [sp, #192]
    mov x0, x16
    mov x1, sp
    bl _gw_enter
    mov x16, x0
    ldp x0, x1, [sp, #0]
    ldp x2, x3, [sp, #16]
    ldp x4, x5, [sp, #32]
    ldp x6, x7, [sp, #48]
    ldr x8, [sp, #64]
    ldp q0, q1, [sp, #96]
    ldp q2, q3, [sp, #128]
    ldp q4, q5, [sp, #160]
    ldp q6, q7, [sp, #192]
    blr x16
    stp x0, x1, [sp, #0]
    stp q0, q1, [sp, #96]
    stp q2, q3, [sp, #128]
    ldr x1, [sp, #0]
    ldr x0, [sp, #80]
    bl _gw_returned
    ldp x0, x1, [sp, #0]
    ldp q0, q1, [sp, #96]
    ldp q2, q3, [sp, #128]
    ldr x30, [sp, #72]
    add sp, sp, #224
    ret
#endif
