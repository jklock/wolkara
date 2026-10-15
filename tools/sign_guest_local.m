// sign_guest_local.m — code-sign a bare arm64 Mach-O (dylib, bundle or
// executable) without invoking codesign(1). Emits the superblob layout Apple
// produces: CodeDirectory v=0x20400 + designated requirement + detached CMS
// SignedData (BER, indefinite-length outer layers, embedded WWDR, Apple Root
// CA and leaf certificates), or with --adhoc the same ad-hoc signature as
// `codesign -s -` (CS_ADHOC, empty requirement set, no CMS signature).
//
// This is the prototype for signing guest code entirely on-device: it uses only
// Security.framework (keychain identity, SecKeyCreateSignature) and CommonCrypto
// (CC_SHA256), both available on iOS. All Mach-O, blob and DER parsing is
// bounds-checked because this code will later consume untrusted guest binaries.
//
// Usage:
//   sign_guest_local [-i identifier] [-s identity] [--team TEAMID] <in> <out>
//   sign_guest_local --adhoc [-i identifier] <in> <out>
//   sign_guest_local --verify <signed-file>
// -s takes a CN substring, an exact CN or a SHA-1 fingerprint; only valid
// code-signing identities count, and more than one match is an error (as in
// codesign). --verify checks structure, hash coverage (including a bound
// Info.plist embedded in __TEXT,__info_plist) and, for CMS signatures, the
// messageDigest binding and the signature itself; it does not evaluate
// certificate trust, and prints certificate names escaped. The output is
// written atomically.
//
// Build:
//   xcrun clang -fobjc-arc -Wall -Wextra -Werror \
//       -framework Foundation -framework Security tools/sign_guest_local.m

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonCrypto.h>
#include <errno.h>
#include <limits.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define SGL_PAGE_BITS 14
#define SGL_PAGE_SIZE (1u << SGL_PAGE_BITS)
#define SGL_HASH_SIZE 32 // SHA-256
#define SGL_MAX_IDENT 128
#define SGL_MAX_SHOWN 128 // bytes of an untrusted name (certificate, segment) shown in output
#define SGL_EXIT_KEY_DENIED 3 // the keychain refused to use the private key

// Blob magics / types (big-endian on disk).
#define SGL_MAGIC_SUPERBLOB 0xfade0cc0u
#define SGL_MAGIC_CODEDIRECTORY 0xfade0c02u
#define SGL_MAGIC_REQUIREMENTS 0xfade0c01u
#define SGL_MAGIC_REQUIREMENT 0xfade0c00u
#define SGL_MAGIC_ENTITLEMENTS 0xfade7171u
#define SGL_MAGIC_DER_ENTITLEMENTS 0xfade7172u
#define SGL_MAGIC_BLOBWRAPPER 0xfade0b01u
#define SGL_SLOT_INFO_PLIST 1u
#define SGL_SLOT_REQUIREMENTS 2u
#define SGL_SLOT_ENTITLEMENTS 5u
#define SGL_SLOT_DER_ENTITLEMENTS 7u
#define SGL_SLOT_CMS 0x10000u
#define SGL_CD_VERSION 0x20400u
#define SGL_CS_ADHOC 0x2u
#define SGL_CS_EXECSEG_MAIN_BINARY 0x1u

// Mach-O constants we rely on (avoid pulling in mach-o headers so field
// offsets below stay explicit and reviewable).
#define SGL_MH_MAGIC_64 0xfeedfacfu
#define SGL_CPU_TYPE_ARM64 0x0100000cu
#define SGL_MH_EXECUTE 0x2u
#define SGL_MH_DYLIB 0x6u
#define SGL_MH_BUNDLE 0x8u
#define SGL_LC_SYMTAB 0x2u
#define SGL_LC_DYSYMTAB 0xbu
#define SGL_LC_SEGMENT_64 0x19u
#define SGL_LC_CODE_SIGNATURE 0x1du
#define SGL_LC_SEGMENT_SPLIT_INFO 0x1eu
#define SGL_LC_DYLD_INFO 0x22u
#define SGL_LC_DYLD_INFO_ONLY 0x80000022u
#define SGL_LC_FUNCTION_STARTS 0x26u
#define SGL_LC_DATA_IN_CODE 0x29u
#define SGL_LC_DYLIB_CODE_SIGN_DRS 0x2bu
#define SGL_LC_ENCRYPTION_INFO_64 0x2cu
#define SGL_LC_LINKER_OPTIMIZATION_HINT 0x2eu
#define SGL_LC_NOTE 0x31u
#define SGL_LC_DYLD_EXPORTS_TRIE 0x80000033u
#define SGL_LC_DYLD_CHAINED_FIXUPS 0x80000034u
#define SGL_LC_ATOM_INFO 0x36u
#define SGL_LC_FUNCTION_VARIANTS 0x37u
#define SGL_LC_FUNCTION_VARIANT_FIXUPS 0x38u
#define SGL_LC_LAZY_LOAD_DYLIB_INFO 0x3au
#define SGL_S_ZEROFILL 0x1u
#define SGL_S_GB_ZEROFILL 0xcu
#define SGL_S_THREAD_LOCAL_ZEROFILL 0x12u

// ---------------------------------------------------------------- utilities

static void sgl_fail_code(int code, NSString *fmt, ...) __attribute__((format(NSString, 2, 3), noreturn));
static void sgl_fail_code(int code, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "sign_guest_local: error: %s\n", msg.UTF8String);
    exit(code);
}

static void sgl_fail(NSString *fmt, ...) __attribute__((format(NSString, 1, 2), noreturn));
static void sgl_fail(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "sign_guest_local: error: %s\n", msg.UTF8String);
    exit(1);
}

// Bounds-checked reader over an immutable buffer.
typedef struct {
    const uint8_t *p;
    size_t len;
} sgl_buf;

static sgl_buf sgl_buf_from_data(NSData *d) {
    sgl_buf b = { (const uint8_t *)d.bytes, d.length };
    return b;
}

static bool sgl_in_bounds(sgl_buf b, size_t off, size_t n) {
    return off <= b.len && n <= b.len - off;
}

static bool sgl_r8(sgl_buf b, size_t off, uint8_t *out) {
    if (!sgl_in_bounds(b, off, 1)) return false;
    *out = b.p[off];
    return true;
}

static bool sgl_r32le(sgl_buf b, size_t off, uint32_t *out) {
    if (!sgl_in_bounds(b, off, 4)) return false;
    *out = (uint32_t)b.p[off] | ((uint32_t)b.p[off + 1] << 8) |
           ((uint32_t)b.p[off + 2] << 16) | ((uint32_t)b.p[off + 3] << 24);
    return true;
}

static bool sgl_r64le(sgl_buf b, size_t off, uint64_t *out) {
    uint32_t lo, hi;
    if (!sgl_r32le(b, off, &lo) || !sgl_r32le(b, off + 4, &hi)) return false;
    *out = (uint64_t)lo | ((uint64_t)hi << 32);
    return true;
}

static bool sgl_r32be(sgl_buf b, size_t off, uint32_t *out) {
    if (!sgl_in_bounds(b, off, 4)) return false;
    *out = ((uint32_t)b.p[off] << 24) | ((uint32_t)b.p[off + 1] << 16) |
           ((uint32_t)b.p[off + 2] << 8) | (uint32_t)b.p[off + 3];
    return true;
}

static bool sgl_r64be(sgl_buf b, size_t off, uint64_t *out) {
    uint32_t hi, lo;
    if (!sgl_r32be(b, off, &hi) || !sgl_r32be(b, off + 4, &lo)) return false;
    *out = ((uint64_t)hi << 32) | lo;
    return true;
}

static void sgl_put32le(uint8_t *p, uint32_t v) {
    for (unsigned i = 0; i < 4; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static void sgl_put64le(uint8_t *p, uint64_t v) {
    for (unsigned i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i));
}

static void sgl_be32(NSMutableData *d, uint32_t v) {
    uint8_t b[4] = { (uint8_t)(v >> 24), (uint8_t)(v >> 16), (uint8_t)(v >> 8), (uint8_t)v };
    [d appendBytes:b length:4];
}

static void sgl_be64(NSMutableData *d, uint64_t v) {
    sgl_be32(d, (uint32_t)(v >> 32));
    sgl_be32(d, (uint32_t)v);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
// CC_SHA256/CC_SHA1 are deprecated in favor of CryptoKit (Swift-only); they
// remain the only C digest primitives available on both macOS and iOS.
static NSData *sgl_sha256(NSData *data) {
    uint8_t md[SGL_HASH_SIZE];
    CC_SHA256(data.bytes, (CC_LONG)data.length, md);
    return [NSData dataWithBytes:md length:SGL_HASH_SIZE];
}

static NSData *sgl_sha1(NSData *data) {
    uint8_t md[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, md);
    return [NSData dataWithBytes:md length:CC_SHA1_DIGEST_LENGTH];
}
#pragma clang diagnostic pop

static NSString *sgl_hex(NSData *d) {
    const uint8_t *p = d.bytes;
    NSMutableString *s = [NSMutableString stringWithCapacity:d.length * 2];
    for (NSUInteger i = 0; i < d.length; i++) [s appendFormat:@"%02x", p[i]];
    return s;
}

// Untrusted bytes (certificate names, Mach-O segment names, paths) made safe
// to print: printable ASCII other than the backslash is kept, every other
// byte is shown as \xNN, and input past `max` bytes is cut and marked "...".
static NSString *sgl_escape_bytes(const uint8_t *p, size_t len, size_t max) {
    NSMutableString *s = [NSMutableString stringWithCapacity:MIN(len, max) + 3];
    for (size_t i = 0; i < len && i < max; i++) {
        if (p[i] >= 0x20 && p[i] < 0x7f && p[i] != '\\') [s appendFormat:@"%c", p[i]];
        else [s appendFormat:@"\\x%02x", p[i]];
    }
    if (len > max) [s appendString:@"..."];
    return s;
}

// sgl_escape_bytes over the UTF-8 form of `s` (nil gives "").
static NSString *sgl_escape(NSString *s, size_t max) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:YES];
    return sgl_escape_bytes(d.bytes, d.length, max);
}

static bool sgl_all_zero(const uint8_t *p, size_t n) {
    for (size_t i = 0; i < n; i++)
        if (p[i]) return false;
    return true;
}

static NSString *sgl_utc_string(NSDate *date, NSString *format) {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    df.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    df.dateFormat = format;
    return [df stringFromDate:date];
}

