// The AppKit adapter's views and windows as a guest's own subclasses use them,
// run in the simulator (tools/test_translation_sim.sh): no scene is connected,
// so windows are never put on screen here.
#import "AppKit.h"
#include <assert.h>

// Draws by updating its layer, as Wine's Mac driver does.
@interface LayerView : NSView
@property int updates;
@end
@implementation LayerView
- (BOOL)wantsUpdateLayer { return YES; }
- (void)updateLayer { self.updates++; self.layer.position = CGPointMake(5, 6); }
@end

static void run_main_queue(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false); }

int main(void) { @autoreleasepool {
    // Marking for display coalesces into one updateLayer on the main queue;
    // a view that does not want updateLayer gets none.
    LayerView *view = [[LayerView alloc] initWithFrame:CGRectMake(0, 0, 100, 50)];
    view.wantsLayer = YES;
    [view setNeedsDisplayInRect:CGRectMake(0, 0, 1, 1)]; view.needsDisplay = YES; view.needsDisplay = YES;
    assert(view.needsDisplay && view.updates == 0);
    run_main_queue();
    assert(!view.needsDisplay && view.updates == 1);
    view.needsDisplay = YES; view.needsDisplay = NO; run_main_queue();
    assert(view.updates == 1);
    [view display]; assert(view.updates == 2);
    NSView *still = [[NSView alloc] initWithFrame:CGRectMake(0, 0, 1, 1)];
    still.needsDisplay = YES; run_main_queue(); assert(!still.needsDisplay && !still.wantsUpdateLayer);

    // Frame and content coincide; panels are windows.
    CGRect rect = CGRectMake(1, 2, 3, 4);
    NSWindow *window = [[NSWindow alloc] initWithContentRect:CGRectMake(0, 0, 100, 50) styleMask:0 backing:2 defer:NO];
    assert(CGRectEqualToRect([window frameRectForContentRect:rect], rect) && CGRectEqualToRect([window contentRectForFrameRect:rect], rect));
    assert(CGRectEqualToRect([NSWindow frameRectForContentRect:rect styleMask:15], rect) && CGRectEqualToRect([NSPanel contentRectForFrameRect:rect styleMask:15], rect));
    NSPanel *panel = [[NSPanel alloc] initWithContentRect:rect styleMask:0 backing:2 defer:NO];
    panel.floatingPanel = YES; assert([panel isKindOfClass:NSWindow.class] && panel.isFloatingPanel);

    // Tracking areas are kept once each, for their owner.
    NSTrackingArea *area = [[NSTrackingArea alloc] initWithRect:rect options:0x20 owner:view userInfo:@{@"k": @1}];
    assert(area.owner == view && area.options == 0x20 && CGRectEqualToRect(area.rect, rect) && [area.userInfo[@"k"] isEqual:@1]);
    [view addTrackingArea:area]; [view addTrackingArea:area]; [view addTrackingArea:nil];
    assert(view.trackingAreas.count == 1);
    [view removeTrackingArea:area]; assert(view.trackingAreas.count == 0);

    puts("display pass, frame rects, panels and tracking areas: PASS");
} }
