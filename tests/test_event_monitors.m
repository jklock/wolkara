#import "EventMonitors.h"
#include <assert.h>

static id install(NSUInteger mask, NSMutableArray *seen, NSString *name, BOOL consume) {
    // A stack block, as the guest may pass: the token must not depend on it.
    return AKEventMonitorAdd(mask, ^id(id event) { [seen addObject:name]; return consume ? nil : event; });
}
int main(void) { @autoreleasepool {
    NSMutableArray *seen=[NSMutableArray new];
    NSString *event=@"key down";
    assert(AKEventMonitorRun(event,10)==event);                 // no monitor: unchanged
    assert(!AKEventMonitorAdd(1,nil));
    id keys=install(1ULL<<10, seen, @"keys", NO), any=install(NSUIntegerMax, seen, @"any", NO);
    assert(keys && any && keys!=any);
    assert(AKEventMonitorRun(event,10)==event);
    assert([seen isEqual:(@[@"keys", @"any"])]);                // oldest first
    [seen removeAllObjects];
    assert(AKEventMonitorRun(event,1)==event && [seen isEqual:@[@"any"]]);   // mask filters by type
    [seen removeAllObjects];
    assert(AKEventMonitorRun(event,64)==event && seen.count==0);  // no mask bit for such a type
    // Consumed: nil, and later handlers do not run.
    AKEventMonitorRemove(any);
    id eat=install(1ULL<<10, seen, @"eat", YES), late=install(1ULL<<10, seen, @"late", NO);
    [seen removeAllObjects];
    assert(AKEventMonitorRun(event,10)==nil && [seen isEqual:(@[@"keys", @"eat"])]);
    AKEventMonitorRemove(eat); AKEventMonitorRemove(late); AKEventMonitorRemove(keys);
    // A handler that removes monitors, itself included, while events are dispatched.
    __block id self_removing=nil, other=nil;
    self_removing=AKEventMonitorAdd(NSUIntegerMax, ^id(id e) { [seen addObject:@"remover"]; AKEventMonitorRemove(self_removing); AKEventMonitorRemove(other); return e; });
    other=install(NSUIntegerMax, seen, @"other", NO);
    [seen removeAllObjects];
    assert(AKEventMonitorRun(event,3)==event && [seen isEqual:@[@"remover"]]);   // removed ones do not run
    [seen removeAllObjects];
    assert(AKEventMonitorRun(event,3)==event && seen.count==0);
    self_removing=other=nil;
    AKEventMonitorRemove(nil); AKEventMonitorRemove(@"not a monitor");
    // The handler may answer with a different event.
    id swap=AKEventMonitorAdd(NSUIntegerMax, ^id(id e) { (void)e; return @"replacement"; });
    assert([AKEventMonitorRun(event,5) isEqual:@"replacement"]);
    AKEventMonitorRemove(swap);
    puts("local event monitors: order, masks, consumption, removal during dispatch: PASS");
} }
