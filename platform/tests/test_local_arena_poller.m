#import <Foundation/Foundation.h>
#import "LocalArenaPoller.h"
#include "Control/ArenaControl.h"
#include <assert.h>
#include <unistd.h>
static NSData *reply(NSData *request,TKACOutcome outcome) {
    uint8_t bytes[TKAC_SIZE];assert(tkac_reply(request.bytes,request.length,outcome,bytes,sizeof bytes));
    return [NSData dataWithBytes:bytes length:sizeof bytes];
}
int main(void) {@autoreleasepool {
    for(unsigned mode=0;mode<3;mode++) {
        TKACRequest raw={.pid=(uint32_t)getpid(),.uid=(uint32_t)geteuid(),.address=0x200000,.size=16384,.challenge_address=0x100000,
            .deadline_ms=(uint64_t)(NSProcessInfo.processInfo.systemUptime*1000)+(mode==2?2500:10000)};
        memset(raw.challenge,1,32);memset(raw.identifier,2,16);
        uint8_t bytes[TKAC_SIZE];assert(tkac_encode(&raw,bytes,sizeof bytes));NSData *request=[NSData dataWithBytes:bytes length:sizeof bytes];
        __block unsigned submits=0,polls=0,completions=0;
        dispatch_semaphore_t done=dispatch_semaphore_create(0);
        TKLocalArenaPoller *poller=[[TKLocalArenaPoller alloc] initWithTransport:^BOOL(NSData *data,void (^completion)(NSData *)) {
            uint8_t normalized[TKAC_SIZE];TKACCommand command=0;
            assert(tkac_normalize(data.bytes,data.length,&command,normalized,sizeof normalized));
            assert(!memcmp(normalized,request.bytes,sizeof normalized));
            if(command==TKAC_SUBMIT) {
                submits++;
                if(mode!=0)completion(reply(request,TKAC_PENDING)); // mode 0 loses the submit reply entirely.
            } else {
                polls++;
                if(mode==2)completion(nil); // silent/invalid results never authorize.
                else if(polls==1)completion(reply(request,TKAC_PENDING));
                else completion(reply(request,mode==0?TKAC_PREPARED:TKAC_UNCERTAIN));
            }
            return YES;
        }];
        [poller start:request completion:^(NSData *data) {
            completions++;TKACOutcome outcome=0;
            if(mode==2)assert(!data);
            else assert(tkac_match(request.bytes,request.length,data.bytes,data.length,&outcome) && outcome==(mode==0?TKAC_PREPARED:TKAC_UNCERTAIN));
            dispatch_semaphore_signal(done);
        }];
        assert(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC))==0);
        assert(submits==1 && polls>=2 && completions==1);
        (void)poller;
    }
    puts("PASS: one-shot submission, lost initial reply recovery, pending polling, uncertainty and absolute deadline");
}}
