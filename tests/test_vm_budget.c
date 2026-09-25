#include "GuestVMBudget.h"
#include <assert.h>
#include <errno.h>
#include <mach/mach.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

enum { MB = 1024 * 1024 };
static const int ANON = MAP_ANON | MAP_PRIVATE;

// Whether a page is mapped, and with which protection.
static bool mapped(uintptr_t address) { return !msync((void *)address, 1, MS_ASYNC) || errno != ENOMEM; }
static vm_prot_t protection(uintptr_t address) {
    vm_address_t at = address;
    vm_size_t size = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    assert(vm_region_64(mach_task_self(), &at, &size, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object) == KERN_SUCCESS);
    assert(at <= address);
    return info.protection;
}
// Something else the kernel places in the part an application was not given.
static uintptr_t place(uintptr_t address, size_t size) {
    vm_address_t at = address;
    return vm_allocate(mach_task_self(), &at, size, VM_FLAGS_FIXED) == KERN_SUCCESS ? at : 0;
}

static GVBudget shared;
static void *churn(void *unused) {
    (void)unused;
    for (int i = 0; i < 50; i++) {
        size_t granted;
        char *p = gv_reserve(&shared, 4 * MB, PROT_READ | PROT_WRITE, ANON, -1, &granted);
        assert(p != MAP_FAILED && granted);
        p[0] = 1; p[granted - 1] = 1;
        assert(!gv_unmap(&shared, p, 4 * MB));
    }
    return NULL;
}

