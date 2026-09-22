// Host-only test for SignedFileProbe's Mach-O parser and mode dispatch. Builds
// synthetic Mach-O files (valid and malformed) in a temp directory and runs the
// non-executing 'inspect' mode against them, asserting the logged result. No
// file-mapped code is ever executed here: 'inspect' only maps PROT_READ.
#include "SignedFileProbe.h"
#include <assert.h>
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define RET_INSTRUCTION 0xd65f03c0u // arm64 `ret`, never called by this test
#define CAP (1u << 20)

static char dir[1024];

static void put_be32(unsigned char *p, uint32_t v) {
    p[0] = (unsigned char)(v >> 24); p[1] = (unsigned char)(v >> 16);
    p[2] = (unsigned char)(v >> 8); p[3] = (unsigned char)v;
}

static const char *write_file(const char *name, const unsigned char *data, size_t size) {
    static char path[1200];
    snprintf(path, sizeof path, "%s/%s", dir, name);
    FILE *f = fopen(path, "wb");
    assert(f);
    assert(fwrite(data, 1, size, f) == size);
    assert(fclose(f) == 0);
    return path;
}

// Fills a Mach-O with a single LC_SEGMENT_64/__TEXT,__text section and an
// optional LC_CODE_SIGNATURE, letting each field be corrupted for one case.
typedef struct {
    bool with_signature;    // emit an LC_CODE_SIGNATURE command
    bool signature_out_of_range; // point that command past the file
    uint32_t segment_cmdsize;    // 0 => the natural size
    uint32_t nsects_override;    // 0 => 1
    int32_t text_offset_delta;   // added to the true __text offset
    const char *text_sectname;   // "__text" unless overridden
    const unsigned char *signature; size_t signature_size; // embedded superblob
    bool end_on_page_boundary;   // pad so the blob's last byte ends a page
    uint32_t signature_pad;      // deliberately misalign the blob by this many bytes
} plan;

static size_t build(unsigned char *b, const plan *p) {
    memset(b, 0, CAP);
    struct mach_header_64 *h = (void *)b;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_ARM64;
    h->cpusubtype = CPU_SUBTYPE_ARM64_ALL;
    h->filetype = MH_DYLIB;

    uint32_t seg_size = sizeof(struct segment_command_64) + sizeof(struct section_64);
    uint32_t sig_size = p->with_signature ? sizeof(struct linkedit_data_command) : 0;
    h->ncmds = p->with_signature ? 2 : 1;
    h->sizeofcmds = seg_size + sig_size;

    struct segment_command_64 *seg = (void *)(b + sizeof *h);
    seg->cmd = LC_SEGMENT_64;
    seg->cmdsize = p->segment_cmdsize ? p->segment_cmdsize : seg_size;
    memcpy(seg->segname, "__TEXT", 6);
    seg->nsects = p->nsects_override ? p->nsects_override : 1;
    struct section_64 *sec = (void *)(seg + 1);
    memcpy(sec->sectname, p->text_sectname ? p->text_sectname : "__text", 6);
    memcpy(sec->segname, "__TEXT", 6);

    uint32_t text_offset = sizeof(*h) + h->sizeofcmds; // just past the load commands
    sec->addr = text_offset;
    sec->size = 4;
    sec->offset = (uint32_t)((int64_t)text_offset + p->text_offset_delta);
    put_be32(b + text_offset, __builtin_bswap32(RET_INSTRUCTION)); // stored so mmap sees `ret`
    size_t end = text_offset + 4;

    if (p->with_signature) {
        struct linkedit_data_command *sig = (void *)((unsigned char *)seg + seg_size);
        sig->cmd = LC_CODE_SIGNATURE;
        sig->cmdsize = sizeof(*sig);
        if (p->signature_out_of_range) {
            sig->dataoff = (uint32_t)end;   // valid start...
            sig->datasize = CAP;            // ...but datasize runs off the file
        } else if (p->signature && p->signature_size) {
            uint32_t sig_off = (uint32_t)((end + 15) & ~(size_t)15);
            if (p->end_on_page_boundary) {
                // Anchor the blob so its final byte (the identifier's last byte,
                // since the identifier runs to the blob end with no NUL) is the
                // last byte of the file, and the file ends exactly on a page
                // boundary. mmap then leaves the next page unmapped, so a
                // regression from the bounded %.*s to a raw %s reads off the end
                // of the mapping and faults instead of stopping at page zero-
                // fill. signature_size is a multiple of 4, so sig_off stays
                // 4-aligned and the blob's 32-bit reads remain aligned for UBSan.
                size_t pg = (size_t)getpagesize();
                size_t want_end = ((sig_off + p->signature_size + pg - 1) / pg) * pg;
                sig_off = (uint32_t)(want_end - p->signature_size);
            } else {
                // Deliberately misalign the blob for the alignment case, so the
                // blob's 32-bit and 64-bit field reads land on an address the
                // required type alignment forbids. The memcpy readers are
                // defined there; a raw pointer dereference is UB that
                // -fsanitize=alignment faults on.
                sig_off += p->signature_pad;
            }
            memcpy(b + sig_off, p->signature, p->signature_size);
            sig->dataoff = sig_off;
            sig->datasize = (uint32_t)p->signature_size;
            end = sig_off + p->signature_size;
        } else {
            sig->dataoff = 0; sig->datasize = 0;
        }
    }
    return end;
}

