#include <stdexcept>
#include <cstring>

struct Cleanup {
    int *count;
    ~Cleanup() { ++*count; }
};
extern "C" __attribute__((noinline)) void fixture_throw(int value, int *cleaned) {
    Cleanup cleanup{cleaned};
    throw value;
}
extern "C" __attribute__((noinline)) int fixture_catch(int value, int *cleaned) {
    Cleanup cleanup{cleaned};
    try { fixture_throw(value, cleaned); }
    catch (int caught) { return caught + 1; }
    return -1;
}

// Original polymorphic exception: its type information and vtable live in
// this placed image, while its standard-library base lives in a host image.
class FixtureError : public std::runtime_error {
public:
    FixtureError() : std::runtime_error("placed exception") {}
};
extern "C" __attribute__((noinline)) void fixture_throw_class(int *cleaned) {
    Cleanup cleanup{cleaned};
    throw FixtureError();
}
extern "C" void fixture_dwarf(void (*)());
extern "C" __attribute__((noinline)) bool fixture_catch_host(void (*callback)(), int *cleaned) {
    Cleanup cleanup{cleaned};
    try { fixture_dwarf(callback); }
    catch (const std::exception &error) { return !std::strcmp(error.what(), "host exception"); }
    return false;
}
