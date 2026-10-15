#include "MemoryProbe.h"
#include "DarwinMemory.h"
#include <stdio.h>

bool guest_memory_probe(char *error, size_t error_size) {
    DarwinMemory d = {.thread = {.jit_write_protected = true}};
    const unsigned flags = GD_MAP_PRIVATE | GD_MAP_ANON | GD_MAP_JIT;
    unsigned char code[] = {0x40, 0x05, 0x80, 0x52, 0xc0, 0x03, 0x5f, 0xd6};
    uint32_t insn = 0;
    const char *failure = NULL;
    uint64_t a = gd_mmap(&d, 0, GM_PAGE_SIZE, 7, flags, -1, 0);
#define CHECK(condition, message) if (!(condition)) { failure = message; goto done; }
    CHECK(a != UINT64_MAX, "guest MAP_JIT allocation failed");
    CHECK(gm_write(&d.memory, &d.thread, a, code, sizeof code) == GM_PROTECTION, "JIT write protection was not enforced");
    gd_jit_write_protect(&d, false);
    CHECK(gm_write(&d.memory, &d.thread, a, code, sizeof code) == GM_OK, "guest code write failed");
    CHECK(gm_fetch(&d.memory, &d.thread, a, &insn) == GM_PROTECTION, "JIT execute protection was not enforced");
    gd_jit_write_protect(&d, true);
    CHECK(gm_fetch(&d.memory, &d.thread, a, &insn) == GM_OK && insn == 0x52800540, "guest code fetch failed");
    CHECK(gd_mprotect(&d, a, GM_PAGE_SIZE, GM_READ) == 0, "guest mprotect failed");
    CHECK(gm_fetch(&d.memory, &d.thread, a, &insn) == GM_PROTECTION, "non-executable fetch was allowed");
    CHECK(gd_mmap(&d, a, GM_PAGE_SIZE, 7, flags | GD_MAP_FIXED, -1, 0) == a, "fixed-address JIT remap failed");
    CHECK(gm_fetch(&d.memory, &d.thread, a, &insn) == GM_OK && insn == 0, "remapped page was not zero-filled");
    CHECK(gd_munmap(&d, a, GM_PAGE_SIZE) == 0, "guest munmap failed");
    CHECK(gm_fetch(&d.memory, &d.thread, a, &insn) == GM_UNMAPPED, "unmapped instruction fetch was allowed");
done:
    gm_destroy(&d.memory);
    if (failure) snprintf(error, error_size, "%s", failure);
    return !failure;
#undef CHECK
}