// An embedded signature superblob with one CodeDirectory whose identifier runs
// to the very end of the blob with no terminating NUL. describe_signature must
// bound its %.*s print to the CodeDirectory and never read past it. The
// identifier is 12 bytes so the blob length (64 + ident) stays a multiple of 4,
// keeping the blob's 32-bit reads aligned once it is page-anchored (see the
// end_on_page_boundary path in build).
static size_t build_unterminated_signature(unsigned char *s) {
    const char ident[] = {'g','u','e','s','t','_','t','e','s','t','_','x'}; // 12 bytes, no trailing NUL
    uint32_t cd_off = 12 + 8;                 // superblob header + one index entry
    uint32_t cd_len = 44 + (uint32_t)sizeof ident;
    uint32_t total = cd_off + cd_len;
    put_be32(s + 0, 0xfade0cc0u);             // CS_MAGIC_EMBEDDED_SIGNATURE
    put_be32(s + 4, total);
    put_be32(s + 8, 1);                       // one blob
    put_be32(s + 12, 0);                      // slot type: CodeDirectory
    put_be32(s + 16, cd_off);
    unsigned char *cd = s + cd_off;
    put_be32(cd + 0, 0xfade0c02u);            // CS_MAGIC_CODEDIRECTORY
    put_be32(cd + 4, cd_len);
    put_be32(cd + 8, 0x20001);                // version
    put_be32(cd + 12, 0);                     // flags
    put_be32(cd + 16, 0);                     // hashOffset
    put_be32(cd + 20, 44);                    // identOffset -> the identifier
    memcpy(cd + 44, ident, sizeof ident);
    return total;
}

// A superblob with one CodeDirectory that advertises the execseg extension
// (version 0x20400, length >= 88), so describe_signature performs the 64-bit
// execseg reads at content+72 and content+80 as well as the 32-bit field reads.
// Combined with a misaligned blob offset (plan.signature_pad), those reads land
// on addresses that uint32_t/uint64_t alignment forbids: the memcpy readers are
// defined there, a raw pointer dereference is UB that -fsanitize=alignment
// faults on. The identifier is NUL-terminated and sits past the execseg fields.
static size_t build_execseg_signature(unsigned char *s) {
    const char ident[] = "guest_test";        // 10 bytes + terminating NUL
    uint32_t cd_off = 12 + 8;                  // superblob header + one index entry
    uint32_t cd_len = 88 + (uint32_t)sizeof ident; // through execSegFlags (80..87) + ident
    uint32_t total = cd_off + cd_len;
    memset(s, 0, total);                       // CD spares + execSeg fields default to 0
    put_be32(s + 0, 0xfade0cc0u);              // CS_MAGIC_EMBEDDED_SIGNATURE
    put_be32(s + 4, total);
    put_be32(s + 8, 1);                        // one blob
    put_be32(s + 12, 0);                       // slot type: CodeDirectory
    put_be32(s + 16, cd_off);
    unsigned char *cd = s + cd_off;
    put_be32(cd + 0, 0xfade0c02u);             // CS_MAGIC_CODEDIRECTORY
    put_be32(cd + 4, cd_len);
    put_be32(cd + 8, 0x20400);                 // version advertising execSeg fields
    put_be32(cd + 12, 0);                      // flags
    put_be32(cd + 16, 0);                      // hashOffset
    put_be32(cd + 20, 88);                     // identOffset -> just past execSegFlags
    // Bytes 40..87 (spares, codeLimit64, execSegBase/Limit/Flags) stay zero;
    // describe_signature reads execSegLimit (72) and execSegFlags (80) from here.
    memcpy(cd + 88, ident, sizeof ident);
    return total;
}

