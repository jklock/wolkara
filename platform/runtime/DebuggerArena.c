#include "DebuggerArena.h"
#include "HostDiagnostics.h"
#include <TargetConditionals.h>
#include <errno.h>
#include <stdint.h>
#include <sys/mman.h>
#include <unistd.h>

// The trap means something only on a device.
#if defined(__aarch64__) && TARGET_OS_IOS && !TARGET_OS_SIMULATOR
#define DA_PROTOCOL 1
#else
#define DA_PROTOCOL 0
#endif

static bool (*attachment)(void);
void da_attachment_probe(bool (*probe)(void)) { attachment = probe; }

// Attached now, not merely prepared: that flag survives the detach.
bool da_debugger_present(void) { return attachment ? attachment() : hd_debugger_attached(); }

bool da_plausible_region(const void *address) {
    uintptr_t value = (uintptr_t)address;
    if (!value || value == (uintptr_t)-1) return false;
    // Leftovers of an unserviced breakpoint rather than an address.
    if (value == 0x690000e0ull || value == 0xcccccccc690000e0ull) return false;
    return (value & ((uintptr_t)getpagesize() - 1)) == 0;
}

#if DA_PROTOCOL
// x16 selects the command; naked, the protocol names registers.
__attribute__((noinline, optnone, naked))
static void *jit26_prepare_region(void *address __attribute__((unused)),
                                  size_t length __attribute__((unused))) {
    __asm__ volatile("mov x16, #1\n"
                     "brk #0xf00d\n"
                     "ret\n");
}
__attribute__((noinline, optnone, naked))
static void jit26_detach(void) {
    __asm__ volatile("mov x16, #0\n"
                     "brk #0xf00d\n"
                     "ret\n");
}
#endif

// Ask whatever is attached to let go.
static bool da_detached(FILE *log) {
    if (!da_debugger_present()) return true;
#if DA_PROTOCOL
    jit26_detach();
#else
    if (log) fprintf(log, "[debugger] nothing here can ask a debugger to let go\n");
#endif
    bool attached = da_debugger_present();
    if (log) fprintf(log, "[debugger] asked to let go; %s attached\n", attached ? "still" : "no longer");
    return !attached;
}

bool da_request_arena(NativeCodeMemory *memory, size_t size, FILE *log) {
#if !DA_PROTOCOL
    (void)memory; (void)size;
    if (log) fprintf(log, "[debugger] the breakpoint protocol exists only on an arm64 device\n");
    return false;
#else
    if (!da_debugger_present()) {
        if (log) fprintf(log, "[debugger] nothing has prepared this process; not trapping\n");
        return false;
    }
    void *executable = NULL;
    for (unsigned attempt = 0; attempt < 3 && !executable; attempt++) {
        if (attempt) usleep(50 * 1000);   // the script can be busy for a moment
        if (log) { fprintf(log, "[debugger] requesting %zu bytes, attempt %u\n", size, attempt + 1); fflush(log); }
        // Null selects the debugger's own allocation; ours stays unexecutable.
        void *candidate = jit26_prepare_region(NULL, size);
        if (da_plausible_region(candidate)) executable = candidate;
        else if (log) fprintf(log, "[debugger] attempt %u answered %p\n", attempt + 1, candidate);
    }
    if (!executable) {
        if (log) fprintf(log, "[debugger] no executable region was provided\n");
        return false;
    }
    // What comes back is execute-only; the writable view is ours.
    if (!da_adopt_region(memory, executable, size, log)) return false;
    if (log) fprintf(log, "[debugger] arena rx=%p rw=%p size=%zu protection=%#x\n",
                     memory->executable, memory->writable, memory->size,
                     hd_protection(memory->executable));
    return true;
#endif
}

bool da_adopt_region(NativeCodeMemory *memory, void *region, size_t size, FILE *log) {
    if (nc_adopt(memory, region, size)) return true;
    int refusal = errno;
    size_t page = (size_t)getpagesize();
    // Give back exactly what was asked for, or nothing.
    bool released = region && !((uintptr_t)region % page) && size && !(size % page) &&
                    size <= NC_MAX_ARENA && !munmap(region, size);
    if (log) fprintf(log, "[debugger] region %p of %zu bytes refused errno=%d, %s\n",
                     region, size, refusal, released ? "given back" : "not given back");
    return false;
}

bool da_release_debugger(const NativeCodeMemory *memory, FILE *log) {
    if (!memory || !memory->executable) return false;
    (void)da_detached(log);
    // Whether execute survives the detach is the device's answer.
    bool executable = hd_is_executable(memory->executable);
    if (log) fprintf(log, "[debugger] the arena %s executable (protection %#x)\n",
                     executable ? "is still" : "is no longer", hd_protection(memory->executable));
    return executable;
}

// Every route into guest code passes here.
bool da_entry_allowed(const NativeCodeMemory *memory, FILE *log) {
    if (!memory || !memory->executable) return false;
    if (!da_detached(log)) {
        if (log) fprintf(log, "[debugger] something is still attached to this process\n");
        return false;
    }
    if (!hd_is_executable(memory->executable)) {
        if (log) fprintf(log, "[debugger] the arena is not executable: nothing prepared it,"
                              " or it did not survive detaching\n");
        return false;
    }
    return true;
}