// Identifiers and team IDs: 1-128 characters from [A-Za-z0-9._-] starting with
// a letter or digit. A conservative subset of what codesign accepts; it keeps
// control characters and separators out of CodeDirectories and logs.
static bool sgl_valid_identifier(NSString *s) {
    NSData *d = [s dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *p = d.bytes;
    if (!d || d.length == 0 || d.length > SGL_MAX_IDENT) return false;
    for (NSUInteger i = 0; i < d.length; i++) {
        uint8_t c = p[i], l = c | 0x20;
        bool alnum = (c >= '0' && c <= '9') || (l >= 'a' && l <= 'z');
        if (!alnum && (i == 0 || (c != '.' && c != '_' && c != '-'))) return false;
    }
    return true;
}

// Replaces `path` atomically: a temporary file in the same directory is
// written, synced and renamed over it, so a failure never leaves a partial
// output behind. Everything that can fail other than I/O (path conversion)
// happens before the temporary file exists.
static void sgl_write_atomic(NSData *data, NSString *path) {
    if (path.length == 0) sgl_fail(@"empty output path");
    NSString *dir = path.stringByDeletingLastPathComponent;
    NSString *tmpl = [(dir.length ? dir : @".") stringByAppendingPathComponent:
                      [NSString stringWithFormat:@".%@.XXXXXX", path.lastPathComponent]];
    const char *dst = path.fileSystemRepresentation;
    char *tmp = strdup(tmpl.fileSystemRepresentation);
    int fd = tmp ? mkstemp(tmp) : -1;
    if (fd < 0) sgl_fail(@"cannot create a temporary file next to %@: %s", path, strerror(errno));
    const uint8_t *p = data.bytes;
    size_t left = data.length;
    bool ok = true;
    while (ok && left) {
        ssize_t n = write(fd, p, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) ok = false;
        else { p += n; left -= (size_t)n; }
    }
    ok = ok && fchmod(fd, 0755) == 0 && fsync(fd) == 0;
    ok = close(fd) == 0 && ok;
    if (!ok || rename(tmp, dst) != 0) {
        int err = errno;
        unlink(tmp);
        free(tmp);
        sgl_fail(@"cannot write %@: %s", path, strerror(err));
    }
    free(tmp);
}

// ------------------------------------------------------------- Mach-O model

typedef struct {
    uint64_t vmaddr, vmsize, fileoff, filesize;
} sgl_segment;

typedef struct {
    uint32_t filetype;
    uint32_t ncmds;
    uint32_t sizeofcmds;
    size_t cmdsEnd;        // 32 + sizeofcmds
    size_t contentStart;   // lowest file offset of content past the load commands
    uint64_t dataEnd;      // end of the last linkedit data range (signature excluded)
    bool hasText;
    uint64_t textFileoff, textFilesize;
    bool hasLinkedit;
    size_t linkeditCmdOff; // offset of the LC_SEGMENT_64 command for __LINKEDIT
    uint64_t leVmaddr, leVmsize, leFileoff, leFilesize;
    bool hasCodeSignature;
    uint32_t sigOff, sigSize; // LC_CODE_SIGNATURE dataoff / datasize
    bool hasInfoPlist;        // __TEXT,__info_plist: an embedded Info.plist
    uint32_t infoPlistOff;    // file offset and size of its first such section,
    uint64_t infoPlistSize;   // the one codesign binds (not range-checked here)
} sgl_macho;

// Records a file range referenced by load command `i`: it must lie inside the
// file and past the load commands; the lowest start bounds the header pad.
static void sgl_note_range(sgl_buf f, sgl_macho *m, uint32_t i, uint64_t off, uint64_t size, bool linkedit) {
    if (size == 0) return;
    if (off > f.len || size > f.len - off)
        sgl_fail(@"load command %u references [%#llx, +%#llx) outside the file (%zu bytes)", i, off, size, f.len);
    if (off < m->cmdsEnd)
        sgl_fail(@"load command %u references data at %#llx inside the load commands", i, off);
    if (off < m->contentStart) m->contentStart = (size_t)off;
    if (linkedit && off + size > m->dataEnd) m->dataEnd = off + size;
}

static bool sgl_overlap(uint64_t a, uint64_t alen, uint64_t b, uint64_t blen) {
    return alen && blen && a < b + blen && b < a + alen;
}

// Parses and validates the header, load commands and segment layout. Both
// signing and --verify depend on: every segment inside the file and without
// VM wrap, no overlapping segments, exactly one __TEXT (at file offset 0,
// containing the load commands) and one __LINKEDIT (last in file and VM
// order, ending at EOF), every referenced data range inside the file and past
// the load commands, and at most one LC_CODE_SIGNATURE, covering the end of
// __LINKEDIT.
static void sgl_parse_macho(sgl_buf f, bool allowSigned, sgl_macho *m) {
    memset(m, 0, sizeof(*m));
    uint32_t magic, cputype;
    if (!sgl_r32le(f, 0, &magic) || !sgl_r32le(f, 4, &cputype))
        sgl_fail(@"truncated Mach-O header (%zu bytes)", f.len);
    if (magic != SGL_MH_MAGIC_64)
        sgl_fail(@"not a thin 64-bit Mach-O (magic 0x%08x); fat or 32-bit inputs are unsupported", magic);
    if (cputype != SGL_CPU_TYPE_ARM64)
        sgl_fail(@"not an arm64 Mach-O (cputype 0x%08x)", cputype);
    if (f.len < 32 || !sgl_r32le(f, 12, &m->filetype) || !sgl_r32le(f, 16, &m->ncmds) ||
        !sgl_r32le(f, 20, &m->sizeofcmds))
        sgl_fail(@"truncated Mach-O header");
    if (m->filetype != SGL_MH_EXECUTE && m->filetype != SGL_MH_DYLIB && m->filetype != SGL_MH_BUNDLE)
        sgl_fail(@"unsupported Mach-O file type %u (need an executable, dylib or bundle)", m->filetype);
    if (m->ncmds > 4096)
        sgl_fail(@"implausible ncmds %u", m->ncmds);
    uint64_t cmdsEnd64 = 32ull + m->sizeofcmds;
    if (cmdsEnd64 > f.len)
        sgl_fail(@"load commands (%u bytes) extend past end of file (%zu)", m->sizeofcmds, f.len);
    m->cmdsEnd = (size_t)cmdsEnd64;
    m->contentStart = f.len;

    NSMutableData *segStore = [NSMutableData dataWithLength:(m->ncmds + 1) * sizeof(sgl_segment)];
    sgl_segment *segs = segStore.mutableBytes;
    uint32_t nsegs = 0;
    size_t off = 32;
    for (uint32_t i = 0; i < m->ncmds; i++) {
        uint32_t cmd, cmdsize;
        if (m->cmdsEnd - off < 8 || !sgl_r32le(f, off, &cmd) || !sgl_r32le(f, off + 4, &cmdsize))
            sgl_fail(@"truncated load command %u", i);
        if (cmdsize < 8 || (cmdsize & 7) != 0 || cmdsize > m->cmdsEnd - off)
            sgl_fail(@"malformed load command %u (cmd 0x%x size %u)", i, cmd, cmdsize);
        switch (cmd) {
        case SGL_LC_SEGMENT_64: {
            uint32_t nsects;
            uint64_t vmaddr, vmsize, fileoff, filesize;
            if (cmdsize < 72 || !sgl_r64le(f, off + 24, &vmaddr) || !sgl_r64le(f, off + 32, &vmsize) ||
                !sgl_r64le(f, off + 40, &fileoff) || !sgl_r64le(f, off + 48, &filesize) ||
                !sgl_r32le(f, off + 64, &nsects))
                sgl_fail(@"short LC_SEGMENT_64 at command %u", i);
            if ((uint64_t)cmdsize != 72ull + 80ull * nsects)
                sgl_fail(@"LC_SEGMENT_64 %u: section array (%u sections) does not match cmdsize %u", i, nsects, cmdsize);
            char segname[17];
            memcpy(segname, f.p + off + 8, 16);
            segname[16] = '\0';
            NSString *shown = sgl_escape_bytes((const uint8_t *)segname, strlen(segname), 16);
            if (fileoff > f.len || filesize > f.len - fileoff)
                sgl_fail(@"segment %@ [%#llx, +%#llx) extends past end of file (%zu bytes)", shown, fileoff, filesize, f.len);
            if (vmsize > UINT64_MAX - vmaddr)
                sgl_fail(@"segment %@ VM range [%#llx, +%#llx) wraps", shown, vmaddr, vmsize);
            if (filesize > vmsize)
                sgl_fail(@"segment %@ filesize %#llx exceeds vmsize %#llx", shown, filesize, vmsize);
            if (fileoff > 0 && filesize > 0) {
                if (fileoff < m->cmdsEnd)
                    sgl_fail(@"segment %@ at file offset %#llx overlaps the load commands", shown, fileoff);
                if (fileoff < m->contentStart) m->contentStart = (size_t)fileoff;
            }
            // section_64: sectname[16] segname[16] addr size offset align
            // reloff nreloc flags ...; size at +40, offset at +48, flags at +64.
            for (uint32_t s = 0; s < nsects; s++) {
                size_t soff = off + 72 + 80 * (size_t)s;
                uint64_t sectSize;
                uint32_t sectOff, sflags;
                if (!sgl_r64le(f, soff + 40, &sectSize) || !sgl_r32le(f, soff + 48, &sectOff) ||
                    !sgl_r32le(f, soff + 64, &sflags))
                    sgl_fail(@"truncated section %u of command %u", s, i);
                // codesign binds the first __info_plist section of the __TEXT
                // segment, whatever its type; --verify bounds-checks it.
                if (!m->hasInfoPlist && strcmp(segname, "__TEXT") == 0 &&
                    strncmp((const char *)f.p + soff, "__info_plist", 16) == 0) {
                    m->hasInfoPlist = true;
                    m->infoPlistOff = sectOff;
                    m->infoPlistSize = sectSize;
                }
                uint32_t type = sflags & 0xff;
                if (sectSize == 0 || type == SGL_S_ZEROFILL || type == SGL_S_GB_ZEROFILL ||
                    type == SGL_S_THREAD_LOCAL_ZEROFILL)
                    continue; // no file content
                if (sectOff < m->cmdsEnd)
                    sgl_fail(@"section %u of segment %@ at file offset %#x overlaps the load commands", s, shown, sectOff);
                if (sectOff < fileoff || sectOff - fileoff > filesize || sectSize > filesize - (sectOff - fileoff))
                    sgl_fail(@"section %u of segment %@ [%#x, +%#llx) lies outside the segment's file range",
                             s, shown, sectOff, sectSize);
                if (sectOff < m->contentStart) m->contentStart = sectOff;
            }
            if (strcmp(segname, "__TEXT") == 0) {
                if (m->hasText) sgl_fail(@"more than one __TEXT segment");
                m->hasText = true;
                m->textFileoff = fileoff;
                m->textFilesize = filesize;
            }
            if (strcmp(segname, "__LINKEDIT") == 0) {
                if (m->hasLinkedit) sgl_fail(@"more than one __LINKEDIT segment");
                m->hasLinkedit = true;
                m->linkeditCmdOff = off;
                m->leVmaddr = vmaddr;
                m->leVmsize = vmsize;
                m->leFileoff = fileoff;
                m->leFilesize = filesize;
            } else {
                segs[nsegs++] = (sgl_segment){ vmaddr, vmsize, fileoff, filesize };
            }
            break;
        }
        case SGL_LC_CODE_SIGNATURE:
            if (m->hasCodeSignature) sgl_fail(@"more than one LC_CODE_SIGNATURE");
            if (cmdsize != 16) sgl_fail(@"LC_CODE_SIGNATURE (command %u) has size %u, expected 16", i, cmdsize);
            m->hasCodeSignature = true;
            sgl_r32le(f, off + 8, &m->sigOff);
            sgl_r32le(f, off + 12, &m->sigSize);
            if (m->sigSize == 0) sgl_fail(@"empty LC_CODE_SIGNATURE");
            sgl_note_range(f, m, i, m->sigOff, m->sigSize, false);
            break;
        case SGL_LC_SEGMENT_SPLIT_INFO:
        case SGL_LC_FUNCTION_STARTS:
        case SGL_LC_DATA_IN_CODE:
        case SGL_LC_DYLIB_CODE_SIGN_DRS:
        case SGL_LC_LINKER_OPTIMIZATION_HINT:
        case SGL_LC_DYLD_EXPORTS_TRIE:
        case SGL_LC_DYLD_CHAINED_FIXUPS:
        case SGL_LC_ATOM_INFO:
        case SGL_LC_FUNCTION_VARIANTS:
        case SGL_LC_FUNCTION_VARIANT_FIXUPS:
        case SGL_LC_LAZY_LOAD_DYLIB_INFO: {
            uint32_t dataoff, datasize;
            if (cmdsize != 16 || !sgl_r32le(f, off + 8, &dataoff) || !sgl_r32le(f, off + 12, &datasize))
                sgl_fail(@"malformed linkedit_data_command %u (cmd 0x%x size %u)", i, cmd, cmdsize);
            sgl_note_range(f, m, i, dataoff, datasize, true);
            break;
        }
        case SGL_LC_SYMTAB: {
            uint32_t symoff, nsyms, stroff, strsize;
            if (cmdsize != 24 || !sgl_r32le(f, off + 8, &symoff) || !sgl_r32le(f, off + 12, &nsyms) ||
                !sgl_r32le(f, off + 16, &stroff) || !sgl_r32le(f, off + 20, &strsize))
                sgl_fail(@"malformed LC_SYMTAB (command %u)", i);
            sgl_note_range(f, m, i, symoff, (uint64_t)nsyms * 16, true);
            sgl_note_range(f, m, i, stroff, strsize, true);
            break;
        }
        case SGL_LC_DYSYMTAB: {
            // tocoff/ntoc, modtaboff/nmodtab, extrefsymoff/nextrefsyms,
            // indirectsymoff/nindirectsyms, extreloff/nextrel, locreloff/nlocrel
            static const uint32_t entrySize[6] = { 8, 56, 4, 4, 8, 8 };
            if (cmdsize != 80) sgl_fail(@"malformed LC_DYSYMTAB (command %u)", i);
            for (unsigned k = 0; k < 6; k++) {
                uint32_t tOff, tCount;
                sgl_r32le(f, off + 32 + 8 * k, &tOff);
                sgl_r32le(f, off + 36 + 8 * k, &tCount);
                sgl_note_range(f, m, i, tOff, (uint64_t)tCount * entrySize[k], true);
            }
            break;
        }
        case SGL_LC_DYLD_INFO:
        case SGL_LC_DYLD_INFO_ONLY:
            // rebase, bind, weak_bind, lazy_bind, export: (off, size) pairs
            if (cmdsize != 48) sgl_fail(@"malformed LC_DYLD_INFO (command %u)", i);
            for (unsigned k = 0; k < 5; k++) {
                uint32_t tOff, tSize;
                sgl_r32le(f, off + 8 + 8 * k, &tOff);
                sgl_r32le(f, off + 12 + 8 * k, &tSize);
                sgl_note_range(f, m, i, tOff, tSize, true);
            }
            break;
        case SGL_LC_ENCRYPTION_INFO_64: {
            uint32_t cryptoff, cryptsize;
            if (cmdsize != 24 || !sgl_r32le(f, off + 8, &cryptoff) || !sgl_r32le(f, off + 12, &cryptsize))
                sgl_fail(@"malformed LC_ENCRYPTION_INFO_64 (command %u)", i);
            sgl_note_range(f, m, i, cryptoff, cryptsize, false);
            break;
        }
        case SGL_LC_NOTE: {
            uint64_t noteOff, noteSize;
            if (cmdsize != 40 || !sgl_r64le(f, off + 24, &noteOff) || !sgl_r64le(f, off + 32, &noteSize))
                sgl_fail(@"malformed LC_NOTE (command %u)", i);
            sgl_note_range(f, m, i, noteOff, noteSize, false);
            break;
        }
        default:
            break;
        }
        off += cmdsize;
    }
    if (off != m->cmdsEnd)
        sgl_fail(@"load commands do not end on sizeofcmds boundary");
    if (m->hasCodeSignature && !allowSigned)
        sgl_fail(@"input already has LC_CODE_SIGNATURE; refusing to re-sign");
    if (!m->hasText) sgl_fail(@"no __TEXT segment found");
    if (!m->hasLinkedit) sgl_fail(@"no __LINKEDIT segment found");
    // dyld maps the header and load commands through __TEXT. Once __TEXT
    // covers [0, cmdsEnd), the pairwise check below also rejects any other
    // segment mapping the header.
    if (m->textFileoff != 0 || m->textFilesize < m->cmdsEnd)
        sgl_fail(@"__TEXT [%#llx, +%#llx) must start at file offset 0 and contain the load commands (%#zx bytes)",
                 m->textFileoff, m->textFilesize, m->cmdsEnd);
    if (m->leFileoff < m->cmdsEnd)
        sgl_fail(@"__LINKEDIT at file offset %#llx overlaps the load commands", m->leFileoff);
    for (uint32_t a = 0; a < nsegs; a++) {
        if (segs[a].filesize && segs[a].fileoff + segs[a].filesize > m->leFileoff)
            sgl_fail(@"__LINKEDIT is not the last segment in the file (a segment ends at %#llx, __LINKEDIT starts at %#llx)",
                     segs[a].fileoff + segs[a].filesize, m->leFileoff);
        if (segs[a].vmsize && segs[a].vmaddr + segs[a].vmsize > m->leVmaddr)
            sgl_fail(@"__LINKEDIT is not the last segment in memory (a segment ends at %#llx, __LINKEDIT starts at %#llx)",
                     segs[a].vmaddr + segs[a].vmsize, m->leVmaddr);
        for (uint32_t b = a + 1; b < nsegs; b++) {
            if (sgl_overlap(segs[a].fileoff, segs[a].filesize, segs[b].fileoff, segs[b].filesize))
                sgl_fail(@"segments overlap in the file at %#llx and %#llx", segs[a].fileoff, segs[b].fileoff);
            if (sgl_overlap(segs[a].vmaddr, segs[a].vmsize, segs[b].vmaddr, segs[b].vmsize))
                sgl_fail(@"segments overlap in memory at %#llx and %#llx", segs[a].vmaddr, segs[b].vmaddr);
        }
    }
    // The signature is appended after the file, inside a grown __LINKEDIT;
    // trailing bytes outside every segment are not supported.
    if (m->leFileoff + m->leFilesize != f.len)
        sgl_fail(@"__LINKEDIT [%#llx, +%#llx) does not end at the end of the file (%zu bytes)",
                 m->leFileoff, m->leFilesize, f.len);
    if (m->hasCodeSignature) {
        if (m->sigOff < m->leFileoff || (uint64_t)m->sigOff + m->sigSize != f.len)
            sgl_fail(@"code signature [%#x, +%#x) is not at the end of __LINKEDIT and the file", m->sigOff, m->sigSize);
        if (m->dataEnd > m->sigOff)
            sgl_fail(@"linkedit data extends into the code signature");
    }
}

// ------------------------------------------------------------ DER utilities

// Low-tag-number-form DER reader; all tags we handle are < 31. Lengths must
// be definite and minimally encoded. Advances *pp past the TLV; returns tag,
// content slice, and raw TLV extent.
static bool sgl_der_tlv(const uint8_t **pp, const uint8_t *end,
                        uint8_t *tag, const uint8_t **content, size_t *contentLen,
                        const uint8_t **tlv, size_t *tlvLen) {
    const uint8_t *p = *pp;
    if (p >= end) return false;
    const uint8_t *start = p;
    if ((*p & 0x1f) == 0x1f) return false; // multi-byte tags not used here
    *tag = *p++;
    if (p >= end) return false;
    uint8_t lb = *p++;
    size_t len;
    if ((lb & 0x80) == 0) {
        len = lb;
    } else {
        unsigned n = lb & 0x7f;
        // no indefinite form (0x80), at most 4 length bytes, no leading zero
        if (n == 0 || n > 4 || (size_t)(end - p) < n || *p == 0) return false;
        len = 0;
        for (unsigned i = 0; i < n; i++) len = (len << 8) | *p++;
        if (len < 0x80) return false; // DER requires the short form
    }
    if ((size_t)(end - p) < len) return false;
    *content = p;
    *contentLen = len;
    *tlv = start;
    *tlvLen = (size_t)(p - start) + len;
    *pp = p + len;
    return true;
}

// BER reader for the CMS outer layers, which Apple's signer (and this tool)
// encode with indefinite lengths: a constructed element may use 0x80 and end
// with an end-of-contents marker, whose content then excludes the marker.
// Definite lengths follow the strict DER rules above; nesting is bounded.
static bool sgl_ber_tlv(const uint8_t **pp, const uint8_t *end, unsigned depth,
                        uint8_t *tag, const uint8_t **content, size_t *contentLen) {
    const uint8_t *p = *pp, *tlv;
    size_t tlvLen;
    if (depth > 16 || p >= end || end - p < 2) return false;
    if (p[1] != 0x80) return sgl_der_tlv(pp, end, tag, content, contentLen, &tlv, &tlvLen);
    if ((p[0] & 0x1f) == 0x1f || (p[0] & 0x20) == 0) return false; // constructed only
    const uint8_t *c = p + 2, *q = c;
    while (!(end - q >= 2 && q[0] == 0 && q[1] == 0)) {
        uint8_t t;
        const uint8_t *cc;
        size_t cl;
        if (!sgl_ber_tlv(&q, end, depth + 1, &t, &cc, &cl)) return false;
    }
    *tag = p[0];
    *content = c;
    *contentLen = (size_t)(q - c);
    *pp = q + 2;
    return true;
}

// Next element of *in (advancing it) with the expected tag; BER or strict DER.
static bool sgl_ber_next(sgl_buf *in, unsigned depth, uint8_t want, sgl_buf *content) {
    const uint8_t *p = in->p, *c;
    uint8_t tag;
    size_t clen;
    if (!sgl_ber_tlv(&p, in->p + in->len, depth, &tag, &c, &clen) || tag != want) return false;
    *content = (sgl_buf){ c, clen };
    in->len -= (size_t)(p - in->p);
    in->p = p;
    return true;
}

static bool sgl_der_next(sgl_buf *in, uint8_t want, sgl_buf *content, sgl_buf *whole) {
    const uint8_t *p = in->p, *c, *tlv;
    uint8_t tag;
    size_t clen, tlvLen;
    if (!sgl_der_tlv(&p, in->p + in->len, &tag, &c, &clen, &tlv, &tlvLen) || tag != want) return false;
    *content = (sgl_buf){ c, clen };
    if (whole) *whole = (sgl_buf){ tlv, tlvLen };
    in->len -= (size_t)(p - in->p);
    in->p = p;
    return true;
}

static bool sgl_oid_is(sgl_buf c, const uint8_t *oid, size_t n) {
    return c.len == n && memcmp(c.p, oid, n) == 0;
}

// AlgorithmIdentifier content: an OID and absent or NULL parameters (RFC 5754
// allows both for SHA-2 digests; RSA signatures use NULL, ECDSA none).
static bool sgl_alg_id(sgl_buf alg, sgl_buf *oid) {
    sgl_buf null;
    if (!sgl_der_next(&alg, 0x06, oid, NULL)) return false;
    if (alg.len && (!sgl_der_next(&alg, 0x05, &null, NULL) || null.len)) return false;
    return alg.len == 0;
}

static void sgl_der_len(NSMutableData *d, size_t len) {
    if (len < 0x80) {
        uint8_t b = (uint8_t)len;
        [d appendBytes:&b length:1];
    } else {
        uint8_t tmp[8];
        unsigned n = 0;
        size_t v = len;
        while (v) { tmp[7 - n] = (uint8_t)v; v >>= 8; n++; }
        uint8_t hdr = 0x80 | (uint8_t)n;
        [d appendBytes:&hdr length:1];
        [d appendBytes:tmp + (8 - n) length:n];
    }
}

static void sgl_der_tag(NSMutableData *d, uint8_t tag, NSData *content) {
    [d appendBytes:&tag length:1];
    sgl_der_len(d, content.length);
    [d appendData:content];
}

static NSData *sgl_der(uint8_t tag, NSData *content) {
    NSMutableData *d = [NSMutableData data];
    sgl_der_tag(d, tag, content);
    return d;
}

static NSData *sgl_der_oid(const uint8_t *bytes, size_t n) {
    return sgl_der(0x06, [NSData dataWithBytes:bytes length:n]);
}

static NSData *sgl_der_int(uint64_t v) {
    uint8_t b[8] = {0};
    unsigned n = 0;
    while (v) { b[7 - n] = (uint8_t)v; v >>= 8; n++; }
    if (n == 0) n = 1; // value zero: a single 0x00 content byte
    NSMutableData *d = [NSMutableData data];
    if (b[8 - n] & 0x80) [d appendBytes:"\0" length:1]; // keep it positive
    [d appendBytes:b + (8 - n) length:n];
    return sgl_der(0x02, d);
}

static NSData *sgl_alg_seq(const uint8_t *oid, size_t oidLen, BOOL withNull) {
    NSMutableData *c = [NSMutableData data];
    [c appendData:sgl_der_oid(oid, oidLen)];
    if (withNull) [c appendBytes:"\x05\x00" length:2];
    return sgl_der(0x30, c);
}

// UTCTime YYMMDDHHMMSSZ or GeneralizedTime YYYYMMDDHHMMSSZ (the DER forms).
static NSDate *sgl_der_time(uint8_t tag, const uint8_t *p, size_t len) {
    size_t ylen = tag == 0x17 ? 2 : tag == 0x18 ? 4 : 0;
    if (ylen == 0 || len != ylen + 11 || p[len - 1] != 'Z') return nil;
    for (size_t i = 0; i + 1 < len; i++)
        if (p[i] < '0' || p[i] > '9') return nil;
    int year = 0;
    for (size_t i = 0; i < ylen; i++) year = year * 10 + (p[i] - '0');
    if (ylen == 2) year += year < 50 ? 2000 : 1900;
    const uint8_t *q = p + ylen;
    int f[5];
    for (unsigned i = 0; i < 5; i++) f[i] = (q[2 * i] - '0') * 10 + (q[2 * i + 1] - '0');
    if (f[0] < 1 || f[0] > 12 || f[1] < 1 || f[1] > 31 || f[2] > 23 || f[3] > 59 || f[4] > 59) return nil;
    struct tm tm = { .tm_year = year - 1900, .tm_mon = f[0] - 1, .tm_mday = f[1],
                     .tm_hour = f[2], .tm_min = f[3], .tm_sec = f[4] };
    return [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)timegm(&tm)];
}

