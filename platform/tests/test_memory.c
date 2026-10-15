#include "DarwinMemory.h"
#include "MemoryProbe.h"
#include <assert.h>
#include <inttypes.h>
#include <stdio.h>
#include <string.h>

#define BASE UINT64_C(0x100000000)
#define PAGE GM_PAGE_SIZE
static void ranges_and_faults(void) {
    GuestMemory m = {0}; GMThread t = {0};
    assert(gm_map(&m, BASE, 3 * PAGE, 3, 7, false, false) == GM_OK);
    unsigned char input[16], output[16]; memset(input, 0x53, sizeof input);
    uint64_t cross = BASE + PAGE - 8;
    assert(gm_write(&m, &t, cross, input, 16) == GM_OK);
    assert(gm_read(&m, cross, output, 16) == GM_OK && !memcmp(input, output, 16));
    assert(gm_protect(&m, BASE + PAGE, PAGE, GM_READ) == GM_OK);
    memset(input, 0x99, 16);
    assert(gm_write(&m, &t, cross, input, 16) == GM_PROTECTION);
    assert(m.fault_address == BASE + PAGE);
    assert(gm_read(&m, cross, output, 16) == GM_OK);
    for (int i = 0; i < 16; i++) assert(output[i] == 0x53); // no partial write
    assert(gm_read(&m, 0, output, 1) == GM_UNMAPPED);
    assert(gm_read(&m, UINT64_MAX - 3, output, 8) == GM_INVALID);
    assert(gm_map(&m, BASE + 1, PAGE, 3, 7, false, false) == GM_INVALID);
    assert(gm_map(&m, BASE, 0, 3, 7, false, false) == GM_INVALID);
    assert(gm_map(&m, BASE, PAGE, 8, 7, false, false) == GM_INVALID);
    assert(gm_map(&m, BASE, PAGE, 3, 7, false, false) == GM_OVERLAP);
    assert(gm_unmap(&m, BASE + PAGE, PAGE) == GM_OK);
    assert(gm_protect(&m, BASE, 3 * PAGE, GM_EXEC) == GM_UNMAPPED);
    assert(gm_write(&m, &t, BASE, input, 16) == GM_OK); // protect was atomic
    assert(gm_map(&m, BASE + PAGE, PAGE, GM_READ, GM_READ, false, false) == GM_OK);
    assert(gm_protect(&m, BASE, 3 * PAGE, GM_WRITE) == GM_PROTECTION);
    assert(gm_write(&m, &t, BASE, input, 16) == GM_OK);
    assert(gm_unmap(&m, BASE, 3 * PAGE) == GM_OK && m.count == 0);
    gm_destroy(&m);
}
static void zero_fill_replace_and_find(void) {
    GuestMemory m = {0}; unsigned char data[4] = {1, 2, 3, 4}, out[4];
    assert(gm_map(&m, BASE, 3 * PAGE, 3, 7, false, false) == GM_OK);
    assert(!m.pages[0].bytes && !m.pages[1].bytes && !m.pages[2].bytes);
    assert(gm_read(&m, BASE, out, 4) == GM_OK && !memcmp(out, "\0\0\0\0", 4));
    assert(!m.pages[0].bytes); // zero reads do not materialize backing pages
    assert(gm_write(&m, NULL, BASE, data, 4) == GM_OK);
    assert(gm_write(&m, NULL, BASE + PAGE, data, 4) == GM_OK);
    assert(gm_write(&m, NULL, BASE + 2 * PAGE, data, 4) == GM_OK);
    assert(gm_map(&m, BASE + PAGE, PAGE, 3, 7, false, true) == GM_OK);
    assert(gm_read(&m, BASE + PAGE, out, 4) == GM_OK && !memcmp(out, "\0\0\0\0", 4));
    assert(gm_read(&m, BASE, out, 4) == GM_OK && !memcmp(out, data, 4));
    assert(gm_read(&m, BASE + 2 * PAGE, out, 4) == GM_OK && !memcmp(out, data, 4));
    uint64_t address;
    assert(gm_find_free(&m, BASE, PAGE, &address) == GM_OK && address == BASE + 3 * PAGE);
    assert(gm_unmap(&m, BASE + PAGE, PAGE) == GM_OK);
    assert(gm_find_free(&m, BASE, PAGE, &address) == GM_OK && address == BASE + PAGE);
    assert(gm_find_free(&m, BASE, 2 * PAGE, &address) == GM_OK && address == BASE + 3 * PAGE);
    gm_destroy(&m);
}
static void darwin_jit(void) {
    DarwinMemory d = {.thread = {.jit_write_protected = true}};
    unsigned flags = GD_MAP_PRIVATE | GD_MAP_ANON | GD_MAP_JIT;
    uint64_t a = gd_mmap(&d, 0, 1, 7, flags, -1, 0);
    assert(a != UINT64_MAX && !(a % PAGE));
    // MOV W0, #42; RET -- bytes remain guest data, never host machine code.
    unsigned char code[] = {0x40,0x05,0x80,0x52, 0xc0,0x03,0x5f,0xd6};
    uint32_t insn;
    assert(gm_write(&d.memory, &d.thread, a, code, sizeof code) == GM_PROTECTION);
    gd_jit_write_protect(&d, false);
    assert(gm_write(&d.memory, &d.thread, a, code, sizeof code) == GM_OK);
    assert(gm_fetch(&d.memory, &d.thread, a, &insn) == GM_PROTECTION);
    gd_jit_write_protect(&d, true);
    assert(gm_fetch(&d.memory, &d.thread, a, &insn) == GM_OK && insn == 0x52800540);
    assert(gm_fetch(&d.memory, &d.thread, a + 4, &insn) == GM_OK && insn == 0xd65f03c0);
    assert(gm_fetch(&d.memory, &d.thread, a + 1, &insn) == GM_INVALID);
    GMThread other = {.jit_write_protected = false};
    assert(gm_write(&d.memory, &other, a, code, sizeof code) == GM_OK); // per-thread state
    assert(gm_write(&d.memory, &d.thread, a, code, sizeof code) == GM_PROTECTION);
    assert(gd_mprotect(&d, a, 1, GM_READ) == 0);
    assert(gm_fetch(&d.memory, &d.thread, a, &insn) == GM_PROTECTION);
    assert(gd_mmap(&d, a, PAGE, 7, flags | GD_MAP_FIXED, -1, 0) == a);
    assert(gm_fetch(&d.memory, &d.thread, a, &insn) == GM_OK && insn == 0);
    assert(gd_munmap(&d, a, 1) == 0);
    assert(gm_fetch(&d.memory, &d.thread, a, &insn) == GM_UNMAPPED);
    assert(gd_mmap(&d, 0, 0, 7, flags, -1, 0) == UINT64_MAX && d.error == 22);
    assert(gd_mmap(&d, 0, UINT64_MAX, 7, flags, -1, 0) == UINT64_MAX);
    assert(gd_mmap(&d, 0, PAGE, 7, flags | GD_MAP_FIXED, -1, 0) == UINT64_MAX);
    assert(gd_mmap(&d, 0, PAGE, 7, GD_MAP_PRIVATE, 0, 0) == UINT64_MAX && d.error == 45);
    assert(gd_mmap(&d, 0, PAGE, 7, flags | 0x40000000, -1, 0) == UINT64_MAX);
    gm_destroy(&d.memory);
}
int main(void) {
    ranges_and_faults(); zero_fill_replace_and_find(); darwin_jit();
    char error[256];
    assert(guest_memory_probe(error, sizeof error));
    puts("PASS: soft-MMU ranges, atomic faults, zero fill, fixed remaps, protections, per-thread JIT, instruction fetch");
}
