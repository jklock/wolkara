#import "WindowFullscreen.h"
#include <assert.h>
#include <stdio.h>

@interface FixtureWindow : NSObject <AKFullscreenWindow>
@property NSUInteger styleMask;
@property(weak) id delegate;
@property NSMutableArray *events;
@end
@implementation FixtureWindow
- (void)ak_layoutFullscreenWindow {
    assert(NSThread.isMainThread);
    [self.events addObject:@"layout"];
}
@end
@interface FixtureDelegate : NSObject
@property NSMutableArray *events;
@property NSUInteger completions;
@property BOOL retryDuringWill;
@end
@implementation FixtureDelegate
- (void)windowWillEnterFullScreen:(NSNotification *)note {
    FixtureWindow *window=note.object;
    assert(!(window.styleMask&(1UL<<14)) && NSThread.isMainThread);
    [self.events addObject:@"delegate will enter"];
    if(self.retryDuringWill)AKToggleFullscreenWindow(window);
}
- (void)windowDidEnterFullScreen:(NSNotification *)note {
    assert([note.object styleMask]&(1UL<<14));
    [self.events addObject:@"delegate did enter"];self.completions++;
}
- (void)windowWillExitFullScreen:(NSNotification *)note {
    assert([note.object styleMask]&(1UL<<14));
    [self.events addObject:@"delegate will exit"];
}
- (void)windowDidExitFullScreen:(NSNotification *)note {
    assert(!([note.object styleMask]&(1UL<<14)));
    [self.events addObject:@"delegate did exit"];self.completions++;
}
@end
static void pump(FixtureDelegate *delegate,NSUInteger completions) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:2];
    while(delegate.completions<completions && deadline.timeIntervalSinceNow>0)
        [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    assert(delegate.completions==completions);
}
int main(void) { @autoreleasepool {
    FixtureWindow *window=[FixtureWindow new];window.styleMask=3;window.events=[NSMutableArray new];
    FixtureDelegate *delegate=[FixtureDelegate new];delegate.events=window.events;delegate.retryDuringWill=YES;
    window.delegate=delegate;
    id observer=[NSNotificationCenter.defaultCenter addObserverForName:nil object:window queue:nil usingBlock:^(NSNotification *note) {
        assert(NSThread.isMainThread);
        [window.events addObject:note.name];
    }];
    AKToggleFullscreenWindow(nil);
    AKToggleFullscreenWindow(window);
    AKToggleFullscreenWindow(window); // an in-flight transition cannot toggle twice
    assert(window.styleMask==(3|(1UL<<14)) && delegate.completions==0);
    assert([window.events isEqual:(@[@"delegate will enter",NSWindowWillEnterFullScreenNotification,@"layout"])]);
    pump(delegate,1);
    assert([window.events isEqual:(@[@"delegate will enter",NSWindowWillEnterFullScreenNotification,@"layout",
                                     @"delegate did enter",NSWindowDidEnterFullScreenNotification])]);
    [window.events removeAllObjects];
    AKToggleFullscreenWindow(window);
    assert(window.styleMask==3 && delegate.completions==1);
    pump(delegate,2);
    assert([window.events isEqual:(@[@"delegate will exit",NSWindowWillExitFullScreenNotification,@"layout",
                                     @"delegate did exit",NSWindowDidExitFullScreenNotification])]);
    // Background requests are delivered on the UI thread as a complete transition.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{ AKToggleFullscreenWindow(window); });
    pump(delegate,3);
    assert(window.styleMask==(3|(1UL<<14)));
    [NSNotificationCenter.defaultCenter removeObserver:observer];
    window.delegate=nil;
    AKToggleFullscreenWindow(window); // delegate callbacks are optional
    assert(window.styleMask==3);
    [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:.01]];
    puts("PASS: fullscreen style, layout, asynchronous completion, delegate/observer ordering, reentrancy and UI-thread delivery");
} }
