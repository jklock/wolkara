#pragma once
// Replacements for imports nothing on this system provides.
#define GS_SLOTS 8192

#ifndef __ASSEMBLER__
#include <stdbool.h>
#include <stdio.h>

typedef enum { GS_FUNCTION, GS_DATA, GS_CLASS, GS_METACLASS } GSKind;

// A guess: the bind stream says what, not what kind.
GSKind gs_kind(const char *symbol);
// With lazy pointers the image says which; otherwise the name.
GSKind gs_kind_bound(const char *symbol, bool image_binds_lazily, bool bound_lazily);
// Where to bind this symbol; the same address each time.
void *gs_bind(const char *symbol, GSKind kind);
unsigned gs_capacity(void);
unsigned gs_used(void);
// Where a stub's first call is reported; unset means stderr.
void gs_log(FILE *log);
// Test support: forget every stub; handed-out addresses stay valid.
void gs_reset(void);
// Called by the trampolines with their own slot number.
long gs_called(unsigned slot);
#endif
