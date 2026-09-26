extern "C" {
#include "GuestWrap.h"
}
#include <cassert>
#include <cstdio>

struct Failure { int value; };
static unsigned destroyed;
struct Cleanup { ~Cleanup() { ++destroyed; } };
static void fail(int value) {
    Cleanup cleanup;
    throw Failure{value};
}
static void (*wrapped)(int);
static void nested(int value) {
    Cleanup cleanup;
    try { wrapped(value); }
    catch (const Failure &failure) {
        assert(failure.value == value);
        throw;
    }
}
int main() {
    FILE *log = tmpfile();
    assert(log);
    gw_log(log);
    wrapped = reinterpret_cast<void (*)(int)>(gw_wrap("fail", reinterpret_cast<void *>(fail)));
    auto outer = reinterpret_cast<void (*)(int)>(gw_wrap("nested", reinterpret_cast<void *>(nested)));
    for (int value = 1; value <= 3; ++value) {
        bool caught = false;
        try { outer(value); }
        catch (const Failure &failure) {
            assert(failure.value == value);
            caught = true;
        }
        assert(caught && destroyed == static_cast<unsigned>(value * 2));
    }
    gw_reset();
    gw_log(nullptr);
    fclose(log);
    puts("wrapped C++ exceptions: catch, rethrow and cleanup pass");
}
