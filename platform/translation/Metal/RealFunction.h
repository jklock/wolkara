// The system function behind an adapter's wrapper of the same name, kept apart
// from UIKit so it can be tested on the Mac. The adapter re-exports the real
// library, so dyld finds it among the images after the adapter (RTLD_NEXT);
// failing that, the already loaded library by path. Never the wrapper itself,
// which would call itself forever.
#pragma once
#include <dlfcn.h>
#include <stddef.h>

#define AK_METAL_PATH "/System/Library/Frameworks/Metal.framework/Metal"

static inline void *AKRealFunction(const char *name, const char *library, void *wrapper) {
    void *function = dlsym(RTLD_NEXT, name);
    if (!function || function == wrapper) {
        void *handle = dlopen(library, RTLD_LAZY | RTLD_NOLOAD);
        function = handle ? dlsym(handle, name) : NULL;
        if (handle) dlclose(handle);   // only the reference taken here; the library stays loaded
    }
    return function == wrapper ? NULL : function;
}
