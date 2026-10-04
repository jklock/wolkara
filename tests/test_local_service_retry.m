#import "LocalServiceRetry.h"
#include <assert.h>

static void pumpUntil(BOOL (^done)(void)) {
    NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:2];
    while(!done() && limit.timeIntervalSinceNow>0)
        [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
    assert(done());
}
static void settle(void) {
    NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:0.06];
    while(limit.timeIntervalSinceNow>0) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
int main(void) { @autoreleasepool {
    // Unavailable twice, then ready. Duplicated/stale replies cannot start a
    // second attempt or finish the new one, even when delivered off-main.
    __block NSUInteger attempts=0, waiting=0, completed=0;
    __block TKLocalServiceReply stale;
    TKLocalServiceRetry *retry=[[TKLocalServiceRetry alloc] initWithTimeout:1 interval:0.01 attempt:^(TKLocalServiceReply reply) {
        attempts++;
        if(attempts==1) { stale=[reply copy]; reply(TKLocalServiceUnavailable,@"offline"); reply(TKLocalServiceReady,@"duplicate"); }
        else if(attempts==2) { stale(TKLocalServiceReady,@"late"); reply(TKLocalServiceUnavailable,@"still offline"); }
        else dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{ reply(TKLocalServiceReady,@"ready"); });
    }];
    [retry startWithWaiting:^{waiting++;} completion:^(BOOL ready,NSString *report) {
        assert(ready && [report isEqual:@"ready"] && NSThread.isMainThread); completed++;
    }];
    pumpUntil(^BOOL{return completed>0;});
    [retry cancel]; stale(TKLocalServiceUnavailable,@"late"); settle();
    assert(attempts==3 && waiting==1 && completed==1);

    // Authentication/protocol failure is terminal, not a network retry.
    attempts=waiting=completed=0;
    retry=[[TKLocalServiceRetry alloc] initWithTimeout:1 interval:0.01 attempt:^(TKLocalServiceReply reply) {
        attempts++; reply(TKLocalServiceFailed,@"proof rejected");
    }];
    [retry startWithWaiting:^{waiting++;} completion:^(BOOL ready,NSString *report) {
        assert(!ready && [report isEqual:@"proof rejected"]); completed++;
    }];
    pumpUntil(^BOOL{return completed>0;}); settle();
    assert(attempts==1 && waiting==0 && completed==1);

    // Missing callbacks expire; no concurrent request is started. Late success
    // after timeout or cancellation never grants readiness.
    for(unsigned cancel=0;cancel<2;cancel++) {
        attempts=completed=0;
        retry=[[TKLocalServiceRetry alloc] initWithTimeout:0.04 interval:0.01 attempt:^(TKLocalServiceReply reply) {
            attempts++; stale=[reply copy];
        }];
        [retry startWithWaiting:nil completion:^(BOOL ready,NSString *report) {
            assert(!ready && report.length); completed++;
        }];
        if(cancel) [retry cancel];
        pumpUntil(^BOOL{return completed>0;}); stale(TKLocalServiceReady,@"late"); settle();
        assert(attempts==1 && completed==1);
    }
    // Cancelling while a retry is scheduled also prevents that attempt.
    attempts=completed=waiting=0;
    retry=[[TKLocalServiceRetry alloc] initWithTimeout:1 interval:0.03 attempt:^(TKLocalServiceReply reply) {
        attempts++; reply(TKLocalServiceUnavailable,@"offline");
    }];
    [retry startWithWaiting:^{waiting++;} completion:^(BOOL ready,NSString *report) {
        (void)report; assert(!ready); completed++;
    }];
    pumpUntil(^BOOL{return waiting>0;}); [retry cancel]; settle();
    assert(attempts==1 && completed==1);
    assert(![[TKLocalServiceRetry alloc] initWithTimeout:0 interval:1 attempt:^(TKLocalServiceReply r){(void)r;}]);
    puts("PASS: local service recovery, sequential retries, terminal proof failure, deadlines, cancellation and stale callbacks");
} }