// Header + a filler load command that consumes the load-command region up to
// the last 8 bytes of a one-page file, then an LC_SEGMENT_64 whose cmdsize is
// only 8. The file is exactly one page long, so the page after it is unmapped.
// The parser copies the 8-byte load_command header (the last 8 bytes of the
// file), sees cmdsize < sizeof(segment_command_64) and returns -4 before
// touching the rest of the struct. Code lacking that check reads the full
// 72-byte segment (its nsects field included) from that offset, running 64
// bytes past the page into unmapped memory and faulting -- so removing the
// check is observable as a crash here, not merely as a wrong result.
static size_t build_truncated_segment_at_page_end(unsigned char *b) {
    size_t page = (size_t)getpagesize();
    memset(b, 0, page);
    struct mach_header_64 *h = (void *)b;
    h->magic = MH_MAGIC_64;
    h->cputype = CPU_TYPE_ARM64;
    h->cpusubtype = CPU_SUBTYPE_ARM64_ALL;
    h->filetype = MH_DYLIB;
    h->ncmds = 2;
    h->sizeofcmds = (uint32_t)(page - sizeof *h);   // load commands fill to page end

    struct load_command *filler = (void *)(b + sizeof *h);
    filler->cmd = LC_UUID;                            // not a segment/signature: skipped
    filler->cmdsize = (uint32_t)(page - sizeof *h - sizeof(struct load_command));

    struct load_command *seg = (void *)(b + page - sizeof(struct load_command));
    seg->cmd = LC_SEGMENT_64;
    seg->cmdsize = (uint32_t)sizeof(struct load_command); // 8 < sizeof(segment_command_64)
    return page;
}

static const char *last_result(const char *buf) {
    const char *needle = "[signed-file] result=";
    const char *p = buf, *last = NULL;
    while ((p = strstr(p, needle)) != NULL) { last = p; p += 1; }
    assert(last && "probe must log a result line");
    return last + strlen(needle);
}

// Runs one case: build (unless raw), inspect, and assert both the return value
// and the trailing result token. Never runs any mode that maps executable.
static void expect(const char *name, const char *mode, const unsigned char *raw, size_t raw_size,
                   const plan *p, bool want_pass) {
    unsigned char *b = malloc(CAP);
    assert(b);
    size_t size = raw ? raw_size : build(b, p);
    const unsigned char *bytes = raw ? raw : b;
    const char *path = write_file(name, bytes, size);

    char *log_buf = NULL; size_t log_len = 0;
    FILE *log = open_memstream(&log_buf, &log_len);
    assert(log);
    bool ok = HostSignedFileProbe(path, mode, 0, log);
    fclose(log); // finalizes log_buf

    const char *want = want_pass ? "PASS" : "FAIL";
    assert(ok == want_pass);
    assert(!strncmp(last_result(log_buf), want, strlen(want)));
    fprintf(stderr, "  %-28s mode=%-7s -> %s\n", name, mode, want);
    free(log_buf);
    free(b);
}

