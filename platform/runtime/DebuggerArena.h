#pragma once
#include "NativeCodeMemory.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdio.h>

// Executable memory from a debugger outside the app.

// Only with a debugger attached: an unserviced trap kills us.
bool da_debugger_present(void);
// An unserviced request leaves the breakpoint encoding, not a null.
bool da_plausible_region(const void *address);
// Request one arena and adopt it, with its writable alias.
bool da_request_arena(NativeCodeMemory *memory, size_t size, FILE *log);
// Adopt a region the enabler granted, or give it back.
bool da_adopt_region(NativeCodeMemory *memory, void *region, size_t size, FILE *log);
// Ask the debugger to detach; report whether execute survived.
bool da_release_debugger(const NativeCodeMemory *memory, FILE *log);
// Guest entry: nothing attached, and the arena executes.
bool da_entry_allowed(const NativeCodeMemory *memory, FILE *log);
// Test support: answer the attachment question with this instead.
void da_attachment_probe(bool (*probe)(void));
