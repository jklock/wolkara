#include "DebuggerArena.h"
#include "HostDiagnostics.h"
#include <assert.h>
#include <mach/mach.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static unsigned asked;
// Attached and staying: the launch has no way in.
static bool holds_on(void) { asked++; return true; }
// Attached, then gone once asked.
static bool lets_go(void) { return asked++ == 0; }

int main(void) {
    size_t page = (size_t)getpagesize();
    // An unserviced request leaves the breakpoint encoding, not a null.
    assert(!da_plausible_region(NULL));
    assert(!da_plausible_region((const void *)(uintptr_t)-1));
    assert(!da_plausible_region((const void *)(uintptr_t)0x690000e0ull));
    assert(!da_plausible_region((const void *)(uintptr_t)0xcccccccc690000e0ull));
    assert(!da_plausible_region((const void *)(uintptr_t)(page + 8)));
    assert(da_plausible_region((const void *)(uintptr_t)(page * 4)));

    // With nothing attached the protocol must refuse, not trap.
    NativeCodeMemory arena = {0};
    assert(!da_request_arena(&arena, page, NULL));
    assert(!arena.executable && !arena.writable && !arena.published);
    assert(!da_release_debugger(&arena, NULL));
    assert(!da_entry_allowed(&arena, NULL));

    // What the external path falls back to.
    void *mapped = mmap(NULL, page, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    void *runs = mapped == MAP_FAILED ? (void *)(uintptr_t)&main : mapped;
    NativeCodeMemory fallback = {.executable = runs, .size = page, .published = true};
    void *writable = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(writable != MAP_FAILED);
    NativeCodeMemory unexecutable = {.executable = writable, .size = page, .published = true};
    assert(da_entry_allowed(&fallback, NULL));
    assert(!da_entry_allowed(&unexecutable, NULL));

    // A refused request, with a debugger that holds on.
    asked = 0; da_attachment_probe(holds_on);
    NativeCodeMemory refused = {0};
    assert(!da_request_arena(&refused, page, NULL));
    assert(!da_entry_allowed(&fallback, NULL));
    assert(asked >= 2);   // asked to let go, then asked again
    assert(!da_release_debugger(&unexecutable, NULL));

    // One that lets go: the mapping decides on its own.
    asked = 0; da_attachment_probe(lets_go);
    assert(da_entry_allowed(&fallback, NULL));
    assert(asked == 2);
    da_attachment_probe(NULL);
    assert(munmap(writable, page) == 0);
    if (mapped != MAP_FAILED) assert(munmap(mapped, page) == 0);

    // A granted region the adoption refuses is given back, not stranded.
    char *text = NULL; size_t length = 0;
    FILE *record = open_memstream(&text, &length);
    assert(record);
    void *granted = mmap(NULL, page, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(granted != MAP_FAILED);
    // Execute-only, as a region from outside the app can be.
    assert(!vm_protect(mach_task_self(), (vm_address_t)granted, page, TRUE,
                       VM_PROT_READ | VM_PROT_EXECUTE));
    NativeCodeMemory stranded = {0};
    assert(!da_adopt_region(&stranded, granted, page, record));
    assert(!stranded.executable && !stranded.writable);
    assert(!hd_protection(granted));
    assert(!fflush(record) && strstr(text, "errno=") && strstr(text, ", given back"));

    // One it takes: the region stays ours, with a writable view beside it.
    void *region = mmap(NULL, page, PROT_READ | PROT_EXEC, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (region == MAP_FAILED) region = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(region != MAP_FAILED);
    NativeCodeMemory taken = {0};
    assert(da_adopt_region(&taken, region, page, NULL));
    assert(taken.executable == region && taken.writable && taken.published);
    assert(hd_protection(region));
    nc_destroy(&taken);

    // A size nothing could have been granted for is not unmapped either.
    void *kept = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    assert(kept != MAP_FAILED);
    NativeCodeMemory oversized = {0};
    assert(!da_adopt_region(&oversized, kept, (size_t)NC_MAX_ARENA + page, record));
    assert(hd_protection(kept));
    assert(!fflush(record) && strstr(text, ", not given back"));
    assert(munmap(kept, page) == 0);
    fclose(record); free(text);

    puts("PASS: debugger region validation, refused request with nothing attached (no breakpoint executed),"
         " no entry while a debugger holds on, a refused region given back");
}
