// macOS stand-in for the Local signing load path: load the original
// executable as data, dlopen its signed page container, apply the runtime's
// own container checks (runtime/SignedImage.c), vm_remap the validated pages
// and call the exported probe leaf in the remapped copy.
// usage: signed_container_host <executable> <container>   (prints probe=0x...)
#include "GuestImage.h"
#include "SignedImage.h"
#include <dlfcn.h>
#include <mach/mach.h>
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 3) { fprintf(stderr, "usage: signed_container_host <executable> <container>\n"); return 2; }
    GuestImage guest = {0}; char error[1024];
    if (!gi_load(argv[1], &guest, error, sizeof error)) { printf("load: %s\n", error); return 3; }
    void *handle = dlopen(argv[2], RTLD_NOW | RTLD_LOCAL);
    if (!handle) { printf("dlopen: %s\n", dlerror()); return 4; }
    uintptr_t v1 = (uintptr_t)dlsym(handle, "tolkara_container_v1"), final = (uintptr_t)dlsym(handle, "tolkara_container_final");
    uintptr_t probe = (uintptr_t)dlsym(handle, "guest_test");
    Dl_info info = {0};
    if (!v1 || !dladdr((void *)v1, &info)) { printf("markers missing\n"); return 5; }
    SIImage image; uint64_t shadow = 0;
    if (!si_locate_image(info.dli_fbase, v1, final, &image, error, sizeof error)) { printf("locate: %s\n", error); return 6; }
    if (!si_match_guest(&image, &guest, error, sizeof error)) { printf("match: %s\n", error); return 7; }
    if (!si_shadow_size(&image, &guest, &shadow, error, sizeof error)) { printf("shadow: %s\n", error); return 8; }
    vm_address_t target = 0; vm_prot_t current = 0, maximum = 0;
    kern_return_t result = vm_remap(mach_task_self(), &target, (vm_size_t)image.size, 0, VM_FLAGS_ANYWHERE, mach_task_self(),
                                    (vm_address_t)image.bytes, false, &current, &maximum, VM_INHERIT_NONE);
    if (result != KERN_SUCCESS || !(current & VM_PROT_EXECUTE) || (current & VM_PROT_WRITE)) {
        printf("remap failed kr=%d protection=%d\n", result, current); return 9;
    }
    printf("matched: %llu pages, shadow %llu pages\n", (unsigned long long)(image.size / GM_PAGE_SIZE),
           (unsigned long long)(shadow / GM_PAGE_SIZE));
    if (probe) {
        int (*leaf)(void) = (int (*)(void))(target + (probe - v1));
        printf("probe=0x%08x\n", (unsigned)leaf());
    }
    gi_destroy(&guest);
    return 0;
}
