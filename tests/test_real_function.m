// AKRealFunction (translation/Metal/RealFunction.h): an adapter that defines
// MTLCreateSystemDefaultDevice beside the Metal it re-exports forwards to
// Metal's own function, never to itself. Built twice: with -DAK_FIXTURE_LIBRARY
// as such an adapter (a dylib re-exporting Metal), and as the host that loads it
// after Metal, as the app does.
#import <Metal/Metal.h>
#import "RealFunction.h"
#include <assert.h>
#include <stdio.h>

typedef id<MTLDevice> (*DeviceFactory)(void) __attribute__((ns_returns_retained));

#ifdef AK_FIXTURE_LIBRARY
static unsigned calls;
unsigned AKFixtureCalls(void) { return calls; }
void *AKFixtureLookup(const char *name, const char *library, void *wrapper) {
    return AKRealFunction(name, library, wrapper);
}
id<MTLDevice> MTLCreateSystemDefaultDevice(void) {
    static DeviceFactory real; static dispatch_once_t once;
    dispatch_once(&once, ^{
        real = (DeviceFactory)AKRealFunction("MTLCreateSystemDefaultDevice", AK_METAL_PATH, (void *)MTLCreateSystemDefaultDevice);
    });
    calls++;
    return real ? real() : nil;
}
#else
int main(int argc, char **argv) { @autoreleasepool {
    assert(argc == 2);
    const char *fixture = argv[1];
    void *adapter = dlopen(fixture, RTLD_NOW | RTLD_GLOBAL);
    if (!adapter) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    DeviceFactory wrapper = (DeviceFactory)dlsym(adapter, "MTLCreateSystemDefaultDevice");
    void *(*lookup)(const char *, const char *, void *) = dlsym(adapter, "AKFixtureLookup");
    unsigned (*count)(void) = dlsym(adapter, "AKFixtureCalls");
    assert(wrapper && lookup && count);
    // The adapter's handle answers with its own definition, as the runtime binds it.
    void *metal = (void *)MTLCreateSystemDefaultDevice;
    assert((void *)wrapper != metal);
    // From inside the adapter: Metal's function, found after the adapter.
    assert(lookup("MTLCreateSystemDefaultDevice", AK_METAL_PATH, (void *)wrapper) == metal);
    // Nothing after the adapter has it: the named, already loaded library answers.
    assert(lookup("AKFixtureCalls", fixture, NULL) == (void *)count);
    // Never the wrapper, even when the named library's answer is the wrapper.
    assert(lookup("AKFixtureCalls", fixture, (void *)count) == NULL);
    assert(lookup("AKNoSuchFunction", AK_METAL_PATH, NULL) == NULL);
    assert(lookup("MTLCreateSystemDefaultDevice", "/nonexistent/Unloaded.dylib", (void *)wrapper) == metal);
    // The wrapper forwards to Metal: the same device, or none on a Mac without a GPU.
    id<MTLDevice> direct = MTLCreateSystemDefaultDevice(), wrapped = wrapper();
    assert(count() == 1);
    assert((direct == nil) == (wrapped == nil));
    assert(!direct || direct.registryID == wrapped.registryID);
    puts("adapter wrappers find the system function loaded before them, never themselves: PASS");
} return 0; }
#endif
