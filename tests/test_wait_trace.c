#include "GuestWaitTrace.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
static const char first[]="first",second[]="second";
static atomic_bool finished;
static void *writer(void *unused) {
    (void)unused;
    for(unsigned i=0;i<100000;i++) {
        GWWaitRecord outer=gwt_begin(2,first,first);
        GWWaitRecord inner=gwt_begin(2,second,second);
        gwt_end(2,inner);gwt_end(2,outer);
    }
    atomic_store(&finished,true);return NULL;
}
int main(void) {
    GWWaitRecord record={0},outer=gwt_begin(1,first,first);
    assert(gwt_snapshot(1,&record) && record.operation==first && record.address==(uintptr_t)first);
    GWWaitRecord inner=gwt_begin(1,second,second);
    assert(gwt_snapshot(1,&record) && record.operation==second);
    gwt_end(1,inner);
    assert(gwt_snapshot(1,&record) && record.operation==first);
    gwt_end(1,outer);assert(!gwt_snapshot(1,&record));
    assert(!gwt_snapshot(0,&record) && !gwt_snapshot(GWT_THREAD_LIMIT+1,&record));
    assert(!gwt_snapshot(1,NULL));
    gwt_end(0,gwt_begin(0,first,first));
    gwt_end(GWT_THREAD_LIMIT+1,gwt_begin(GWT_THREAD_LIMIT+1,first,first));
    pthread_t thread;assert(!pthread_create(&thread,NULL,writer,NULL));
    while(!atomic_load(&finished)) if(gwt_snapshot(2,&record))
        assert((record.operation==first || record.operation==second) && record.address==(uintptr_t)record.operation);
    assert(!pthread_join(thread,NULL) && !gwt_snapshot(2,&record));
    puts("PASS: wait telemetry nesting, bounds and consistent concurrent snapshots");
}
