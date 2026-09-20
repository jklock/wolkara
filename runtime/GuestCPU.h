#pragma once
#include "GuestMemory.h"

// Feasibility backend, not a complete AArch64 CPU. Every unsupported instruction
// stops at its original PC. No generated instructions are executed by the host.
typedef enum { GC_BUDGET, GC_RETURNED, GC_UNSUPPORTED, GC_MEMORY } GCResult;
typedef struct {
    uint64_t pc, immediate;
    uint32_t instruction;
    uint8_t op, rd, rn, rm, ra, width, shift, amount, flags;
    bool valid;
} GCDecoded;
enum { GC_CACHE_SIZE = 4096 };
typedef struct {
    uint64_t x[31], sp, pc, retired;
    uint8_t nzcv; // N Z C V in bits 3..0.
    GMThread thread;
    GMResult memory_result;
    uint32_t fault_instruction;
    uint64_t cache_generation;
    bool cache_write_protected;
    GCDecoded cache[GC_CACHE_SIZE];
} GuestCPU;

// One CPU per thread. GuestMemory currently needs external serialization for
// multi-threaded access. Reset CPU whenever the backing GuestMemory is replaced.
void gc_reset(GuestCPU *cpu, uint64_t entry, uint64_t stack);
GCResult gc_run(GuestCPU *cpu, GuestMemory *memory, uint64_t budget, uint64_t return_pc);
const char *gc_result_string(GCResult result);
