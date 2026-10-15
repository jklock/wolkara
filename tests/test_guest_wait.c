#include "GuestWait.h"
#include <assert.h>
#include <errno.h>
#include <stdio.h>
static unsigned calls, pumps, expected_timeout;
static bool active;
static int last_result, last_errno;
static int native_wait(uint32_t op, void *address, uint64_t value, uint32_t timeout) {
    (void)op;
    assert(address == &active && value == 0x123456789ULL && timeout == expected_timeout);
    if (++calls < 3) { errno = ETIMEDOUT; active = calls == 2; return -1; }
    errno = last_errno; return last_result;
}
static bool pending(void) { return active; }
static void pump(void) { pumps++; errno = EINVAL; }
int main(void) {
    for (unsigned i = 0; i < 3; i++) {
        calls = pumps = 0; active = false; expected_timeout = 10000;
        last_result = i == 0 ? 0 : -1;
        last_errno = i == 1 ? EINTR : i == 2 ? EFAULT : 0;
        assert(gw_wait(native_wait, 1, &active, 0x123456789ULL, 0, true, pending, pump) == last_result);
        assert(calls == 3 && pumps == 1 && errno == last_errno);
    }
    for (unsigned i = 0; i < 4; i++) {
        calls = pumps = 0; expected_timeout = i == 0 ? 1234 : 0;
        assert(gw_wait(native_wait, i == 1 ? 2 : 1, &active, 0x123456789ULL,
            expected_timeout, i != 2, i == 3 ? NULL : pending, pump) == -1);
        assert(calls == 1 && pumps == 0 && errno == ETIMEDOUT);
    }
    puts("PASS: shader-pause wait pump, delayed pending state, native wake/error and finite-timeout preservation");
}
