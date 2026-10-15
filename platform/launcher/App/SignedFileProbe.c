// File-backed signed-code experiment: does iPadOS execute a custom-mapped page
// backed by a locally signed Mach-O, without any debugger/JIT authorization?
// Every step is logged and flushed before any operation that may CS-kill the
// process, so the log always records exactly how far execution reached.
#include "SignedFileProbe.h"
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

extern int csops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize);

#define CS_OPS_STATUS 0
#define CS_MAGIC_REQUIREMENT 0xfade0c00u
#define CS_MAGIC_REQUIREMENTS 0xfade0c01u
#define CS_MAGIC_CODEDIRECTORY 0xfade0c02u
#define CS_MAGIC_EMBEDDED_SIGNATURE 0xfade0cc0u
#define CS_MAGIC_BLOBWRAPPER 0xfade0b01u
#define CS_SLOT_CODEDIRECTORY 0u
#define CS_SLOT_REQUIREMENTS 2u
#define CS_SLOT_CMS_SIGNATURE 0x10000u

// Every multi-byte Mach-O/signature field is read at a file-controlled offset
// into an mmap'd file, so the byte at that offset may not meet a uint32_t /
// uint64_t / struct alignment. Dereferencing a typed pointer there is undefined
// behaviour that -fsanitize=alignment flags (e.g. the CodeDirectory execseg
// 64-bit read). Read every such field with memcpy into an aligned local
// instead; larger structs are copied whole with memcpy the same way.
static uint32_t read_be32(const void *base, size_t offset) {
    uint32_t value;
    memcpy(&value, (const char *)base + offset, sizeof value);
    return __builtin_bswap32(value);
}

static uint64_t read_be64(const void *base, size_t offset) {
    uint64_t value;
    memcpy(&value, (const char *)base + offset, sizeof value);
    return __builtin_bswap64(value);
}

static uint8_t read_u8(const void *base, size_t offset) {
    return ((const uint8_t *)base)[offset];
}

// Rewrites an absolute path under $HOME to "~/..." so the probe log never
// carries the personal app-data-container path (which embeds the install UUID).
// A path outside $HOME is reduced to its basename for the same reason.
static const char *home_relative(const char *path, char *buffer, size_t size) {
    const char *home = getenv("HOME");
    size_t home_len = home ? strlen(home) : 0;
    if (home_len && !strncmp(path, home, home_len) && (path[home_len] == '/' || !path[home_len])) {
        snprintf(buffer, size, "~%s", path + home_len);
        return buffer;
    }
    const char *slash = strrchr(path, '/');
    return slash ? slash + 1 : path;
}

// dlerror() and other diagnostic strings embed the full absolute dylib path,
// whose app-data-container component is the install UUID. Copy the message,
// replacing every embedded occurrence of $HOME with "~", so no personal
// container path reaches the probe log. Used for every dlerror/path string.
static const char *sanitize(const char *message, char *buffer, size_t size) {
    if (!size) return "";
    if (!message) { buffer[0] = '\0'; return buffer; }
    const char *home = getenv("HOME");
    size_t home_len = home ? strlen(home) : 0;
    size_t out = 0;
    for (size_t i = 0; message[i] && out + 1 < size; ) {
        if (home_len && !strncmp(message + i, home, home_len)) {
            buffer[out++] = '~';
            i += home_len;
        } else {
            buffer[out++] = message[i++];
        }
    }
    buffer[out] = '\0';
    return buffer;
}

// A file-controlled __text offset is only safe to map executable and call
// when its first instruction is inside the mapping and 4-byte aligned.
static bool text_callable(uint32_t text_offset, size_t size, FILE *log) {
    if ((uint64_t)text_offset + 4 > size || (text_offset & 3u)) {
        fprintf(log, "[signed-file] text_offset %u not callable within %zu\n", text_offset, size);
        return false;
    }
    return true;
}

static void log_own_status(FILE *log) {
    uint32_t flags = 0;
    if (csops(getpid(), CS_OPS_STATUS, &flags, sizeof flags)) {
        fprintf(log, "[signed-file] csops status failed errno=%d\n", errno);
        return;
    }
    fprintf(log, "[signed-file] own csflags=0x%08x valid=%d adhoc=%d get-task-allow=%d hard=%d kill=%d enforcement=%d require-lv=%d runtime=%d linker-signed=%d debugged=%d\n",
        flags, !!(flags & 0x1), !!(flags & 0x2), !!(flags & 0x4), !!(flags & 0x100), !!(flags & 0x200),
        !!(flags & 0x1000), !!(flags & 0x2000), !!(flags & 0x10000), !!(flags & 0x20000), !!(flags & 0x10000000));
    fflush(log);
}

