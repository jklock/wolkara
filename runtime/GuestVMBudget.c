#include "GuestVMBudget.h"
#include <errno.h>
#include <mach/mach.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

void gv_init(GVBudget *budget, uint64_t bytes, size_t threshold, size_t floor) {
    memset(budget, 0, sizeof *budget);
    budget->page = (size_t)getpagesize();
    budget->budget = bytes;
    budget->threshold = threshold > budget->page ? threshold : budget->page;
    budget->floor = floor > budget->page ? floor - floor % budget->page : budget->page;
    budget->lock = OS_UNFAIR_LOCK_INIT;
}
bool gv_enabled(const GVBudget *budget) { return budget && budget->budget; }
bool gv_counts(const GVBudget *budget, const void *address, size_t size, int flags) {
    return gv_enabled(budget) && !address && (flags & MAP_ANON) && !(flags & MAP_FIXED) && size >= budget->threshold;
}

static uintptr_t lesser(uintptr_t a, uintptr_t b) { return a < b ? a : b; }
// Where the kernel's answer for [address, address+size) ends: a whole page; 0
// past the end of the address space.
static uintptr_t page_end(const GVBudget *budget, uintptr_t address, size_t size) {
    uintptr_t end = address + size, rounded = end + (budget->page - 1);
    if (end < address || rounded < end) return 0;
    return rounded - rounded % budget->page;
}
typedef enum { OUTSIDE, GRANTED, GUARD, MISSING } Part;
// What an operation starts in: a region's own mapping or a later mapping of
// the application. That stays the application's even inside another region's
// missing part; the rest of a missing part is never touched. The lock is held
// here and below.
static void anchor_at(const GVBudget *budget, uintptr_t address, uintptr_t *from, uintptr_t *to) {
    *from = *to = address;
    for (size_t i = 0; i < budget->count; i++) {
        const GVRegion *r = &budget->regions[i];
        if (address >= r->start && address < r->limit) { *from = r->start; *to = r->limit; return; }
    }
    for (size_t i = 0; i < budget->claim_count; i++) {
        const GVClaim *claim = &budget->claims[i];
        if (address >= claim->start && address < claim->end) { *from = claim->start; *to = claim->end; return; }
    }
}
// What the piece of [cursor, end) at cursor is, the region it is in and where it ends.
static Part part(GVBudget *budget, uintptr_t cursor, uintptr_t end, uintptr_t anchor_from, uintptr_t anchor_to,
                 uintptr_t *until, GVRegion **region) {
    uintptr_t next = end;
    *region = NULL;
    if (cursor >= anchor_from && cursor < anchor_to) next = lesser(next, anchor_to);
    else for (size_t i = 0; i < budget->count; i++) {
        GVRegion *r = &budget->regions[i];
        if (cursor >= r->limit && cursor < r->span) { *region = r; *until = lesser(r->span, end); return MISSING; }
        if (r->limit > cursor && r->limit < r->span) next = lesser(next, r->limit);
    }
    for (size_t i = 0; i < budget->count; i++) {
        GVRegion *r = &budget->regions[i];
        if (cursor >= r->start && cursor < r->limit) {
            *region = r;
            *until = lesser(cursor < r->end ? r->end : r->limit, next);
            return cursor < r->end ? GRANTED : GUARD;
        }
        if (r->start > cursor) next = lesser(next, r->start);
    }
    *until = next;
    return OUTSIDE;
}
// A mapping of the application: inside a missing part, it stays its own. With
// no room to remember that, the missing part ends where it begins.
static void claim(GVBudget *budget, uintptr_t address, size_t size) {
    for (size_t i = 0; i < budget->count; i++) {
        GVRegion *r = &budget->regions[i];
        if (address + size <= r->limit || address >= r->span) continue;
        if (budget->claim_count < GV_MAX_CLAIMS) {
            budget->claims[budget->claim_count++] = (GVClaim){address, page_end(budget, address, size)};
            return;
        }
        r->span = address > r->limit ? address : r->limit;
    }
}
static void unclaim(GVBudget *budget, uintptr_t from, uintptr_t to) {
    for (size_t i = 0; i < budget->claim_count;) {
        GVClaim *claim = &budget->claims[i];
        if (from <= claim->start && to >= claim->end) { *claim = budget->claims[--budget->claim_count]; continue; }
        if (from <= claim->start && to > claim->start) claim->start = to;
        else if (from < claim->end && to >= claim->end) claim->end = from;
        i++;
    }
}
// [from, to) of a region's own mapping is gone. Its missing part stays
// missing until the call is over (sweep), whatever else it unmapped. A hole in
// the middle splits it: what lies before the hole becomes a region of its own,
// never downsized, so no byte is released twice. With no room for that, the
// hole stays counted until the region goes.
static void forget(GVBudget *budget, GVRegion *r, uintptr_t from, uintptr_t to) {
    if (from <= r->start) {
        r->start = to;
        if (r->end < to) r->end = to;
    } else if (to >= r->limit) {
        if (r->end > from) r->end = from;
        r->limit = from;
    } else if (budget->count < GV_MAX_REGIONS) {
        budget->regions[budget->count++] = (GVRegion){r->start, lesser(r->end, from), from, from};
        r->start = to;
        if (r->end < to) r->end = to;
    } else return;
    budget->reserved -= to - from;
}
// Regions with nothing of their own left are gone.
static void sweep(GVBudget *budget) {
    for (size_t i = 0; i < budget->count;) {
        GVRegion *r = &budget->regions[i];
        if (r->start < r->limit) { i++; continue; }
        unclaim(budget, r->limit, r->span);
        *r = budget->regions[--budget->count];
    }
}
// Whether nothing is mapped in [from, from+size).
static bool unmapped(uintptr_t from, size_t size) {
    vm_address_t address = from;
    vm_size_t length = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &address, &length, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS)
        return true;
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    return address >= from + size;
}
// The first address at or above `from` with `size` free bytes, or 0.
static uintptr_t free_span(uintptr_t from, size_t size) {
    for (int step = 0; step < 4096 && from + size > from; step++) {
        vm_address_t address = from;
        vm_size_t length = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t object = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &address, &length, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count, &object) != KERN_SUCCESS)
            return from;
        if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
        if (address >= from + size) return from;
        from = address + length;
    }
    return 0;
}

