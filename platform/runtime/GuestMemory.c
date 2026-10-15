#include "GuestMemory.h"
#include <stdlib.h>
#include <string.h>

static bool range(uint64_t a, uint64_t n) {
    return n && !(a % GM_PAGE_SIZE) && !(n % GM_PAGE_SIZE) && n <= UINT64_MAX - a;
}
static size_t lower(const GuestMemory *m, uint64_t a) {
    size_t lo = 0, hi = m->count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (m->pages[mid].address < a) lo = mid + 1; else hi = mid;
    }
    return lo;
}
void gm_destroy(GuestMemory *m) {
    for (size_t i = 0; i < m->count; i++) free(m->pages[i].bytes);
    free(m->pages);
    *m = (GuestMemory){0};
}
GMResult gm_map(GuestMemory *m, uint64_t a, uint64_t n, unsigned prot,
                unsigned maxprot, bool jit, bool replace) {
    if (!range(a, n) || (maxprot & ~7u) || (prot & ~maxprot)) return GM_INVALID;
    size_t first = lower(m, a), last = lower(m, a + n);
    if (!replace && first != last) return GM_OVERLAP;
    uint64_t newpages = n / GM_PAGE_SIZE;
    if (newpages > SIZE_MAX / sizeof(GMPage) - (m->count - (last - first))) return GM_NOMEM;
    size_t count = m->count - (last - first) + (size_t)newpages;
    GMPage *pages = calloc(count, sizeof *pages);
    if (!pages) return GM_NOMEM;
    if (first) memcpy(pages, m->pages, first * sizeof *pages);
    for (size_t i = 0; i < newpages; i++)
        pages[first + i] = (GMPage){.address = a + i * GM_PAGE_SIZE,
                                  .prot = prot, .maxprot = maxprot, .jit = jit};
    if (last < m->count)
        memcpy(pages + first + newpages, m->pages + last, (m->count - last) * sizeof *pages);
    for (size_t i = first; i < last; i++) free(m->pages[i].bytes);
    free(m->pages);
    m->pages = pages; m->count = count; m->generation++; m->code_generation++;
    return GM_OK;
}
GMResult gm_unmap(GuestMemory *m, uint64_t a, uint64_t n) {
    if (!range(a, n)) return GM_INVALID;
    size_t first = lower(m, a), last = lower(m, a + n);
    for (size_t i = first; i < last; i++) free(m->pages[i].bytes);
    if (last < m->count)
        memmove(m->pages + first, m->pages + last, (m->count - last) * sizeof *m->pages);
    m->count -= last - first; m->generation++; m->code_generation++;
    return GM_OK;
}
GMResult gm_protect(GuestMemory *m, uint64_t a, uint64_t n, unsigned prot) {
    if (!range(a, n) || (prot & ~7u)) return GM_INVALID;
    size_t first = lower(m, a), last = lower(m, a + n);
    if (last - first != n / GM_PAGE_SIZE) return GM_UNMAPPED;
    for (size_t i = first; i < last; i++)
        if (prot & ~m->pages[i].maxprot) return GM_PROTECTION;
    for (size_t i = first; i < last; i++) m->pages[i].prot = prot;
    m->generation++; m->code_generation++;
    return GM_OK;
}
// Check the entire access before changing bytes or exposing partial reads.
static GMResult access_range(GuestMemory *m, const GMThread *t, uint64_t a,
                             size_t n, unsigned permission) {
    if (n > UINT64_MAX - a) { m->fault_address = a; return GM_INVALID; }
    uint64_t end = a + n;
    while (a < end) {
        uint64_t base = a & ~(uint64_t)(GM_PAGE_SIZE - 1);
        size_t i = lower(m, base);
        m->fault_address = a;
        if (i == m->count || m->pages[i].address != base) return GM_UNMAPPED;
        GMPage *p = &m->pages[i];
        if ((p->prot & permission) != permission) return GM_PROTECTION;
        if (p->jit && t && ((permission == GM_WRITE && t->jit_write_protected) ||
                            (permission == GM_EXEC && !t->jit_write_protected))) return GM_PROTECTION;
        uint64_t chunk = GM_PAGE_SIZE - (a - base);
        a += chunk < end - a ? chunk : end - a;
    }
    m->fault_address = 0;
    return GM_OK;
}
static GMResult copy(GuestMemory *m, const GMThread *t, uint64_t a, void *buffer,
                     size_t n, unsigned permission, bool write) {
    // Most interpreted loads/stores fit within one page. Resolve that page once;
    // retain the full preflight path below for atomic cross-page accesses.
    size_t offset = (size_t)(a & (GM_PAGE_SIZE - 1));
    if (n && n <= GM_PAGE_SIZE - offset && n <= UINT64_MAX - a) {
        uint64_t base = a - offset;
        size_t i = lower(m, base);
        m->fault_address = a;
        if (i == m->count || m->pages[i].address != base) return GM_UNMAPPED;
        GMPage *p = &m->pages[i];
        if ((p->prot & permission) != permission ||
            (p->jit && t && ((permission == GM_WRITE && t->jit_write_protected) ||
                             (permission == GM_EXEC && !t->jit_write_protected)))) return GM_PROTECTION;
        m->fault_address = 0;
        if (!buffer) return GM_INVALID;
        if (write) {
            if (!p->bytes && !(p->bytes = calloc(1, GM_PAGE_SIZE))) return GM_NOMEM;
            memcpy(p->bytes + offset, buffer, n);
            m->generation++;
            if (p->prot & GM_EXEC) m->code_generation++;
        } else if (p->bytes) memcpy(buffer, p->bytes + offset, n);
        else memset(buffer, 0, n);
        return GM_OK;
    }
    GMResult r = access_range(m, t, a, n, permission);
    if (r != GM_OK || !n) return r;
    if (!buffer) return GM_INVALID;
    // Allocate before copying so allocation failure cannot cause a partial store.
    if (write) {
        uint64_t end = a + n;
        for (size_t i = lower(m, a & ~(uint64_t)(GM_PAGE_SIZE - 1));
             i < m->count && m->pages[i].address < end; i++) {
            if (!m->pages[i].bytes) {
                m->pages[i].bytes = calloc(1, GM_PAGE_SIZE);
                if (!m->pages[i].bytes) return GM_NOMEM;
            }
        }
    }
    unsigned char *b = buffer;
    bool executable_write = false;
    while (n) {
        uint64_t base = a & ~(uint64_t)(GM_PAGE_SIZE - 1);
        GMPage *p = &m->pages[lower(m, base)];
        if (write && (p->prot & GM_EXEC)) executable_write = true;
        size_t offset = (size_t)(a - base), chunk = GM_PAGE_SIZE - offset;
        if (chunk > n) chunk = n;
        if (write) memcpy(p->bytes + offset, b, chunk);
        else if (p->bytes) memcpy(b, p->bytes + offset, chunk);
        else memset(b, 0, chunk);
        b += chunk; a += chunk; n -= chunk;
    }
    if (write) m->generation++;
    if (executable_write) m->code_generation++;
    return GM_OK;
}
GMResult gm_read(GuestMemory *m, uint64_t a, void *b, size_t n) {
    return copy(m, NULL, a, b, n, GM_READ, false);
}
GMResult gm_write(GuestMemory *m, const GMThread *t, uint64_t a, const void *b, size_t n) {
    return copy(m, t, a, (void *)b, n, GM_WRITE, true);
}
GMResult gm_populate(GuestMemory *m, uint64_t a, const void *b, size_t n) {
    return copy(m, NULL, a, (void *)b, n, 0, true);
}
GMResult gm_fetch(GuestMemory *m, const GMThread *t, uint64_t a, uint32_t *instruction) {
    if (!instruction) return GM_INVALID;
    if (a & 3) { m->fault_address = a; return GM_INVALID; }
    unsigned char bytes[4];
    GMResult r = copy(m, t, a, bytes, sizeof bytes, GM_EXEC, false);
    if (r == GM_OK) *instruction = (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 |
                                   (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
    return r;
}
GMResult gm_find_free(const GuestMemory *m, uint64_t hint, uint64_t n, uint64_t *a) {
    if (!range(hint, n)) return GM_INVALID;
    uint64_t candidate = hint;
    for (size_t i = lower(m, hint); i < m->count; i++) {
        if (m->pages[i].address >= candidate + n) break;
        candidate = m->pages[i].address + GM_PAGE_SIZE;
        if (n > UINT64_MAX - candidate) return GM_NOMEM;
    }
    *a = candidate;
    return GM_OK;
}
const char *gm_result_string(GMResult r) {
    switch (r) {
        case GM_OK: return "ok";
        case GM_INVALID: return "invalid memory range or permissions";
        case GM_OVERLAP: return "mapping overlaps existing pages";
        case GM_UNMAPPED: return "unmapped guest address";
        case GM_PROTECTION: return "guest protection fault";
        case GM_NOMEM: return "out of backing memory";
    }
    return "unknown memory error";
}
