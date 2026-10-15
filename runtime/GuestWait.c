#include "GuestWait.h"
#include <errno.h>
int gw_wait(GWWait wait, uint32_t operation, void *address, uint64_t value,
            uint32_t microseconds, bool main_thread, GWPending pending, GWPump pump) {
    // UL_COMPARE_AND_WAIT without flags is the client's job-completion wait.
    // Do not pump while owning an unfair lock or change finite timeout semantics.
    if (!main_thread || operation != 1 || microseconds || !pending || !pump)
        return wait(operation, address, value, microseconds);
    int original_errno = errno;
    for (;;) {
        errno = original_errno;
        int result = wait(operation, address, value, 10000);
        int native_errno = errno;
        if (result != -1 || native_errno != ETIMEDOUT) {
            errno = native_errno;
            return result;
        }
        if (pending()) pump();
    }
}
