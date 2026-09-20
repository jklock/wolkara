#pragma once
#include <stdbool.h>
#include <stdint.h>
typedef int (*GWWait)(uint32_t operation, void *address, uint64_t value, uint32_t microseconds);
typedef bool (*GWPending)(void);
typedef void (*GWPump)(void);
// Keep the host responsive only while a shader worker is paused. Other wait
// operations, explicit deadlines, native errors and wakeups retain their ABI.
int gw_wait(GWWait wait, uint32_t operation, void *address, uint64_t value,
            uint32_t microseconds, bool main_thread, GWPending pending, GWPump pump);
