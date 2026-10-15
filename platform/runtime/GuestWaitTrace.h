#pragma once
#include <stdbool.h>
#include <stdint.h>
enum { GWT_THREAD_LIMIT = 256 };
typedef struct { const char *operation; uintptr_t address; } GWWaitRecord;
// Thread identifiers are unique, one-based and assigned by the runtime.
// The operation name must have static lifetime. Nested callbacks restore it.
GWWaitRecord gwt_begin(unsigned thread, const char *operation, const void *address);
void gwt_end(unsigned thread, GWWaitRecord previous);
bool gwt_snapshot(unsigned thread, GWWaitRecord *out);
