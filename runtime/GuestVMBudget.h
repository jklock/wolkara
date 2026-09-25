#pragma once
#include <os/lock.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

// Experimental and opt-in (TOLKARA_VM_BUDGET_MB): iPadOS caps a process's
// virtual reservations near 64 GB and charges them when they are made, while
// a macOS application may reserve pools for a far larger address space
// (Cyberpunk 2077: about 118 GB) and fail on a pool it did not get.
//
// Large anonymous reservations the kernel places are counted against a budget
// and, beyond it, mapped smaller than asked, ending in a PROT_NONE guard page,
// where the whole span asked for is free address space if such a place is
// found. The application still believes it has the whole region, so the
// missing part is never unmapped, protected or advised for it (other code's
// mappings may come to live there), and a fixed mapping into it fails; the
// application's own later mappings there stay its own. Touching memory past
// what was granted faults at the guard page, or beyond it reaches whatever was
// placed there since.
enum { GV_MAX_REGIONS = 256, GV_MAX_CLAIMS = 1024 };
// [start, end) granted; [end, limit) the guard; [limit, span) not mapped for
// the application although it asked for it. Not downsized: end == limit == span.
typedef struct { uintptr_t start, end, limit, span; } GVRegion;
// A later mapping of the application inside a missing part.
typedef struct { uintptr_t start, end; } GVClaim;
typedef struct {
    uint64_t budget;       // bytes for counted reservations; 0: off
    size_t threshold;      // counted: anonymous, placed by the kernel, at least this size
    size_t floor;          // a downsized reservation is still asked for this much first
    size_t page;
    uint64_t reserved;     // counted bytes mapped now, guards included
    GVRegion regions[GV_MAX_REGIONS];
    size_t count;
    GVClaim claims[GV_MAX_CLAIMS];
    size_t claim_count;
    os_unfair_lock lock;
} GVBudget;

void gv_init(GVBudget *budget, uint64_t bytes, size_t threshold, size_t floor);
bool gv_enabled(const GVBudget *budget);
// Counted: anonymous (fd is then only a tag), placed by the kernel, and at
// least threshold bytes.
bool gv_counts(const GVBudget *budget, const void *address, size_t size, int flags);
// A counted reservation within what is left of the budget (at least floor,
// never more than asked), halved while the kernel refuses it for want of
// memory. *granted: what the application may use, 0 on failure. Past
// GV_MAX_REGIONS live reservations, one is mapped as asked and not counted.
void *gv_reserve(GVBudget *budget, size_t size, int prot, int flags, int fd, size_t *granted);
// Any other mapping. A fixed one into a missing part fails with ENOMEM; a
// hint into one is dropped.
void *gv_map(GVBudget *budget, void *address, size_t size, int prot, int flags, int fd, off_t offset);
// munmap, mprotect and madvise, skipping missing parts (and, but for munmap,
// guard pages); the rest as asked.
int gv_unmap(GVBudget *budget, void *address, size_t size);
int gv_protect(GVBudget *budget, void *address, size_t size, int prot);
int gv_advise(GVBudget *budget, void *address, size_t size, int advice);
