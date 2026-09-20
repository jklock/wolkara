#include "GuestImage.h"
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <inttypes.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

static bool fail(char *error, size_t size, const char *format, ...) {
    va_list args; va_start(args, format);
    vsnprintf(error, size, format, args);
    va_end(args); return false;
}
static bool within(uint64_t offset, uint64_t size, uint64_t total) {
    return offset <= total && size <= total - offset;
}
static uint32_t be32(const unsigned char *p) {
    return (uint32_t)p[0] << 24 | (uint32_t)p[1] << 16 | (uint32_t)p[2] << 8 | p[3];
}
static uint64_t be64(const unsigned char *p) { return (uint64_t)be32(p) << 32 | be32(p + 4); }
static bool read_at(FILE *f, uint64_t offset, void *out, size_t size) {
    return offset <= INT64_MAX && fseeko(f, (off_t)offset, SEEK_SET) == 0 && fread(out, 1, size, f) == size;
}
void gi_destroy(GuestImage *image) {
    for (size_t i = 0; i < image->dylib_count; i++) free(image->dylibs[i]);
    free(image->exports);
    gm_destroy(&image->memory); *image = (GuestImage){0};
}
static bool load(FILE *f, GuestImage *image, uint32_t file_type, char *error, size_t error_size) {
#define BAD(...) return fail(error, error_size, __VA_ARGS__)
    if (fseeko(f, 0, SEEK_END)) BAD("cannot seek executable");
    off_t end = ftello(f);
    if (end < 32) BAD("truncated executable");
    uint64_t file_size = (uint64_t)end, slice = 0, slice_size = file_size;
    unsigned char head[8];
    if (!read_at(f, 0, head, sizeof head)) BAD("cannot read executable header");
    uint32_t magic = be32(head);
    if (magic == 0xcafebabe || magic == 0xcafebabf) {
        uint32_t count = be32(head + 4);
        size_t record_size = magic == 0xcafebabf ? 32 : 20;
        if (!count || count > 128 || !within(8, (uint64_t)count * record_size, file_size)) BAD("invalid fat architecture table");
        bool found = false;
        for (uint32_t i = 0; i < count; i++) {
            unsigned char arch[32];
            if (!read_at(f, 8 + i * record_size, arch, record_size)) BAD("truncated fat architecture");
            uint32_t cpu = be32(arch), subtype = be32(arch + 4);
            if (cpu != CPU_TYPE_ARM64 || (subtype & 0xffffff) != CPU_SUBTYPE_ARM64_ALL) continue;
            if (found) BAD("ambiguous arm64 slices");
            found = true;
            slice = record_size == 32 ? be64(arch + 8) : be32(arch + 8);
            slice_size = record_size == 32 ? be64(arch + 16) : be32(arch + 12);
            uint32_t alignment = be32(arch + (record_size == 32 ? 24 : 16));
            if (alignment >= 63 || (slice & ((1ULL << alignment) - 1)) ||
                slice < 8 + count * record_size || !within(slice, slice_size, file_size)) BAD("invalid arm64 slice range");
        }
        if (!found) BAD("no plain arm64 slice (arm64e is unsupported)");
    }
    struct mach_header_64 mh;
    if (slice_size < sizeof mh || !read_at(f, slice, &mh, sizeof mh)) BAD("truncated Mach-O header");
    if (mh.magic != MH_MAGIC_64 || mh.cputype != CPU_TYPE_ARM64 ||
        (mh.cpusubtype & 0xffffff) != CPU_SUBTYPE_ARM64_ALL || mh.filetype != file_type)
        BAD("expected original arm64 %s Mach-O", file_type == MH_EXECUTE ? "MH_EXECUTE" : "MH_DYLIB");
    image->file_type = mh.filetype;
    if (!mh.ncmds || mh.ncmds > 65536 || mh.sizeofcmds > 16 * 1024 * 1024 ||
        !within(sizeof mh, mh.sizeofcmds, slice_size)) BAD("invalid load-command range");
    image->slice_offset = slice; image->slice_size = slice_size;
    uint64_t cursor = sizeof mh, commands_end = sizeof mh + mh.sizeofcmds;
    uint64_t entry_offset = 0, init_address = 0, init_size = 0;
    bool have_entry = false, have_init = false, have_text = false;
    uint64_t header_address = 0;
    uint32_t export_offset = 0;
    bool have_exports = false;
    for (uint32_t c = 0; c < mh.ncmds; c++) {
        struct load_command lc;
        if (!within(cursor, sizeof lc, commands_end) || !read_at(f, slice + cursor, &lc, sizeof lc) ||
            lc.cmdsize < sizeof lc || (lc.cmdsize & 7) || !within(cursor, lc.cmdsize, commands_end)) BAD("invalid load command %u", c);
        if (lc.cmd == LC_SEGMENT_64) {
            struct segment_command_64 s;
            if (lc.cmdsize < sizeof s || !read_at(f, slice + cursor, &s, sizeof s) ||
                s.nsects > (lc.cmdsize - sizeof s) / sizeof(struct section_64)) BAD("invalid segment command");
            if (image->segment_count == GI_MAX_SEGMENTS) BAD("too many segments");
            if (!within(s.fileoff, s.filesize, slice_size) || s.filesize > s.vmsize ||
                s.vmsize > UINT64_MAX - s.vmaddr || (s.vmaddr % GM_PAGE_SIZE) ||
                (s.vmsize % GM_PAGE_SIZE) || (s.maxprot & ~7) || (s.initprot & ~s.maxprot)) BAD("invalid segment %.16s", s.segname);
            GISegment *segment = &image->segments[image->segment_count++];
            memcpy(segment->name, s.segname, 16);
            segment->address = s.vmaddr; segment->size = s.vmsize;
            segment->file_offset = s.fileoff; segment->file_size = s.filesize;
            segment->prot = s.initprot; segment->maxprot = s.maxprot;
            if (!strncmp(s.segname, "__TEXT", 16)) {
                if (have_text || s.fileoff || s.filesize < commands_end || !(s.initprot & GM_EXEC)) BAD("invalid __TEXT header mapping");
                have_text = true; header_address = s.vmaddr;
            }
            for (uint32_t j = 0; j < s.nsects; j++) {
                struct section_64 section;
                if (!read_at(f, slice + cursor + sizeof s + j * sizeof section, &section, sizeof section)) BAD("cannot read section");
                if (section.addr < s.vmaddr || !within(section.addr - s.vmaddr, section.size, s.vmsize)) BAD("section outside segment");
                unsigned type = section.flags & SECTION_TYPE;
                if (type != S_ZEROFILL && type != S_GB_ZEROFILL && type != S_THREAD_LOCAL_ZEROFILL &&
                    (!within(section.offset, section.size, slice_size) || section.offset < s.fileoff ||
                     !within(section.offset - s.fileoff, section.size, s.filesize) ||
                     section.addr - s.vmaddr != section.offset - s.fileoff)) BAD("invalid file-backed section");
                if (type == S_MOD_INIT_FUNC_POINTERS) {
                    if (have_init || (section.size % 8)) BAD("unsupported initializer section layout");
                    have_init = true; init_address = section.addr; init_size = section.size;
                }
                if (type == S_THREAD_LOCAL_REGULAR || type == S_THREAD_LOCAL_ZEROFILL) {
                    if (section.align > 20) BAD("unsupported TLS alignment");
                    size_t alignment = (size_t)1 << section.align;
                    if (alignment > image->tls_alignment) image->tls_alignment = alignment;
                    uint64_t start = image->tls_address, end = start + image->tls_size;
                    if (!image->tls_size || section.addr < start) start = section.addr;
                    if (section.addr + section.size > end) end = section.addr + section.size;
                    image->tls_address = start; image->tls_size = end - start;
                    if (image->tls_size > 16 * 1024 * 1024) BAD("TLS template too large");
                }
                if (type == S_THREAD_LOCAL_VARIABLES) {
                    if (image->tls_descriptors_size || section.size % 24) BAD("unsupported TLS descriptor section");
                    image->tls_descriptors = section.addr; image->tls_descriptors_size = section.size;
                }
                if (type == S_THREAD_LOCAL_INIT_FUNCTION_POINTERS) image->tls_initializer_count += section.size / 8;
                if (type >= S_THREAD_LOCAL_REGULAR && type <= S_THREAD_LOCAL_INIT_FUNCTION_POINTERS) image->has_tls = true;
            }
        } else if (lc.cmd == LC_LOAD_DYLIB || lc.cmd == LC_LOAD_WEAK_DYLIB ||
                   lc.cmd == LC_REEXPORT_DYLIB || lc.cmd == LC_LOAD_UPWARD_DYLIB) {
            struct dylib_command d;
            if (image->dylib_count == GI_MAX_DYLIBS || lc.cmdsize < sizeof d ||
                !read_at(f, slice + cursor, &d, sizeof d) || d.dylib.name.offset < sizeof d ||
                d.dylib.name.offset >= lc.cmdsize) BAD("invalid dylib command");
            size_t length = lc.cmdsize - d.dylib.name.offset;
            char *name = malloc(length);
            if (!name) BAD("cannot allocate dylib name");
            image->dylibs[image->dylib_count++] = name;
            if (!read_at(f, slice + cursor + d.dylib.name.offset, name, length) ||
                !memchr(name, 0, length)) BAD("unterminated dylib name");
        } else if (lc.cmd == LC_MAIN) {
            struct entry_point_command entry;
            if (have_entry || lc.cmdsize < sizeof entry || !read_at(f, slice + cursor, &entry, sizeof entry)) BAD("invalid LC_MAIN");
            have_entry = true; entry_offset = entry.entryoff;
        } else if (lc.cmd == LC_DYLD_INFO || lc.cmd == LC_DYLD_INFO_ONLY) {
            struct dyld_info_command info;
            if (lc.cmdsize < sizeof info || !read_at(f, slice + cursor, &info, sizeof info)) BAD("invalid dyld info");
            uint32_t pairs[10]; memcpy(pairs, &info.rebase_off, sizeof pairs);
            for (size_t i = 0; i < 10; i += 2)
                if (!within(pairs[i], pairs[i + 1], slice_size)) BAD("dyld info outside slice");
            image->bind_offset = info.bind_off; image->lazy_bind_offset = info.lazy_bind_off;
            image->weak_bind_offset = info.weak_bind_off; image->rebase_offset = info.rebase_off;
            image->bind_size = info.bind_size; image->lazy_bind_size = info.lazy_bind_size;
            image->weak_bind_size = info.weak_bind_size; image->rebase_size = info.rebase_size;
            if (info.export_size) {
                if (have_exports) BAD("duplicate export trie");
                have_exports = true; export_offset = info.export_off; image->export_size = info.export_size;
            }
        } else if (lc.cmd == LC_DYLD_EXPORTS_TRIE) {
            struct linkedit_data_command info;
            if (have_exports || lc.cmdsize < sizeof info || !read_at(f, slice + cursor, &info, sizeof info) ||
                !within(info.dataoff, info.datasize, slice_size)) BAD("invalid export trie command");
            have_exports = true; export_offset = info.dataoff; image->export_size = info.datasize;
        } else if (lc.cmd == LC_DYLD_CHAINED_FIXUPS) {
            image->chained_fixups = true;
        } else if (lc.cmd == LC_ENCRYPTION_INFO_64) {
            struct encryption_info_command_64 encryption;
            if (lc.cmdsize < sizeof encryption || !read_at(f, slice + cursor, &encryption, sizeof encryption)) BAD("invalid encryption info");
            if (encryption.cryptid) BAD("encrypted Mach-O is unsupported");
        }
        cursor += lc.cmdsize;
    }
    if (cursor != commands_end || !have_text || (file_type == MH_EXECUTE && !have_entry) ||
        (file_type == MH_DYLIB && have_entry)) BAD("missing header/entry or inconsistent image commands");
    if (image->export_size) {
        if (image->export_size > 32 * 1024 * 1024) BAD("export trie exceeds 32 MiB budget");
        image->exports = malloc(image->export_size);
        if (!image->exports || !read_at(f, slice + export_offset, image->exports, image->export_size)) BAD("cannot read export trie");
    }
    for (size_t i = 0; i < image->segment_count; i++) {
        GISegment *s = &image->segments[i];
        for (size_t j = 0; j < i; j++) {
            GISegment *p = &image->segments[j];
            if (s->size && p->size && s->address < p->address + p->size && p->address < s->address + s->size) BAD("overlapping segments");
        }
        // Keep PAGEZERO as a guest reservation with no backing pages. Low addresses
        // remain unmapped and the Darwin allocator will not allocate in this range.
        if (!strcmp(s->name, "__PAGEZERO")) {
            if (s->address || s->size != 0x100000000ULL || s->file_size || s->maxprot) BAD("unsupported __PAGEZERO layout");
            continue;
        }
        if (!s->size) continue;
        // A malformed image must not request unbounded allocation of page metadata.
        if ((file_type == MH_EXECUTE && s->address < 0x100000000ULL) || s->size > 2ULL * 1024 * 1024 * 1024 ||
            image->mapped_size > 2ULL * 1024 * 1024 * 1024 - s->size) BAD("guest image exceeds 2 GiB mapping budget");
        GMResult r = gm_map(&image->memory, s->address, s->size, s->prot, s->maxprot, false, false);
        if (r != GM_OK) BAD("map %s: %s", s->name, gm_result_string(r));
        image->mapped_size += s->size; image->file_backed_size += s->file_size;
        unsigned char buffer[65536];
        for (uint64_t off = 0; off < s->file_size;) {
            size_t n = s->file_size - off > sizeof buffer ? sizeof buffer : (size_t)(s->file_size - off);
            if (!read_at(f, slice + s->file_offset + off, buffer, n)) BAD("cannot read %s", s->name);
            r = gm_populate(&image->memory, s->address + off, buffer, n);
            if (r != GM_OK) BAD("populate %s: %s", s->name, gm_result_string(r));
            off += n;
        }
    }
    bool found_entry = false;
    for (size_t i = 0; have_entry && i < image->segment_count; i++) {
        GISegment *s = &image->segments[i];
        if ((s->prot & GM_EXEC) && entry_offset >= s->file_offset &&
            within(entry_offset - s->file_offset, 4, s->file_size)) {
            image->entry = s->address + entry_offset - s->file_offset;
            found_entry = true; break;
        }
    }
    if (have_entry && (!found_entry || (image->entry & 3))) BAD("LC_MAIN is not in executable file-backed memory");
    image->header_address = header_address; image->initializer_address = init_address;
    image->initializer_count = init_size / 8;
    if (init_size && gm_read(&image->memory, init_address, &image->first_initializer, 8) != GM_OK) BAD("cannot read initializer pointer");
    if (image->first_initializer && !image->chained_fixups) {
        uint32_t instruction;
        if (gm_fetch(&image->memory, NULL, image->first_initializer, &instruction) != GM_OK) BAD("first initializer is not executable");
    }
    // Ensure header bytes were copied verbatim, including MH_EXECUTE and platform.
    struct mach_header_64 guest_header;
    if (gm_read(&image->memory, header_address, &guest_header, sizeof guest_header) != GM_OK ||
        memcmp(&mh, &guest_header, sizeof mh)) BAD("guest header differs from source");
    return true;
#undef BAD
}
static bool load_path(const char *path, GuestImage *image, uint32_t file_type, char *error, size_t error_size) {
    if (image->memory.pages || image->segment_count) return fail(error, error_size, "image is already loaded");
    FILE *f = fopen(path, "rb");
    if (!f) return fail(error, error_size, "cannot open guest executable: %s", path);
    GuestImage staged = {0};
    bool ok = load(f, &staged, file_type, error, error_size);
    fclose(f);
    if (ok) *image = staged; else gi_destroy(&staged);
    return ok;
}
bool gi_load(const char *path, GuestImage *image, char *error, size_t error_size) {
    return load_path(path, image, MH_EXECUTE, error, error_size);
}
bool gi_load_library(const char *path, GuestImage *image, char *error, size_t error_size) {
    return load_path(path, image, MH_DYLIB, error, error_size);
}
static bool export_uleb(const unsigned char **cursor, const unsigned char *end, uint64_t *value) {
    *value = 0;
    for (unsigned shift = 0; shift <= 63 && *cursor < end; shift += 7) {
        unsigned byte = *(*cursor)++;
        if (shift == 63 && (byte & 0xfe)) return false;
        *value |= (uint64_t)(byte & 127) << shift;
        if (!(byte & 128)) return true;
    }
    return false;
}
GIExportResult gi_export(const GuestImage *image, const char *symbol,
                         uint64_t *address, bool *absolute, char *error, size_t error_size) {
#define INVALID(...) do { fail(error, error_size, __VA_ARGS__); return GI_EXPORT_INVALID; } while (0)
    if (error_size) error[0] = 0;
    if (!symbol || !address || !absolute) INVALID("invalid export query");
    size_t remaining = strnlen(symbol, 4097);
    if (!remaining || remaining > 4096) INVALID("invalid export symbol length");
    if (!image->export_size) return GI_EXPORT_MISSING;
    if (!image->exports) INVALID("missing export trie data");
    const unsigned char *end = image->exports + image->export_size;
    uint64_t node = 0;
    // Some Apple linkers put a prefix symbol's terminal on an empty edge. Bound
    // traversal explicitly so those edges cannot form an infinite malformed cycle.
    for (size_t steps = 0; steps < 8192; steps++) {
        if (node >= image->export_size) INVALID("export node outside trie");
        const unsigned char *cursor = image->exports + node;
        uint64_t terminal_size;
        if (!export_uleb(&cursor, end, &terminal_size) || terminal_size > (uint64_t)(end - cursor)) INVALID("invalid export terminal size");
        const unsigned char *children = cursor + terminal_size;
        if (!remaining && terminal_size) {
            uint64_t flags, value;
            if (!export_uleb(&cursor, children, &flags)) INVALID("invalid export flags");
            unsigned kind = flags & EXPORT_SYMBOL_FLAGS_KIND_MASK;
            if ((flags & ~(uint64_t)(EXPORT_SYMBOL_FLAGS_KIND_MASK | EXPORT_SYMBOL_FLAGS_WEAK_DEFINITION)) ||
                (kind != EXPORT_SYMBOL_FLAGS_KIND_REGULAR && kind != EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE))
                INVALID("unsupported export kind/flags %#" PRIx64, flags);
            if (!export_uleb(&cursor, children, &value) || cursor != children) INVALID("invalid export address");
            bool is_absolute = kind == EXPORT_SYMBOL_FLAGS_KIND_ABSOLUTE;
            if (!is_absolute) {
                if (value > UINT64_MAX - image->header_address) INVALID("export address overflow");
                value += image->header_address;
                bool mapped = false;
                for (size_t i = 0; i < image->segment_count; i++) {
                    const GISegment *s = &image->segments[i];
                    if (s->prot && value >= s->address && value - s->address < s->size) mapped = true;
                }
                if (!mapped) INVALID("export outside mapped image");
            }
            *address = value; *absolute = is_absolute;
            return GI_EXPORT_FOUND;
        }
        if (children == end) INVALID("missing export child count");
        cursor = children;
        unsigned count = *cursor++;
        bool found = false; uint64_t next = 0; size_t consumed = 0;
        for (unsigned i = 0; i < count; i++) {
            const unsigned char *nul = memchr(cursor, 0, (size_t)(end - cursor));
            if (!nul) INVALID("invalid export edge");
            size_t length = (size_t)(nul - cursor);
            bool matches = length ? length <= remaining && !memcmp(cursor, symbol, length) : !remaining;
            cursor = nul + 1;
            uint64_t offset;
            if (!export_uleb(&cursor, end, &offset) || offset >= image->export_size) INVALID("invalid export child offset");
            if (matches) {
                if (found) INVALID("ambiguous export edges");
                found = true; next = offset; consumed = length;
            }
        }
        if (!found) return GI_EXPORT_MISSING;
        node = next; symbol += consumed; remaining -= consumed;
    }
    INVALID("export path exceeds traversal budget");
#undef INVALID
}
void gi_report(const GuestImage *image, FILE *out) {
    fprintf(out, "[guest] original arm64 %s, slice offset=%#" PRIx64 " size=%" PRIu64 "\n", image->file_type == MH_DYLIB ? "MH_DYLIB" : "MH_EXECUTE", image->slice_offset, image->slice_size);
    for (size_t i = 0; i < image->segment_count; i++) {
        const GISegment *s = &image->segments[i];
        fprintf(out, "[guest] %-16s VA=%#" PRIx64 " size=%#" PRIx64 " file=%#" PRIx64 " %c%c%c\n",
                s->name, s->address, s->size, s->file_size,
                s->prot & GM_READ ? 'r' : '-', s->prot & GM_WRITE ? 'w' : '-', s->prot & GM_EXEC ? 'x' : '-');
    }
    fprintf(out, "[guest] mapped=%" PRIu64 " file-backed=%" PRIu64 " entry=%#" PRIx64 " initializers=%" PRIu64 " first=%#" PRIx64 "\n",
            image->mapped_size, image->file_backed_size, image->entry, image->initializer_count, image->first_initializer);
    fprintf(out, "[guest] pending runtime work: arm64 execution, dyld imports (bind=%u lazy=%u weak=%u), TLS=%s ObjC registration; chained-fixups=%s\n",
            image->bind_size, image->lazy_bind_size, image->weak_bind_size,
            image->has_tls ? "yes" : "no", image->chained_fixups ? "yes" : "no");
}