// Locates the first __TEXT,__text section and the LC_CODE_SIGNATURE range.
static int inspect_mach_o(const void *base, size_t size, uint32_t *text_offset, uint64_t *text_size,
                          uint32_t *signature_offset, uint32_t *signature_size, FILE *log) {
    if (size < sizeof(struct mach_header_64)) return -1;
    const struct mach_header_64 *header = base;
    if (header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) return -2;
    // The load-command region must fit and agree with the header's own count.
    if ((uint64_t)sizeof(*header) + header->sizeofcmds > size) return -3;
    fprintf(log, "[signed-file] mach-o filetype=%u ncmds=%u flags=0x%x\n", header->filetype, header->ncmds, header->flags);
    const char *cmds_end = (const char *)base + sizeof(*header) + header->sizeofcmds;
    const char *command = (const char *)base + sizeof(*header);
    *text_offset = 0; *text_size = 0; *signature_offset = 0; *signature_size = 0;
    for (uint32_t index = 0; index < header->ncmds; index++) {
        // The load command lies at a file-controlled offset (each cmdsize may
        // be any value), so copy every command/section struct out with memcpy
        // into an aligned local rather than dereferencing a struct pointer at
        // an unaligned address. Read the fixed load_command header only once it
        // is known to fit, then bound cmdsize before reading any larger struct.
        if (command + sizeof(struct load_command) > cmds_end) return -3;
        struct load_command lc;
        memcpy(&lc, command, sizeof lc);
        if (lc.cmdsize < sizeof(lc) ||
            lc.cmdsize > (uint32_t)(cmds_end - command)) return -3;
        if (lc.cmd == LC_SEGMENT_64) {
            // Copy the fixed segment struct only once cmdsize covers it, then
            // bound the section array without overflowing the multiply.
            if (lc.cmdsize < sizeof(struct segment_command_64)) return -4;
            struct segment_command_64 segment;
            memcpy(&segment, command, sizeof segment);
            if ((uint64_t)lc.cmdsize < sizeof(segment) + (uint64_t)segment.nsects * sizeof(struct section_64)) return -4;
            const char *section_ptr = command + sizeof(struct segment_command_64);
            for (uint32_t s = 0; s < segment.nsects; s++, section_ptr += sizeof(struct section_64)) {
                struct section_64 section;
                memcpy(&section, section_ptr, sizeof section);
                if (!strncmp(section.sectname, "__text", 16) && !strncmp(section.segname, "__TEXT", 16)) {
                    // The section body must lie inside the mapping, and its
                    // entry point must be callable, before any caller maps it
                    // executable or calls through it. Reject an implausible
                    // section.size (read straight from the file) on its own
                    // first: it can never legitimately exceed the mapping, and
                    // the standalone check closes the wrap window in the
                    // offset+size addition below.
                    if ((uint64_t)section.offset + 4 > size ||
                        section.size > size ||
                        (uint64_t)section.offset + section.size > size ||
                        (section.offset & 3u)) return -7;
                    *text_offset = section.offset; *text_size = section.size;
                }
            }
        } else if (lc.cmd == LC_CODE_SIGNATURE) {
            if (lc.cmdsize < sizeof(struct linkedit_data_command)) return -5;
            struct linkedit_data_command linkedit;
            memcpy(&linkedit, command, sizeof linkedit);
            if ((uint64_t)linkedit.dataoff + linkedit.datasize > size) return -8;
            *signature_offset = linkedit.dataoff; *signature_size = linkedit.datasize;
        }
        command += lc.cmdsize;
    }
    return *text_offset ? 0 : -6;
}

