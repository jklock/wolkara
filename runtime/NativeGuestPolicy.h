#pragma once
// Small launch decisions of NativeGuest, kept apart so they can be tested
// on the Mac without a device or a debugger.
#include <stdbool.h>
#include <stddef.h>

// An import nothing provides becomes a logged stub only where no build-time
// analysis covered it: in a generic build (no library map), or for a carried
// library's imports, which a build covers only for the libraries classify.py
// read from the application's Contents/Frameworks. A build made for one
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

// A profile's environment names memory made at launch by a placeholder
// (${CodePool}): value with each occurrence replaced. False when there is
// none, or when the result does not fit in size (out is then empty).
static inline bool ng_expand(const char *value, const char *placeholder, const char *replacement,
                             char *out, size_t size) {
    size_t used = 0, placeholder_length = 0, replacement_length = 0;
    bool found = false;
    while (placeholder[placeholder_length]) placeholder_length++;
    while (replacement[replacement_length]) replacement_length++;
    if (!size || !placeholder_length) return false;
    for (const char *at = value; *at;) {
        bool match = true;
        for (size_t i = 0; i < placeholder_length && match; i++) match = at[i] == placeholder[i];
        const char *piece = match ? replacement : at;
        size_t length = match ? replacement_length : 1;
        if (used + length >= size) { out[0] = 0; return false; }
        for (size_t i = 0; i < length; i++) out[used++] = piece[i];
        at += match ? placeholder_length : 1;
        found |= match;
    }
    out[used] = 0;
    return found;
}
