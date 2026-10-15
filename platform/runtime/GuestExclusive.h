#pragma once
#include "GuestCPU.h"
#include "GuestMemoryInstruction.h"

typedef bool (*GMInstructionFetch)(uint64_t pc, uint32_t *instruction, void *context);
typedef struct {
    uint64_t pc;
    const char *reason;
} GMExclusiveDiagnostic;
bool gm_exclusive_instruction(uint32_t instruction);
// Execute a bounded exclusive sequence as one runtime operation. No monitor
// survives a return to native execution. An isolated store-exclusive fails.
// Unsupported sequences leave registers and memory unchanged.
GMMemoryStep gm_exclusive_sequence(GMSparseMemory *memory, uint32_t first,
                                   GCRegisters *registers, GMInstructionFetch fetch,
                                   void *context, GMResult *fault, GMExclusiveDiagnostic *diagnostic);