static void describe_signature(const void *base, size_t size, uint32_t offset, uint32_t signature_size, FILE *log) {
    if (!offset || !signature_size || (uint64_t)offset + signature_size > size) {
        fprintf(log, "[signed-file] no usable LC_CODE_SIGNATURE (offset=%u size=%u)\n", offset, signature_size);
        return;
    }
    const char *blob = (const char *)base + offset;
    if (signature_size < 12 || read_be32(blob, 0) != CS_MAGIC_EMBEDDED_SIGNATURE) {
        fprintf(log, "[signed-file] signature superblob magic=0x%08x unexpected\n",
            signature_size >= 4 ? read_be32(blob, 0) : 0);
        return;
    }
    uint32_t count = read_be32(blob, 8);
    fprintf(log, "[signed-file] superblob count=%u length=%u\n", count, read_be32(blob, 4));
    for (uint32_t index = 0; index < count && index < 16; index++) {
        if (12 + (uint64_t)(index + 1) * 8 > signature_size) break;
        uint32_t type = read_be32(blob, 12 + index * 8);
        uint32_t entry = read_be32(blob, 12 + index * 8 + 4);
        if ((uint64_t)entry + 8 > signature_size) break;
        const char *content = blob + entry;
        uint32_t magic = read_be32(content, 0), length = read_be32(content, 4);
        if ((uint64_t)entry + length > signature_size || length < 8) break;
        if (type == CS_SLOT_CODEDIRECTORY && magic == CS_MAGIC_CODEDIRECTORY && length >= 44) {
            uint32_t version = read_be32(content, 8);
            uint32_t flags = read_be32(content, 12);
            uint32_t hash_offset = read_be32(content, 16);
            uint32_t ident_offset = read_be32(content, 20);
            uint32_t special = read_be32(content, 24);
            uint32_t slots = read_be32(content, 28);
            uint32_t limit = read_be32(content, 32);
            uint8_t hash_size = read_u8(content, 36);
            uint8_t hash_type = read_u8(content, 37);
            uint8_t platform = read_u8(content, 38);
            uint8_t page_size = read_u8(content, 39);
            // Bound the identifier by the CodeDirectory's own length: a crafted
            // CD may run its identifier to the blob end with no NUL, and %s
            // would read past the mapping.
            const char *ident = "?"; int ident_len = 1;
            if (ident_offset < length) { ident = content + ident_offset; ident_len = (int)strnlen(ident, length - ident_offset); }
            uint64_t exec_limit = 0, exec_flags = 0;
            if (version >= 0x20400 && length >= 88) {
                exec_limit = read_be64(content, 72);
                exec_flags = read_be64(content, 80);
            }
            fprintf(log, "[signed-file] codedirectory version=0x%x flags=0x%x ident=%.*s slots=%u special=%u limit=%u hash=%u(%u) platform=%u pagebits=%u execseg_limit=%llu execseg_flags=0x%llx\n",
                version, flags, ident_len, ident, slots, special, limit, hash_size, hash_type, platform, page_size,
                (unsigned long long)exec_limit, (unsigned long long)exec_flags);
            fprintf(log, "[signed-file] codedirectory adhoc=%d get-task-allow=%d linker-signed=%d\n",
                !!(flags & 0x2), !!(flags & 0x4), !!(flags & 0x20000));
            (void)hash_offset;
        } else if (type == CS_SLOT_REQUIREMENTS) {
            fprintf(log, "[signed-file] requirements magic=0x%08x length=%u\n", magic, length);
        } else if (type == CS_SLOT_CMS_SIGNATURE) {
            fprintf(log, "[signed-file] cms signature magic=0x%08x length=%u%s\n", magic, length,
                magic == CS_MAGIC_BLOBWRAPPER ? "" : " (unexpected)");
        } else {
            fprintf(log, "[signed-file] slot type=%u magic=0x%08x length=%u\n", type, magic, length);
        }
    }
    fflush(log);
}

