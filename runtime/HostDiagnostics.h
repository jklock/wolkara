#pragma once
#include "HostExecutionProbe.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

// Read-only facts about our own process, before trusting a run.
typedef struct {
    bool debugger_attached;       // a debugger is attached right now
    bool code_signing_known;      // the status query itself succeeded
    uint32_t code_signing_flags;
    bool debugged;                // CS_DEBUGGED: survives the debugger detaching
    uint64_t physical_memory;
    uint64_t footprint;           // what the system counts against our limit
    int64_t available_memory;     // left before this process is killed; -1 unknown
    size_t page_size;
    size_t arena_limit;           // largest arena the runtime will prepare
    bool execution_probed;
    HPResult write_then_execute, read_write_execute, dual_mapping;
} HostDiagnostics;

// Collect the facts; executing the probe sample is opt-in.
void hd_collect(HostDiagnostics *report, bool probe_execution, FILE *log);
// Readable report, NUL-terminated; returns the length it wanted.
size_t hd_format(const HostDiagnostics *report, char *out, size_t size);
// Whether this process may run unsigned code (CS_DEBUGGED).
bool hd_may_run_unsigned_code(void);
// Whether a debugger is attached now, not merely was.
bool hd_debugger_attached(void);
// Protection of the mapping at this address, 0 when unknown.
unsigned hd_protection(const void *address);
// Whether that mapping really is executable now.
bool hd_is_executable(const void *address);
