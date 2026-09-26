#include "SparseMemoryProbe.h"
#include "GuestMemoryInstruction.h"
#include <errno.h>
#include <inttypes.h>
#include <mach/mach.h>
#include <signal.h>
#include <stdatomic.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/sysctl.h>
#include <time.h>
#include <sys/ucontext.h>
#include <unistd.h>

extern uint64_t gm_sparse_probe_program(void *slot, uint64_t seed, void *output);
extern void gm_sparse_address_probe(void *slot, uint64_t seed, void *output);
extern const unsigned char gm_sparse_probe_program_end[];
static GMSparseMemory *active_memory;
static struct sigaction previous_segv, previous_bus;
static volatile sig_atomic_t handled_faults;
static atomic_flag probe_busy = ATOMIC_FLAG_INIT;

static void probe_signal(int signal_number, siginfo_t *info, void *context) {
    (void)info;
    int previous_errno = errno;
    ucontext_t *u = context;
    uintptr_t pc = (uintptr_t)u->uc_mcontext->__ss.__pc;
    if (active_memory && pc >= (uintptr_t)gm_sparse_probe_program &&
        pc < (uintptr_t)gm_sparse_probe_program_end && !(pc & 3)) {
        GMMemoryRegisters r = {0};
        for (unsigned i = 0; i < 29; ++i) r.x[i] = u->uc_mcontext->__ss.__x[i];
        r.x[29] = u->uc_mcontext->__ss.__fp; r.x[30] = u->uc_mcontext->__ss.__lr;
        r.sp = u->uc_mcontext->__ss.__sp; r.pc = pc;
        memcpy(r.vector, u->uc_mcontext->__ns.__v, sizeof r.vector);
        GMResult fault;
        // Only our own fixture's instruction bytes are read here.
        uint32_t instruction; memcpy(&instruction, (const void *)pc, sizeof instruction);
        if (gm_memory_step(active_memory, instruction, &r, &fault) == GM_STEP_OK) {
            for (unsigned i = 0; i < 29; ++i) u->uc_mcontext->__ss.__x[i] = r.x[i];
            u->uc_mcontext->__ss.__fp = r.x[29]; u->uc_mcontext->__ss.__lr = r.x[30];
            u->uc_mcontext->__ss.__sp = r.sp; u->uc_mcontext->__ss.__pc = r.pc;
            memcpy(u->uc_mcontext->__ns.__v, r.vector, sizeof r.vector);
            ++handled_faults;
            errno = previous_errno;
            return;
        }
    }
    // Never skip an unknown instruction or swallow an unrelated application fault.
    sigaction(signal_number, signal_number == SIGBUS ? &previous_bus : &previous_segv, NULL);
    raise(signal_number);
    errno = previous_errno;
}
static double seconds(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return t.tv_sec + t.tv_nsec * 1e-9;
}
static void native_pool_placement(FILE *log) {
    const size_t mib=(size_t)1<<20, pool_size=(size_t)64<<30;
    const unsigned banks[]={64,256,1024,4096};
    // Our own anonymous mappings only: model the loader arena's address-space
    // use, then check whether allocation order can keep a 64 GiB pool native.
    void *arena=mmap(NULL,233*mib,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    for(unsigned order=0;order<2;order++)for(unsigned i=0;i<4;i++) {
        size_t bank_size=banks[i]*mib;
        void *first=mmap(NULL,order?pool_size:bank_size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
        void *second=mmap(NULL,order?bank_size:pool_size,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
        fprintf(log,"Native placement arena=%s order=%s bank=%u MiB first=%s second=%s\n",
                arena==MAP_FAILED?"failed":"ok",order?"pool-first":"bank-first",banks[i],
                first==MAP_FAILED?"failed":"ok",second==MAP_FAILED?"failed":"ok");
        if(second!=MAP_FAILED)munmap(second,order?bank_size:pool_size);
        if(first!=MAP_FAILED)munmap(first,order?pool_size:bank_size);
    }
    if(arena!=MAP_FAILED)munmap(arena,233*mib);
    fflush(log);
}
bool guest_sparse_memory_probe(FILE *log) {
    if (!log || atomic_flag_test_and_set(&probe_busy)) return false;
    native_pool_placement(log);
    int lse = 0; size_t feature_size = sizeof lse;
    if (sysctlbyname("hw.optional.arm.FEAT_LSE", &lse, &feature_size, NULL, 0) || lse != 1) {
        fprintf(log, "The extended fixture requires confirmed hardware LSE support.\n");
        atomic_flag_clear(&probe_busy);
        return false;
    }
    const uint64_t gib = UINT64_C(1) << 30, span = 112 * gib;
    GMSparseMemory memory = {0};
    // On the Mac reserve a guard so this fixture cannot alias another mapping.
    // On the iPad use an address above TASK_VM_INFO.max_address if the native
    // reservation is refused. Neither path replaces an existing mapping.
    void *guard = mmap(NULL, (size_t)span, PROT_NONE, MAP_PRIVATE | MAP_ANON, -1, 0);
    uint64_t base = (uint64_t)(uintptr_t)guard;
    bool ok = false, handlers = false;
    if (guard == MAP_FAILED) {
        task_vm_info_data_t vm = {0}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
        if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &count) != KERN_SUCCESS ||
            count < TASK_VM_INFO_REV2_COUNT || vm.max_address > UINT64_C(0x10000000000)) goto finish;
        base = UINT64_C(0x10000000000);
        fprintf(log, "Native 112 GiB reservation refused; software base=%#" PRIx64 ", host max=%#" PRIx64 "\n",
                base, (uint64_t)vm.max_address);
    } else fprintf(log, "Host guard for fixture: base=%#" PRIx64 ", 112 GiB\n", base);
    if (gm_sparse_init(&memory, base, span, 16 * GM_PAGE_SIZE) != GM_OK) goto finish;
    const uint64_t sizes[] = {16 * gib, 64 * gib, 32 * gib};
    uint64_t addresses[3];
    for (unsigned i = 0; i < 3; ++i) {
        if (gm_sparse_find_free(&memory, sizes[i], &addresses[i]) != GM_OK ||
            gm_sparse_map(&memory, addresses[i], sizes[i], 3, 3, false) != GM_OK) goto finish;
        fprintf(log, "Software reservation %u: %" PRIu64 " GiB at %#" PRIx64 "\n", i + 1, sizes[i] / gib, addresses[i]);
    }
    fflush(log);
    struct sigaction action = {0};
    action.sa_sigaction = probe_signal; action.sa_flags = SA_SIGINFO;
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGSEGV, &action, &previous_segv)) goto finish;
    if (sigaction(SIGBUS, &action, &previous_bus)) {
        sigaction(SIGSEGV, &previous_segv, NULL); goto finish;
    }
    handlers = true; active_memory = &memory; handled_faults = 0;
    double began = seconds();
    ok = true;
    for (unsigned repeat = 0; repeat < 100 && ok; ++repeat) {
        uint64_t seed = UINT64_C(0x9876543210fedcba) + repeat;
        uint64_t signed_byte = (seed & 255) < 128 ? seed & 255 : (seed & 255) - 256;
        uint64_t expected = (seed & 255) + (seed & 65535) + (seed & UINT32_MAX) + seed * 3 + signed_byte;
        for (unsigned i = 0; i < 3 && ok; ++i) for (unsigned end = 0; end < 2; ++end) {
            uint64_t address = addresses[i] + (end ? sizes[i] - 128 : 0);
            uint64_t vectors[4] = {0};
            uint64_t result = gm_sparse_probe_program((void *)(uintptr_t)address, seed, vectors);
            if (result != expected) ok = false;
            for (unsigned j = 0; j < 4; ++j) if (vectors[j] != seed) ok = false;
            uint64_t native_storage[16] = {0}, native_output[16] = {0}, software_output[16] = {0};
            unsigned char zero[128] = {0}, actual[128];
            if (gm_sparse_write(&memory, address, zero, sizeof zero) != GM_OK) { ok = false; break; }
            gm_sparse_address_probe(native_storage, seed, native_output);
            gm_sparse_address_probe((void *)(uintptr_t)address, seed, software_output);
            if (memcmp(native_output, software_output, sizeof native_output) ||
                gm_sparse_read(&memory, address, actual, sizeof actual) != GM_OK ||
                memcmp(actual, native_storage, sizeof actual)) ok = false;
        }
    }
    double elapsed = seconds() - began;
    GMSparseStats stats = gm_sparse_stats(&memory);
    ok = ok && handled_faults == 18600 && stats.reserved_bytes == span && stats.resident_pages == 6;
    fprintf(log, "Native scalar/SIMD/addressing/atomic fixture: %s; faults=%d; elapsed=%.6fs\n", ok ? "PASS" : "FAIL", (int)handled_faults, elapsed);
    fprintf(log, "Reserved=%" PRIu64 " GiB; backing pages used=%zu/%zu (%zu KiB used)\n",
            stats.reserved_bytes / gib, stats.resident_pages, stats.capacity_pages,
            stats.resident_pages * GM_PAGE_SIZE / 1024);
    fprintf(log, "Only our fixture ran. No imported application, native API bridge or gameplay claim.\n");
finish:
    active_memory = NULL;
    if (handlers) { sigaction(SIGBUS, &previous_bus, NULL); sigaction(SIGSEGV, &previous_segv, NULL); }
    gm_sparse_destroy(&memory);
    if (guard != MAP_FAILED) munmap(guard, (size_t)span);
    atomic_flag_clear(&probe_busy);
    return ok;
}