static NSData *sgl_der_time_enc(NSDate *date) {
    NSInteger year = sgl_utc_string(date, @"yyyy").integerValue;
    BOOL utc = year >= 1950 && year < 2050;
    NSString *s = sgl_utc_string(date, utc ? @"yyMMddHHmmss'Z'" : @"yyyyMMddHHmmss'Z'");
    return sgl_der(utc ? 0x17 : 0x18, [s dataUsingEncoding:NSASCIIStringEncoding]);
}

// ----------------------------------------------------- certificate decoding

typedef struct {
    NSData *tbsTLV;     // raw TBSCertificate, what the issuer signed
    NSData *serialTLV;  // raw INTEGER TLV
    NSData *issuerTLV;  // raw Name TLV of the issuer
    NSData *subjectTLV; // raw Name TLV of the subject
    NSString *subjectCN;
    NSString *subjectOU;
    NSDate *notBefore, *notAfter;
    NSData *sigAlgOID;  // outer signatureAlgorithm OID content
    NSData *signature;  // signatureValue without the unused-bits byte
    bool selfSigned;    // subject == issuer
    bool codeSigning;   // extendedKeyUsage lists id-kp-codeSigning
} sgl_cert_info;

static NSString *sgl_der_string(uint8_t tag, const uint8_t *p, size_t len) {
    if (tag == 0x1e) // BMPString, UTF-16BE
        return [[NSString alloc] initWithBytes:p length:len encoding:NSUTF16BigEndianStringEncoding];
    // UTF8String, PrintableString, TeletexString (ASCII subset), IA5String
    return [[NSString alloc] initWithBytes:p length:len encoding:NSUTF8StringEncoding];
}

// Parse an X.501 Name (SET OF RDN) content and return attr for OID {55,04,x}.
static NSString *sgl_name_attr(const uint8_t *p, size_t len, uint8_t oidLastByte) {
    const uint8_t *end = p + len;
    while (p < end) {
        uint8_t tag;
        const uint8_t *c, *tlv;
        size_t clen, tlvlen;
        if (!sgl_der_tlv(&p, end, &tag, &c, &clen, &tlv, &tlvlen) || tag != 0x31) return nil;
        const uint8_t *rp = c, *rend = c + clen;
        while (rp < rend) {
            const uint8_t *rc, *rtlv;
            size_t rclen, rtlvlen;
            uint8_t rtag;
            if (!sgl_der_tlv(&rp, rend, &rtag, &rc, &rclen, &rtlv, &rtlvlen) || rtag != 0x30) return nil;
            const uint8_t *ap = rc, *aend = rc + rclen;
            const uint8_t *oc, *otlv, *vc, *vtlv;
            size_t oclen, otlvlen, vclen, vtlvlen;
            uint8_t otag, vtag;
            if (!sgl_der_tlv(&ap, aend, &otag, &oc, &oclen, &otlv, &otlvlen) || otag != 0x06) return nil;
            if (!sgl_der_tlv(&ap, aend, &vtag, &vc, &vclen, &vtlv, &vtlvlen)) return nil;
            if (oclen == 3 && oc[0] == 0x55 && oc[1] == 0x04 && oc[2] == oidLastByte)
                return sgl_der_string(vtag, vc, vclen);
        }
    }
    return nil;
}

// [3] Extensions: sets info->codeSigning when extendedKeyUsage lists
// id-kp-codeSigning (codesign -v enforces that EKU).
static bool sgl_parse_extensions(sgl_buf ext, sgl_cert_info *info) {
    static const uint8_t kOidExtKeyUsage[] = { 0x55, 0x1d, 0x25 };
    static const uint8_t kOidCodeSigningKP[] = { 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03 };
    sgl_buf seq, x, oid, val, kps, kp;
    if (!sgl_der_next(&ext, 0x30, &seq, NULL) || ext.len) return false;
    while (seq.len) {
        if (!sgl_der_next(&seq, 0x30, &x, NULL) || !sgl_der_next(&x, 0x06, &oid, NULL)) return false;
        sgl_buf critical;
        if (x.len && x.p[0] == 0x01 && !sgl_der_next(&x, 0x01, &critical, NULL)) return false;
        if (!sgl_der_next(&x, 0x04, &val, NULL) || x.len) return false;
        if (!sgl_oid_is(oid, kOidExtKeyUsage, sizeof(kOidExtKeyUsage))) continue;
        if (!sgl_der_next(&val, 0x30, &kps, NULL) || val.len) return false;
        while (kps.len) {
            if (!sgl_der_next(&kps, 0x06, &kp, NULL)) return false;
            if (sgl_oid_is(kp, kOidCodeSigningKP, sizeof(kOidCodeSigningKP))) info->codeSigning = true;
        }
    }
    return true;
}

static bool sgl_parse_certificate(NSData *der, sgl_cert_info *info) {
    *info = (sgl_cert_info){0};
    sgl_buf in = sgl_buf_from_data(der), cert, tbs, tbsTLV, x, xTLV, vp;
    if (!sgl_der_next(&in, 0x30, &cert, NULL) || in.len) return false;
    // TBSCertificate, kept raw: it is what the issuer signed
    if (!sgl_der_next(&cert, 0x30, &tbs, &tbsTLV)) return false;
    info->tbsTLV = [NSData dataWithBytes:tbsTLV.p length:tbsTLV.len];
    if (tbs.len && tbs.p[0] == 0xa0 && !sgl_der_next(&tbs, 0xa0, &x, NULL)) return false; // [0] version
    // serialNumber INTEGER — keep the raw TLV
    if (!sgl_der_next(&tbs, 0x02, &x, &xTLV)) return false;
    info->serialTLV = [NSData dataWithBytes:xTLV.p length:xTLV.len];
    // signature AlgorithmIdentifier
    if (!sgl_der_next(&tbs, 0x30, &x, NULL)) return false;
    // issuer Name — keep the raw TLV
    if (!sgl_der_next(&tbs, 0x30, &x, &xTLV)) return false;
    info->issuerTLV = [NSData dataWithBytes:xTLV.p length:xTLV.len];
    // validity
    if (!sgl_der_next(&tbs, 0x30, &vp, NULL)) return false;
    for (unsigned i = 0; i < 2; i++) {
        const uint8_t *p = vp.p, *c, *tlv;
        uint8_t tag;
        size_t clen, tlvLen;
        if (!sgl_der_tlv(&p, vp.p + vp.len, &tag, &c, &clen, &tlv, &tlvLen)) return false;
        NSDate *t = sgl_der_time(tag, c, clen);
        if (!t) return false;
        if (i == 0) info->notBefore = t; else info->notAfter = t;
        vp.len -= (size_t)(p - vp.p);
        vp.p = p;
    }
    if (vp.len) return false;
    // subject Name
    if (!sgl_der_next(&tbs, 0x30, &x, &xTLV)) return false;
    info->subjectTLV = [NSData dataWithBytes:xTLV.p length:xTLV.len];
    info->subjectCN = sgl_name_attr(x.p, x.len, 0x03);
    info->subjectOU = sgl_name_attr(x.p, x.len, 0x0b);
    info->selfSigned = [info->subjectTLV isEqual:info->issuerTLV];
    // subjectPublicKeyInfo, then optional [1]/[2] unique IDs and [3] extensions
    if (!sgl_der_next(&tbs, 0x30, &x, NULL)) return false;
    if (tbs.len && tbs.p[0] == 0x81 && !sgl_der_next(&tbs, 0x81, &x, NULL)) return false;
    if (tbs.len && tbs.p[0] == 0x82 && !sgl_der_next(&tbs, 0x82, &x, NULL)) return false;
    if (tbs.len && (!sgl_der_next(&tbs, 0xa3, &x, NULL) || !sgl_parse_extensions(x, info))) return false;
    if (tbs.len) return false;
    // signatureAlgorithm and signatureValue
    sgl_buf alg, oid;
    if (!sgl_der_next(&cert, 0x30, &alg, NULL) || !sgl_der_next(&alg, 0x06, &oid, NULL)) return false;
    info->sigAlgOID = [NSData dataWithBytes:oid.p length:oid.len];
    if (!sgl_der_next(&cert, 0x03, &x, NULL) || x.len < 1 || x.p[0] != 0 || cert.len) return false;
    info->signature = [NSData dataWithBytes:x.p + 1 length:x.len - 1];
    return info->subjectCN != nil;
}

static bool sgl_cert_valid_at(const sgl_cert_info *ci, NSDate *now) {
    return [now compare:ci->notBefore] != NSOrderedAscending && [now compare:ci->notAfter] != NSOrderedDescending;
}

