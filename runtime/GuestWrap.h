#pragma once
// Logs calls through function pointers the guest resolved with dlsym.
#define GW_SLOTS 64

#ifndef __ASSEMBLER__
#include <stdio.h>

// The address to hand out for name: a logging trampoline around target.
// The same name and target wrap once. Returns target unchanged when the
// table is full or name or target is null.
void *gw_wrap(const char *name, void *target);
unsigned gw_used(void);
// Where calls are reported; unset means stderr.
void gw_log(FILE *log);
// Test support: forget every wrap; handed-out addresses stay valid.
void gw_reset(void);
// Called by the trampolines: slot, and the saved registers (x0-x7, x8, the
// caller's return address). gw_enter answers the function to call.
void *gw_enter(unsigned slot, const unsigned long *frame);
void gw_returned(unsigned slot, void *result);
#endif
