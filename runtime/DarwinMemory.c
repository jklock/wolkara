#include "DarwinMemory.h"
#include <limits.h>

// Darwin errno values (do not use the build host's errno ABI).
enum { GD_ENOMEM = 12, GD_EACCES = 13, GD_EINVAL = 22, GD_ENOTSUP = 45 };
static bool rounded(uint64_t n, uint64_t *out) {
    if (!n || n > UINT64_MAX - (GM_PAGE_SIZE - 1)) return false;
    *out = (n + GM_PAGE_SIZE - 1) & ~(uint64_t)(GM_PAGE_SIZE - 1);
    return true;
}
static int result(DarwinMemory *d, GMResult r) {
    if (r == GM_OK) return 0; // Successful calls do not clear errno.
    d->error = r == GM_PROTECTION ? GD_EACCES :
               (r == GM_NOMEM || r == GM_UNMAPPED) ? GD_ENOMEM : GD_EINVAL;
    return -1;
}
uint64_t gd_mmap(DarwinMemory *d, uint64_t a, uint64_t n, unsigned prot,
                 unsigned flags, int fd, uint64_t offset) {
    uint64_t size;
    unsigned known = GD_MAP_PRIVATE | GD_MAP_SHARED | GD_MAP_FIXED | GD_MAP_ANON | GD_MAP_JIT;
    if (!rounded(n, &size) || (prot & ~7u) || (flags & ~known) ||
        (flags & (GD_MAP_PRIVATE | GD_MAP_SHARED)) != GD_MAP_PRIVATE || offset ||
        ((flags & GD_MAP_FIXED) && (a % GM_PAGE_SIZE))) {
        d->error = GD_EINVAL; return UINT64_MAX;
    }
    if (!(flags & GD_MAP_ANON) || fd != -1) { d->error = GD_ENOTSUP; return UINT64_MAX; }
    GMResult r;
    if (!(flags & GD_MAP_FIXED)) {
        a &= ~(uint64_t)(GM_PAGE_SIZE - 1);
        if (a < 0x100000000ULL) a = 0x200000000ULL;
        r = gm_find_free(&d->memory, a, size, &a);
        if (result(d, r)) return UINT64_MAX;
    }
    // Preserve the null/low-address guard used by 64-bit Darwin executables.
    if (a < 0x100000000ULL) { d->error = GD_EINVAL; return UINT64_MAX; }
    r = gm_map(&d->memory, a, size, prot, 7, !!(flags & GD_MAP_JIT), !!(flags & GD_MAP_FIXED));
    return result(d, r) ? UINT64_MAX : a;
}
int gd_mprotect(DarwinMemory *d, uint64_t a, uint64_t n, unsigned prot) {
    uint64_t size;
    if (!rounded(n, &size)) { d->error = GD_EINVAL; return -1; }
    return result(d, gm_protect(&d->memory, a, size, prot));
}
int gd_munmap(DarwinMemory *d, uint64_t a, uint64_t n) {
    uint64_t size;
    if (!rounded(n, &size)) { d->error = GD_EINVAL; return -1; }
    return result(d, gm_unmap(&d->memory, a, size));
}
void gd_jit_write_protect(DarwinMemory *d, bool enabled) {
    d->thread.jit_write_protected = enabled;
}
