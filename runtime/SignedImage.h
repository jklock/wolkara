#pragma once
#include "GuestImage.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Local signing page container contract. The container is a signed arm64
// Mach-O whose __TEXT segment holds one 16 KiB aligned section with the
// guest's final (post-unpack) __TEXT pages. Both exported markers
// tolkara_container_v1 and tolkara_container_final sit at the start of that
// section. Pure checks over mapped bytes: no dyld, no mapping, no guest code.
typedef struct {
    const unsigned char *bytes; // container's copy of the guest __TEXT, page aligned
    uint64_t size;              // bytes of that section, a whole number of pages
} SIImage;

// header is the container's mach header as mapped (dladdr's dli_fbase); v1 and
// final are the two marker addresses (0 when a marker is missing). Load
// commands must fit in the first 16 KiB page.
bool si_locate_image(const void *header, uintptr_t v1, uintptr_t final, SIImage *image,
                     char *error, size_t error_size);
// Binds the container to this guest before any of its code runs: the guest's
// only executable segment is __TEXT at its header address, its vmsize equals
// the image size, and the image starts with the guest's own header and load
// commands (LC_UUID and segment layout) exactly as staged from the executable.
bool si_match_guest(const SIImage *image, const GuestImage *guest, char *error, size_t error_size);
// Call after si_match_guest. The rewritten range [0, *shadow_size) ends after
// the last __TEXT page whose staged original bytes (zeros when demand-zero or
// unstaged) differ from the image; every later page is identical. The first
// initializer, which rebuilds that range, must lie in [*shadow_size, size).
bool si_shadow_size(const SIImage *image, const GuestImage *guest, uint64_t *shadow_size,
                    char *error, size_t error_size);
// Number of differing bytes; *first receives the first differing offset, or
// size when the ranges are identical.
size_t si_count_mismatches(const void *a, const void *b, size_t size, size_t *first);
