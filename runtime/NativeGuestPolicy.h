#pragma once
// Two small launch decisions of NativeGuest, kept apart so they can be tested
// on the Mac without a device or a debugger.
#include <stdbool.h>
#include <stddef.h>

// An import nothing provides becomes a logged stub only where no build-time
// analysis covered it: in a generic build (no library map), or for a carried
// library's imports, which classify.py never reads. A build made for one
// executable already stubs that executable's gaps; anything else fails.
static inline bool ng_may_stub(bool generic_build, bool carried_image, bool weak) {
    return !weak && (generic_build || carried_image);
}

// What happens to an arena an enabler provided before the launch.
typedef enum {
    NG_RESERVED_NONE,        // nothing was reserved
    NG_RESERVED_TAKE,        // External JIT, and the image fits
    NG_RESERVED_REFUSE,      // External JIT, too small: it cannot grow and nothing is attached to ask again
    NG_RESERVED_GIVE_BACK,   // another route runs this launch
} NGReservedChoice;
static inline NGReservedChoice ng_reserved_choice(bool external, bool reserved, size_t total, size_t reserved_size) {
    if (!reserved) return NG_RESERVED_NONE;
    if (!external) return NG_RESERVED_GIVE_BACK;
    return total <= reserved_size ? NG_RESERVED_TAKE : NG_RESERVED_REFUSE;
}