int main(void) {
    static GVBudget budget;
    size_t page = (size_t)getpagesize(), granted;

    // Off: nothing is counted and every call is the plain one.
    gv_init(&budget, 0, MB, MB);
    assert(!gv_enabled(&budget) && !gv_counts(&budget, NULL, 64 * MB, ANON));
    void *plain = gv_map(&budget, NULL, page, PROT_READ, ANON, -1, 0);
    assert(plain != MAP_FAILED && !gv_protect(&budget, plain, page, PROT_NONE) && !gv_unmap(&budget, plain, page));

    // Only large anonymous reservations the kernel places are counted.
    gv_init(&budget, 4 * MB, MB, MB);
    assert(gv_enabled(&budget) && gv_counts(&budget, NULL, MB, ANON));
    assert(!gv_counts(&budget, NULL, MB - 1, ANON) && !gv_counts(&budget, (void *)0x10000000, MB, ANON));
    assert(!gv_counts(&budget, NULL, MB, MAP_PRIVATE) && !gv_counts(&budget, NULL, MB, ANON | MAP_FIXED));

    // Within the budget: as asked, no guard.
    char *whole = gv_reserve(&budget, 2 * MB, PROT_READ | PROT_WRITE, ANON, -1, &granted);
    assert(whole != MAP_FAILED && granted == 2 * MB && budget.reserved == 2 * MB && budget.count == 1);
    whole[2 * MB - 1] = 1;
    // Beyond it: what is left, then a guard page; the rest is missing.
    char *pool = gv_reserve(&budget, 16 * MB, PROT_READ | PROT_WRITE, ANON, -1, &granted);
    uintptr_t start = (uintptr_t)pool;
    assert(pool != MAP_FAILED && granted == 2 * MB && budget.reserved == 4 * MB + page && budget.count == 2);
    pool[granted - 1] = 1;
    assert(protection(start + granted) == VM_PROT_NONE);
    // Exhausted: the floor.
    size_t floor_granted;
    char *small = gv_reserve(&budget, 3 * MB, PROT_READ | PROT_WRITE, ANON, -1, &floor_granted);
    assert(small != MAP_FAILED && floor_granted == MB && budget.count == 3);
    assert(!gv_unmap(&budget, small, 3 * MB) && budget.count == 2 && budget.reserved == 4 * MB + page);

    // Something placed in the missing part is never unmapped, protected or
    // replaced for the application; its own region is.
    uintptr_t other = place(start + granted + 4 * page, page);
    GVRegion *region = &budget.regions[1];
    assert(region->start == start && region->end == start + granted && region->limit == start + granted + page);
    if (other && other < region->span) {
        assert(!gv_protect(&budget, pool, 16 * MB, PROT_READ));
        assert(protection(start) == VM_PROT_READ && protection(start + granted) == VM_PROT_NONE);
        assert(protection(other) == (VM_PROT_READ | VM_PROT_WRITE));
        assert(!gv_advise(&budget, pool, 16 * MB, MADV_DONTNEED));
        assert(gv_map(&budget, (void *)other, page, PROT_READ, ANON | MAP_FIXED, -1, 0) == MAP_FAILED && errno == ENOMEM);
        assert(gv_map(&budget, (void *)(start + granted), page, PROT_READ, ANON | MAP_FIXED, -1, 0) == MAP_FAILED);
        // A hint into it is dropped; wherever the mapping lands, it is the application's.
        void *hinted = gv_map(&budget, (void *)(other + page), page, PROT_READ, ANON, -1, 0);
        assert(hinted != MAP_FAILED && !gv_protect(&budget, hinted, page, PROT_READ | PROT_WRITE));
        assert(protection((uintptr_t)hinted) == (VM_PROT_READ | VM_PROT_WRITE));
        assert(!gv_unmap(&budget, hinted, page) && !mapped((uintptr_t)hinted) && !budget.claim_count);
    }
    assert(!gv_protect(&budget, pool, granted, PROT_READ | PROT_WRITE));
    // A fixed mapping inside what was granted is the application's.
    assert(gv_map(&budget, pool, page, PROT_READ | PROT_WRITE, ANON | MAP_FIXED, -1, 0) == pool);
    // Trimming the tail of an aligned reservation touches only the missing part.
    assert(!gv_unmap(&budget, pool + 12 * MB, 4 * MB) && mapped(start) && budget.count == 2);
    // Trimming the head releases it.
    assert(!gv_unmap(&budget, pool, page) && !mapped(start) && mapped(start + page));
    assert(budget.reserved == 4 * MB && budget.regions[1].start == start + page);
    // Unmapping it as asked releases what was granted and the guard, nothing more.
    assert(!gv_unmap(&budget, pool, 16 * MB));
    assert(!mapped(start + page) && !mapped(start + granted) && budget.count == 1 && budget.reserved == 2 * MB);
    if (other && other < start + 16 * MB) assert(mapped(other) && !vm_deallocate(mach_task_self(), other, page));
    assert(!gv_unmap(&budget, whole, 2 * MB) && !budget.count && !budget.reserved);

    // A later mapping of the application inside a missing part is its own.
    pool = gv_reserve(&budget, 16 * MB, PROT_READ | PROT_WRITE, ANON, -1, &granted);
    assert(pool != MAP_FAILED && granted == 4 * MB);
    start = (uintptr_t)pool;
    uintptr_t missing = budget.regions[0].limit;
    assert(budget.regions[0].span == start + 16 * MB);
    void *later = gv_map(&budget, (void *)(missing + page), page, PROT_READ, ANON | MAP_FIXED, -1, 0);
    assert(later == MAP_FAILED && errno == ENOMEM);
    // Wherever the kernel places a later mapping, even in the missing part, it is the application's.
    later = gv_map(&budget, NULL, page, PROT_READ, ANON, -1, 0);
    assert(later != MAP_FAILED);
    bool inside = (uintptr_t)later >= missing && (uintptr_t)later < start + 16 * MB;
    assert(budget.claim_count == (inside ? 1u : 0u));
    assert(!gv_protect(&budget, later, page, PROT_NONE) && protection((uintptr_t)later) == VM_PROT_NONE);
    assert(!gv_unmap(&budget, later, page) && !mapped((uintptr_t)later) && !budget.claim_count);
    assert(!gv_unmap(&budget, pool, 16 * MB) && !budget.count && !budget.reserved);

    // A full table maps as asked, uncounted.
    gv_init(&budget, 1, MB, MB);
    void *held[GV_MAX_REGIONS];
    for (size_t i = 0; i < GV_MAX_REGIONS; i++) {
        held[i] = gv_reserve(&budget, MB, PROT_READ, ANON, -1, &granted);
        assert(held[i] != MAP_FAILED && granted == MB);
    }
    uint64_t reserved = budget.reserved;
    void *extra = gv_reserve(&budget, 2 * MB, PROT_READ, ANON, -1, &granted);
    assert(extra != MAP_FAILED && granted == 2 * MB && budget.count == GV_MAX_REGIONS && budget.reserved == reserved);
    assert(!gv_unmap(&budget, extra, 2 * MB));
    for (size_t i = 0; i < GV_MAX_REGIONS; i++) assert(!gv_unmap(&budget, held[i], MB));
    assert(!budget.count && !budget.reserved);

    // Accounting holds across threads.
    gv_init(&shared, 8 * MB, MB, MB);
    pthread_t threads[8];
    for (int i = 0; i < 8; i++) assert(!pthread_create(&threads[i], NULL, churn, NULL));
    for (int i = 0; i < 8; i++) assert(!pthread_join(threads[i], NULL));
    assert(!shared.count && !shared.reserved);

    puts("PASS: VM budget: counted reservations downsized with a guard page, missing parts never unmapped or protected, "
         "trims, full table, threads");
}
