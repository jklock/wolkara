#include "GuestMemoryInstruction.h"
#include <string.h>

static uint64_t extend(uint64_t value, unsigned bits) {
    uint64_t sign = UINT64_C(1) << (bits - 1);
    return (value ^ sign) - sign;
}
static uint64_t get(const GMMemoryRegisters *r, unsigned index, bool stack) {
    return index < 31 ? r->x[index] : stack ? r->sp : 0;
}
static void scalar_bytes(unsigned char *out, uint64_t value, unsigned size) {
    for (unsigned i = 0; i < size; ++i) out[i] = (unsigned char)(value >> (i * 8));
}
static uint64_t scalar_value(const unsigned char *bytes, unsigned size) {
    uint64_t value = 0;
    for (unsigned i = 0; i < size; ++i) value |= (uint64_t)bytes[i] << (i * 8);
    return value;
}
static GMMemoryStep atomic_step(GMSparseMemory *m, uint32_t instruction,
                                GMMemoryRegisters *r, GMResult *fault) {
    unsigned rt = instruction & 31, rn = (instruction >> 5) & 31;
    unsigned rs = (instruction >> 16) & 31, size = 1u << (instruction >> 30);
    uint64_t address = get(r, rn, true), previous = 0;
    if ((instruction & 0xbfa07c00) == 0x08207c00) {
        // CASP operates on two adjacent registers and one aligned memory pair.
        if ((rs & 1) || (rt & 1)) return GM_STEP_UNSUPPORTED;
        size = (instruction & (1u << 30)) ? 8 : 4;
        unsigned char expected[16], desired[16], old[16];
        for (unsigned j = 0; j < 2; ++j) {
            scalar_bytes(expected + j * size, get(r, rs + j, false), size);
            scalar_bytes(desired + j * size, get(r, rt + j, false), size);
        }
        *fault = gm_sparse_compare_exchange(m, address, expected, desired, old, size * 2);
        if (*fault != GM_OK) return GM_STEP_FAULT;
        for (unsigned j = 0; j < 2; ++j)
            if (rs + j != 31) r->x[rs + j] = scalar_value(old + j * size, size);
    } else if ((instruction & 0x3fa07c00) == 0x08a07c00) {
        unsigned char expected[8], desired[8], old[8];
        scalar_bytes(expected, get(r, rs, false), size);
        scalar_bytes(desired, get(r, rt, false), size);
        *fault = gm_sparse_compare_exchange(m, address, expected, desired, old, size);
        if (*fault != GM_OK) return GM_STEP_FAULT;
        previous = scalar_value(old, size);
        if (rs != 31) r->x[rs] = previous;
    } else if ((instruction & 0x3f200c00) == 0x38200000) {
        unsigned op = (instruction >> 12) & 15;
        if (op > 8) return GM_STEP_UNSUPPORTED;
        *fault = gm_sparse_atomic(m, address, size, (GMSparseAtomic)op,
                                  get(r, rs, false), &previous);
        if (*fault != GM_OK) return GM_STEP_FAULT;
        if (rt != 31) r->x[rt] = previous;
    } else return GM_STEP_UNSUPPORTED;
    r->pc += 4;
    return GM_STEP_OK;
}

