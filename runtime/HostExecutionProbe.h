#pragma once
#include <stdbool.h>
#include <stdio.h>

typedef enum { HP_WRITE_THEN_EXECUTE, HP_READ_WRITE_EXECUTE, HP_DUAL_MAPPING } HPMode;
typedef struct {
    bool executable;
    bool rewrite_executable;
    int allocation_errno, protection_errno;
    int first_value, rewritten_value;
} HPResult;
// Opt-in diagnostic: executes only our two-instruction arm64 sample. A kernel
// code-signing rejection can terminate the process; stage logs are flushed first.
// A passing result applies to this process/launch mode only, not future launches.
HPResult host_execution_probe(HPMode mode, FILE *log);
