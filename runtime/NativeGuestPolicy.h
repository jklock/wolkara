#pragma once
// Small launch decisions of NativeGuest, kept apart so they can be tested
// on the Mac without a device or a debugger.
#include <stdbool.h>
#include <stddef.h>
#include <string.h>

// Optional CPU topology limit for the software-memory performance experiment.
// Apply only to a successful native integer result; never increase capacity.
static inline bool ng_limit_cpu_answer(const char *name,void *answer,size_t size,unsigned limit) {
    if(!limit || !name || !answer || size!=sizeof(int)) return false;
    const char *queries[]={"hw.ncpu","hw.activecpu","hw.logicalcpu","hw.logicalcpu_max",
        "hw.physicalcpu","hw.physicalcpu_max"};
    bool selected=false;
    for(size_t i=0;i<sizeof queries/sizeof *queries;i++) if(!strcmp(name,queries[i])) selected=true;
    if(!selected)return false;
    int count;memcpy(&count,answer,sizeof count);
    if(count<=0 || (unsigned)count<=limit)return false;
    count=(int)limit;memcpy(answer,&count,sizeof count);return true;
}

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
