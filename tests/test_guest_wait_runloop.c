#include "GuestWait.h"
#include <CoreFoundation/CoreFoundation.h>
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <unistd.h>
extern int __ulock_wait(uint32_t,void *,uint64_t,uint32_t);
extern int __ulock_wake(uint32_t,void *,uint64_t);
static atomic_uint completed;
static atomic_bool active;
static unsigned timer_calls;
static bool pending(void) { return atomic_load(&active); }
static void pump(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode,.001,true); }
static void complete(CFRunLoopTimerRef timer,void *info) {
    (void)timer;(void)info;
    timer_calls++;
    atomic_store(&completed,1);
    __ulock_wake(1,&completed,0);
}
static void *worker(void *unused) {
    (void)unused;usleep(100000);atomic_store(&active,true);return NULL;
}
int main(void) {
    // A real kernel wait starts before the worker announces a missing shader.
    // Only servicing the main run loop can finish the synthetic job. Alarm
    // makes a regression fail rather than hanging the test runner indefinitely.
    alarm(5);
    CFRunLoopTimerRef timer=CFRunLoopTimerCreate(NULL,CFAbsoluteTimeGetCurrent()+.25,0,0,0,complete,NULL);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(),timer,kCFRunLoopDefaultMode);
    pthread_t thread;assert(!pthread_create(&thread,NULL,worker,NULL));
    (void)gw_wait(__ulock_wait,1,&completed,0,0,true,pending,pump);
    assert(timer_calls==1 && atomic_load(&completed)==1);
    assert(!pthread_join(thread,NULL));
    CFRunLoopTimerInvalidate(timer);CFRelease(timer);alarm(0);
    puts("PASS: real kernel job wait remains responsive to main-run-loop work during shader pause");
}
