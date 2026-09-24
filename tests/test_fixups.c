#include "GuestFixups.h"
#include <mach-o/fixup-chains.h>
#include <stdint.h>
#include <assert.h>
#include <string.h>
static bool resolve(const char *name, int ordinal, bool weak, bool lazy, uint64_t *value, void *context) {
    (void)context; (void)weak; (void)lazy;
    assert(!strcmp(name, "_sample") && ordinal == 1);
    *value = 0x12340000; return true;
}
static unsigned recorded; static bool recorded_lazy[4];
// Which kind of bind each call came from, in order.
static bool record(const char *name, int ordinal, bool weak, bool lazy, uint64_t *value, void *context) {
    (void)name; (void)ordinal; (void)weak; (void)context;
    if (recorded < 4) recorded_lazy[recorded] = lazy;
    recorded++; *value = 0x12340000; return true;
}
static void setup(GuestImage *i, const uint8_t *r, size_t rn, const uint8_t *b, size_t bn) {
    *i = (GuestImage){0}; i->segment_count = 1; i->dylib_count = 1;
    i->segments[0] = (GISegment){.address=0x100000000, .size=GM_PAGE_SIZE, .file_size=GM_PAGE_SIZE, .prot=3};
    assert(gm_map(&i->memory, 0x100000000, GM_PAGE_SIZE, 3, 7, false, false) == GM_OK);
    i->rebase_offset=256; i->rebase_size=(uint32_t)rn;
    i->bind_offset=512; i->bind_size=(uint32_t)bn;
    assert(gm_populate(&i->memory, 0x100000100, r, rn) == GM_OK);
    assert(gm_populate(&i->memory, 0x100000200, b, bn) == GM_OK);
    uint64_t pointer = 0x100000800;
    assert(gm_populate(&i->memory, 0x100000000, &pointer, 8) == GM_OK);
}
// One page, one import, one chain, built by hand.
static size_t chained_blob(uint8_t *out, uint16_t format) {
    memset(out, 0, 128);
    uint32_t header[7] = {0, 32, 64, 80, 1, DYLD_CHAINED_IMPORT, 0};
    memcpy(out, header, sizeof header);
    uint32_t starts[2] = {1, 8};                    // one segment, its info eight bytes on
    memcpy(out + 32, starts, sizeof starts);
    uint32_t size = 24;
    uint16_t page_size = GM_PAGE_SIZE, page_count = 1, page_start = 0;
    uint64_t segment_offset = 0;
    memcpy(out + 40, &size, 4);
    memcpy(out + 44, &page_size, 2);
    memcpy(out + 46, &format, 2);
    memcpy(out + 48, &segment_offset, 8);
    memcpy(out + 60, &page_count, 2);
    memcpy(out + 62, &page_start, 2);
    uint32_t import = 1;                            // library ordinal one, name at zero
    memcpy(out + 64, &import, 4);
    memcpy(out + 80, "_sample", 8);
    return 88;
}
static void chained_setup(GuestImage *i, uint16_t format, uint64_t first, uint64_t second) {
    *i = (GuestImage){0}; i->segment_count = 1; i->dylib_count = 1;
    i->segments[0] = (GISegment){.address=0x100000000, .size=GM_PAGE_SIZE, .file_size=GM_PAGE_SIZE, .prot=3};
    assert(gm_map(&i->memory, 0x100000000, GM_PAGE_SIZE, 3, 7, false, false) == GM_OK);
    i->header_address = 0x100000000; i->mapped_size = GM_PAGE_SIZE;
    i->chained_fixups = true; i->chained_offset = 1024;
    uint8_t blob[128];
    i->chained_size = (uint32_t)chained_blob(blob, format);
    assert(gm_populate(&i->memory, 0x100000400, blob, i->chained_size) == GM_OK);
    assert(gm_populate(&i->memory, 0x100000000, &first, 8) == GM_OK);
    assert(gm_populate(&i->memory, 0x100000008, &second, 8) == GM_OK);
}

