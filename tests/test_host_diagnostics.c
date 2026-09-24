#include "HostDiagnostics.h"
#include "NativeCodeMemory.h"
#include <assert.h>
#include <mach/mach.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>
#include <unistd.h>

int main(void) {
    HostDiagnostics report;
    // No probe: collecting facts must never execute generated code.
    hd_collect(&report, false, NULL);
    assert(!report.execution_probed);
    assert(report.page_size == (size_t)getpagesize());
    // What may be prepared follows the system, under the ceiling.
    assert(report.arena_limit == nc_arena_limit() && report.arena_limit <= NC_MAX_ARENA);
    assert(!(report.arena_limit % (size_t)getpagesize()));
    assert(report.physical_memory > 0);
    assert(report.footprint > 0);

    char small[16];
    memset(small, 'x', sizeof small);
    size_t wanted = hd_format(&report, small, sizeof small);
    assert(wanted > sizeof small);            // truncation is reported, not hidden
    assert(strnlen(small, sizeof small) < sizeof small);

    char text[4096];
    size_t written = hd_format(&report, text, sizeof text);
    assert(written == wanted && written < sizeof text);
    assert(strstr(text, "debugger attached now"));
    assert(strstr(text, "largest guest arena"));
    assert(strstr(text, "not probed"));       // the probe results are opt-in

    // Protections are read from the mapping itself.
    size_t page = (size_t)getpagesize();
    void *writable = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(writable != MAP_FAILED);
    assert((hd_protection(writable) & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE));
    assert(!hd_is_executable(writable));
    assert(hd_is_executable((const void *)(uintptr_t)&main));
    assert(!hd_protection(NULL));
    assert(munmap(writable, page) == 0);

    puts("PASS: host diagnostics collection, bounded report, mapping protections (no generated code executed)");
}
