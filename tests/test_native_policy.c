#include "NativeGuestPolicy.h"
#include <assert.h>
#include <string.h>
#include <stdio.h>

int main(void) {
    // A build made for one executable never stubs that executable's imports.
    assert(!ng_may_stub(false, false, false));
    // A generic build does, and a carried library's imports are stubbed in any build.
    assert(ng_may_stub(true, false, false));
    assert(ng_may_stub(false, true, false));
    assert(ng_may_stub(true, true, false));
    // A weak import that nothing provides stays null.
    for (unsigned i = 0; i < 4; i++) assert(!ng_may_stub(i & 1, i & 2, true));

    // Nothing reserved: nothing to decide.
    assert(ng_reserved_choice(true, false, 1, 0) == NG_RESERVED_NONE);
    assert(ng_reserved_choice(false, false, 1, 0) == NG_RESERVED_NONE);
    // External JIT takes a reservation the image fits in, up to its last byte.
    assert(ng_reserved_choice(true, true, 4096, 8192) == NG_RESERVED_TAKE);
    assert(ng_reserved_choice(true, true, 8192, 8192) == NG_RESERVED_TAKE);
    // Too small: refused, not replaced by a region nothing prepared.
    assert(ng_reserved_choice(true, true, 8193, 8192) == NG_RESERVED_REFUSE);
    // Another route gives it back, whatever its size.
    assert(ng_reserved_choice(false, true, 4096, 8192) == NG_RESERVED_GIVE_BACK);
    assert(ng_reserved_choice(false, true, 16384, 8192) == NG_RESERVED_GIVE_BACK);

    // A placeholder in a profile's environment, replaced wherever it occurs.
    char out[64];
    assert(ng_expand("${CodePool}", "${CodePool}", "0x1-0x2@0x3", out, sizeof out) && !strcmp(out, "0x1-0x2@0x3"));
    assert(ng_expand("a=${CodePool};b=${CodePool}", "${CodePool}", "x", out, sizeof out) && !strcmp(out, "a=x;b=x"));
    assert(!ng_expand("${Documents}/x", "${CodePool}", "x", out, sizeof out) && !strcmp(out, "${Documents}/x"));
    assert(!ng_expand("${CodePool}", "${CodePool}", "0123456789", out, 8) && !out[0]);
    assert(!ng_expand("${CodePo", "${CodePool}", "x", out, sizeof out) && !strcmp(out, "${CodePo"));
    assert(!ng_expand("", "${CodePool}", "x", out, sizeof out) && !out[0]);
    puts("PASS: runtime stubs only where no build-time analysis covered an import; reserved arena taken, refused or given back;"
         " environment placeholders expanded");
}
