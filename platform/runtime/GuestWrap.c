#include "GuestWrap.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

// Slot n begins at eight times n, its index below.
extern char gw_slot_table[];

static struct {
    char *name;
    void *target;
    atomic_ulong calls;
} slots[GW_SLOTS];
static unsigned used;
static FILE *wrap_log;
// A chatty function (a per-frame update) must not drown the one that
// crashes; each name logs its first calls and then falls silent.
#define GW_LOGGED 64

static FILE *log_file(void) { return wrap_log ? wrap_log : stderr; }
// Trace lines carry a small per-thread number, like the runtime's own.
static unsigned gw_tid(void) {
    static _Thread_local unsigned mine;
    static atomic_uint handed_out;
    if (!mine) mine = atomic_fetch_add(&handed_out, 1) + 1;
    return mine;
}

void *gw_wrap(const char *name, void *target) {
    if (!name || !target) return target;
    for (unsigned i = 0; i < used; i++)
        if (slots[i].target == target && !strcmp(slots[i].name, name))
            return gw_slot_table + (size_t)i * 8;
    if (used == GW_SLOTS) return target;
    unsigned slot = used;
    char *owned = strdup(name);
    if (!owned) return target;
    slots[slot].name = owned;
    slots[slot].target = target;
    atomic_store(&slots[slot].calls, 0);
    used++;
    return gw_slot_table + (size_t)slot * 8;
}

void *gw_enter(unsigned slot, const unsigned long *frame) {
    if (slot >= GW_SLOTS || !slots[slot].target) return NULL;
    unsigned long call = atomic_fetch_add(&slots[slot].calls, 1) + 1;
    if (call <= GW_LOGGED) {
        fprintf(log_file(), "[wrap] %s #%lu [t%u] enter caller=%p args=(%p, %p, %p, %p)\n",
                slots[slot].name, call, gw_tid(), (void *)frame[9],
                (void *)frame[0], (void *)frame[1], (void *)frame[2], (void *)frame[3]);
        fflush(log_file());
    }
    return slots[slot].target;
}

void gw_returned(unsigned slot, void *result) {
    if (slot >= GW_SLOTS || !slots[slot].target) return;
    unsigned long call = atomic_load(&slots[slot].calls);
    if (call <= GW_LOGGED) {
        fprintf(log_file(), "[wrap] %s #%lu [t%u] leave = %p\n", slots[slot].name, call, gw_tid(), result);
        fflush(log_file());
    }
}

unsigned gw_used(void) { return used; }
void gw_log(FILE *log) { wrap_log = log; }
void gw_reset(void) {
    for (unsigned i = 0; i < used; i++) { free(slots[i].name); slots[i].name = NULL; slots[i].target = NULL; }
    used = 0;
}