static bool run_exec(const char *path, bool mprotect_first, bool attempt_write, unsigned expected, FILE *log) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { fprintf(log, "[signed-file] open failed errno=%d\n", errno); return false; }
    struct stat status;
    if (fstat(fd, &status) || status.st_size <= 0 || status.st_size > (64 << 20)) {
        fprintf(log, "[signed-file] fstat failed or implausible size=%lld\n", (long long)status.st_size);
        close(fd); return false;
    }
    size_t size = (size_t)status.st_size;
    void *reading = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (reading == MAP_FAILED) { fprintf(log, "[signed-file] control mmap failed errno=%d\n", errno); close(fd); return false; }
    uint32_t text_offset = 0, sig_offset = 0, sig_size = 0; uint64_t text_size = 0;
    int parse = inspect_mach_o(reading, size, &text_offset, &text_size, &sig_offset, &sig_size, log);
    if (!parse) describe_signature(reading, size, sig_offset, sig_size, log);
    munmap(reading, size);
    if (parse || !text_callable(text_offset, size, log)) {
        fprintf(log, "[signed-file] mach-o parse failed=%d\n", parse); close(fd); return false;
    }
    fprintf(log, "[signed-file] text offset=%u size=%llu filesize=%zu\n", text_offset,
        (unsigned long long)text_size, size);
    fflush(log);

    void *mapping;
    if (mprotect_first) {
        mapping = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
        if (mapping == MAP_FAILED) { fprintf(log, "[signed-file] read mmap failed errno=%d\n", errno); close(fd); return false; }
        int protection = mprotect(mapping, size, PROT_READ | PROT_EXEC);
        fprintf(log, "[signed-file] mprotect R->RX result=%d errno=%d\n", protection, protection ? errno : 0);
        fflush(log);
        if (protection) { munmap(mapping, size); close(fd); return false; }
    } else {
        mapping = mmap(NULL, size, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
        fprintf(log, "[signed-file] mmap RX result=%s errno=%d\n", mapping == MAP_FAILED ? "FAILED" : "ok",
            mapping == MAP_FAILED ? errno : 0);
        fflush(log);
        if (mapping == MAP_FAILED) { close(fd); return false; }
    }
    close(fd);

    volatile uint32_t first_word = *(volatile uint32_t *)((const char *)mapping + text_offset);
    fprintf(log, "[signed-file] page-in read ok first_instruction=0x%08x\n", first_word);
    fflush(log);

    if (attempt_write) {
        int protection = mprotect(mapping, size, PROT_READ | PROT_WRITE | PROT_EXEC);
        fprintf(log, "[signed-file] mprotect RX->RWX result=%d errno=%d\n", protection, protection ? errno : 0);
        fflush(log);
        if (!protection) {
            fprintf(log, "[signed-file] writing 4 bytes into signed executable page\n");
            fflush(log);
            memcpy((char *)mapping + text_offset, (const void *)&first_word, 4);
            fprintf(log, "[signed-file] write completed; readback=0x%08x\n",
                *(volatile uint32_t *)((const char *)mapping + text_offset));
            fflush(log);
        }
    }

    fprintf(log, "[signed-file] calling guest_test at mapping+%u\n", text_offset);
    fflush(log);
    int value = ((int (*)(void))((char *)mapping + text_offset))();
    fprintf(log, "[signed-file] guest_test returned 0x%08x expected=0x%08x\n", value, expected);
    bool ok = (unsigned)value == expected;
    munmap(mapping, size);
    return ok;
}

static bool run_dlopen(const char *path, unsigned expected, FILE *log) {
    char err[1024];
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    fprintf(log, "[signed-file] dlopen result=%s error=%s\n",
        handle ? "ok" : "FAILED", handle ? "-" : sanitize(dlerror(), err, sizeof err));
    fflush(log);
    if (!handle) return false;
    void *symbol = dlsym(handle, "guest_test");
    fprintf(log, "[signed-file] dlsym result=%s error=%s\n",
        symbol ? "ok" : "FAILED", symbol ? "-" : sanitize(dlerror(), err, sizeof err));
    fflush(log);
    if (!symbol) return false;
    int value = ((int (*)(void))symbol)();
    fprintf(log, "[signed-file] guest_test returned 0x%08x expected=0x%08x\n", value, expected);
    return (unsigned)value == expected;
}

