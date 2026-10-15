#include "SignedImage.h"
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <mach/vm_prot.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static bool fail(char *error, size_t size, const char *format, ...) {
    va_list args; va_start(args, format);
    if (error && size) vsnprintf(error, size, format, args);
    va_end(args); return false;
}
static bool within(uint64_t offset, uint64_t size, uint64_t total) {
    return offset <= total && size <= total - offset;
}
#define BAD(...) return fail(error, error_size, __VA_ARGS__)
bool si_locate_image(const void *header, uintptr_t v1, uintptr_t final, SIImage *image,
                     char *error, size_t error_size) {
    if (!v1) BAD("container lacks the tolkara_container_v1 marker");
    if (!final) BAD("container lacks the tolkara_container_final marker; rebuild it from a capture of the final pages");
    if (v1 != final) BAD("container markers tolkara_container_v1 and tolkara_container_final differ");
    if (!header || (uintptr_t)header % GM_PAGE_SIZE) BAD("container header is not page aligned");
    const unsigned char *bytes = header;
    struct mach_header_64 mh;
    memcpy(&mh, bytes, sizeof mh);
    if (mh.magic != MH_MAGIC_64 || mh.cputype != CPU_TYPE_ARM64) BAD("container is not an arm64 Mach-O");
    // dyld maps at least the first page; never read load commands beyond it.
    if (mh.sizeofcmds > GM_PAGE_SIZE - sizeof mh) BAD("container load commands exceed one 16 KiB page");
    uint64_t cursor = sizeof mh, commands_end = sizeof mh + mh.sizeofcmds;
    struct segment_command_64 text = {0};
    struct section_64 section = {0};
    bool have_text = false, found = false;
    for (uint32_t c = 0; c < mh.ncmds; c++) {
        struct load_command lc;
        if (!within(cursor, sizeof lc, commands_end)) BAD("container load command %u lies past sizeofcmds", c);
        memcpy(&lc, bytes + cursor, sizeof lc);
        if (lc.cmdsize < sizeof lc || (lc.cmdsize & 7) || !within(cursor, lc.cmdsize, commands_end))
            BAD("invalid container load command %u (cmdsize %u)", c, lc.cmdsize);
        if (lc.cmd == LC_SEGMENT_64) {
            struct segment_command_64 s;
            if (lc.cmdsize < sizeof s) BAD("truncated container segment command %u", c);
            memcpy(&s, bytes + cursor, sizeof s);
            if (s.nsects > (lc.cmdsize - sizeof s) / sizeof(struct section_64)) BAD("container segment %.16s sections exceed its command", s.segname);
            if (!strncmp(s.segname, "__TEXT", 16)) {
                if (have_text) BAD("container has more than one __TEXT segment");
                have_text = true; text = s;
                for (uint32_t j = 0; j < s.nsects; j++) {
                    struct section_64 candidate;
                    memcpy(&candidate, bytes + cursor + sizeof s + j * sizeof candidate, sizeof candidate);
                    // Wrapping match only picks the section; its range is validated below.
                    if (!candidate.size || (uint64_t)(uintptr_t)header + (candidate.addr - s.vmaddr) != (uint64_t)v1) continue;
                    if (found) BAD("two container sections start at the marker");
                    found = true; section = candidate;
                }
            }
        }
        cursor += lc.cmdsize;
    }
    if (cursor != commands_end) BAD("container sizeofcmds %u disagrees with its %u load commands", mh.sizeofcmds, mh.ncmds);
    if (!have_text) BAD("container has no __TEXT segment");
    if (text.fileoff || (text.initprot & (VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE)) != (VM_PROT_READ | VM_PROT_EXECUTE))
        BAD("container __TEXT must map its header read/execute");
    if (!found) BAD("container marker is not at the start of a __TEXT section");
    // Only file-backed bytes of the segment are covered by the signature.
    uint64_t limit = text.filesize < text.vmsize ? text.filesize : text.vmsize, offset = section.addr - text.vmaddr;
    if (section.addr < text.vmaddr || !within(offset, section.size, limit))
        BAD("container section %.16s lies outside its __TEXT segment", section.sectname);
    if (offset % GM_PAGE_SIZE) BAD("container section %.16s is not 16 KiB aligned", section.sectname);
    if (section.size % GM_PAGE_SIZE) BAD("container image size %#llx is not a whole number of pages", (unsigned long long)section.size);
    *image = (SIImage){ .bytes = (const unsigned char *)v1, .size = section.size };
    return true;
}
static const unsigned char zero_page[GM_PAGE_SIZE];
// Original bytes of the page at a page-aligned guest address: the staged bytes,
// or zeros for a demand-zero or unstaged page.
static const unsigned char *original_page(const GuestMemory *m, uint64_t address) {
    size_t lo = 0, hi = m->count;
    while (lo < hi) {
        size_t mid = lo + (hi - lo) / 2;
        if (m->pages[mid].address < address) lo = mid + 1; else hi = mid;
    }
    return lo < m->count && m->pages[lo].address == address && m->pages[lo].bytes ? m->pages[lo].bytes : zero_page;
}
bool si_match_guest(const SIImage *image, const GuestImage *guest, char *error, size_t error_size) {
    const GISegment *text = NULL;
    size_t executable = 0;
    for (size_t i = 0; i < guest->segment_count; i++) {
        const GISegment *s = &guest->segments[i];
        if (!(s->prot & GM_EXEC)) continue;
        executable++;
        if (!strncmp(s->name, "__TEXT", 16)) text = s;
    }
    if (executable != 1 || !text || !text->size || text->address != guest->header_address ||
        text->address % GM_PAGE_SIZE || text->size % GM_PAGE_SIZE)
        BAD("Local signing supports guests whose only executable segment is __TEXT");
    if (image->size != text->size)
        BAD("container image is %#llx bytes but the guest __TEXT is %#llx bytes; it was built for a different executable",
            (unsigned long long)image->size, (unsigned long long)text->size);
    const unsigned char *page = original_page(&guest->memory, guest->header_address);
    struct mach_header_64 mh;
    memcpy(&mh, page, sizeof mh);
    if (mh.magic != MH_MAGIC_64) BAD("guest header is not staged at its __TEXT");
    if (mh.sizeofcmds > GM_PAGE_SIZE - sizeof mh)
        BAD("guest header and load commands (%llu bytes) exceed one 16 KiB page; Local signing cannot bind a container to this guest",
            (unsigned long long)sizeof mh + mh.sizeofcmds);
    // Header and load commands carry LC_UUID and the segment layout.
    size_t first, differing = si_count_mismatches(page, image->bytes, sizeof mh + mh.sizeofcmds, &first);
    if (differing)
        BAD("container was built for a different executable: %zu of %zu header and load-command bytes differ, first at offset %#zx",
            differing, sizeof mh + mh.sizeofcmds, first);
    return true;
}
bool si_shadow_size(const SIImage *image, const GuestImage *guest, uint64_t *shadow_size,
                    char *error, size_t error_size) {
    uint64_t base = guest->header_address, size = image->size, shadow = 0;
    if (!size || size % GM_PAGE_SIZE || base % GM_PAGE_SIZE || size > UINT64_MAX - base) BAD("invalid guest __TEXT range");
    // Scan every page: identical pages may lie inside the rewritten range.
    for (uint64_t offset = 0; offset < size; offset += GM_PAGE_SIZE)
        if (memcmp(original_page(&guest->memory, base + offset), image->bytes + offset, GM_PAGE_SIZE)) shadow = offset + GM_PAGE_SIZE;
    uint64_t initializer = guest->first_initializer - base;
    if (!guest->initializer_count || guest->first_initializer < base || initializer >= size)
        BAD("the guest's first initializer %#llx lies outside __TEXT", (unsigned long long)guest->first_initializer);
    // Rewritten pages stay anonymous and non-executable until it returns.
    if (initializer < shadow)
        BAD("the unpacking code lies inside the rewritten range (first initializer at __TEXT+%#llx, range ends at +%#llx)",
            (unsigned long long)initializer, (unsigned long long)shadow);
    *shadow_size = shadow;
    return true;
}
#undef BAD
size_t si_count_mismatches(const void *a, const void *b, size_t size, size_t *first) {
    const unsigned char *x = a, *y = b;
    size_t count = 0, unused;
    if (!first) first = &unused;
    *first = size;
    for (size_t chunk = 0; chunk < size; chunk += 4096) {
        size_t n = size - chunk < 4096 ? size - chunk : 4096;
        if (!memcmp(x + chunk, y + chunk, n)) continue;
        for (size_t i = chunk; i < chunk + n; i++) if (x[i] != y[i]) { if (!count) *first = i; count++; }
    }
    return count;
}