// SecKeyAlgorithm for an X.509 signatureAlgorithm OID (PKCS#1 v1.5 RSA with
// SHA-1/256/384/512, ECDSA with SHA-256/384/512), or NULL.
static SecKeyAlgorithm sgl_x509_sig_alg(NSData *oid) {
    static const uint8_t kPkcs1[8] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01 };
    static const uint8_t kEcdsaSha2[7] = { 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03 };
    const uint8_t *p = oid.bytes;
    if (oid.length == 9 && memcmp(p, kPkcs1, 8) == 0) {
        switch (p[8]) {
        case 0x05: return kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA1;
        case 0x0b: return kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256;
        case 0x0c: return kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA384;
        case 0x0d: return kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA512;
        }
    } else if (oid.length == 8 && memcmp(p, kEcdsaSha2, 7) == 0) {
        switch (p[7]) {
        case 0x02: return kSecKeyAlgorithmECDSASignatureMessageX962SHA256;
        case 0x03: return kSecKeyAlgorithmECDSASignatureMessageX962SHA384;
        case 0x04: return kSecKeyAlgorithmECDSASignatureMessageX962SHA512;
        }
    }
    return NULL;
}

// Whether the certificate `issuerDER`'s public key verifies child's signature.
static bool sgl_cert_issued_by(const sgl_cert_info *child, NSData *issuerDER) {
    SecKeyAlgorithm alg = sgl_x509_sig_alg(child->sigAlgOID);
    SecCertificateRef cert = alg ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)issuerDER) : NULL;
    SecKeyRef key = cert ? SecCertificateCopyKey(cert) : NULL;
    if (cert) CFRelease(cert);
    if (!key) return false;
    bool ok = SecKeyVerifySignature(key, alg, (__bridge CFDataRef)child->tbsTLV,
                                    (__bridge CFDataRef)child->signature, NULL);
    CFRelease(key);
    return ok;
}

// First candidate that issued `child`: its subject equals child's issuer, it
// is valid at `now`, self-signed exactly when a root is wanted, and its key
// verifies child's signature (several WWDR generations share a subject).
static NSData *sgl_find_issuer(const sgl_cert_info *child, NSArray<NSData *> *candidates, NSDate *now, bool root) {
    for (NSData *der in candidates) {
        sgl_cert_info ci;
        if (!sgl_parse_certificate(der, &ci) || ci.selfSigned != root || ![ci.subjectTLV isEqual:child->issuerTLV] ||
            !sgl_cert_valid_at(&ci, now))
            continue;
        if (sgl_cert_issued_by(child, der)) return der;
    }
    return nil;
}

// Certificates to embed, ordered like Apple's CMS: the intermediate that
// issued the leaf (WWDR), then its root when one is among the candidates
// (Apple embeds the Apple Root CA as well), leaf last. Returns nil with
// *error when no issuing intermediate is found.
static NSArray<NSData *> *sgl_select_chain(NSData *leafDER, NSArray<NSData *> *candidates, NSDate *now,
                                           NSString **error) {
    sgl_cert_info leaf, inter;
    if (!sgl_parse_certificate(leafDER, &leaf)) {
        *error = @"cannot parse the leaf certificate";
        return nil;
    }
    NSData *interDER = sgl_find_issuer(&leaf, candidates, now, false);
    if (!interDER || !sgl_parse_certificate(interDER, &inter)) {
        *error = [NSString stringWithFormat:@"could not locate the intermediate CA certificate (WWDR) that issued '%@'",
                  sgl_escape(leaf.subjectCN, SGL_MAX_SHOWN)];
        return nil;
    }
    NSMutableArray<NSData *> *certs = [NSMutableArray arrayWithObject:interDER];
    NSData *rootDER = sgl_find_issuer(&inter, candidates, now, true);
    if (rootDER) [certs addObject:rootDER];
    [certs addObject:leafDER];
    return certs;
}

// Picks one identity certificate: valid at `now`, with the code-signing EKU,
// in `team` (subject OU) when given, then matched by SHA-1 fingerprint (40 hex
// digits), exact CN, or CN substring, in that order. More than one distinct
// certificate is ambiguous, as in codesign. Returns the index or -1 with *error.
static NSInteger sgl_select_identity(NSArray<NSData *> *ders, NSString *query, NSString *team, NSDate *now,
                                     NSString **error) {
    NSCharacterSet *nonHex = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"] invertedSet];
    BOOL byHash = query.length == 40 && [query rangeOfCharacterFromSet:nonHex].location == NSNotFound;
    NSMutableArray<NSNumber *> *exact = [NSMutableArray array], *partial = [NSMutableArray array];
    NSMutableArray<NSString *> *fps = [NSMutableArray array], *labels = [NSMutableArray array];
    NSUInteger unusable = 0;
    for (NSUInteger i = 0; i < ders.count; i++) {
        sgl_cert_info ci;
        [fps addObject:sgl_hex(sgl_sha1(ders[i])).uppercaseString];
        [labels addObject:@""];
        if (!sgl_parse_certificate(ders[i], &ci) || !ci.codeSigning) continue;
        BOOL match = byHash ? [fps[i] caseInsensitiveCompare:query] == NSOrderedSame
                            : [ci.subjectCN containsString:query];
        if (!match) continue;
        if (!sgl_cert_valid_at(&ci, now) || (team && ![ci.subjectOU isEqual:team])) {
            unusable++;
            continue;
        }
        labels[i] = [NSString stringWithFormat:@"%@ \"%@\" (team %@, valid until %@)", fps[i],
                     sgl_escape(ci.subjectCN, SGL_MAX_SHOWN),
                     ci.subjectOU ? sgl_escape(ci.subjectOU, SGL_MAX_SHOWN) : @"none",
                     sgl_utc_string(ci.notAfter, @"yyyy-MM-dd")];
        [(byHash || [ci.subjectCN isEqual:query] ? exact : partial) addObject:@(i)];
    }
    NSMutableArray<NSNumber *> *unique = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (NSNumber *n in exact.count ? exact : partial) // the same certificate may sit in several keychains
        if (![seen containsObject:fps[n.unsignedIntegerValue]]) {
            [seen addObject:fps[n.unsignedIntegerValue]];
            [unique addObject:n];
        }
    if (unique.count == 1) return unique[0].integerValue;
    NSMutableString *msg = [NSMutableString string];
    if (unique.count == 0) {
        [msg appendFormat:@"no valid code-signing identity matching '%@'%@", query,
                          team ? [NSString stringWithFormat:@" in team %@", team] : @""];
        if (unusable) [msg appendFormat:@" (%lu matching identities are expired, not yet valid or in another team)",
                                        (unsigned long)unusable];
    } else {
        [msg appendFormat:@"identity '%@' is ambiguous (%lu matches); select one with -s <SHA-1> or --team:",
                          query, (unsigned long)unique.count];
        for (NSNumber *n in unique) [msg appendFormat:@"\n  %@", labels[n.unsignedIntegerValue]];
    }
    *error = msg;
    return -1;
}

// --------------------------------------------------------------- keychain

static SecIdentityRef sgl_find_identity(NSString *query, NSString *team) {
    NSDictionary *q = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassIdentity,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
        (__bridge id)kSecReturnRef: @YES,
    };
    CFTypeRef result = NULL;
    OSStatus st = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
    if (st != errSecSuccess || !result)
        sgl_fail(@"no code-signing identities in the keychain (status %d)", (int)st);
    NSArray *items = CFBridgingRelease(result);
    NSMutableArray *idents = [NSMutableArray array];
    NSMutableArray<NSData *> *ders = [NSMutableArray array];
    for (id obj in items) {
        SecCertificateRef cert = NULL;
        if (SecIdentityCopyCertificate((__bridge SecIdentityRef)obj, &cert) != errSecSuccess || !cert) continue;
        [ders addObject:CFBridgingRelease(SecCertificateCopyData(cert))];
        CFRelease(cert);
        [idents addObject:obj];
    }
    NSString *error = nil;
    NSInteger idx = sgl_select_identity(ders, query, team, [NSDate date], &error);
    if (idx < 0) sgl_fail(@"%@", error);
    return (SecIdentityRef)CFRetain((__bridge CFTypeRef)idents[(NSUInteger)idx]);
}

// Chain for a keychain leaf: SecTrust's chain first; when it lacks the
// issuing intermediate or a root (on iOS trustd does not search the app's
// keychain), complete it from every certificate the keychains hold.
static NSArray<NSData *> *sgl_certificate_chain(SecCertificateRef leaf, NSData *leafDER) {
    NSMutableArray<NSData *> *candidates = [NSMutableArray array];
    SecPolicyRef policy = SecPolicyCreateBasicX509();
    SecTrustRef trust = NULL;
    if (SecTrustCreateWithCertificates(leaf, policy, &trust) == errSecSuccess && trust) {
        (void)SecTrustEvaluateWithError(trust, NULL); // builds the chain whether trusted or not
        CFArrayRef chain = SecTrustCopyCertificateChain(trust);
        if (chain) {
            for (CFIndex i = 1; i < CFArrayGetCount(chain); i++)
                [candidates addObject:CFBridgingRelease(SecCertificateCopyData(
                    (SecCertificateRef)CFArrayGetValueAtIndex(chain, i)))];
            CFRelease(chain);
        }
        CFRelease(trust);
    }
    CFRelease(policy);
    NSDate *now = [NSDate date];
    NSString *error = nil;
    NSArray<NSData *> *certs = sgl_select_chain(leafDER, candidates, now, &error);
    if (certs.count < 3) {
        NSDictionary *q = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassCertificate,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitAll,
            (__bridge id)kSecReturnRef: @YES,
        };
        CFTypeRef result = NULL;
        if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &result) == errSecSuccess && result) {
            NSArray *items = CFBridgingRelease(result);
            for (id obj in items)
                [candidates addObject:CFBridgingRelease(SecCertificateCopyData((__bridge SecCertificateRef)obj))];
        }
        certs = sgl_select_chain(leafDER, candidates, now, &error);
    }
    if (!certs) sgl_fail(@"%@", error);
    if (certs.count < 3)
        fprintf(stderr, "note: no root certificate for the intermediate found; embedding the intermediate only\n");
    return certs;
}

// ------------------------------------------------------- blob construction

static void sgl_pad4(NSMutableData *d) {
    uint8_t z[3] = {0, 0, 0};
    NSUInteger pad = (4 - d.length % 4) % 4;
    if (pad) [d appendBytes:z length:pad];
}

// Designated requirement, expression form, mirroring Apple's layout:
//   identifier IDENT and anchor apple generic and
//   certificate leaf[subject.CN] = CN and
//   certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */
static NSData *sgl_build_requirements(NSString *ident, NSString *leafCN) {
    static const uint8_t kOidAppleCertExt[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x06, 0x02, 0x01 };
    NSData *identData = [ident dataUsingEncoding:NSUTF8StringEncoding];
    NSData *cnData = [leafCN dataUsingEncoding:NSUTF8StringEncoding];

    NSMutableData *expr = [NSMutableData data];
    sgl_be32(expr, 1); // kind: expression form
    sgl_be32(expr, 6); // opAnd
    sgl_be32(expr, 2); // opIdent
    sgl_be32(expr, (uint32_t)identData.length);
    [expr appendData:identData];
    sgl_pad4(expr);
    sgl_be32(expr, 6);  // opAnd
    sgl_be32(expr, 15); // opAppleGenericAnchor
    sgl_be32(expr, 6);  // opAnd
    sgl_be32(expr, 11); // opCertField
    sgl_be32(expr, 0);  // leaf
    sgl_be32(expr, 10); // strlen("subject.CN")
    [expr appendBytes:"subject.CN" length:10];
    sgl_pad4(expr);
    sgl_be32(expr, 1); // matchEqual
    sgl_be32(expr, (uint32_t)cnData.length);
    [expr appendData:cnData];
    sgl_pad4(expr);
    sgl_be32(expr, 14); // opCertGeneric
    sgl_be32(expr, 1);  // certificate slot 1 (intermediate)
    sgl_be32(expr, (uint32_t)sizeof(kOidAppleCertExt));
    [expr appendBytes:kOidAppleCertExt length:sizeof(kOidAppleCertExt)];
    sgl_pad4(expr);
    sgl_be32(expr, 0); // matchExists

    NSMutableData *req = [NSMutableData data];
    sgl_be32(req, SGL_MAGIC_REQUIREMENT);
    sgl_be32(req, (uint32_t)expr.length + 8);
    [req appendData:expr];

    NSMutableData *set = [NSMutableData data];
    sgl_be32(set, SGL_MAGIC_REQUIREMENTS);
    sgl_be32(set, (uint32_t)req.length + 20);
    sgl_be32(set, 1);  // count
    sgl_be32(set, 3);  // designated requirement
    sgl_be32(set, 20); // offset of first requirement
    [set appendData:req];
    return set;
}

// Ad-hoc signatures carry an empty requirement set, like codesign -s -.
static NSData *sgl_empty_requirements(void) {
    NSMutableData *set = [NSMutableData data];
    sgl_be32(set, SGL_MAGIC_REQUIREMENTS);
    sgl_be32(set, 12);
    sgl_be32(set, 0); // count
    return set;
}

static void sgl_pad_ident(NSMutableData *d, NSString *s) {
    NSData *b = [s dataUsingEncoding:NSUTF8StringEncoding];
    [d appendData:b];
    uint8_t z = 0;
    [d appendBytes:&z length:1];
}

static NSUInteger sgl_cd_length(NSString *ident, NSString *team, NSUInteger nCodeSlots) {
    return 0x58 + [ident dataUsingEncoding:NSUTF8StringEncoding].length + 1 +
           (team ? [team dataUsingEncoding:NSUTF8StringEncoding].length + 1 : 0) +
           (2 + nCodeSlots) * SGL_HASH_SIZE;
}

// CodeDirectory v=0x20400. Special slots: requirements (-2), zero Info.plist
// slot (-1), then nCodeSlots page hashes. No team string when `team` is nil.
static NSData *sgl_build_code_directory(NSString *ident, NSString *team, uint32_t flags, uint32_t codeLimit,
                                        uint64_t execSegBase, uint64_t execSegLimit, uint64_t execSegFlags,
                                        NSData *reqHash, NSArray<NSData *> *pageHashes) {
    NSUInteger identLen = [ident dataUsingEncoding:NSUTF8StringEncoding].length + 1;
    NSUInteger teamLen = team ? [team dataUsingEncoding:NSUTF8StringEncoding].length + 1 : 0;
    uint32_t identOff = 0x58;
    uint32_t teamOff = team ? identOff + (uint32_t)identLen : 0;
    uint32_t hashOff = identOff + (uint32_t)identLen + (uint32_t)teamLen + 2 * SGL_HASH_SIZE;
    uint32_t length = hashOff + (uint32_t)pageHashes.count * SGL_HASH_SIZE;

    NSMutableData *cd = [NSMutableData data];
    sgl_be32(cd, SGL_MAGIC_CODEDIRECTORY);
    sgl_be32(cd, length);
    sgl_be32(cd, SGL_CD_VERSION);
    sgl_be32(cd, flags);
    sgl_be32(cd, hashOff);
    sgl_be32(cd, identOff);
    sgl_be32(cd, 2); // nSpecialSlots
    sgl_be32(cd, (uint32_t)pageHashes.count);
    sgl_be32(cd, codeLimit);
    uint8_t hd[4] = { SGL_HASH_SIZE, 2, 0, SGL_PAGE_BITS }; // sha256, platform 0
    [cd appendBytes:hd length:4];
    sgl_be32(cd, 0); // spare2
    sgl_be32(cd, 0); // scatterOffset
    sgl_be32(cd, teamOff);
    sgl_be32(cd, 0); // spare3
    sgl_be64(cd, 0); // codeLimit64
    sgl_be64(cd, execSegBase);
    sgl_be64(cd, execSegLimit);
    sgl_be64(cd, execSegFlags);
    sgl_pad_ident(cd, ident);
    if (team) sgl_pad_ident(cd, team);
    [cd appendData:reqHash];                       // special slot -2
    uint8_t zeros[SGL_HASH_SIZE] = {0};
    [cd appendBytes:zeros length:SGL_HASH_SIZE];   // special slot -1 (no Info.plist)
    for (NSData *h in pageHashes) [cd appendData:h];
    return cd;
}

