#include "GuestFixups.h"
#include <mach-o/loader.h>
#include <stdlib.h>
#include <string.h>

typedef struct { const uint8_t *p, *end; bool bad; } Cursor;
static uint64_t leb(Cursor *c, bool sign) {
    uint64_t value = 0;
    for (unsigned shift = 0; shift < 70; shift += 7) {
        if (c->p == c->end) break;
        uint8_t byte = *c->p++;
        if (shift == 63 && (sign ? ((byte & 0x7f) != 0 && (byte & 0x7f) != 0x7f) : (byte & 0x7e))) break;
        value |= (uint64_t)(byte & 0x7f) << shift;
        if (!(byte & 0x80)) {
            if (sign && shift < 63 && (byte & 0x40)) value |= UINT64_MAX << (shift + 7);
            return value;
        }
    }
    c->bad = true; return 0;
}
static bool add(uint64_t *a, uint64_t b) {
    if (b > UINT64_MAX - *a) return false;
    *a += b; return true;
}
static uint8_t *stream(GuestImage *image, uint32_t offset, uint32_t size) {
    if (size > 32 * 1024 * 1024) return NULL;
    for (size_t i = 0; i < image->segment_count; i++) {
        GISegment *s = &image->segments[i];
        if (offset < s->file_offset || offset - s->file_offset > s->file_size ||
            size > s->file_size - (offset - s->file_offset)) continue;
        uint8_t *bytes = malloc(size);
        if (!bytes) return NULL;
        if (gm_read(&image->memory, s->address + offset - s->file_offset, bytes, size) == GM_OK) return bytes;
        free(bytes); return NULL;
    }
    return NULL;
}
static bool target(GuestImage *image, size_t seg, uint64_t offset, uint64_t *address) {
    if (seg >= image->segment_count) return false;
    GISegment *s = &image->segments[seg];
    if (!s->prot || offset > s->size || 8 > s->size - offset || (offset & 7)) return false;
    *address = s->address + offset; return true;
}
static bool rebases(GuestImage *image, Cursor *c, uint64_t slide, GFStats *stats) {
    size_t seg = SIZE_MAX; uint64_t offset = 0; unsigned type = 0;
    while (c->p < c->end) {
        uint8_t byte = *c->p++, op = byte & 0xf0, imm = byte & 15;
        uint64_t count = 0, skip = 0;
        switch (op) {
        case REBASE_OPCODE_DONE: return true;
        case REBASE_OPCODE_SET_TYPE_IMM: type = imm; break;
        case REBASE_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB: seg = imm; offset = leb(c, false); break;
        case REBASE_OPCODE_ADD_ADDR_ULEB: if (!add(&offset, leb(c, false))) return false; break;
        case REBASE_OPCODE_ADD_ADDR_IMM_SCALED: if (!add(&offset, imm * 8)) return false; break;
        case REBASE_OPCODE_DO_REBASE_IMM_TIMES: count = imm; break;
        case REBASE_OPCODE_DO_REBASE_ULEB_TIMES: count = leb(c, false); break;
        case REBASE_OPCODE_DO_REBASE_ADD_ADDR_ULEB: count = 1; skip = leb(c, false); break;
        case REBASE_OPCODE_DO_REBASE_ULEB_TIMES_SKIPPING_ULEB: count = leb(c, false); skip = leb(c, false); break;
        default: return false;
        }
        if (c->bad || count > 1000000 || skip > UINT64_MAX - 8) return false;
        while (count--) {
            uint64_t address, value;
            if (type != REBASE_TYPE_POINTER || ++stats->rebases > 1000000 || !target(image, seg, offset, &address) ||
                gm_read(&image->memory, address, &value, 8) != GM_OK) return false;
            value += slide; // Mach-O pointer arithmetic intentionally wraps for negative slides.
            if (gm_populate(&image->memory, address, &value, 8) != GM_OK || !add(&offset, 8 + skip)) return false;
        }
    }
    return false; // Missing DONE.
}
static bool binds(GuestImage *image, Cursor *c, bool lazy, bool weak_stream, GFResolve resolve,
                  void *context, GFStats *stats, char *error, size_t error_size) {
    size_t seg = SIZE_MAX; uint64_t offset = 0, addend = 0;
    int ordinal = weak_stream ? BIND_SPECIAL_DYLIB_WEAK_LOOKUP : 0;
    unsigned type = BIND_TYPE_POINTER, flags = 0; const char *symbol = NULL;
    bool ended = false;
    while (c->p < c->end) {
        uint8_t byte = *c->p++, op = byte & 0xf0, imm = byte & 15;
        uint64_t count = 0, skip = 0;
        ended = false;
        switch (op) {
        case BIND_OPCODE_DONE:
            if (!lazy) return true;
            seg = SIZE_MAX; offset = addend = 0; ordinal = 0; flags = 0;
            type = BIND_TYPE_POINTER; symbol = NULL; ended = true; break;
        case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM: ordinal = imm; break;
        case BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB: {
            uint64_t n = leb(c, false); if (n > image->dylib_count) return false; ordinal = (int)n; break;
        }
        case BIND_OPCODE_SET_DYLIB_SPECIAL_IMM: ordinal = imm ? (int)(int8_t)(imm | 0xf0) : 0; break;
        case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM: {
            const uint8_t *end = memchr(c->p, 0, (size_t)(c->end - c->p));
            if (!end) return false;
            symbol = (const char *)c->p; c->p = end + 1; flags = imm; break;
        }
        case BIND_OPCODE_SET_TYPE_IMM: type = imm; break;
        case BIND_OPCODE_SET_ADDEND_SLEB: addend = leb(c, true); break;
        case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB: seg = imm; offset = leb(c, false); break;
        // Apple linkers encode backward moves as wrapping unsigned ULEB deltas.
        // The resulting fixup target is bounds checked before any access.
        case BIND_OPCODE_ADD_ADDR_ULEB: offset += leb(c, false); break;
        case BIND_OPCODE_DO_BIND: count = 1; break;
        case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB: count = 1; skip = leb(c, false); break;
        case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED: count = 1; skip = imm * 8; break;
        case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB: count = leb(c, false); skip = leb(c, false); break;
        default: return false;
        }
        if (c->bad || count > 1000000) return false;
        while (count--) {
            uint64_t address, value;
            if (type != BIND_TYPE_POINTER || !symbol || ordinal > (int)image->dylib_count || ordinal < -3 ||
                ++stats->binds > 1000000 || !target(image, seg, offset, &address)) {
                snprintf(error, error_size, "invalid bind target segment=%zu offset=%#llx type=%u ordinal=%d",
                         seg, (unsigned long long)offset, type, ordinal);
                return false;
            }
            if (!resolve(symbol, ordinal, (flags & BIND_SYMBOL_FLAGS_WEAK_IMPORT) || weak_stream, &value, context)) {
                snprintf(error, error_size, "unresolved import %s (ordinal %d)", symbol, ordinal); return false;
            }
            value += addend;
            if (gm_populate(&image->memory, address, &value, 8) != GM_OK) return false;
            // Like ADD_ADDR_ULEB, bind-and-skip can encode a backward move as
            // an unsigned wrapping delta. Validate every resulting target above.
            offset += 8 + skip;
        }
    }
    return lazy && ended;
}
bool gf_apply(GuestImage *image, uint64_t slide, GFResolve resolve, void *context,
              GFStats *stats, char *error, size_t error_size) {
    *stats = (GFStats){0};
    if (error_size) error[0] = 0;
    if (image->chained_fixups || !resolve) { snprintf(error, error_size, "unsupported fixup configuration"); return false; }
    const uint32_t offsets[] = {image->rebase_offset, image->bind_offset, image->lazy_bind_offset, image->weak_bind_offset};
    const uint32_t sizes[] = {image->rebase_size, image->bind_size, image->lazy_bind_size, image->weak_bind_size};
    for (size_t i = 0; i < 4; i++) {
        if (!sizes[i]) continue;
        uint8_t *bytes = stream(image, offsets[i], sizes[i]);
        if (!bytes) { snprintf(error, error_size, "fixup stream outside readable image"); return false; }
        Cursor c = {bytes, bytes + sizes[i], false};
        bool ok = i == 0 ? rebases(image, &c, slide, stats) : binds(image, &c, i == 2, i == 3, resolve, context, stats, error, error_size);
        size_t consumed = (size_t)(c.p - bytes);
        free(bytes);
        if (!ok) { if (error_size && !error[0]) snprintf(error, error_size, "invalid or unsupported fixup stream %zu at byte %zu (rebases=%zu binds=%zu)", i, consumed, stats->rebases, stats->binds); return false; }
    }
    return true;
}