GMMemoryStep gm_memory_step(GMSparseMemory *memory, uint32_t instruction,
                            GMMemoryRegisters *r, GMResult *fault) {
    if (!r || !fault) return GM_STEP_UNSUPPORTED;
    unsigned rt = instruction & 31, rn = (instruction >> 5) & 31;
    unsigned size = 0, rt2 = 0, destination_width = 64;
    bool load = false, vector = (instruction >> 26) & 1, pair = false;
    bool sign = false, writeback = false;
    uint64_t address = get(r, rn, true), newbase = address;
    if (r->pc > UINT64_MAX - 4 || (r->pc & 3) || (rn == 31 && (r->sp & 15))) {
        *fault = GM_INVALID; return GM_STEP_FAULT;
    }
    bool rcpc_load = (instruction & 0x3ffffc00) == 0x38bfc000;
    if (!rcpc_load && ((instruction & 0xbfa07c00) == 0x08207c00 ||
        (instruction & 0x3fa07c00) == 0x08a07c00 ||
        (instruction & 0x3f200c00) == 0x38200000))
        return atomic_step(memory, instruction, r, fault);
    if (rcpc_load || (instruction & 0x3f9ffc00) == 0x089ffc00) {
        // LDAR/STLR/LDAPR: the backing lock provides acquire/release ordering,
        // which is also sufficient for LDAPR's weaker RCpc acquire requirement.
        size = 1u << (instruction >> 30);
        load = rcpc_load || ((instruction >> 22) & 1);
        if (address % size) { *fault = GM_INVALID; return GM_STEP_FAULT; }
    } else if ((instruction & 0x3b000000) == 0x39000000 ||
               (instruction & 0x3b000000) == 0x38000000) {
        // Scalar and SIMD/FP load/store immediate and register addressing.
        unsigned scale = instruction >> 30, opc = (instruction >> 22) & 3;
        if (vector) {
            if (opc >= 2) {
                if (scale != 0) return GM_STEP_UNSUPPORTED;
                size = 16;
            } else size = 1u << scale;
            load = opc & 1;
        } else {
            size = 1u << scale;
            if (opc >= 2) {
                if (scale == 3 || (scale == 2 && opc == 3)) return GM_STEP_UNSUPPORTED;
                sign = true; load = true; destination_width = opc == 3 ? 32 : 64;
            } else load = opc == 1;
        }
        if (instruction & (1u << 24)) {
            address += (uint64_t)((instruction >> 10) & 4095) * size;
        } else {
            unsigned mode = (instruction >> 10) & 3;
            if (instruction & (1u << 21)) {
                unsigned option = (instruction >> 13) & 7;
                if (mode != 2 || !(option & 2)) return GM_STEP_UNSUPPORTED;
                uint64_t offset = get(r, (instruction >> 16) & 31, false);
                if (!(option & 1)) offset &= UINT32_MAX;
                if (option == 6) offset = extend(offset, 32);
                address += offset * ((instruction & (1u << 12)) ? size : 1);
            } else {
                if (vector && mode == 2) return GM_STEP_UNSUPPORTED;
                uint64_t offset = extend((instruction >> 12) & 511, 9);
                newbase += offset;
                if (mode != 1) address = newbase;
                writeback = mode == 1 || mode == 3;
                if (writeback && !vector && rn != 31 && rn == rt) return GM_STEP_UNSUPPORTED;
            }
        }
    } else if ((instruction & 0x3a000000) == 0x28000000) {
        // Pair accesses, including pre/post-index and non-temporal forms.
        unsigned opc = instruction >> 30, mode = (instruction >> 23) & 3;
        load = (instruction >> 22) & 1;
        rt2 = (instruction >> 10) & 31;
        if (vector) {
            if (opc == 3) return GM_STEP_UNSUPPORTED;
            size = 4u << opc;
        } else if (opc == 0) size = 4;
        else if (opc == 2) size = 8;
        else if (opc == 1 && load && mode != 0) { size = 4; sign = true; }
        else return GM_STEP_UNSUPPORTED;
        writeback = mode == 1 || mode == 3;
        if (load && rt == rt2) return GM_STEP_UNSUPPORTED;
        if (writeback && !vector && rn != 31 && (rn == rt || rn == rt2)) return GM_STEP_UNSUPPORTED;
        uint64_t offset = extend((instruction >> 15) & 127, 7) * size;
        newbase += offset;
        if (mode != 1) address = newbase;
        pair = true;
    } else return GM_STEP_UNSUPPORTED;
    unsigned char bytes[32] = {0};
    unsigned count = pair ? 2 : 1;
    for (unsigned i = 0; !load && i < count; ++i) {
        unsigned index = i ? rt2 : rt;
        if (vector) memcpy(bytes + i * size, r->vector[index], size);
        else scalar_bytes(bytes + i * size, get(r, index, false), size);
    }
    *fault = load ? gm_sparse_read(memory, address, bytes, count * size) :
                    gm_sparse_write(memory, address, bytes, count * size);
    if (*fault != GM_OK) return GM_STEP_FAULT;
    for (unsigned i = 0; load && i < count; ++i) {
        unsigned index = i ? rt2 : rt;
        if (vector) {
            memset(r->vector[index], 0, 16);
            memcpy(r->vector[index], bytes + i * size, size);
        } else if (index != 31) {
            uint64_t value = scalar_value(bytes + i * size, size);
            if (sign) value = extend(value, size * 8);
            if (destination_width == 32) value &= UINT32_MAX;
            r->x[index] = value;
        }
    }
    if (writeback) {
        if (rn == 31) r->sp = newbase;
        else r->x[rn] = newbase;
    }
    r->pc += 4;
    return GM_STEP_OK;
}