// --------------------------------------------------------------- CMS (BER)

static const uint8_t kOidSignedData[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x02 };
static const uint8_t kOidData[]       = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x07, 0x01 };
static const uint8_t kOidSHA256[]     = { 0x60, 0x86, 0x48, 0x01, 0x65, 0x03, 0x04, 0x02, 0x01 };
static const uint8_t kOidRSA[]        = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01 };
static const uint8_t kOidSHA256RSA[]  = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x0b };
static const uint8_t kOidSHA256ECDSA[]= { 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02 };
static const uint8_t kOidECPublicKey[]= { 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x02, 0x01 };
static const uint8_t kOidP256[]       = { 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03, 0x01, 0x07 };
static const uint8_t kOidP384[]       = { 0x2b, 0x81, 0x04, 0x00, 0x22 };
static const uint8_t kOidP521[]       = { 0x2b, 0x81, 0x04, 0x00, 0x23 };
static const uint8_t kOidContentType[]= { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x03 };
static const uint8_t kOidSigningTime[]= { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x05 };
static const uint8_t kOidMessageDigest[]={0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x09, 0x04 };
static const uint8_t kOidAppleHashAgilityV1[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x09, 0x01 };
static const uint8_t kOidAppleHashAgilityV2[] = { 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x63, 0x64, 0x09, 0x02 };

static NSData *sgl_digest_alg_seq(void) {
    return sgl_alg_seq(kOidSHA256, sizeof(kOidSHA256), YES);
}

static NSData *sgl_attr(const uint8_t *oid, size_t oidLen, NSData *valueTlv) {
    NSMutableData *c = [NSMutableData data];
    [c appendData:sgl_der_oid(oid, oidLen)];
    [c appendData:sgl_der(0x31, valueTlv)];
    return sgl_der(0x30, c);
}

// The cdhashes plist Apple embeds as the 1.2.840.113635.100.9.1 attribute.
static NSData *sgl_cdhash_plist(NSData *cdHash20) {
    NSString *b64 = [cdHash20 base64EncodedStringWithOptions:0];
    NSString *plist = [NSString stringWithFormat:
        @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        @"<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
        @"<plist version=\"1.0\">\n"
        @"<dict>\n"
        @"\t<key>cdhashes</key>\n"
        @"\t<array>\n"
        @"\t\t<data>\n"
        @"\t\t%@\n"
        @"\t\t</data>\n"
        @"\t</array>\n"
        @"</dict>\n"
        @"</plist>\n", b64];
    return [plist dataUsingEncoding:NSUTF8StringEncoding];
}

// Signed attributes in Apple's exact order (contentType, signingTime,
// messageDigest, hash-agility-v2, hash-agility-v1 plist). Returned as the
// attribute content bytes; caller wraps with 0x31 (for signing) or 0xa0.
static NSData *sgl_signed_attrs_content(NSData *cdHash32, NSString *signingTime) {
    NSMutableData *c = [NSMutableData data];
    [c appendData:sgl_attr(kOidContentType, sizeof(kOidContentType),
                           sgl_der_oid(kOidData, sizeof(kOidData)))];
    [c appendData:sgl_attr(kOidSigningTime, sizeof(kOidSigningTime),
                           sgl_der(0x17, [signingTime dataUsingEncoding:NSASCIIStringEncoding]))];
    [c appendData:sgl_attr(kOidMessageDigest, sizeof(kOidMessageDigest),
                           sgl_der(0x04, cdHash32))];
    NSMutableData *agility = [NSMutableData data];
    [agility appendData:sgl_der_oid(kOidSHA256, sizeof(kOidSHA256))];
    [agility appendData:sgl_der(0x04, cdHash32)];
    [c appendData:sgl_attr(kOidAppleHashAgilityV2, sizeof(kOidAppleHashAgilityV2),
                           sgl_der(0x30, agility))];
    [c appendData:sgl_attr(kOidAppleHashAgilityV1, sizeof(kOidAppleHashAgilityV1),
                           sgl_der(0x04, sgl_cdhash_plist([cdHash32 subdataWithRange:NSMakeRange(0, 20)])))];
    return c;
}

// Assemble the full CMS ContentInfo. Outer layers use BER indefinite lengths
// exactly like Apple's signer; inner layers are definite-length DER.
static NSData *sgl_build_cms(NSArray<NSData *> *certDERs, NSData *issuerTLV, NSData *serialTLV,
                             NSData *attrsContent, NSData *signature, BOOL rsaKey) {
    // SignerInfo
    NSMutableData *sid = [NSMutableData data];
    [sid appendData:issuerTLV];
    [sid appendData:serialTLV];
    NSMutableData *si = [NSMutableData data];
    uint8_t version[3] = { 0x02, 0x01, 0x01 };
    [si appendBytes:version length:3];
    [si appendData:sgl_der(0x30, sid)]; // issuerAndSerialNumber
    [si appendData:sgl_digest_alg_seq()];
    [si appendData:sgl_der(0xa0, attrsContent)]; // [0] signed attributes
    [si appendData:rsaKey ? sgl_alg_seq(kOidSHA256RSA, sizeof(kOidSHA256RSA), YES)
                          : sgl_alg_seq(kOidSHA256ECDSA, sizeof(kOidSHA256ECDSA), NO)];
    [si appendData:sgl_der(0x04, signature)];
    NSData *signerInfo = sgl_der(0x30, si);

    NSMutableData *certs = [NSMutableData data];
    for (NSData *c in certDERs) [certs appendData:c];

    NSMutableData *cms = [NSMutableData data];
    uint8_t hdr[2];
    hdr[0] = 0x30; hdr[1] = 0x80; [cms appendBytes:hdr length:2]; // ContentInfo, indefinite
    [cms appendData:sgl_der_oid(kOidSignedData, sizeof(kOidSignedData))];
    hdr[0] = 0xa0; [cms appendBytes:hdr length:2]; // [0], indefinite
    hdr[0] = 0x30; [cms appendBytes:hdr length:2]; // SignedData, indefinite
    [cms appendBytes:version length:3];
    [cms appendData:sgl_der(0x31, sgl_digest_alg_seq())]; // digestAlgorithms
    hdr[0] = 0x30; [cms appendBytes:hdr length:2]; // contentInfo, indefinite
    [cms appendData:sgl_der_oid(kOidData, sizeof(kOidData))]; // detached content
    uint8_t eoc[2] = { 0, 0 };
    [cms appendBytes:eoc length:2]; // EOC contentInfo
    [cms appendData:sgl_der(0xa0, certs)];        // [0] certificates
    [cms appendData:sgl_der(0x31, signerInfo)];   // signerInfos
    [cms appendBytes:eoc length:2]; // EOC SignedData
    [cms appendBytes:eoc length:2]; // EOC [0]
    [cms appendBytes:eoc length:2]; // EOC ContentInfo
    return cms;
}

// ------------------------------------------------------------------ signing

// A signer: private key plus everything the CMS and requirements need.
typedef struct {
    SecKeyRef key;           // retained
    SecIdentityRef identity; // retained, NULL for the ephemeral test signer
    BOOL rsa;
    size_t sigLen;            // reserved signature length (upper bound)
    NSArray<NSData *> *certs; // intermediates first, leaf last
    NSString *cn;             // leaf subject CN (goes into the requirement)
    NSString *team;           // leaf subject OU (team identifier)
    NSData *issuerTLV;        // raw issuer Name TLV of the leaf
    NSData *serialTLV;        // raw serial INTEGER TLV of the leaf
} sgl_signer;

static void sgl_signer_release(sgl_signer *s) {
    if (s->key) CFRelease(s->key);
    if (s->identity) CFRelease(s->identity);
}

// Largest signature a key produces: RSA PKCS#1 v1.5 signatures are exactly the
// modulus size (`size` = block size in bytes); an X9.62 ECDSA signature is a
// DER SEQUENCE of two INTEGERs of at most ceil(bits/8)+1 bytes each (`size` =
// key bits): 72 bytes for P-256, 104 for P-384, 141 for P-521.
static size_t sgl_signature_bound(BOOL rsa, size_t size) {
    if (rsa || size == 0) return size;
    size_t n = (size + 7) / 8 + 1, content = 2 * (2 + n);
    return content + (content < 128 ? 2 : 3);
}

static void sgl_signer_key_setup(sgl_signer *s) {
    NSDictionary *keyAttrs = CFBridgingRelease(SecKeyCopyAttributes(s->key));
    id type = keyAttrs[(__bridge id)kSecAttrKeyType];
    s->rsa = [type isEqual:(__bridge id)kSecAttrKeyTypeRSA];
    if (!s->rsa && ![type isEqual:(__bridge id)kSecAttrKeyTypeECSECPrimeRandom])
        sgl_fail(@"unsupported signing key type %@", type);
    SecKeyAlgorithm alg = s->rsa ? kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256
                                 : kSecKeyAlgorithmECDSASignatureMessageX962SHA256;
    if (!SecKeyIsAlgorithmSupported(s->key, kSecKeyOperationTypeSign, alg))
        sgl_fail(@"private key does not support the required signature algorithm");
    s->sigLen = sgl_signature_bound(s->rsa, s->rsa ? SecKeyGetBlockSize(s->key)
                                                   : (size_t)[keyAttrs[(__bridge id)kSecAttrKeySizeInBits] integerValue]);
    if (s->sigLen == 0) sgl_fail(@"cannot determine the signature size of the signing key");
}

static sgl_signer sgl_keychain_signer(NSString *query, NSString *team) {
    sgl_signer s = {0};
    s.identity = sgl_find_identity(query, team);
    SecCertificateRef leaf = NULL;
    if (SecIdentityCopyCertificate(s.identity, &leaf) != errSecSuccess || !leaf)
        sgl_fail(@"identity has no certificate");
    NSData *leafDER = CFBridgingRelease(SecCertificateCopyData(leaf));
    sgl_cert_info info;
    if (!sgl_parse_certificate(leafDER, &info) || !info.subjectCN || !info.subjectOU)
        sgl_fail(@"could not parse the leaf certificate (need subject CN and OU)");
    fprintf(stderr, "identity: %s %s\n", sgl_hex(sgl_sha1(leafDER)).uppercaseString.UTF8String,
            sgl_escape(info.subjectCN, SGL_MAX_SHOWN).UTF8String);
    s.cn = info.subjectCN;
    s.team = info.subjectOU;
    s.issuerTLV = info.issuerTLV;
    s.serialTLV = info.serialTLV;
    s.certs = sgl_certificate_chain(leaf, leafDER);
    CFRelease(leaf);
    if (SecIdentityCopyPrivateKey(s.identity, &s.key) != errSecSuccess || !s.key)
        sgl_fail(@"identity has no private key");
    sgl_signer_key_setup(&s);
    return s;
}

// ------------------------------------------ in-memory certificates (self-test)

// X.501 Name with CN and optional OU (in that order, like Apple development certs).
static NSData *sgl_name_der(NSString *cn, NSString *ou) {
    static const uint8_t kOidCN[] = { 0x55, 0x04, 0x03 };
    static const uint8_t kOidOU[] = { 0x55, 0x04, 0x0b };
    NSMutableData *name = [NSMutableData data];
    const struct { const uint8_t *oid; size_t oidLen; NSString *value; } attrs[] = {
        { kOidCN, sizeof(kOidCN), cn },
        { kOidOU, sizeof(kOidOU), ou },
    };
    for (unsigned i = 0; i < 2; i++) {
        if (!attrs[i].value) continue;
        NSMutableData *rdn = [NSMutableData data];
        [rdn appendData:sgl_der_oid(attrs[i].oid, attrs[i].oidLen)];
        [rdn appendData:sgl_der(0x0c, [attrs[i].value dataUsingEncoding:NSUTF8StringEncoding])];
        [name appendData:sgl_der(0x31, sgl_der(0x30, rdn))];
    }
    return sgl_der(0x30, name);
}

static NSData *sgl_spki(SecKeyRef pub) {
    NSDictionary *a = CFBridgingRelease(SecKeyCopyAttributes(pub));
    NSData *raw = CFBridgingRelease(SecKeyCopyExternalRepresentation(pub, NULL)); // PKCS#1 or 04||X||Y
    if (!raw) return nil;
    NSMutableData *spki = [NSMutableData data];
    if ([a[(__bridge id)kSecAttrKeyType] isEqual:(__bridge id)kSecAttrKeyTypeRSA]) {
        [spki appendData:sgl_alg_seq(kOidRSA, sizeof(kOidRSA), YES)];
    } else {
        NSInteger bits = [a[(__bridge id)kSecAttrKeySizeInBits] integerValue];
        NSMutableData *alg = [NSMutableData data];
        [alg appendData:sgl_der_oid(kOidECPublicKey, sizeof(kOidECPublicKey))];
        if (bits == 256) [alg appendData:sgl_der_oid(kOidP256, sizeof(kOidP256))];
        else if (bits == 384) [alg appendData:sgl_der_oid(kOidP384, sizeof(kOidP384))];
        else if (bits == 521) [alg appendData:sgl_der_oid(kOidP521, sizeof(kOidP521))];
        else return nil;
        [spki appendData:sgl_der(0x30, alg)];
    }
    NSMutableData *bits = [NSMutableData dataWithBytes:"\0" length:1];
    [bits appendData:raw];
    [spki appendData:sgl_der(0x03, bits)];
    return sgl_der(0x30, spki);
}

enum { SGL_CERT_CODE_SIGNING, SGL_CERT_NO_EKU, SGL_CERT_CA };

