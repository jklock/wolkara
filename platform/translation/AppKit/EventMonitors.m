#import "EventMonitors.h"

@interface AKEventMonitor : NSObject
@property(nonatomic) NSUInteger mask;
@property(nonatomic, copy) AKEventHandler handler;
@end
@implementation AKEventMonitor
@end

static NSMutableArray<AKEventMonitor *> *monitors(void) {
    static NSMutableArray *list; static dispatch_once_t once;
    dispatch_once(&once, ^{ list=[NSMutableArray new]; });
    return list;
}
id AKEventMonitorAdd(NSUInteger mask, AKEventHandler handler) {
    if (!handler) return nil;
    AKEventMonitor *monitor=[AKEventMonitor new]; monitor.mask=mask; monitor.handler=handler;
    NSMutableArray *list=monitors();
    @synchronized(list) { [list addObject:monitor]; }
    return monitor;
}
void AKEventMonitorRemove(id token) {
    if (!token) return;
    NSMutableArray *list=monitors();
    @synchronized(list) { [list removeObjectIdenticalTo:token]; }
}
id AKEventMonitorRun(id event, NSUInteger type) {
    NSMutableArray *list=monitors(); NSArray<AKEventMonitor *> *snapshot;
    // A snapshot: handlers may add or remove monitors, and run without the lock.
    @synchronized(list) { if (!list.count) return event; snapshot=[list copy]; }
    for (AKEventMonitor *monitor in snapshot) {
        if (type>=64 || !(monitor.mask & (1ULL<<type))) continue;
        BOOL installed;
        @synchronized(list) { installed=[list indexOfObjectIdenticalTo:monitor]!=NSNotFound; }
        if (!installed) continue;   // removed by an earlier handler
        event=monitor.handler(event);
        if (!event) break;
    }
    return event;
}
