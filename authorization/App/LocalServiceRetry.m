#import "LocalServiceRetry.h"
#include <math.h>

@implementation TKLocalServiceRetry {
    NSTimeInterval _timeout, _interval;
    void (^_attempt)(TKLocalServiceReply);
    void (^_waiting)(void);
    void (^_completion)(BOOL, NSString *);
    dispatch_source_t _timer;
    NSUInteger _generation;
    BOOL _started, _finished, _pending, _notified;
}
- (instancetype)initWithTimeout:(NSTimeInterval)timeout interval:(NSTimeInterval)interval
                        attempt:(void (^)(TKLocalServiceReply))attempt {
    if (!(self=[super init])) return nil;
    if (!isfinite(timeout) || !isfinite(interval) || timeout<=0 || timeout>120 || interval<=0 || interval>timeout || !attempt) return nil;
    _timeout=timeout; _interval=interval; _attempt=[attempt copy];
    return self;
}
- (void)finish:(BOOL)ready report:(NSString *)report {
    if (_finished) return;
    _finished=YES; _pending=NO; _generation++;
    if (_timer) { dispatch_source_cancel(_timer); _timer=nil; }
    void (^completion)(BOOL, NSString *)=_completion;
    _completion=nil; _waiting=nil; _attempt=nil;
    if (completion) completion(ready,report);
}
- (void)startWithWaiting:(void (^)(void))waiting completion:(void (^)(BOOL, NSString *))completion {
    NSAssert(NSThread.isMainThread, @"Main thread only");
    if (_started || _finished) return;
    _started=YES; _waiting=[waiting copy]; _completion=[completion copy];
    __weak TKLocalServiceRetry *weakSelf=self;
    _timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(_timer,dispatch_time(DISPATCH_TIME_NOW,(int64_t)(_timeout*NSEC_PER_SEC)),DISPATCH_TIME_FOREVER,0);
    dispatch_source_set_event_handler(_timer,^{
        [weakSelf finish:NO report:@"Local service remains unavailable. If you disabled mobile data, turn it back on. No memory preparation was started."];
    });
    dispatch_resume(_timer);
    [self attempt];
}
- (void)attempt {
    if (_finished || _pending) return;
    _pending=YES;
    NSUInteger generation=++_generation;
    __weak TKLocalServiceRetry *weakSelf=self;
    _attempt(^(TKLocalServiceResult result, NSString *report) {
        dispatch_async(dispatch_get_main_queue(),^{
            TKLocalServiceRetry *self=weakSelf;
            if (!self || self->_finished || !self->_pending || self->_generation!=generation) return;
            self->_pending=NO;
            if (result!=TKLocalServiceUnavailable) { [self finish:result==TKLocalServiceReady report:report]; return; }
            if (!self->_notified) { self->_notified=YES; if (self->_waiting) self->_waiting(); }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(self->_interval*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
                TKLocalServiceRetry *self=weakSelf;
                if (self && !self->_finished && self->_generation==generation) [self attempt];
            });
        });
    });
}
- (void)cancel {
    NSAssert(NSThread.isMainThread, @"Main thread only");
    [self finish:NO report:@"Local service connection cancelled. No memory preparation was started."];
}
- (void)dealloc { if (_timer) dispatch_source_cancel(_timer); }
@end