// Minimal X.509 v3 certificate for `subjectPub`, signed by `issuerKey` (RSA:
// sha256WithRSAEncryption, EC: ecdsa-with-SHA256). Leaves carry keyUsage
// digitalSignature and (SGL_CERT_CODE_SIGNING) the code-signing EKU, which
// codesign -v enforces; CAs carry basicConstraints CA:TRUE. nil on failure.
static NSData *sgl_make_certificate(NSData *subject, SecKeyRef subjectPub, NSData *issuer, SecKeyRef issuerKey,
                                    uint64_t serial, NSDate *notBefore, NSDate *notAfter, int kind) {
    static const uint8_t kOidKeyUsage[] = { 0x55, 0x1d, 0x0f };
    static const uint8_t kOidExtKeyUsage[] = { 0x55, 0x1d, 0x25 };
    static const uint8_t kOidBasicConstraints[] = { 0x55, 0x1d, 0x13 };
    static const uint8_t kOidCodeSigning[] = { 0x2b, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x03 };
    NSData *spki = sgl_spki(subjectPub);
    if (!spki) return nil;
    NSDictionary *ia = CFBridgingRelease(SecKeyCopyAttributes(issuerKey));
    BOOL rsa = [ia[(__bridge id)kSecAttrKeyType] isEqual:(__bridge id)kSecAttrKeyTypeRSA];
    NSData *sigAlg = rsa ? sgl_alg_seq(kOidSHA256RSA, sizeof(kOidSHA256RSA), YES)
                         : sgl_alg_seq(kOidSHA256ECDSA, sizeof(kOidSHA256ECDSA), NO);
    NSMutableData *validity = [NSMutableData data];
    [validity appendData:sgl_der_time_enc(notBefore)];
    [validity appendData:sgl_der_time_enc(notAfter)];

    NSMutableData *exts = [NSMutableData data];
    NSMutableData *ext = [NSMutableData data];
    [ext appendData:sgl_der_oid(kOidKeyUsage, sizeof(kOidKeyUsage))];
    [ext appendBytes:"\x01\x01\xff" length:3]; // critical
    [ext appendData:sgl_der(0x04, kind == SGL_CERT_CA ? [NSData dataWithBytes:"\x03\x02\x01\x06" length:4]
                                                      : [NSData dataWithBytes:"\x03\x02\x07\x80" length:4])];
    [exts appendData:sgl_der(0x30, ext)];
    if (kind == SGL_CERT_CA) {
        ext = [NSMutableData data];
        [ext appendData:sgl_der_oid(kOidBasicConstraints, sizeof(kOidBasicConstraints))];
        [ext appendBytes:"\x01\x01\xff" length:3];
        [ext appendData:sgl_der(0x04, [NSData dataWithBytes:"\x30\x03\x01\x01\xff" length:5])];
        [exts appendData:sgl_der(0x30, ext)];
    } else if (kind == SGL_CERT_CODE_SIGNING) {
        ext = [NSMutableData data];
        [ext appendData:sgl_der_oid(kOidExtKeyUsage, sizeof(kOidExtKeyUsage))];
        [ext appendBytes:"\x01\x01\xff" length:3];
        [ext appendData:sgl_der(0x04, sgl_der(0x30, sgl_der_oid(kOidCodeSigning, sizeof(kOidCodeSigning))))];
        [exts appendData:sgl_der(0x30, ext)];
    }

    NSMutableData *tbs = [NSMutableData data];
    [tbs appendData:sgl_der(0xa0, sgl_der_int(2))]; // version v3
    [tbs appendData:sgl_der_int(serial)];
    [tbs appendData:sigAlg];
    [tbs appendData:issuer];
    [tbs appendData:sgl_der(0x30, validity)];
    [tbs appendData:subject];
    [tbs appendData:spki];
    [tbs appendData:sgl_der(0xa3, sgl_der(0x30, exts))];
    NSData *tbsDER = sgl_der(0x30, tbs);
    NSData *sig = CFBridgingRelease(SecKeyCreateSignature(
        issuerKey, rsa ? kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256 : kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
        (__bridge CFDataRef)tbsDER, NULL));
    if (!sig) return nil;
    NSMutableData *sigBits = [NSMutableData dataWithBytes:"\0" length:1];
    [sigBits appendData:sig];
    NSMutableData *cert = [NSMutableData data];
    [cert appendData:tbsDER];
    [cert appendData:sigAlg];
    [cert appendData:sgl_der(0x03, sigBits)];
    return sgl_der(0x30, cert);
}

// Ephemeral self-signed RSA-2048 or P-256 signer built in memory. Used by
// --selftest / --selftest-ec to validate the full signing pipeline without
// touching the keychain (the dev identity's key prompts for approval on first
// use per binary).
static sgl_signer sgl_ephemeral_signer(BOOL ec) {
    NSDictionary *params = @{
        (__bridge id)kSecAttrKeyType: ec ? (__bridge id)kSecAttrKeyTypeECSECPrimeRandom : (__bridge id)kSecAttrKeyTypeRSA,
        (__bridge id)kSecAttrKeySizeInBits: ec ? @256 : @2048,
        (__bridge id)kSecAttrIsPermanent: @NO,
    };
    CFErrorRef err = NULL;
    SecKeyRef key = SecKeyCreateRandomKey((__bridge CFDictionaryRef)params, &err);
    if (!key) sgl_fail(@"SecKeyCreateRandomKey failed: %@", err ? CFBridgingRelease(err) : @"unknown");
    SecKeyRef pub = SecKeyCopyPublicKey(key);
    if (!pub) sgl_fail(@"no public key for ephemeral key");
    NSString *cn = @"Apple Development: sign-local self-test", *team = @"SELFTEST00";
    NSData *name = sgl_name_der(cn, team);
    NSData *certDER = sgl_make_certificate(name, pub, name, key, 0x0102030405060708,
                                           [NSDate dateWithTimeIntervalSinceNow:-3600],
                                           [NSDate dateWithTimeIntervalSinceNow:86400 * 365], SGL_CERT_CODE_SIGNING);
    CFRelease(pub);
    // Sanity: our own parser must accept our own certificate.
    sgl_cert_info info;
    if (!certDER || !sgl_parse_certificate(certDER, &info) || !info.selfSigned || !info.codeSigning)
        sgl_fail(@"self-built certificate does not parse (internal error)");
    sgl_signer s = {0};
    s.key = key;
    s.certs = @[ certDER ];
    s.cn = cn;
    s.team = team;
    s.issuerTLV = info.issuerTLV;
    s.serialTLV = info.serialTLV;
    sgl_signer_key_setup(&s);
    return s;
}

typedef enum { SGL_MODE_KEYCHAIN, SGL_MODE_SELFTEST_RSA, SGL_MODE_SELFTEST_EC, SGL_MODE_ADHOC } sgl_mode;

static bool sgl_key_access_denied(NSError *e) {
    return [e.domain isEqual:NSOSStatusErrorDomain] &&
           (e.code == errSecUserCanceled || e.code == errSecAuthFailed || e.code == errSecInteractionNotAllowed);
}

static void sgl_sign(NSString *inPath, NSString *outPath, NSString *ident, NSString *query, NSString *team,
                     sgl_mode mode, BOOL dryRun) {
    NSData *input = [NSData dataWithContentsOfFile:inPath];
    if (!input) sgl_fail(@"cannot read %@", inPath);
    sgl_buf fb = sgl_buf_from_data(input);
    sgl_macho m;
    sgl_parse_macho(fb, false, &m);

    // LC_CODE_SIGNATURE is stamped into the header pad right after the load
    // commands (no insertion: all file offsets stay put). No section, segment
    // or modeled load-command data may start there, the bytes must lie inside
    // __TEXT and be zero: data of a load command this parser does not model is
    // never overwritten.
    size_t freeSpace = m.contentStart - m.cmdsEnd;
    if (freeSpace < 16)
        sgl_fail(@"no room for LC_CODE_SIGNATURE: %zu bytes of header pad, need 16.\n"
                 @"Relink the input with -Wl,-headerpad,32 (or more) and retry.", freeSpace);
    if (m.cmdsEnd + 16 > m.textFilesize)
        sgl_fail(@"no room for LC_CODE_SIGNATURE inside __TEXT (%#llx bytes, load commands end at %#zx)",
                 m.textFilesize, m.cmdsEnd);
    if (!sgl_all_zero(fb.p + m.cmdsEnd, 16))
        sgl_fail(@"header pad after the load commands (%#zx) is not zero-filled; refusing to overwrite it", m.cmdsEnd);

    BOOL explicitIdent = ident != nil;
    if (!ident) ident = inPath.lastPathComponent.stringByDeletingPathExtension;
    if (!sgl_valid_identifier(ident))
        sgl_fail(@"invalid identifier '%@': need 1-%d characters from [A-Za-z0-9._-] starting with a letter or digit%@",
                 ident, SGL_MAX_IDENT, explicitIdent ? @"" : @" (derived from the file name; pass -i)");

    uint64_t sigOff = ((uint64_t)input.length + 15) & ~(uint64_t)15;
    if (sigOff > UINT32_MAX) sgl_fail(@"input too large");
    uint32_t codeLimit = (uint32_t)sigOff;
    NSUInteger nCodeSlots = (NSUInteger)((sigOff + SGL_PAGE_SIZE - 1) / SGL_PAGE_SIZE);

    BOOL adhoc = mode == SGL_MODE_ADHOC;
    sgl_signer signer = adhoc ? (sgl_signer){0}
                      : mode == SGL_MODE_KEYCHAIN ? sgl_keychain_signer(query, team)
                                                  : sgl_ephemeral_signer(mode == SGL_MODE_SELFTEST_EC);
    NSString *cdTeam = adhoc ? nil : signer.team;
    NSData *reqs = adhoc ? sgl_empty_requirements() : sgl_build_requirements(ident, signer.cn);
    NSString *signingTime = sgl_utc_string([NSDate date], @"yyMMddHHmmss'Z'");

    // datasize is part of the hashed load commands, so it must not depend on
    // the actual (for ECDSA, variable) signature length: reserve room for the
    // largest signature the key can produce and zero-pad the superblob, whose
    // own length field carries the real size, up to datasize (as codesign does).
    NSData *probeCMS = [NSData data], *cms = [NSData data];
    if (!adhoc)
        probeCMS = sgl_build_cms(signer.certs, signer.issuerTLV, signer.serialTLV,
                                 sgl_signed_attrs_content([NSMutableData dataWithLength:SGL_HASH_SIZE], signingTime),
                                 [NSMutableData dataWithLength:signer.sigLen], signer.rsa);
    NSUInteger cdLen = sgl_cd_length(ident, cdTeam, nCodeSlots);
    uint64_t superblobLen = 36 + cdLen + reqs.length + 8 + probeCMS.length;
    // codesign reserves 8 bytes beyond an ad-hoc superblob; matching it keeps
    // --adhoc output byte-identical to `codesign -s - -i <identifier>`.
    uint64_t datasize = ((adhoc ? superblobLen + 8 : superblobLen) + 15) & ~(uint64_t)15;
    if (datasize > UINT32_MAX) sgl_fail(@"signature too large");
    uint64_t fileEnd = sigOff + datasize;

    // Stamp LC_CODE_SIGNATURE, patch ncmds/sizeofcmds and grow __LINKEDIT
    // (the last segment, ending at EOF) over the signature.
    NSMutableData *img = [NSMutableData dataWithData:input];
    uint8_t csCmd[16] = { SGL_LC_CODE_SIGNATURE, 0, 0, 0, 16 };
    sgl_put32le(csCmd + 8, (uint32_t)sigOff);
    sgl_put32le(csCmd + 12, (uint32_t)datasize);
    [img replaceBytesInRange:NSMakeRange(m.cmdsEnd, 16) withBytes:csCmd length:16];
    uint8_t *b = img.mutableBytes;
    sgl_put32le(b + 16, m.ncmds + 1);
    sgl_put32le(b + 20, m.sizeofcmds + 16);
    uint64_t leFilesize = fileEnd - m.leFileoff; // leFileoff <= input length <= sigOff
    uint64_t leVmsize = MAX(m.leVmsize, (leFilesize + 0x3fff) & ~(uint64_t)0x3fff);
    if (leVmsize > UINT64_MAX - m.leVmaddr) sgl_fail(@"__LINKEDIT VM range would wrap");
    sgl_put64le(b + m.linkeditCmdOff + 32, leVmsize);
    sgl_put64le(b + m.linkeditCmdOff + 48, leFilesize);
    [img setLength:(NSUInteger)sigOff]; // zero pad to the signature offset

    NSMutableArray<NSData *> *pageHashes = [NSMutableArray arrayWithCapacity:nCodeSlots];
    for (NSUInteger i = 0; i < nCodeSlots; i++) {
        uint64_t start = i * (uint64_t)SGL_PAGE_SIZE;
        uint64_t len = MIN((uint64_t)SGL_PAGE_SIZE, sigOff - start);
        [pageHashes addObject:sgl_sha256([img subdataWithRange:NSMakeRange(start, len)])];
    }
    NSData *cd = sgl_build_code_directory(ident, cdTeam, adhoc ? SGL_CS_ADHOC : 0, codeLimit,
                                          m.textFileoff, m.textFilesize,
                                          m.filetype == SGL_MH_EXECUTE ? SGL_CS_EXECSEG_MAIN_BINARY : 0,
                                          sgl_sha256(reqs), pageHashes);
    if (cd.length != cdLen) sgl_fail(@"CodeDirectory length mismatch (internal error)");
    NSData *cdHash = sgl_sha256(cd);

    if (!adhoc) {
        NSData *attrsContent = sgl_signed_attrs_content(cdHash, signingTime);
        NSData *sig;
        if (dryRun) {
            // No key access: zeroed placeholder so the full superblob can be
            // structurally diffed against a codesign reference without
            // triggering the keychain ACL prompt.
            sig = [NSMutableData dataWithLength:signer.sigLen];
        } else {
            CFErrorRef err = NULL;
            sig = CFBridgingRelease(SecKeyCreateSignature(
                signer.key, signer.rsa ? kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256
                                       : kSecKeyAlgorithmECDSASignatureMessageX962SHA256,
                (__bridge CFDataRef)sgl_der(0x31, attrsContent), &err));
            if (!sig) {
                NSError *e = CFBridgingRelease(err);
                if (sgl_key_access_denied(e))
                    sgl_fail_code(SGL_EXIT_KEY_DENIED, @"the keychain denied access to the signing key: %@\n"
                                  @"(rerun interactively and choose \"Always Allow\" in the approval dialog)", e);
                sgl_fail(@"SecKeyCreateSignature failed: %@", e ?: @"unknown");
            }
        }
        if (sig.length > signer.sigLen)
            sgl_fail(@"signature of %lu bytes exceeds the reserved %zu (internal error)", (unsigned long)sig.length,
                     signer.sigLen);
        cms = sgl_build_cms(signer.certs, signer.issuerTLV, signer.serialTLV, attrsContent, sig, signer.rsa);
        if (cms.length > probeCMS.length) sgl_fail(@"CMS exceeds its reservation (internal error)");
    }

    NSMutableData *superblob = [NSMutableData data];
    uint32_t cdOff = 36, reqOff = cdOff + (uint32_t)cd.length, cmsOff = reqOff + (uint32_t)reqs.length;
    sgl_be32(superblob, SGL_MAGIC_SUPERBLOB);
    sgl_be32(superblob, cmsOff + 8 + (uint32_t)cms.length);
    sgl_be32(superblob, 3);
    sgl_be32(superblob, 0);                     sgl_be32(superblob, cdOff);
    sgl_be32(superblob, SGL_SLOT_REQUIREMENTS); sgl_be32(superblob, reqOff);
    sgl_be32(superblob, SGL_SLOT_CMS);          sgl_be32(superblob, cmsOff);
    [superblob appendData:cd];
    [superblob appendData:reqs];
    sgl_be32(superblob, SGL_MAGIC_BLOBWRAPPER); // empty for ad-hoc, like codesign
    sgl_be32(superblob, (uint32_t)cms.length + 8);
    [superblob appendData:cms];
    if (superblob.length > datasize) sgl_fail(@"superblob exceeds its reservation (internal error)");
    [img appendData:superblob];
    [img setLength:(NSUInteger)fileEnd];

    sgl_write_atomic(img, outPath);
    fprintf(stderr, "%s %s -> %s (identifier %s, team %s, cdhash %s)\n",
            adhoc ? "ad-hoc signed" : dryRun ? "dry-signed (zeroed CMS signature)" : "signed",
            inPath.UTF8String, outPath.UTF8String, ident.UTF8String, cdTeam ? sgl_escape(cdTeam, SGL_MAX_SHOWN).UTF8String : "none",
            sgl_hex(cdHash).UTF8String);
    sgl_signer_release(&signer);
}

// ------------------------------------------------------------------ verify