void *gv_reserve(GVBudget *budget, size_t size, int prot, int flags, int fd, size_t *granted) {
    size_t page = budget->page;
    *granted = 0;
    os_unfair_lock_lock(&budget->lock);
    if (budget->count == GV_MAX_REGIONS) {
        void *result = mmap(NULL, size, prot, flags, fd, 0);
        if (result != MAP_FAILED) { claim(budget, (uintptr_t)result, size); *granted = size; }
        os_unfair_lock_unlock(&budget->lock);
        return result;
    }
    uint64_t room = budget->reserved < budget->budget ? budget->budget - budget->reserved : 0;
    size_t want = size;
    if (want > room) want = room > budget->floor ? (size_t)room : budget->floor;
    if (want > size) want = size;
    if (want < size) want -= want % page;
    void *result;
    size_t mapped;
    for (;;) {
        mapped = want < size ? want + page : want;
        result = mmap(NULL, mapped, prot, flags, fd, 0);
        if (result != MAP_FAILED || errno != ENOMEM || want <= page) break;
        want = want / 2 - want / 2 % page;
        if (want < page) want = page;
    }
    if (result == MAP_FAILED) { os_unfair_lock_unlock(&budget->lock); return result; }
    uintptr_t start = (uintptr_t)result;
    uintptr_t asked = page_end(budget, start, size);
    if (want < size && asked > start + mapped && !unmapped(start + mapped, asked - start - mapped)) {
        // Something lies where the missing part would be: move where the whole span is free.
        uintptr_t hole = free_span(start, size);
        void *moved = hole ? mmap((void *)hole, mapped, prot, flags, fd, 0) : MAP_FAILED;
        if (moved == (void *)hole) { munmap(result, mapped); result = moved; start = hole; }
        else if (moved != MAP_FAILED) munmap(moved, mapped);
    }
    uintptr_t own = page_end(budget, start, want);
    GVRegion region = {start, own, own, own};
    if (want < size) {
        (void)mprotect((void *)region.end, page, PROT_NONE);
        region.limit = region.end + page;
        asked = page_end(budget, start, size);
        region.span = asked > region.limit ? asked : region.limit;
    }
    budget->regions[budget->count++] = region;
    budget->reserved += region.limit - region.start;
    *granted = want;
    os_unfair_lock_unlock(&budget->lock);
    return result;
}