// dyld establishes the validated executable mapping; vm_remap then moves a
// signed page to a caller-chosen address (the Tolkara guest address space
// model). Optionally attempts to dirty the remapped page.
static bool run_remap(const char *path, bool attempt_write, unsigned expected, FILE *log) {
    char err[1024];
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    fprintf(log, "[signed-file] dlopen result=%s error=%s\n",
        handle ? "ok" : "FAILED", handle ? "-" : sanitize(dlerror(), err, sizeof err));
    fflush(log);
    if (!handle) return false;
    void *symbol = dlsym(handle, "guest_test");
    if (!symbol) { fprintf(log, "[signed-file] dlsym failed: %s\n", sanitize(dlerror(), err, sizeof err)); return false; }
    Dl_info info;
    if (!dladdr(symbol, &info)) { fprintf(log, "[signed-file] dladdr failed\n"); return false; }
    // dli_fname is an absolute container path: log it home-relative so the
    // install-UUID component never reaches the log.
    char shown[1024];
    fprintf(log, "[signed-file] image base=%p symbol=%p file=%s\n", info.dli_fbase, symbol,
        info.dli_fname ? home_relative(info.dli_fname, shown, sizeof shown) : "?");
    size_t page = (size_t)getpagesize();
    uintptr_t source = (uintptr_t)symbol & ~(uintptr_t)(page - 1);
    size_t offset_in_page = (uintptr_t)symbol - source;
    void *destination = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (destination == MAP_FAILED) { fprintf(log, "[signed-file] destination mmap failed errno=%d\n", errno); return false; }
    fprintf(log, "[signed-file] remapping signed page %lx -> %p (symbol +%zu)\n",
        (unsigned long)source, destination, offset_in_page);
    fflush(log);
    vm_address_t target = (vm_address_t)destination;
    vm_prot_t current = VM_PROT_READ | VM_PROT_EXECUTE, maximum = current;
    kern_return_t result = vm_remap_new(mach_task_self(), &target, page, 0,
        VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), source, false, &current, &maximum, VM_INHERIT_NONE);
    fprintf(log, "[signed-file] remap result=%d same_address=%d protection=%d maximum=%d\n",
        result, target == (vm_address_t)destination, current, maximum);
    fflush(log);
    if (result != KERN_SUCCESS) {
        target = (vm_address_t)destination; current = maximum = VM_PROT_READ | VM_PROT_EXECUTE;
        result = vm_remap_new(mach_task_self(), &target, page, 0,
            VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, mach_task_self(), source, true, &current, &maximum, VM_INHERIT_NONE);
        fprintf(log, "[signed-file] COW remap result=%d protection=%d maximum=%d\n", result, current, maximum);
        fflush(log);
        if (result != KERN_SUCCESS) { munmap(destination, page); return false; }
    }
    if (attempt_write) {
        int protection = mprotect(destination, page, PROT_READ | PROT_WRITE);
        fprintf(log, "[signed-file] mprotect remapped RX->RW result=%d errno=%d\n", protection, protection ? errno : 0);
        fflush(log);
        if (!protection) {
            fprintf(log, "[signed-file] writing into remapped signed page (CS_DIRTY test)\n");
            fflush(log);
            *(volatile uint32_t *)destination = 0xd65f03c0;
            fprintf(log, "[signed-file] write completed readback=0x%08x\n", *(volatile uint32_t *)destination);
            fflush(log);
        }
    }
    fprintf(log, "[signed-file] calling remapped guest_test\n");
    fflush(log);
    int value = ((int (*)(void))((char *)destination + offset_in_page))();
    fprintf(log, "[signed-file] remapped guest_test returned 0x%08x expected=0x%08x\n", value, expected);
    munmap(destination, page);
    return (unsigned)value == expected;
}

