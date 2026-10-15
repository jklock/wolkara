#include "SignedImage.h"
#include <mach-o/loader.h>
#include <mach/machine.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// Synthetic page containers and guests built in memory: no dyld, no signing.
#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "%s:%d: check failed: %s (error: %s)\n", __FILE__, __LINE__, #condition, error); abort(); } } while (0)
enum { PAGE = GM_PAGE_SIZE, PAGES = 8, TEXT = PAGES * PAGE };
static const uint64_t BASE = 0x100000000ULL;
static char error[512];

static void expect_error(bool ok, const char *fragment, int line) {
    if (ok || !strstr(error, fragment)) {
        fprintf(stderr, "%s:%d: expected failure containing \"%s\", got %s: %s\n",
                __FILE__, line, fragment, ok ? "success" : "failure", error);
        abort();
    }
    error[0] = 0;
}
#define EXPECT_ERROR(ok, fragment) expect_error(ok, fragment, __LINE__)

// Header page with the load commands a minimal container carries, followed by
// the image section and one page of __LINKEDIT.
typedef struct {
    unsigned char *bytes, *image;
    struct mach_header_64 *header;
    struct segment_command_64 *text, *linkedit;
    struct section_64 *section;
    uintptr_t marker;
} Container;
static void container_create(Container *c, uint64_t image_size) {
    size_t size = PAGE + (size_t)image_size + PAGE;
    unsigned char *p = aligned_alloc(PAGE, size);
    CHECK(p);
    memset(p, 0, size);
    c->bytes = p; c->image = p + PAGE; c->marker = (uintptr_t)p + PAGE;
    c->header = (void *)p;
    c->text = (void *)(c->header + 1);
    c->section = (void *)(c->text + 1);
    c->linkedit = (void *)(c->section + 1);
    struct uuid_command *uuid = (void *)(c->linkedit + 1);
    *c->text = (struct segment_command_64){ LC_SEGMENT_64, sizeof *c->text + sizeof *c->section, "__TEXT",
        0, PAGE + image_size, 0, PAGE + image_size, 5, 5, 1, 0 };
    *c->section = (struct section_64){ "__text", "__TEXT", PAGE, image_size, PAGE, 14, 0, 0,
        S_REGULAR | S_ATTR_PURE_INSTRUCTIONS, 0, 0, 0 };
    *c->linkedit = (struct segment_command_64){ LC_SEGMENT_64, sizeof *c->linkedit, "__LINKEDIT",
        PAGE + image_size, PAGE, PAGE + image_size, 0, 1, 1, 0, 0 };
    *uuid = (struct uuid_command){ LC_UUID, sizeof *uuid, {0xc0, 0x17} };
    *c->header = (struct mach_header_64){ MH_MAGIC_64, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL, MH_DYLIB, 3,
        (uint32_t)((unsigned char *)(uuid + 1) - p - sizeof *c->header), MH_NOUNDEFS | MH_DYLDLINK | MH_TWOLEVEL, 0 };
}
static bool locate(const Container *c, SIImage *image) {
    return si_locate_image(c->bytes, c->marker, c->marker, image, error, sizeof error);
}

// Guest header and load commands: the bytes the image must start with.
enum { UUID_OFFSET = sizeof(struct mach_header_64) + sizeof(struct segment_command_64) + 8 };
static size_t guest_header(unsigned char *page) {
    struct segment_command_64 text = { LC_SEGMENT_64, sizeof text, "__TEXT", BASE, TEXT, 0, TEXT, 5, 5, 0, 0 };
    struct uuid_command uuid = { LC_UUID, sizeof uuid, {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16} };
    struct mach_header_64 mh = { MH_MAGIC_64, CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL, MH_EXECUTE, 2,
        sizeof text + sizeof uuid, MH_PIE, 0 };
    memcpy(page, &mh, sizeof mh);
    memcpy(page + sizeof mh, &text, sizeof text);
    memcpy(page + sizeof mh + sizeof text, &uuid, sizeof uuid);
    return sizeof mh + mh.sizeofcmds;
}
// Final pages: the guest header, then a per-page pattern with no zero bytes.
static void final_pages(unsigned char *text) {
    memset(text, 0, TEXT);
    size_t header = guest_header(text);
    for (size_t i = header; i < TEXT; i++) text[i] = (unsigned char)(1 + (i / PAGE * 31 + i * 7) % 255);
}
static GuestImage guest;
// Staged original __TEXT; pages not marked staged stay demand-zero.
static void guest_create(const unsigned char *original, const bool staged[PAGES], uint64_t initializer) {
    gm_destroy(&guest.memory);
    guest = (GuestImage){0};
    guest.segments[0] = (GISegment){ "__TEXT", BASE, TEXT, 0, TEXT, 5, 5 };
    guest.segments[1] = (GISegment){ "__DATA", BASE + TEXT, PAGE, TEXT, PAGE, 3, 3 };
    guest.segment_count = 2; guest.header_address = BASE;
    CHECK(gm_map(&guest.memory, BASE, TEXT, 5, 5, false, false) == GM_OK);
    CHECK(gm_map(&guest.memory, BASE + TEXT, PAGE, 3, 3, false, false) == GM_OK);
    for (size_t i = 0; i < PAGES; i++)
        if (!staged || staged[i]) CHECK(gm_populate(&guest.memory, BASE + i * PAGE, original + i * PAGE, PAGE) == GM_OK);
    guest.first_initializer = BASE + initializer; guest.initializer_count = 1;
}

