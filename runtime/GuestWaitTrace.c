#include "GuestWaitTrace.h"
#include <stdatomic.h>
typedef struct {
    atomic_uint sequence;
    _Atomic(const char *) operation;
    atomic_uintptr_t address;
} Slot;
static Slot slots[GWT_THREAD_LIMIT];
static void publish(Slot *slot, GWWaitRecord record) {
    atomic_fetch_add(&slot->sequence,1);
    atomic_store(&slot->operation,record.operation);
    atomic_store(&slot->address,record.address);
    atomic_fetch_add(&slot->sequence,1);
}
GWWaitRecord gwt_begin(unsigned thread, const char *operation, const void *address) {
    if(!thread || thread>GWT_THREAD_LIMIT) return (GWWaitRecord){0};
    Slot *slot=&slots[thread-1];
    GWWaitRecord old={atomic_load(&slot->operation),atomic_load(&slot->address)};
    publish(slot,(GWWaitRecord){operation,(uintptr_t)address});
    return old;
}
void gwt_end(unsigned thread, GWWaitRecord previous) {
    if(thread && thread<=GWT_THREAD_LIMIT) publish(&slots[thread-1],previous);
}
bool gwt_snapshot(unsigned thread, GWWaitRecord *out) {
    if(!out || !thread || thread>GWT_THREAD_LIMIT) return false;
    Slot *slot=&slots[thread-1]; unsigned before=atomic_load(&slot->sequence);
    if(before&1) return false;
    GWWaitRecord record={atomic_load(&slot->operation),atomic_load(&slot->address)};
    if(before!=atomic_load(&slot->sequence) || !record.operation) return false;
    *out=record; return true;
}