// NUL-terminated UTF-8 string at `off`, entirely inside [lo, hi) of the CD.
static NSString *sgl_cd_string(sgl_buf cd, uint32_t off, uint64_t lo, uint64_t hi) {
    if (off < lo || off >= hi || hi > cd.len) return nil;
    const uint8_t *nul = memchr(cd.p + off, 0, (size_t)(hi - off));
    if (!nul) return nil;
    return [[NSString alloc] initWithBytes:cd.p + off length:(size_t)(nul - (cd.p + off))
                                  encoding:NSUTF8StringEncoding];
}

// Verifies the CMS blob against the CodeDirectory: a detached id-data
// SignedData with one SignerInfo whose messageDigest (and Apple hash-agility
// attributes, when present) equal the CD hash, and whose signature over the
// DER signed attributes verifies with the embedded signer certificate's key.
// Certificate chain trust is not evaluated. Returns the number of failures.
static int sgl_verify_cms(sgl_buf blob, NSData *cdBlob, NSString *cdTeam) {
    static const uint8_t kOidEcdsaSHA256[] = { 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x04, 0x03, 0x02 };
    sgl_buf in = { blob.p + 8, blob.len - 8 }, ci, x, sd, eci, certsBuf = { NULL, 0 }, sis, si;
    if (!sgl_ber_next(&in, 0, 0x30, &ci) || in.len) sgl_fail(@"CMS: malformed ContentInfo");
    if (!sgl_der_next(&ci, 0x06, &x, NULL) || !sgl_oid_is(x, kOidSignedData, sizeof(kOidSignedData)))
        sgl_fail(@"CMS: not a SignedData");
    if (!sgl_ber_next(&ci, 1, 0xa0, &x) || ci.len || !sgl_ber_next(&x, 2, 0x30, &sd) || x.len)
        sgl_fail(@"CMS: malformed SignedData wrapper");
    sgl_buf ver, dalgs, dalg, oid;
    if (!sgl_der_next(&sd, 0x02, &ver, NULL) || !sgl_der_next(&sd, 0x31, &dalgs, NULL) ||
        !sgl_ber_next(&sd, 3, 0x30, &eci))
        sgl_fail(@"CMS: malformed SignedData");
    // digestAlgorithms: exactly one AlgorithmIdentifier, SHA-256.
    if (ver.len != 1 || ver.p[0] != 1 || !sgl_der_next(&dalgs, 0x30, &dalg, NULL) || dalgs.len ||
        !sgl_alg_id(dalg, &oid) || !sgl_oid_is(oid, kOidSHA256, sizeof(kOidSHA256)))
        sgl_fail(@"CMS: unsupported SignedData version or digest algorithms (need v1, SHA-256)");
    if (!sgl_der_next(&eci, 0x06, &x, NULL) || !sgl_oid_is(x, kOidData, sizeof(kOidData)) || eci.len)
        sgl_fail(@"CMS: content is not detached id-data");
    if (sd.len && sd.p[0] == 0xa0 && !sgl_ber_next(&sd, 3, 0xa0, &certsBuf)) sgl_fail(@"CMS: malformed certificates");
    if (sd.len && sd.p[0] == 0xa1 && !sgl_ber_next(&sd, 3, 0xa1, &x)) sgl_fail(@"CMS: malformed CRLs");
    if (!sgl_ber_next(&sd, 3, 0x31, &sis) || sd.len) sgl_fail(@"CMS: malformed signerInfos");
    if (!sgl_der_next(&sis, 0x30, &si, NULL) || sis.len) sgl_fail(@"CMS: need exactly one SignerInfo");

    // SignerInfo (strict DER): version 1, issuerAndSerialNumber, digest
    // algorithm, [0] signed attributes, signature algorithm, signature.
    sgl_buf siVer, sid, issuer, issuerTLV, serial, serialTLV, attrs, salg, salgOid, sig;
    if (!sgl_der_next(&si, 0x02, &siVer, NULL) || siVer.len != 1 || siVer.p[0] != 1)
        sgl_fail(@"CMS: unsupported SignerInfo version (need issuerAndSerialNumber)");
    if (!sgl_der_next(&si, 0x30, &sid, NULL) || !sgl_der_next(&sid, 0x30, &issuer, &issuerTLV) ||
        !sgl_der_next(&sid, 0x02, &serial, &serialTLV) || sid.len)
        sgl_fail(@"CMS: malformed signer identifier");
    if (!sgl_der_next(&si, 0x30, &dalg, NULL) || !sgl_alg_id(dalg, &oid) ||
        !sgl_oid_is(oid, kOidSHA256, sizeof(kOidSHA256)))
        sgl_fail(@"CMS: unsupported digest algorithm (need SHA-256)");
    if (!sgl_der_next(&si, 0xa0, &attrs, NULL)) sgl_fail(@"CMS: no signed attributes");
    if (!sgl_der_next(&si, 0x30, &salg, NULL) || !sgl_alg_id(salg, &salgOid))
        sgl_fail(@"CMS: malformed signature algorithm");
    if (!sgl_der_next(&si, 0x04, &sig, NULL)) sgl_fail(@"CMS: malformed signature");
    if (si.len && si.p[0] == 0xa1 && !sgl_der_next(&si, 0xa1, &x, NULL)) sgl_fail(@"CMS: malformed unsigned attributes");
    if (si.len) sgl_fail(@"CMS: trailing data in SignerInfo");

    int failures = 0;
    NSData *cdHash = sgl_sha256(cdBlob);
    bool seen[4] = { false, false, false, false }; // contentType, messageDigest, agility v2, agility v1
    for (sgl_buf a = attrs; a.len;) {
        sgl_buf attr, aoid, vals, v;
        if (!sgl_der_next(&a, 0x30, &attr, NULL) || !sgl_der_next(&attr, 0x06, &aoid, NULL) ||
            !sgl_der_next(&attr, 0x31, &vals, NULL) || attr.len)
            sgl_fail(@"CMS: malformed signed attribute");
        int which = sgl_oid_is(aoid, kOidContentType, sizeof(kOidContentType)) ? 0
                  : sgl_oid_is(aoid, kOidMessageDigest, sizeof(kOidMessageDigest)) ? 1
                  : sgl_oid_is(aoid, kOidAppleHashAgilityV2, sizeof(kOidAppleHashAgilityV2)) ? 2
                  : sgl_oid_is(aoid, kOidAppleHashAgilityV1, sizeof(kOidAppleHashAgilityV1)) ? 3 : -1;
        if (which < 0) continue; // signingTime and others: not bound to the code
        if (seen[which]) sgl_fail(@"CMS: duplicate signed attribute");
        seen[which] = true;
        if (which == 0) {
            if (!sgl_der_next(&vals, 0x06, &v, NULL) || vals.len || !sgl_oid_is(v, kOidData, sizeof(kOidData)))
                sgl_fail(@"CMS: contentType is not id-data");
        } else if (which == 1) {
            if (!sgl_der_next(&vals, 0x04, &v, NULL) || vals.len) sgl_fail(@"CMS: malformed messageDigest");
            bool ok = v.len == SGL_HASH_SIZE && memcmp(v.p, cdHash.bytes, SGL_HASH_SIZE) == 0;
            printf("CMS messageDigest: %s\n", ok ? "OK" : "FAIL (does not match the CodeDirectory)");
            if (!ok) failures++;
        } else if (which == 2) {
            // SET OF SEQUENCE { digest algorithm OID, OCTET STRING hash }: the
            // SHA-256 entry must be this CodeDirectory's hash.
            unsigned sha256Entries = 0;
            bool ok = true;
            while (vals.len) {
                sgl_buf e, eoid, eh;
                if (!sgl_der_next(&vals, 0x30, &e, NULL) || !sgl_der_next(&e, 0x06, &eoid, NULL) ||
                    !sgl_der_next(&e, 0x04, &eh, NULL) || e.len)
                    sgl_fail(@"CMS: malformed hash-agility-v2 attribute");
                if (!sgl_oid_is(eoid, kOidSHA256, sizeof(kOidSHA256))) continue;
                sha256Entries++;
                ok = ok && eh.len == SGL_HASH_SIZE && memcmp(eh.p, cdHash.bytes, SGL_HASH_SIZE) == 0;
            }
            ok = ok && sha256Entries == 1;
            printf("CMS hash agility v2: %s\n", ok ? "OK" : "FAIL (does not match the CodeDirectory)");
            if (!ok) failures++;
        } else {
            if (!sgl_der_next(&vals, 0x04, &v, NULL) || vals.len) sgl_fail(@"CMS: malformed hash-agility-v1 attribute");
            id plist = [NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:v.p length:v.len]
                                                                 options:NSPropertyListImmutable format:NULL error:NULL];
            NSArray *hashes = [plist isKindOfClass:[NSDictionary class]] ? plist[@"cdhashes"] : nil;
            bool ok = [hashes isKindOfClass:[NSArray class]] && hashes.count == 1 &&
                      [hashes[0] isEqual:[cdHash subdataWithRange:NSMakeRange(0, 20)]];
            printf("CMS hash agility v1 (cdhashes plist): %s\n", ok ? "OK" : "FAIL (does not list the CodeDirectory)");
            if (!ok) failures++;
        }
    }
    if (!seen[0] || !seen[1]) sgl_fail(@"CMS: missing contentType or messageDigest signed attribute");

    // The signer certificate: the embedded certificate named by the SignerInfo.
    NSData *wantIssuer = [NSData dataWithBytes:issuerTLV.p length:issuerTLV.len];
    NSData *wantSerial = [NSData dataWithBytes:serialTLV.p length:serialTLV.len];
    NSData *signerDER = nil;
    sgl_cert_info signerCert = {0};
    unsigned ncerts = 0;
    for (sgl_buf cb = certsBuf; cb.len;) {
        sgl_buf c, ctlv;
        sgl_cert_info info;
        if (!sgl_der_next(&cb, 0x30, &c, &ctlv)) sgl_fail(@"CMS: malformed certificate");
        NSData *der = [NSData dataWithBytes:ctlv.p length:ctlv.len];
        if (!sgl_parse_certificate(der, &info)) sgl_fail(@"CMS: certificate %u does not parse", ncerts);
        ncerts++;
        if (![info.issuerTLV isEqual:wantIssuer] || ![info.serialTLV isEqual:wantSerial]) continue;
        if (signerDER) sgl_fail(@"CMS: more than one certificate matches the signer");
        signerDER = der;
        signerCert = info;
    }
    if (!signerDER) sgl_fail(@"CMS: the signer certificate is not embedded");
    // Certificate names are attacker-controlled: printed escaped and bounded.
    printf("Authority=%s\n", sgl_escape(signerCert.subjectCN, SGL_MAX_SHOWN).UTF8String);
    printf("CMS certificates: %u\n", ncerts);
    // A team the CodeDirectory claims must be backed by the signer's OU.
    if (cdTeam && ![cdTeam isEqual:signerCert.subjectOU]) {
        printf("TeamIdentifier binding: FAIL (CodeDirectory %s, signer certificate OU %s)\n",
               sgl_escape(cdTeam, SGL_MAX_SHOWN).UTF8String,
               signerCert.subjectOU ? sgl_escape(signerCert.subjectOU, SGL_MAX_SHOWN).UTF8String
                                    : "missing or unreadable");
        failures++;
    }

    SecKeyAlgorithm alg;
    const char *algName;
    if (sgl_oid_is(salgOid, kOidSHA256RSA, sizeof(kOidSHA256RSA)) || sgl_oid_is(salgOid, kOidRSA, sizeof(kOidRSA))) {
        alg = kSecKeyAlgorithmRSASignatureMessagePKCS1v15SHA256;
        algName = "RSA PKCS#1 v1.5 SHA-256";
    } else if (sgl_oid_is(salgOid, kOidEcdsaSHA256, sizeof(kOidEcdsaSHA256))) {
        alg = kSecKeyAlgorithmECDSASignatureMessageX962SHA256;
        algName = "ECDSA X9.62 SHA-256";
    } else {
        sgl_fail(@"CMS: unsupported signature algorithm");
    }
    if (sgl_all_zero(sig.p, sig.len)) {
        printf("CMS signature: FAIL (zeroed placeholder, --dry-run output)\n");
        return failures + 1;
    }
    // The signature covers the signed attributes DER-encoded as a SET OF.
    NSData *signedAttrs = sgl_der(0x31, [NSData dataWithBytes:attrs.p length:attrs.len]);
    SecCertificateRef cert = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)signerDER);
    SecKeyRef key = cert ? SecCertificateCopyKey(cert) : NULL;
    if (cert) CFRelease(cert);
    bool ok = key && SecKeyIsAlgorithmSupported(key, kSecKeyOperationTypeVerify, alg) &&
              SecKeyVerifySignature(key, alg, (__bridge CFDataRef)signedAttrs,
                                    (__bridge CFDataRef)[NSData dataWithBytes:sig.p length:sig.len], NULL);
    if (key) CFRelease(key);
    printf("CMS signature (%s): %s\n", algName, ok ? "OK" : "FAIL");
    return failures + (ok ? 0 : 1);
}