int main(void) {
    char template[] = "/tmp/signedfileprobeXXXXXX";
    char *made = mkdtemp(template);
    assert(made);
    snprintf(dir, sizeof dir, "%s", made);

    // 1. Valid tiny image, no signature: parses and passes inspect.
    plan valid = {0};
    expect("valid.macho", "inspect", NULL, 0, &valid, true);

    // 2. Truncated header: below sizeof(mach_header_64).
    unsigned char tiny[16] = {0xcf, 0xfa, 0xed, 0xfe};
    expect("truncated.macho", "inspect", tiny, sizeof tiny, NULL, false);

    // 3. LC_SEGMENT_64 whose cmdsize (8) is smaller than segment_command_64,
    //    placed as the last 8 bytes of a one-page file so the page after it is
    //    unmapped. The parser must reject it after copying only the 8-byte
    //    load_command header; reading nsects (or the rest of the segment) past
    //    cmdsize would cross into that unmapped page and fault. So this checks
    //    the -4 rejection AND makes removing the cmdsize check observable as a
    //    crash rather than only a wrong result (verified by reverting the check
    //    in a scratch copy: it then SIGSEGVs here).
    unsigned char *page_buf = malloc(CAP);
    assert(page_buf);
    size_t page_size = build_truncated_segment_at_page_end(page_buf);
    expect("short-cmdsize-page.macho", "inspect", page_buf, page_size, NULL, false);
    free(page_buf);

    // 4. nsects so large the section array overflows the command.
    plan nsects_overflow = { .nsects_override = 0x10000000u };
    expect("nsects-overflow.macho", "inspect", NULL, 0, &nsects_overflow, false);

    // 5. __text section offset points beyond the file.
    plan section_beyond = { .text_offset_delta = (int32_t)CAP };
    expect("section-beyond.macho", "inspect", NULL, 0, &section_beyond, false);

    // 6. No __TEXT,__text section at all.
    plan no_text = { .text_sectname = "__data" };
    expect("missing-text.macho", "inspect", NULL, 0, &no_text, false);

    // 7. LC_CODE_SIGNATURE whose data range runs off the end of the file.
    plan bogus_sig = { .with_signature = true, .signature_out_of_range = true };
    expect("bogus-signature.macho", "inspect", NULL, 0, &bogus_sig, false);

    // 8. CodeDirectory identifier with no terminating NUL, anchored so its last
    //    byte ends the file exactly on a page boundary. The correct bounded
    //    %.*s print reads only within the mapping and passes; a regression to a
    //    raw %s would run off the end into the unmapped next page and SIGSEGV,
    //    so this case detects that specific unbounded-read regression rather
    //    than relying on sanitizers (which do not instrument mmap'd pages).
    unsigned char sig[256];
    size_t sig_size = build_unterminated_signature(sig);
    plan unterminated = { .with_signature = true, .signature = sig, .signature_size = sig_size,
                          .end_on_page_boundary = true };
    expect("unterminated-ident.macho", "inspect", NULL, 0, &unterminated, true);

    // 9. Unknown mode must fail closed without mapping anything executable.
    expect("valid.macho", "bogusmode", NULL, 0, &valid, false);

    // 10. Signature blob at a deliberately misaligned file offset, carrying a
    //     CodeDirectory with the execseg extension. describe_signature reads the
    //     blob's 32-bit fields and the 64-bit execseg fields (content+72, +80)
    //     at that unaligned address. The memcpy readers are defined there, so
    //     this passes; a raw uint32_t/uint64_t dereference of the same bytes is
    //     UB that the alignment check in -fsanitize=...,undefined faults on
    //     (verified by restoring the raw pointer reads in a scratch copy: it
    //     then reports a misaligned load here).
    unsigned char esig[256];
    size_t esig_size = build_execseg_signature(esig);
    plan unaligned = { .with_signature = true, .signature = esig, .signature_size = esig_size,
                       .signature_pad = 2 }; // 2 mod 4/8: misaligns the 32- and 64-bit reads
    expect("unaligned-execseg.macho", "inspect", NULL, 0, &unaligned, true);

    puts("PASS: signed-file probe parser bounds, signature ranges, and mode dispatch");
    return 0;
}
