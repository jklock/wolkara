#import "ShaderPauseProbe.h"
#import "GuestWait.h"
#import <Metal/Metal.h>
#include <dlfcn.h>
#include <stdatomic.h>
extern int __ulock_wait(uint32_t,void *,uint64_t,uint32_t);
extern int __ulock_wake(uint32_t,void *,uint64_t);
static bool (*pending)(void);
static void pump(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode,.001,true); }
typedef struct { FILE *log; unsigned ticks; } Probe;
static void tick(CFRunLoopTimerRef timer,void *context) {
    (void)timer; Probe *probe=context;
    if(pending && pending()) {
        probe->ticks++;
        if(probe->ticks%10==0) { fprintf(probe->log,"[shader-probe] responsive ticks=%u\n",probe->ticks);fflush(probe->log); }
    }
}
BOOL HostShaderPauseProbe(NSString *frameworks,FILE *log) {
    void *library=dlopen([frameworks stringByAppendingPathComponent:@"akMetal.dylib"].fileSystemRepresentation,RTLD_NOW|RTLD_GLOBAL);
    NSArray *(*enumerate)(id __strong *,void (^)(id,NSString *))=library?dlsym(library,"MTLCopyAllDevicesWithObserver"):NULL;
    pending=library?dlsym(library,"AKShaderWaitPending"):NULL;
    NSData *bytes=[NSData dataWithContentsOfFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/shader-pause-probe.metallib"]];
    if(!enumerate || !pending || !bytes) { fprintf(log,"[shader-probe] missing adapter or synthetic shader\n");return NO; }
    id<MTLDevice> device=[enumerate(NULL,nil) firstObject];
    if(!device)return NO;
    dispatch_data_t input=dispatch_data_create(bytes.bytes,bytes.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    __block atomic_uint completed=0;
    __block BOOL loaded=NO;
    Probe probe={.log=log};CFRunLoopTimerContext context={.info=&probe};
    CFRunLoopTimerRef timer=CFRunLoopTimerCreate(NULL,CFAbsoluteTimeGetCurrent()+1,1,0,0,tick,&context);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(),timer,kCFRunLoopDefaultMode);
    fprintf(log,"[shader-probe] waiting for synthetic shader, no game code executed\n");fflush(log);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *error=nil;
        id<MTLLibrary> shader=[device newLibraryWithData:input error:&error];
        loaded=shader!=nil;
        fprintf(log,"[shader-probe] native library loaded=%d error_code=%ld\n",loaded,(long)error.code);fflush(log);
        atomic_store(&completed,1);__ulock_wake(1,&completed,0);
    });
    (void)gw_wait(__ulock_wait,1,&completed,0,0,true,pending,pump);
    CFRunLoopTimerInvalidate(timer);CFRelease(timer);
    BOOL ok=atomic_load(&completed) && loaded && probe.ticks>=65;
    fprintf(log,"[shader-probe] %s ticks=%u library=%d\n",ok?"PASS":"INCOMPLETE",probe.ticks,loaded);fflush(log);
    return ok;
}