static int sgl_verify(NSString *path) {
    NSString *shownPath = sgl_escape(path, PATH_MAX);
    NSData *file = [NSData dataWithContentsOfFile:path];
    if (!file) sgl_fail(@"cannot read %@", shownPath);
    sgl_buf fb = sgl_buf_from_data(file);
    sgl_macho m;
    sgl_parse_macho(fb, true, &m);
    if (!m.hasCodeSignature) sgl_fail(@"not signed (no LC_CODE_SIGNATURE)");

    // Superblob: strict index (unique slot types, per-slot magic, blobs past
    // the index, inside the superblob and not overlapping), zero padding after.
    sgl_buf sb = { fb.p + m.sigOff, m.sigSize };
    uint32_t magic, sbLen, count;
    if (!sgl_r32be(sb, 0, &magic) || !sgl_r32be(sb, 4, &sbLen) || !sgl_r32be(sb, 8, &count))
        sgl_fail(@"truncated superblob");
    if (magic != SGL_MAGIC_SUPERBLOB) sgl_fail(@"bad superblob magic 0x%08x", magic);
    if (sbLen < 12 || sbLen > m.sigSize) sgl_fail(@"superblob length %u outside datasize %u", sbLen, m.sigSize);
    if (count == 0 || count > 16 || 12 + (uint64_t)count * 8 > sbLen)
        sgl_fail(@"bad superblob index (count %u, length %u)", count, sbLen);
    if (!sgl_all_zero(sb.p + sbLen, sb.len - sbLen)) sgl_fail(@"non-zero bytes after the superblob");
    sb.len = sbLen;
    uint32_t indexEnd = 12 + count * 8, types[16], offs[16], lens[16];
    sgl_buf cd = { NULL, 0 }, req = { NULL, 0 }, ents = { NULL, 0 }, derEnts = { NULL, 0 }, cms = { NULL, 0 };
    for (uint32_t i = 0; i < count; i++) {
        uint32_t type, boff, bmagic, blen, want;
        sgl_buf *dst;
        sgl_r32be(sb, 12 + i * 8, &type);
        sgl_r32be(sb, 16 + i * 8, &boff);
        if (boff < indexEnd || !sgl_r32be(sb, boff, &bmagic) || !sgl_r32be(sb, (size_t)boff + 4, &blen) ||
            blen < 8 || !sgl_in_bounds(sb, boff, blen))
            sgl_fail(@"blob %u (slot %#x) at offset %u lies outside the superblob", i, type, boff);
        for (uint32_t j = 0; j < i; j++) {
            if (types[j] == type) sgl_fail(@"duplicate superblob slot %#x", type);
            if (sgl_overlap(offs[j], lens[j], boff, blen)) sgl_fail(@"superblob blobs overlap");
        }
        types[i] = type; offs[i] = boff; lens[i] = blen;
        switch (type) {
        case 0:                         want = SGL_MAGIC_CODEDIRECTORY; dst = &cd; break;
        case SGL_SLOT_REQUIREMENTS:     want = SGL_MAGIC_REQUIREMENTS; dst = &req; break;
        case SGL_SLOT_ENTITLEMENTS:     want = SGL_MAGIC_ENTITLEMENTS; dst = &ents; break;
        case SGL_SLOT_DER_ENTITLEMENTS: want = SGL_MAGIC_DER_ENTITLEMENTS; dst = &derEnts; break;
        case SGL_SLOT_CMS:              want = SGL_MAGIC_BLOBWRAPPER; dst = &cms; break;
        default:
            if (type >= 0x1000 && type <= 0x1004) sgl_fail(@"alternate CodeDirectories (slot %#x) are unsupported", type);
            sgl_fail(@"unsupported superblob slot %#x", type);
        }
        if (bmagic != want) sgl_fail(@"blob in slot %#x has magic 0x%08x, expected 0x%08x", type, bmagic, want);
        *dst = (sgl_buf){ sb.p + boff, blen };
    }
    if (!cd.p) sgl_fail(@"no CodeDirectory in superblob");
    uint32_t reqCount;
    if (req.p && (!sgl_r32be(req, 8, &reqCount) || 12 + (uint64_t)reqCount * 8 > req.len))
        sgl_fail(@"malformed requirements blob");

    // CodeDirectory header, by version: scatterOffset (0x20100), teamOffset
    // (0x20200), codeLimit64 (0x20300), execSeg (0x20400), runtime (0x20500).
    uint32_t v;
    #define CDU32(o) (sgl_r32be(cd, (o), &v) ? v : (sgl_fail(@"truncated CodeDirectory"), 0u))
    uint32_t cdLen = CDU32(4), version = CDU32(8), flags = CDU32(12); // cdLen sized the blob above
    uint32_t hashOff = CDU32(16), identOff = CDU32(20), nSpecial = CDU32(24);
    uint32_t nCode = CDU32(28), codeLimit = CDU32(32);
    if (version < 0x20100 || version >= 0x20600) sgl_fail(@"unsupported CodeDirectory version 0x%x", version);
    size_t hdrLen = version >= 0x20500 ? 0x60 : version >= 0x20400 ? 0x58 : version >= 0x20300 ? 0x40
                  : version >= 0x20200 ? 0x34 : 0x30;
    uint8_t hashSize, hashType, platform, pageBits;
    if (cd.len < hdrLen || !sgl_r8(cd, 36, &hashSize) || !sgl_r8(cd, 37, &hashType) ||
        !sgl_r8(cd, 38, &platform) || !sgl_r8(cd, 39, &pageBits))
        sgl_fail(@"truncated CodeDirectory");
    if (CDU32(0x2c)) sgl_fail(@"scatter CodeDirectories are unsupported");
    uint32_t teamOff = version >= 0x20200 ? CDU32(0x30) : 0;
    uint64_t codeLimit64 = 0, execBase = 0, execLimit = 0, execFlags = 0;
    if (version >= 0x20300) sgl_r64be(cd, 0x38, &codeLimit64);
    if (codeLimit64) sgl_fail(@"64-bit codeLimit is unsupported");
    if (version >= 0x20400) {
        sgl_r64be(cd, 0x40, &execBase);
        sgl_r64be(cd, 0x48, &execLimit);
        sgl_r64be(cd, 0x50, &execFlags);
    }
    if (version >= 0x20500 && CDU32(0x5c)) sgl_fail(@"pre-encryption hashes are unsupported");
    #undef CDU32
    if (hashType != 2 || hashSize != SGL_HASH_SIZE)
        sgl_fail(@"unsupported hash type %u (size %u); only SHA-256 is supported", hashType, hashSize);
    if (pageBits != 12 && pageBits != 14)
        sgl_fail(@"unsupported CodeDirectory page size 2^%u (need 2^12 or 2^14)", pageBits);
    if (nSpecial > 7) sgl_fail(@"unsupported number of special slots %u", nSpecial);
    uint64_t specialStart = (uint64_t)hashOff - (uint64_t)nSpecial * SGL_HASH_SIZE;
    if ((uint64_t)nSpecial * SGL_HASH_SIZE > hashOff || specialStart < hdrLen)
        sgl_fail(@"special slots overlap the CodeDirectory header");
    if ((uint64_t)hashOff + (uint64_t)nCode * SGL_HASH_SIZE > cd.len)
        sgl_fail(@"hash array overruns CodeDirectory");
    NSString *ident = sgl_cd_string(cd, identOff, hdrLen, specialStart);
    if (!ident || !sgl_valid_identifier(ident)) sgl_fail(@"CodeDirectory identifier is missing or invalid");
    NSString *team = nil;
    if (teamOff) {
        team = sgl_cd_string(cd, teamOff, hdrLen, specialStart);
        if (!team || !sgl_valid_identifier(team)) sgl_fail(@"CodeDirectory team identifier is invalid");
    }
    // Coverage: the page hashes must cover every byte before the signature.
    uint64_t pageSize = 1ull << pageBits;
    if (codeLimit != m.sigOff)
        sgl_fail(@"codeLimit %u does not end at the signature (LC_CODE_SIGNATURE dataoff %u)", codeLimit, m.sigOff);
    if ((uint64_t)nCode != ((uint64_t)codeLimit + pageSize - 1) >> pageBits)
        sgl_fail(@"nCodeSlots %u does not cover codeLimit %u with %llu-byte pages", nCode, codeLimit, pageSize);
    bool adhoc = (flags & SGL_CS_ADHOC) != 0;

    printf("Executable=%s\n", shownPath.UTF8String);
    printf("Identifier=%s\n", ident.UTF8String); // identifier and team are validated above
    printf("CodeDirectory v=%x size=%u flags=0x%x hashes=%u+%u location=embedded\n",
           version, cdLen, flags, nCode, nSpecial);
    printf("Hash type=sha256 size=%u\n", hashSize);
    printf("Platform=%u\n", platform);
    printf("Page size=%llu\n", pageSize);
    printf("TeamIdentifier=%s\n", team ? team.UTF8String : "not set");
    if (version >= 0x20400) {
        printf("Executable Segment base=%llu\n", execBase);
        printf("Executable Segment limit=%llu\n", execLimit);
        printf("Executable Segment flags=0x%llx\n", execFlags);
    }
    printf("Internal requirements: %zu bytes\n", req.len);
    printf("Signature=%s\n", adhoc ? "adhoc" : "CMS");

    int failures = 0;
    // Special slots -1..-7: embedded blobs (requirements, entitlements) must
    // be bound and match. A bound Info.plist slot must match the raw bytes of
    // the Info.plist embedded in __TEXT,__info_plist (as codesign binds it);
    // other external data (resources) cannot exist for a bare Mach-O, so
    // those slots must be zero.
    static const char *slotName[8] = { "", "Info.plist", "requirements", "resource directory",
                                       "application-specific", "entitlements", "representation-specific",
                                       "DER entitlements" };
    for (uint32_t t = 1; t <= 7; t++) {
        sgl_buf blob = t == SGL_SLOT_REQUIREMENTS ? req : t == SGL_SLOT_ENTITLEMENTS ? ents
                     : t == SGL_SLOT_DER_ENTITLEMENTS ? derEnts : (sgl_buf){ NULL, 0 };
        if (t > nSpecial) {
            if (blob.p) {
                printf("slot -%u %s: FAIL (blob present but not bound; nSpecialSlots=%u)\n", t, slotName[t], nSpecial);
                failures++;
            }
            continue;
        }
        const uint8_t *h = cd.p + hashOff - (size_t)t * SGL_HASH_SIZE;
        if (t == SGL_SLOT_INFO_PLIST && !sgl_all_zero(h, SGL_HASH_SIZE) && m.hasInfoPlist) {
            // The parser range-checks only sections with file content; a
            // zerofill-typed __info_plist may point anywhere.
            if (!sgl_in_bounds(fb, m.infoPlistOff, m.infoPlistSize)) {
                printf("slot -%u %s: FAIL (__TEXT,__info_plist lies outside the file)\n", t, slotName[t]);
                failures++;
                continue;
            }
            NSData *plist = [NSData dataWithBytes:fb.p + m.infoPlistOff length:(size_t)m.infoPlistSize];
            bool ok = memcmp(sgl_sha256(plist).bytes, h, SGL_HASH_SIZE) == 0;
            printf("slot -%u %s hash: %s\n", t, slotName[t], ok ? "OK" : "FAIL");
            if (!ok) failures++;
        } else if (blob.p) {
            bool ok = memcmp(sgl_sha256([NSData dataWithBytes:blob.p length:blob.len]).bytes, h, SGL_HASH_SIZE) == 0;
            printf("slot -%u %s hash: %s\n", t, slotName[t], ok ? "OK" : "FAIL");
            if (!ok) failures++;
        } else if (!sgl_all_zero(h, SGL_HASH_SIZE)) {
            printf("slot -%u %s: FAIL (bound, but no such data exists here%s)\n", t, slotName[t],
                   t == SGL_SLOT_INFO_PLIST ? "; there is no __TEXT,__info_plist section" : "");
            failures++;
        } else {
            printf("slot -%u %s: not bound\n", t, slotName[t]);
        }
    }
    // Code slots.
    for (uint32_t i = 0; i < nCode; i++) {
        uint64_t start = (uint64_t)i << pageBits;
        uint64_t len = MIN(pageSize, (uint64_t)codeLimit - start);
        bool ok = memcmp(sgl_sha256([NSData dataWithBytes:fb.p + start length:(size_t)len]).bytes,
                         cd.p + hashOff + (size_t)i * SGL_HASH_SIZE, SGL_HASH_SIZE) == 0;
        printf("page %u (%llu bytes): %s\n", i, len, ok ? "OK" : "FAIL");
        if (!ok) failures++;
    }
    NSData *cdData = [NSData dataWithBytes:cd.p length:cd.len];
    NSData *full = sgl_sha256(cdData);
    printf("CDHash=%s\n", sgl_hex([full subdataWithRange:NSMakeRange(0, 20)]).UTF8String);
    printf("CDHashFull=%s\n", sgl_hex(full).UTF8String);

    // Signature: ad-hoc CodeDirectories carry no signer (codesign writes an
    // empty CMS wrapper); everything else needs a CMS signature bound to the CD.
    if (adhoc) {
        if (cms.p && cms.len != 8) {
            printf("CMS: FAIL (ad-hoc CodeDirectory with a CMS signature)\n");
            failures++;
        }
    } else {
        if (!cms.p || cms.len == 8) sgl_fail(@"no CMS signature, and the CodeDirectory is not ad-hoc");
        failures += sgl_verify_cms(cms, cdData, team);
    }
    if (failures) {
        printf("verification FAILED (%d problems)\n", failures);
        return 1;
    }
    printf(adhoc ? "ad-hoc signature: hashes and coverage OK (no signer to verify)\n"
                 : "hashes and coverage OK; signature and binding OK; trust not evaluated\n");
    return 0;
}

// -------------------------------------------------------------------- main

#ifndef SGL_NO_MAIN
int main(int argc, char **argv) {
    @autoreleasepool {
        NSString *ident = nil, *identity = nil, *team = nil;
        NSMutableArray<NSString *> *positional = [NSMutableArray array];
        BOOL verify = NO, selftest = NO, selftestEC = NO, dryRun = NO, adhoc = NO;
        for (int i = 1; i < argc; i++) {
            NSString *a = [NSString stringWithUTF8String:argv[i]];
            if (!a) sgl_fail(@"argument %d is not valid UTF-8", i);
            if ([a isEqual:@"--verify"]) {
                verify = YES;
            } else if ([a isEqual:@"--selftest"]) {
                selftest = YES;   // ephemeral self-signed RSA key; pipeline validation only
            } else if ([a isEqual:@"--selftest-ec"]) {
                selftestEC = YES; // ephemeral self-signed P-256 key
            } else if ([a isEqual:@"--dry-run"]) {
                dryRun = YES;     // zeroed CMS signature (no private-key use)
            } else if ([a isEqual:@"--adhoc"]) {
                adhoc = YES;      // like codesign -s -: no identity, no keychain
            } else if ([a isEqual:@"-i"] || [a isEqual:@"-s"] || [a isEqual:@"--team"]) {
                if (i + 1 >= argc) sgl_fail(@"%@ needs a value", a);
                NSString *value = [NSString stringWithUTF8String:argv[++i]];
                if (!value) sgl_fail(@"argument %d is not valid UTF-8", i);
                if ([a isEqual:@"-i"]) ident = value;
                else if ([a isEqual:@"-s"]) identity = value;
                else team = value;
            } else if ([a isEqual:@"-h"] || [a isEqual:@"--help"]) {
                fprintf(stderr, "usage: sign_guest_local [-i identifier] [-s identity] [--team TEAMID] <in> <out>\n"
                                "       sign_guest_local --adhoc [-i identifier] <in> <out>\n"
                                "       sign_guest_local --verify <file>\n"
                                "       sign_guest_local --selftest|--selftest-ec [-i identifier] <in> <out>\n"
                                "                        (ephemeral self-signed RSA / P-256 key)\n"
                                "       sign_guest_local --dry-run [...] <in> <out>   (zeroed CMS signature)\n"
                                "-s: CN substring, exact CN or SHA-1 (default \"Apple Development\");\n"
                                "--team: only identities whose certificate OU is TEAMID.\n"
                                "--verify checks hashes, coverage and the CMS signature and binding;\n"
                                "it does not evaluate certificate trust.\n");
                return 0;
            } else if (a.length > 1 && [a hasPrefix:@"-"]) {
                sgl_fail(@"unknown option %@ (see --help)", a);
            } else {
                if (a.length == 0) sgl_fail(@"argument %d is an empty path", i);
                [positional addObject:a];
            }
        }
        if (verify) {
            if (selftest || selftestEC || dryRun || adhoc || ident || identity || team)
                sgl_fail(@"--verify takes no signing options");
            if (positional.count != 1) sgl_fail(@"--verify takes exactly one file");
            return sgl_verify(positional[0]);
        }
        if ((selftest ? 1 : 0) + (selftestEC ? 1 : 0) + (adhoc ? 1 : 0) > 1)
            sgl_fail(@"--selftest, --selftest-ec and --adhoc are mutually exclusive");
        if (adhoc && dryRun) sgl_fail(@"--dry-run does not apply to --adhoc");
        if ((selftest || selftestEC || adhoc) && (identity || team))
            sgl_fail(@"-s and --team select a keychain identity; they do not apply to --selftest or --adhoc");
        if (team && !sgl_valid_identifier(team)) sgl_fail(@"invalid team identifier '%@'", team);
        if (positional.count != 2) sgl_fail(@"need input and output paths (see --help)");
        sgl_mode mode = adhoc ? SGL_MODE_ADHOC : selftest ? SGL_MODE_SELFTEST_RSA
                      : selftestEC ? SGL_MODE_SELFTEST_EC : SGL_MODE_KEYCHAIN;
        sgl_sign(positional[0], positional[1], ident, identity ?: @"Apple Development", team, mode, dryRun);
        return 0;
    }
}
#endif