int main(void) {
    GuestImage i; GFStats stats; char error[256]; uint64_t value;
    const uint8_t r[] = {0x11,0x20,0,0x51,0};
    const uint8_t b[] = {0x11,0x40,'_','s','a','m','p','l','e',0,0x70,8,0x60,0x7c,0x90,0};
    setup(&i,r,sizeof r,b,sizeof b);
    assert(gf_apply(&i,0x200000,resolve,NULL,&stats,error,sizeof error));
    assert(stats.rebases==1 && stats.binds==1);
    assert(gm_read(&i.memory,0x100000000,&value,8)==GM_OK && value==0x100200800);
    assert(gm_read(&i.memory,0x100000008,&value,8)==GM_OK && value==0x1233fffc);
    gi_destroy(&i);
    // A lazy and a plain bind: lazy is bound first.
    const uint8_t lazy_stream[]={0x70,16,0x11,0x40,'_','s','a','m','p','l','e',0,0x90,0};
    setup(&i,r,sizeof r,b,sizeof b);
    assert(gm_populate(&i.memory,0x100000300,lazy_stream,sizeof lazy_stream)==GM_OK);
    i.lazy_bind_offset=768; i.lazy_bind_size=sizeof lazy_stream;
    recorded=0;
    assert(gf_apply(&i,0,record,NULL,&stats,error,sizeof error) && stats.binds==2);
    assert(recorded==2 && recorded_lazy[0] && !recorded_lazy[1]);
    gi_destroy(&i);
    // Vivox uses DO_BIND_ADD_ADDR_ULEB with -8, so the next bind is at the
    // same location. Unsigned wrap is dyld stream arithmetic, not an overflow.
    const uint8_t bind_backwards[]={0x11,0x40,'_','s','a','m','p','l','e',0,0x70,8,
        0xa0,0xf8,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,1,0x90,0};
    setup(&i,r,sizeof r,bind_backwards,sizeof bind_backwards);
    assert(gf_apply(&i,0,resolve,NULL,&stats,error,sizeof error) && stats.binds==2);
    assert(gm_read(&i.memory,0x100000008,&value,8)==GM_OK && value==0x12340000);
    gi_destroy(&i);
    // Real dyld streams use a wrapping ULEB delta to move backward.
    const uint8_t backwards[]={0x11,0x40,'_','s','a','m','p','l','e',0,0x70,16,0x90,
        0x80,0xe8,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,1,0x90,0};
    setup(&i,r,sizeof r,backwards,sizeof backwards);
    assert(gf_apply(&i,0,resolve,NULL,&stats,error,sizeof error) && stats.binds==2);
    assert(gm_read(&i.memory,0x100000000,&value,8)==GM_OK && value==0x12340000);
    gi_destroy(&i);
    // Lazy DONE separates independent records; state cannot leak across them.
    const uint8_t bad_lazy[]={0x11,0x40,'_','s','a','m','p','l','e',0,0x70,8,0x90,0,0x90,0};
    setup(&i,r,sizeof r,bad_lazy,sizeof bad_lazy);
    i.lazy_bind_offset=i.bind_offset; i.lazy_bind_size=i.bind_size; i.bind_size=0;
    assert(!gf_apply(&i,0,resolve,NULL,&stats,error,sizeof error)); gi_destroy(&i);
    // Truncated ULEB, overflowing ULEB, invalid segment, out-of-range pointer,
    // and enormous repeat count must fail without reading beyond the stream.
    const uint8_t invalid[][16] = {{0x20,0x80},{0x20,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,0xff,2},
        {0x11,0x2f,0,0x51,0},{0x11,0x20,0xff,0x7f,0x51,0},{0x11,0x20,0,0x60,0xff,0xff,0xff,0x7f,0}};
    const size_t sizes[]={2,11,5,7,9};
    for(size_t n=0;n<5;n++) { setup(&i,invalid[n],sizes[n],b,sizeof b);
        assert(!gf_apply(&i,0,resolve,NULL,&stats,error,sizeof error)); gi_destroy(&i); }
    setup(&i,r,sizeof r,b,sizeof b-1);
    assert(!gf_apply(&i,0,resolve,NULL,&stats,error,sizeof error)); gi_destroy(&i);
    {
        // A rebase to the next slot, then a bind.
        uint64_t rebase = 0x100000800ULL | (2ULL << 51), bind = (1ULL << 63) | (8ULL << 24);
        chained_setup(&i, DYLD_CHAINED_PTR_64, rebase, bind);
        assert(gf_apply(&i, 0x200000, resolve, NULL, &stats, error, sizeof error));
        assert(stats.rebases == 1 && stats.binds == 1);
        assert(gm_read(&i.memory, 0x100000000, &value, 8) == GM_OK && value == 0x100200800);
        assert(gm_read(&i.memory, 0x100000008, &value, 8) == GM_OK && value == 0x12340008);
        gi_destroy(&i);

        // The same chain written as offsets from the image base.
        chained_setup(&i, DYLD_CHAINED_PTR_64_OFFSET, 0x800ULL | (2ULL << 51), bind);
        assert(gf_apply(&i, 0x200000, resolve, NULL, &stats, error, sizeof error));
        assert(gm_read(&i.memory, 0x100000000, &value, 8) == GM_OK && value == 0x100200800);
        gi_destroy(&i);

        // Two pointer initializers in a chain: read after fixups.
        chained_setup(&i, DYLD_CHAINED_PTR_64, 0x100000800ULL | (2ULL << 51), 0x100000900ULL);
        i.initializer_address = 0x100000000; i.initializer_count = 2;
        uint64_t record = 0;
        assert(gm_read(&i.memory, 0x100000000, &record, 8) == GM_OK);
        assert(gf_apply(&i, 0x200000, resolve, NULL, &stats, error, sizeof error) && stats.rebases == 2);
        uint64_t placed[2];
        assert(gm_read(&i.memory, 0x100000000, placed, sizeof placed) == GM_OK);
        uint64_t at = (uintptr_t)placed - i.initializer_address;
        assert(gi_placed_initializer(&i, at, 0) == 0x100200800 && gi_placed_initializer(&i, at, 1) == 0x100200900);
        assert(record + 0x200000 != 0x100200800);
        gi_destroy(&i);

        // Malformed chains are refused rather than followed.
        chained_setup(&i, 99, rebase, bind);
        assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "pointer format"));
        gi_destroy(&i);
        chained_setup(&i, DYLD_CHAINED_PTR_64, rebase, (1ULL << 63) | 5);
        assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "import 5"));
        gi_destroy(&i);
        // A chain that walks off the end of the image.
        chained_setup(&i, DYLD_CHAINED_PTR_64, 4094ULL << 51, bind);
        uint64_t tail = 1ULL << 51;
        assert(gm_populate(&i.memory, 0x100003FF8, &tail, 8) == GM_OK);
        assert(!gf_apply(&i, 0, resolve, NULL, &stats, error, sizeof error) && strstr(error, "outside guest memory"));
        gi_destroy(&i);
    }
    puts("PASS: Mach-O pointer relocation, import binding, lazy binds first, chained initializers read after fixups,"
         " signed addends, malformed fixup bounds");
}
