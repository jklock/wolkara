// Standalone mmap capacity reproducer; no guest code, debugger, or page writes.
// Call tk_vm_capacity_report(stdout) from an iPad app with the ordinary memory
// entitlements. Define TK_VM_CAPACITY_MAIN for a command-line build on macOS.
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <sys/mman.h>

_Static_assert(sizeof(size_t) == 8, "This reproducer requires a 64-bit target");

int tk_vm_capacity_report(FILE *output) {
    const size_t gib = (size_t)1 << 30;
    const size_t sizes[] = {16 * gib, 64 * gib, 32 * gib};
    void *held[3] = {MAP_FAILED, MAP_FAILED, MAP_FAILED};
    int failures = 0;
    for (size_t i = 0; i < 3; ++i) {
        held[i] = mmap(NULL, sizes[i], PROT_READ | PROT_WRITE,
                       MAP_PRIVATE | MAP_ANON, -1, 0);
        int error = held[i] == MAP_FAILED ? errno : 0;
        if (held[i] == MAP_FAILED) ++failures;
        fprintf(output, "request %zu: %zu GiB -> %p errno=%d\n",
                i + 1, sizes[i] / gib, held[i], error);
    }
    for (size_t i = 0; i < 3; ++i) {
        if (held[i] != MAP_FAILED && munmap(held[i], sizes[i])) {
            fprintf(output, "release %zu: errno=%d\n", i + 1, errno);
            ++failures;
        }
    }
    return failures;
}

#ifdef TK_VM_CAPACITY_MAIN
int main(void) {
    return tk_vm_capacity_report(stdout) ? 1 : 0;
}
#endif