void *gv_map(GVBudget *budget, void *address, size_t size, int prot, int flags, int fd, off_t offset) {
    if (!gv_enabled(budget)) return mmap(address, size, prot, flags, fd, offset);
    os_unfair_lock_lock(&budget->lock);
    uintptr_t cursor = (uintptr_t)address, end = cursor + size, until, from, to;
    GVRegion *region;
    bool missing = false;
    anchor_at(budget, cursor, &from, &to);
    for (; address && cursor < end && !missing; cursor = until) {
        Part kind = part(budget, cursor, end, from, to, &until, &region);
        missing = kind == GUARD || kind == MISSING;
    }
    void *result;
    if (missing && (flags & MAP_FIXED)) { errno = ENOMEM; result = MAP_FAILED; }
    else {
        result = mmap(missing ? NULL : address, size, prot, flags, fd, offset);
        if (result != MAP_FAILED) claim(budget, (uintptr_t)result, size);
    }
    os_unfair_lock_unlock(&budget->lock);
    return result;
}

typedef enum { UNMAP, PROTECT, ADVISE } Operation;
static int apply(GVBudget *budget, Operation operation, void *address, size_t size, int value) {
    // As the kernel does: a page-aligned start, a length to the end of its last page.
    uintptr_t cursor = (uintptr_t)address, end = page_end(budget, cursor, size), until, from, to;
    if (!size) return operation == UNMAP ? munmap(address, size) :
                      operation == PROTECT ? mprotect(address, size, value) : madvise(address, size, value);
    if (!end || cursor % budget->page) { errno = EINVAL; return -1; }
    int result = 0, code = 0;
    os_unfair_lock_lock(&budget->lock);
    anchor_at(budget, cursor, &from, &to);
    // Memory the application was not given never becomes usable: as the kernel
    // answers for an unmapped range, the call fails and changes nothing.
    if (operation == PROTECT && value != PROT_NONE)
        for (uintptr_t at = cursor; at < end; at = until) {
            GVRegion *region;
            Part kind = part(budget, at, end, from, to, &until, &region);
            if (kind == GUARD || kind == MISSING) {
                os_unfair_lock_unlock(&budget->lock);
                errno = ENOMEM;
                return -1;
            }
        }
    for (; cursor < end; cursor = until) {
        GVRegion *region;
        Part kind = part(budget, cursor, end, from, to, &until, &region);
        if (kind == MISSING || (kind == GUARD && operation != UNMAP)) continue;
        void *piece = (void *)cursor;
        size_t length = until - cursor;
        int done = operation == UNMAP ? munmap(piece, length) :
                   operation == PROTECT ? mprotect(piece, length, value) : madvise(piece, length, value);
        if (done) { result = -1; code = errno; }
        else if (operation == UNMAP && region) forget(budget, region, cursor, until);
        else if (operation == UNMAP) unclaim(budget, cursor, until);
    }
    if (operation == UNMAP) sweep(budget);
    os_unfair_lock_unlock(&budget->lock);
    if (result) errno = code;
    return result;
}
int gv_unmap(GVBudget *budget, void *address, size_t size) {
    return gv_enabled(budget) ? apply(budget, UNMAP, address, size, 0) : munmap(address, size);
}
int gv_protect(GVBudget *budget, void *address, size_t size, int prot) {
    return gv_enabled(budget) ? apply(budget, PROTECT, address, size, prot) : mprotect(address, size, prot);
}
int gv_advise(GVBudget *budget, void *address, size_t size, int advice) {
    return gv_enabled(budget) ? apply(budget, ADVISE, address, size, advice) : madvise(address, size, advice);
}
