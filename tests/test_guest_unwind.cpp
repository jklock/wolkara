extern "C" {
#include "GuestUnwind.h"
#include "GuestFixups.h"
#include "GuestWrap.h"
}
#include <cassert>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <sys/mman.h>

static bool resolve(const char *name, int, bool weak, bool, uint64_t *value, void *) {
    *value = reinterpret_cast<uintptr_t>(dlsym(RTLD_DEFAULT, name + 1));
    return *value || weak;
}
static void host_throw() { throw 79; }
int main(int argc, char **argv) {
    assert(argc == 2);
    GuestImage image{};
    char error[512];
    assert(gi_load_library(argv[1], &image, error, sizeof error));
    assert(image.unwind_size && image.eh_frame_size);
    uint64_t low;
    size_t size = gi_extent(&image, &low);
    void *mapping = mmap(nullptr, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    assert(mapping != MAP_FAILED);
    uint64_t slide = reinterpret_cast<uintptr_t>(mapping) - low;
    GFStats stats{};
    if (!gf_apply(&image, slide, resolve, nullptr, &stats, error, sizeof error)) {
        fprintf(stderr, "%s\n", error); return 1;
    }
    for (size_t i = 0; i < image.memory.count; ++i) {
        GMPage &page = image.memory.pages[i];
        if (page.bytes) memcpy(reinterpret_cast<void *>(page.address + slide), page.bytes, GM_PAGE_SIZE);
    }
    for (size_t i = 0; i < image.segment_count; ++i) {
        GISegment &s = image.segments[i];
        if (s.size) assert(!mprotect(reinterpret_cast<void *>(s.address + slide), s.size, s.prot));
    }
    GuestImage invalid = image;
    invalid.unwind_size = UINT64_MAX;
    assert(!ng_unwind_add(&invalid, slide));
    assert(!ng_unwind_add(&image, UINT64_MAX));
    assert(ng_unwind_add(&image, slide));
    assert(!ng_unwind_add(&image, slide));
    GIExport target{};
    assert(gi_export(&image, "_fixture_catch", &target, error, sizeof error) == GI_EXPORT_FOUND);
    auto caught = reinterpret_cast<int (*)(int, int *)>(target.address + slide);
    int cleaned = 0;
    assert(caught(41, &cleaned) == 42 && cleaned == 2);
    assert(gi_export(&image, "_fixture_throw", &target, error, sizeof error) == GI_EXPORT_FOUND);
    auto thrown = reinterpret_cast<void (*)(int, int *)>(
        gw_wrap("fixture_throw", reinterpret_cast<void *>(target.address + slide)));
    bool handled = false;
    try { thrown(73, &cleaned); }
    catch (int value) { assert(value == 73); handled = true; }
    assert(handled && cleaned == 3);
    assert(gi_export(&image, "_fixture_dwarf", &target, error, sizeof error) == GI_EXPORT_FOUND);
    auto dwarf = reinterpret_cast<void (*)(void (*)())>(target.address + slide);
    handled = false;
    try { dwarf(host_throw); }
    catch (int value) { assert(value == 79); handled = true; }
    assert(handled);
    assert(ng_unwind_reset());
    assert(ng_unwind_reset());
    assert(!munmap(mapping, size));
    gi_destroy(&image);
    gw_reset();
    puts("placed-image C++ exceptions: compact unwind, catches, cleanup and wrapper pass");
}