static void test_locate(void) {
    Container c; SIImage image;
    container_create(&c, TEXT);
    CHECK(locate(&c, &image) && image.bytes == c.image && image.size == TEXT);
    EXPECT_ERROR(si_locate_image(c.bytes, c.marker, 0, &image, error, sizeof error), "tolkara_container_final");
    EXPECT_ERROR(si_locate_image(c.bytes, 0, c.marker, &image, error, sizeof error), "tolkara_container_v1");
    EXPECT_ERROR(si_locate_image(c.bytes, c.marker, c.marker + PAGE, &image, error, sizeof error), "markers");
    EXPECT_ERROR(si_locate_image(c.bytes + 8, c.marker, c.marker, &image, error, sizeof error), "page aligned");
    // Marker inside the section, not at its start.
    EXPECT_ERROR(si_locate_image(c.bytes, c.marker + PAGE, c.marker + PAGE, &image, error, sizeof error), "start of a __TEXT section");
    // Section start 16 bytes into a page.
    c.section->addr = PAGE + 16; c.section->size = TEXT - PAGE; c.marker += 16;
    EXPECT_ERROR(locate(&c, &image), "not 16 KiB aligned");
    free(c.bytes);

    container_create(&c, TEXT);
    c.section->size = TEXT - 16;
    EXPECT_ERROR(locate(&c, &image), "whole number of pages");
    c.section->size = TEXT + PAGE;
    EXPECT_ERROR(locate(&c, &image), "outside its __TEXT segment");
    // Only the file-backed part of the segment counts.
    c.section->size = TEXT; c.text->filesize = TEXT;
    EXPECT_ERROR(locate(&c, &image), "outside its __TEXT segment");
    c.text->filesize = PAGE + TEXT;
    c.section->size = UINT64_MAX - PAGE + 1;
    EXPECT_ERROR(locate(&c, &image), "outside its __TEXT segment");
    // Section address wraps: header + (addr - vmaddr) lands one page below.
    c.section->size = TEXT; c.section->addr = UINT64_MAX - PAGE + 1; c.marker = (uintptr_t)c.bytes - PAGE;
    EXPECT_ERROR(locate(&c, &image), "outside its __TEXT segment");
    // Section below its segment; wrapping segment arithmetic.
    c.section->addr = PAGE; c.text->vmaddr = 2 * PAGE;
    EXPECT_ERROR(locate(&c, &image), "outside its __TEXT segment");
    c.text->vmaddr = UINT64_MAX - PAGE + 1; c.section->addr = 0; c.marker = (uintptr_t)c.image;
    EXPECT_ERROR(locate(&c, &image), "outside its __TEXT segment");
    c.text->vmaddr = 0; c.section->addr = PAGE;
    CHECK(locate(&c, &image));
    c.text->initprot = 3;
    EXPECT_ERROR(locate(&c, &image), "read/execute");
    c.text->initprot = 5; c.text->fileoff = PAGE;
    EXPECT_ERROR(locate(&c, &image), "read/execute");
    c.text->fileoff = 0;
    CHECK(locate(&c, &image));
    free(c.bytes);
}
static void test_malformed(void) {
    Container c; SIImage image;
    container_create(&c, TEXT);
    c.header->magic = MH_MAGIC;
    EXPECT_ERROR(locate(&c, &image), "arm64 Mach-O");
    c.header->magic = MH_MAGIC_64; c.header->cputype = CPU_TYPE_X86_64;
    EXPECT_ERROR(locate(&c, &image), "arm64 Mach-O");
    c.header->cputype = CPU_TYPE_ARM64;
    uint32_t sizeofcmds = c.header->sizeofcmds, ncmds = c.header->ncmds;
    c.header->sizeofcmds = PAGE - (uint32_t)sizeof *c.header + 8;
    EXPECT_ERROR(locate(&c, &image), "exceed one 16 KiB page");
    c.header->sizeofcmds = UINT32_MAX;
    EXPECT_ERROR(locate(&c, &image), "exceed one 16 KiB page");
    c.header->sizeofcmds = sizeofcmds;
    c.text->cmdsize = 0;
    EXPECT_ERROR(locate(&c, &image), "invalid container load command 0");
    c.text->cmdsize = sizeofcmds + 8;
    EXPECT_ERROR(locate(&c, &image), "invalid container load command 0");
    c.text->cmdsize = sizeof *c.text + sizeof *c.section + 4;
    EXPECT_ERROR(locate(&c, &image), "invalid container load command 0");
    c.text->cmdsize = 64;
    EXPECT_ERROR(locate(&c, &image), "truncated container segment command 0");
    c.text->cmdsize = sizeof *c.text + sizeof *c.section;
    c.text->nsects = UINT32_MAX;
    EXPECT_ERROR(locate(&c, &image), "sections exceed its command");
    c.text->nsects = 2;
    EXPECT_ERROR(locate(&c, &image), "sections exceed its command");
    c.text->nsects = 1;
    c.header->ncmds = ncmds + 1;
    EXPECT_ERROR(locate(&c, &image), "lies past sizeofcmds");
    c.header->ncmds = ncmds - 1;
    EXPECT_ERROR(locate(&c, &image), "disagrees");
    c.header->ncmds = ncmds;
    memcpy(c.linkedit->segname, "__TEXT\0\0\0\0\0\0\0\0\0\0", 16);
    EXPECT_ERROR(locate(&c, &image), "more than one __TEXT");
    memcpy(c.linkedit->segname, "__LINKEDIT\0\0\0\0\0\0", 16);
    memcpy(c.text->segname, "__TEXX", 6);
    EXPECT_ERROR(locate(&c, &image), "no __TEXT segment");
    memcpy(c.text->segname, "__TEXT", 6);
    CHECK(locate(&c, &image));
    free(c.bytes);
}
static void test_match(void) {
    static unsigned char original[TEXT];
    Container c; SIImage image;
    container_create(&c, TEXT);
    final_pages(c.image);
    memcpy(original, c.image, TEXT);
    guest_create(original, NULL, PAGE);
    CHECK(locate(&c, &image) && si_match_guest(&image, &guest, error, sizeof error));
    // One byte of the guest's LC_UUID differs: a container for another build.
    c.image[UUID_OFFSET + 3] ^= 1;
    EXPECT_ERROR(si_match_guest(&image, &guest, error, sizeof error), "different executable");
    c.image[UUID_OFFSET + 3] ^= 1;
    // Unpacked bytes after the load commands do not take part in the binding.
    c.image[PAGE - 1] ^= 1;
    CHECK(si_match_guest(&image, &guest, error, sizeof error));
    c.image[PAGE - 1] ^= 1;
    // Containers one page smaller and larger than the guest __TEXT.
    for (int delta = -1; delta <= 1; delta += 2) {
        Container other; SIImage sized;
        container_create(&other, TEXT + delta * PAGE);
        memcpy(other.image, c.image, delta < 0 ? TEXT - PAGE : TEXT);
        CHECK(locate(&other, &sized) && sized.size == (uint64_t)(TEXT + delta * PAGE));
        EXPECT_ERROR(si_match_guest(&sized, &guest, error, sizeof error), "different executable");
        free(other.bytes);
    }
    // Load commands beyond one page cannot be bound.
    struct mach_header_64 mh;
    memcpy(&mh, original, sizeof mh);
    mh.sizeofcmds = PAGE;
    memcpy(original, &mh, sizeof mh);
    guest_create(original, NULL, PAGE);
    EXPECT_ERROR(si_match_guest(&image, &guest, error, sizeof error), "exceed one 16 KiB page");
    // Unstaged header page.
    memcpy(original, c.image, TEXT);
    bool staged[PAGES] = {false, true, true, true, true, true, true, true};
    guest_create(original, staged, PAGE);
    EXPECT_ERROR(si_match_guest(&image, &guest, error, sizeof error), "not staged");
    // Executable segments other than __TEXT, or __TEXT away from the header.
    guest_create(original, NULL, PAGE);
    guest.segments[1].prot = 5;
    EXPECT_ERROR(si_match_guest(&image, &guest, error, sizeof error), "only executable segment is __TEXT");
    guest.segments[1].prot = 3; guest.segments[0].prot = 1;
    EXPECT_ERROR(si_match_guest(&image, &guest, error, sizeof error), "only executable segment is __TEXT");
    guest.segments[0].prot = 5; guest.header_address = BASE + PAGE;
    EXPECT_ERROR(si_match_guest(&image, &guest, error, sizeof error), "only executable segment is __TEXT");
    guest.header_address = BASE;
    CHECK(si_match_guest(&image, &guest, error, sizeof error));
    free(c.bytes);
}
static void test_shadow(void) {
    static unsigned char original[TEXT];
    Container c; SIImage image; uint64_t shadow = 1;
    container_create(&c, TEXT);
    final_pages(c.image);
    CHECK(locate(&c, &image));
    // No differing page: nothing is rewritten, the initializer may be anywhere.
    memcpy(original, c.image, TEXT);
    guest_create(original, NULL, 0x40);
    CHECK(si_match_guest(&image, &guest, error, sizeof error));
    CHECK(si_shadow_size(&image, &guest, &shadow, error, sizeof error) && shadow == 0);
    // Leading run of differing pages (page 0 differs after its load commands).
    original[PAGE - 1] ^= 0xff; original[PAGE + 5] ^= 0xff; original[2 * PAGE] ^= 0xff;
    guest_create(original, NULL, 3 * PAGE);
    CHECK(si_shadow_size(&image, &guest, &shadow, error, sizeof error) && shadow == 3 * PAGE);
    guest_create(original, NULL, 3 * PAGE - 4);
    EXPECT_ERROR(si_shadow_size(&image, &guest, &shadow, error, sizeof error), "unpacking code lies inside the rewritten range");
    guest_create(original, NULL, 0);
    EXPECT_ERROR(si_shadow_size(&image, &guest, &shadow, error, sizeof error), "unpacking code lies inside the rewritten range");
    // An identical page inside the run: the range extends through page 4.
    original[2 * PAGE] ^= 0xff; original[4 * PAGE + 100] ^= 0xff;
    guest_create(original, NULL, 5 * PAGE + 8);
    CHECK(si_shadow_size(&image, &guest, &shadow, error, sizeof error) && shadow == 5 * PAGE);
    guest_create(original, NULL, 2 * PAGE);
    EXPECT_ERROR(si_shadow_size(&image, &guest, &shadow, error, sizeof error), "unpacking code lies inside the rewritten range");
    // Demand-zero original page 6 against zero, then non-zero, container bytes.
    memcpy(original, c.image, TEXT);
    memset(c.image + 6 * PAGE, 0, PAGE);
    bool staged[PAGES] = {true, true, true, true, true, true, false, true};
    guest_create(original, staged, PAGE);
    CHECK(si_shadow_size(&image, &guest, &shadow, error, sizeof error) && shadow == 0);
    c.image[6 * PAGE + PAGE / 2] = 1;
    EXPECT_ERROR(si_shadow_size(&image, &guest, &shadow, error, sizeof error), "unpacking code lies inside the rewritten range");
    guest_create(original, staged, 7 * PAGE);
    CHECK(si_shadow_size(&image, &guest, &shadow, error, sizeof error) && shadow == 7 * PAGE);
    // Every page differs: no suffix can hold the initializer.
    for (size_t i = 0; i < PAGES; i++) original[i * PAGE + PAGE - 1] ^= 0xff;
    guest_create(original, NULL, TEXT - 4);
    EXPECT_ERROR(si_shadow_size(&image, &guest, &shadow, error, sizeof error), "unpacking code lies inside the rewritten range");
    // Initializers outside __TEXT, or none at all.
    memcpy(original, c.image, TEXT);
    guest_create(original, NULL, TEXT);
    EXPECT_ERROR(si_shadow_size(&image, &guest, &shadow, error, sizeof error), "outside __TEXT");
    guest.first_initializer = BASE - 4;
    EXPECT_ERROR(si_shadow_size(&image, &guest, &shadow, error, sizeof error), "outside __TEXT");
    guest.first_initializer = BASE + PAGE; guest.initializer_count = 0;
    EXPECT_ERROR(si_shadow_size(&image, &guest, &shadow, error, sizeof error), "outside __TEXT");
    gm_destroy(&guest.memory);
    free(c.bytes);
}
static void test_mismatches(void) {
    static unsigned char a[3 * 4096 + 17], b[sizeof a];
    size_t first = 0;
    memset(a, 0x5a, sizeof a); memset(b, 0x5a, sizeof b);
    CHECK(si_count_mismatches(a, b, sizeof a, &first) == 0 && first == sizeof a);
    CHECK(si_count_mismatches(a, b, 0, &first) == 0 && first == 0);
    b[4095] = 0; b[4096] = 0; b[sizeof b - 1] = 0;
    CHECK(si_count_mismatches(a, b, sizeof a, &first) == 3 && first == 4095);
    CHECK(si_count_mismatches(a, b, 4095, &first) == 0 && first == 4095);
    CHECK(si_count_mismatches(a, b, sizeof a, NULL) == 3);
    b[0] = 1;
    CHECK(si_count_mismatches(a, b, sizeof a, &first) == 4 && first == 0);
}
int main(void) {
    test_locate();
    test_malformed();
    test_match();
    test_shadow();
    test_mismatches();
    puts("signed image contract tests passed");
    return 0;
}
