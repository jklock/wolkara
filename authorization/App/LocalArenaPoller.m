#import "LocalArenaPoller.h"
#include "Control/ArenaControl.h"

@implementation TKLocalArenaPoller {
    TKArenaTransport _transport;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    NSData *_request;
    void (^_completion)(NSData *);
    BOOL _started,_finished,_inflight;
    uint64_t _generation,_deadline;
    NSTimeInterval _sentAt;
}
- (instancetype)initWithTransport:(TKArenaTransport)transport {
    if((self=[super init])) {_transport=[transport copy];_queue=dispatch_queue_create("local.tolkara.arena-poll",DISPATCH_QUEUE_SERIAL);}
    return self;
}
- (void)finish:(NSData *)reply {
    if(_finished)return;_finished=YES;
    if(_timer)dispatch_source_cancel(_timer);_timer=nil;
    void (^completion)(NSData *)=_completion;_completion=nil;
    completion(reply);
}
- (void)send:(TKACCommand)command {
    uint8_t bytes[TKAC_SIZE];
    if(!tkac_command(_request.bytes,_request.length,command,bytes,sizeof bytes)){[self finish:nil];return;}
    _inflight=YES;_sentAt=NSProcessInfo.processInfo.systemUptime;
    uint64_t generation=++_generation;
    BOOL sent=_transport([NSData dataWithBytes:bytes length:sizeof bytes],^(NSData *reply) {
        dispatch_async(self->_queue,^{
            if(self->_finished || generation!=self->_generation)return;
            self->_inflight=NO;
            TKACOutcome outcome=TKAC_UNCERTAIN;
            if(!tkac_match(self->_request.bytes,self->_request.length,reply.bytes,reply.length,&outcome))return;
            if(outcome!=TKAC_PENDING)[self finish:reply];
        });
    });
    if(!sent)_inflight=NO; // Submission is never repeated, even on ambiguous loss.
}
- (void)start:(NSData *)request completion:(void (^)(NSData *))completion {
    dispatch_async(_queue,^{
        TKACRequest raw;
        if(self->_started || !self->_transport || !tkac_decode(request.bytes,request.length,&raw) || raw.deadline_ms<=NSProcessInfo.processInfo.systemUptime*1000){completion(nil);return;}
        self->_started=YES;self->_request=[request copy];self->_completion=[completion copy];self->_deadline=raw.deadline_ms;
        self->_timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,self->_queue);
        dispatch_source_set_timer(self->_timer,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),NSEC_PER_SEC,10*NSEC_PER_MSEC);
        dispatch_source_set_event_handler(self->_timer,^{
            NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
            if(now*1000>=self->_deadline){[self finish:nil];return;}
            // The whole host can be paused for minutes. Once it resumes, an
            // expired message is replaced by a status query, never a new submit.
            if(!self->_inflight || now-self->_sentAt>=5)[self send:TKAC_POLL];
        });
        dispatch_resume(self->_timer);
        [self send:TKAC_SUBMIT];
    });
}
- (void)dealloc {if(_timer)dispatch_source_cancel(_timer);}
@end
