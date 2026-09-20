#include "GuestFixups.h"
#include <assert.h>
#include <string.h>
static bool resolve(const char *name, int ordinal, bool weak, uint64_t *value, void *context) {
    (void)context; (void)weak;
    assert(!strcmp(name, "_sample") && ordinal == 1);
    *value = 0x12340000; return true;
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
    puts("PASS: Mach-O pointer relocation, import binding, signed addends, malformed fixup bounds");
}