// Does a dyld-validated file become mappable RX afterwards? If so, a custom
// loader can mmap its segments MAP_FIXED at guest addresses instead of
// remapping individual pages.
static bool run_exec_after_dlopen(const char *path, unsigned expected, FILE *log) {
    char err[1024];
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    fprintf(log, "[signed-file] dlopen result=%s error=%s\n",
        handle ? "ok" : "FAILED", handle ? "-" : sanitize(dlerror(), err, sizeof err));
    fflush(log);
    int fd = open(path, O_RDONLY);
    if (fd < 0) { fprintf(log, "[signed-file] open failed errno=%d\n", errno); return false; }
    struct stat status;
    if (fstat(fd, &status) || status.st_size <= 0 || status.st_size > (64 << 20)) { close(fd); return false; }
    size_t size = (size_t)status.st_size;
    void *mapping = mmap(NULL, size, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
    fprintf(log, "[signed-file] mmap RX after dlopen result=%s errno=%d\n",
        mapping == MAP_FAILED ? "FAILED" : "ok", mapping == MAP_FAILED ? errno : 0);
    fflush(log);
    if (mapping == MAP_FAILED) { close(fd); return false; }
    uint32_t text_offset = 0, sig_offset = 0, sig_size = 0; uint64_t text_size = 0;
    if (inspect_mach_o(mapping, size, &text_offset, &text_size, &sig_offset, &sig_size, log) ||
        !text_callable(text_offset, size, log)) {
        fprintf(log, "[signed-file] mach-o parse failed\n"); munmap(mapping, size); close(fd); return false;
    }
    fprintf(log, "[signed-file] calling guest_test at custom mapping+%u\n", text_offset);
    fflush(log);
    int value = ((int (*)(void))((char *)mapping + text_offset))();
    fprintf(log, "[signed-file] guest_test returned 0x%08x expected=0x%08x\n", value, expected);
    munmap(mapping, size); close(fd);
    return (unsigned)value == expected;
}

// dyld attaches a file's signature blob to the kernel's unified buffer cache
// via fcntl(F_ADDFILESIGS_RETURN). If we do that ourselves, does the
// subsequent custom mmap(PROT_EXEC) become validated? If yes, a custom loader
// needs no dlopen at all.
typedef struct {
    off_t fs_file_start;
    void *fs_blob_start;
    size_t fs_blob_size;
} probe_fsignatures_t;
#ifndef F_ADDFILESIGS_RETURN
#define F_ADDFILESIGS_RETURN 61
#endif

static bool run_fcntl(const char *path, unsigned expected, FILE *log) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { fprintf(log, "[signed-file] open failed errno=%d\n", errno); return false; }
    struct stat status;
    if (fstat(fd, &status) || status.st_size <= 0 || status.st_size > (64 << 20)) { close(fd); return false; }
    size_t size = (size_t)status.st_size;
    void *reading = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (reading == MAP_FAILED) { fprintf(log, "[signed-file] read mmap failed errno=%d\n", errno); close(fd); return false; }
    uint32_t text_offset = 0, sig_offset = 0, sig_size = 0; uint64_t text_size = 0;
    int parse = inspect_mach_o(reading, size, &text_offset, &text_size, &sig_offset, &sig_size, log);
    if (parse || !sig_offset || !sig_size || !text_callable(text_offset, size, log)) {
        fprintf(log, "[signed-file] no usable text/signature parse=%d text_offset=%u sig=%u+%u filesize=%zu\n",
            parse, text_offset, sig_offset, sig_size, size);
        munmap(reading, size); close(fd); return false;
    }
    // F_ADDFILESIGS* read fs_blob_start as a FILE OFFSET of the signature blob
    // (cast to void *), relative to fs_file_start (the Mach-O slice offset in
    // the file) -- NOT as a memory address. dyld passes
    // (void *)(uintptr_t)codeSignatureFileOffset with fs_file_start = the slice
    // offset. This probe maps a thin slice at offset 0, so fs_file_start = 0 and
    // the blob offset is sig_offset. The earlier version passed a mapped memory
    // pointer as fs_blob_start, so any device results it produced are invalid
    // and must be disregarded.
    off_t slice_offset = 0;
    probe_fsignatures_t signatures = {slice_offset, (void *)(uintptr_t)sig_offset, sig_size};
    int added = fcntl(fd, F_ADDFILESIGS_RETURN, &signatures);
    fprintf(log, "[signed-file] F_ADDFILESIGS_RETURN passed file_start=%lld blob_offset=%u blob_size=%u -> result=%d errno=%d returned_end=%lld\n",
        (long long)slice_offset, sig_offset, sig_size, added, added ? errno : 0,
        (long long)signatures.fs_file_start);
    fflush(log);
    munmap(reading, size);
    void *mapping = mmap(NULL, size, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
    fprintf(log, "[signed-file] mmap RX after F_ADDFILESIGS result=%s errno=%d\n",
        mapping == MAP_FAILED ? "FAILED" : "ok", mapping == MAP_FAILED ? errno : 0);
    fflush(log);
    if (mapping == MAP_FAILED) { close(fd); return false; }
    fprintf(log, "[signed-file] calling guest_test at custom mapping+%u\n", text_offset);
    fflush(log);
    int value = ((int (*)(void))((char *)mapping + text_offset))();
    fprintf(log, "[signed-file] guest_test returned 0x%08x expected=0x%08x\n", value, expected);
    munmap(mapping, size); close(fd);
    return (unsigned)value == expected;
}

// Control: is even our own already-validated executable file mappable RX?
static bool run_self(FILE *log) {
    char path[1024]; uint32_t size = sizeof path;
    if (_NSGetExecutablePath(path, &size)) { fprintf(log, "[signed-file] no executable path\n"); return false; }
    int fd = open(path, O_RDONLY);
    if (fd < 0) { fprintf(log, "[signed-file] open self failed errno=%d\n", errno); return false; }
    void *mapping = mmap(NULL, 16384, PROT_READ | PROT_EXEC, MAP_PRIVATE, fd, 0);
    fprintf(log, "[signed-file] mmap RX of own executable result=%s errno=%d\n",
        mapping == MAP_FAILED ? "FAILED" : "ok", mapping == MAP_FAILED ? errno : 0);
    fflush(log);
    if (mapping == MAP_FAILED) { close(fd); return false; }
    fprintf(log, "[signed-file] own header magic=0x%08x\n", *(volatile uint32_t *)mapping);
    munmap(mapping, 16384); close(fd);
    return true;
}

// Non-executing control: map the file read-only, parse it and log its
// structure and signature, and never map executable or call in. Safe to run on
// the Mac under ASan, so the parser bounds checks can be exercised in a test.
static bool run_inspect(const char *path, FILE *log) {
    int fd = open(path, O_RDONLY);
    if (fd < 0) { fprintf(log, "[signed-file] open failed errno=%d\n", errno); return false; }
    struct stat status;
    if (fstat(fd, &status) || status.st_size <= 0 || status.st_size > (64 << 20)) {
        fprintf(log, "[signed-file] fstat failed or implausible size=%lld\n", (long long)status.st_size);
        close(fd); return false;
    }
    size_t size = (size_t)status.st_size;
    void *reading = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    close(fd);
    if (reading == MAP_FAILED) { fprintf(log, "[signed-file] read mmap failed errno=%d\n", errno); return false; }
    uint32_t text_offset = 0, sig_offset = 0, sig_size = 0; uint64_t text_size = 0;
    int parse = inspect_mach_o(reading, size, &text_offset, &text_size, &sig_offset, &sig_size, log);
    if (!parse) {
        describe_signature(reading, size, sig_offset, sig_size, log);
        fprintf(log, "[signed-file] text offset=%u size=%llu filesize=%zu\n",
            text_offset, (unsigned long long)text_size, size);
    } else {
        fprintf(log, "[signed-file] mach-o parse failed=%d\n", parse);
    }
    fflush(log);
    bool ok = parse == 0 && text_callable(text_offset, size, log);
    munmap(reading, size);
    return ok;
}

bool HostSignedFileProbe(const char *path, const char *mode, unsigned expected, FILE *log) {
    char shown[1024];
    fprintf(log, "[signed-file] path=%s mode=%s page=%d expected=0x%08x\n",
        home_relative(path, shown, sizeof shown), mode, getpagesize(), expected);
    log_own_status(log);
    bool ok;
    if (!strcmp(mode, "inspect")) ok = run_inspect(path, log);
    else if (!strcmp(mode, "dlopen")) ok = run_dlopen(path, expected, log);
    else if (!strcmp(mode, "mprotect")) ok = run_exec(path, true, false, expected, log);
    else if (!strcmp(mode, "write")) ok = run_exec(path, false, true, expected, log);
    else if (!strcmp(mode, "remap")) ok = run_remap(path, false, expected, log);
    else if (!strcmp(mode, "remapwrite")) ok = run_remap(path, true, expected, log);
    else if (!strcmp(mode, "execafter")) ok = run_exec_after_dlopen(path, expected, log);
    else if (!strcmp(mode, "fcntl")) ok = run_fcntl(path, expected, log);
    else if (!strcmp(mode, "self")) ok = run_self(log);
    else if (!strcmp(mode, "exec")) ok = run_exec(path, false, false, expected, log);
    else {
        // Fail closed: an unknown mode must never fall through to an exec-and-call
        // run, or a typo would be recorded as the outcome of a different experiment.
        fprintf(log, "[signed-file] unknown mode=%s (valid: inspect exec mprotect write dlopen remap remapwrite execafter fcntl self)\n", mode);
        ok = false;
    }
    fprintf(log, "[signed-file] result=%s\n", ok ? "PASS" : "FAIL");
    fflush(log);
    return ok;
}
