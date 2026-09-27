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
// One pixel a point, whatever the screen's scale.
- (BOOL)layer:(CALayer *)layer shouldInheritContentsScale:(CGFloat)scale fromWindow:(NSWindow *)window { return NO; }
@end

// Shows itself with orderFront:, as Wine's window class does.
@interface OrderingWindow : NSWindow
@property int depth, deepest;
@end
@implementation OrderingWindow
- (void)makeKeyAndOrderFront:(id)sender {
    self.deepest = MAX(self.deepest, ++self.depth);
    if (self.depth == 1) { [self orderFront:sender]; [self makeKeyWindow]; [self setIsVisible:YES]; }
    self.depth--;
}
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

    // A view's layer is placed by its origin, as AppKit's are: Wine's Mac driver sets the position.
    NSView *plain = [[NSView alloc] initWithFrame:CGRectMake(10, 20, 30, 40)];
    plain.wantsLayer = YES;
    assert(CGPointEqualToPoint(plain.layer.anchorPoint, CGPointZero));
    assert(CGPointEqualToPoint(plain.layer.position, CGPointMake(10, 20)) && CGRectEqualToRect(plain.layer.frame, CGRectMake(10, 20, 30, 40)));
    assert(CGRectEqualToRect(view.layer.frame, CGRectMake(5, 6, 100, 50)));

    // The window's scale reaches a content view's layer unless the view keeps its own.
    window.contentView = view; view.layer.contentsScale = 1;
    [window ak_hostBoundsChanged:CGRectMake(0, 0, 200, 100)];
    assert(view.layer.contentsScale == 1 && CGSizeEqualToSize(view.frame.size, CGSizeMake(200, 100)));
    NSWindow *other = [[NSWindow alloc] initWithContentRect:CGRectMake(0, 0, 100, 50) styleMask:0 backing:2 defer:NO];
    other.contentView = plain; plain.layer.contentsScale = 1;
    [other ak_hostBoundsChanged:CGRectMake(0, 0, 200, 100)];
    assert(other.backingScaleFactor > 1 && plain.layer.contentsScale == other.backingScaleFactor);

    // Showing a window never calls back into a subclass's makeKeyAndOrderFront:.
    OrderingWindow *ordering = [[OrderingWindow alloc] initWithContentRect:rect styleMask:0 backing:2 defer:NO];
    [ordering makeKeyAndOrderFront:nil];
    assert(ordering.deepest == 1);
    // An event's Quartz location is in global display coordinates, top-left
    // origin, which is where Wine's Mac driver takes clicks from.
    NSEvent *click = [NSEvent new];
    click.type = NSEventTypeLeftMouseDown; click.window = window; click.locationInWindow = CGPointMake(10, 20);
    click.clickCount = 2; click.buttonNumber = 1; click.timestamp = 1.5; click.modifierFlags = NSEventModifierFlagShift;
    AKQuartzEvent *quartz = (__bridge AKQuartzEvent *)click.CGEvent;
    CGFloat height = NSScreen.screens.firstObject.frame.size.height;
    assert(quartz && (__bridge AKQuartzEvent *)click.CGEvent == quartz && quartz.type == 1);
    assert(quartz.location.x == 10 && quartz.location.y == height - 20 && quartz.timestamp == 1500000000);
    assert([quartz integerValueField:1] == 2 && [quartz integerValueField:3] == 1 && quartz.flags == NSEventModifierFlagShift);
    NSEvent *scroll = [NSEvent new]; scroll.type = NSEventTypeScrollWheel; scroll.deltaY = 2.6;
    AKQuartzEvent *wheel = (__bridge AKQuartzEvent *)scroll.CGEvent;
    assert(wheel.type == 22 && [wheel integerValueField:11] == 3 && [wheel integerValueField:88] == 0);

    // Windows are numbered once each; with none on screen, none is found.
    assert(window.windowNumber > 0 && other.windowNumber != window.windowNumber && panel.windowNumber != other.windowNumber);
    assert([NSWindow windowNumbersWithOptions:0].count == 0 && [NSWindow windowNumberAtPoint:CGPointMake(1, 1) belowWindowWithWindowNumber:0] == 0);
    // Modifier keys: a key's press and release set and clear it, left and right
    // apart (device bits); the flag stays while either side is held.
    const NSEventModifierFlags LeftOption = 0x20, RightOption = 0x40, LeftCommand = 0x08, LeftShift = 0x02;
    NSEventModifierFlags held = AKModifiersAfterKey(0, 0xE2, YES);
    assert(held == (NSEventModifierFlagOption | LeftOption));
    held = AKModifiersAfterKey(held, 0xE6, YES);
    assert(held == (NSEventModifierFlagOption | LeftOption | RightOption));
    held = AKModifiersAfterKey(held, 0xE2, NO);
    assert(held == (NSEventModifierFlagOption | RightOption));
    held = AKModifiersAfterKey(held, 0xE6, NO);
    assert(held == 0);
    // Whatever the release event reports, the key's own release clears it.
    held = AKModifiersAfterKey(AKModifiersAfterKey(0, 0xE2, YES), 0xE2, NO);
    assert(held == 0 && AKModifiersAfterKey(0, 0x04, YES) == 0);
    // Other events reconcile with UIKit: what it no longer reports is released;
    // what it reports with no key held is the left key; Caps Lock is its own.
    held = AKModifiersAfterKey(AKModifiersAfterKey(0, 0xE2, YES), 0xE3, YES);
    assert(AKModifiersReconciled(held, NSEventModifierFlagCommand) == (NSEventModifierFlagCommand | LeftCommand));
    assert(AKModifiersReconciled(0, NSEventModifierFlagShift | NSEventModifierFlagCapsLock) ==
           (NSEventModifierFlagShift | LeftShift | NSEventModifierFlagCapsLock));
    assert(AKModifiersReconciled(held, 0) == 0);
    assert(AKModifiersReconciled(AKModifiersAfterKey(0, 0xE6, YES), NSEventModifierFlagOption) == (NSEventModifierFlagOption | RightOption));
    puts("display pass, frame rects, panels, tracking areas, layer placement, contents scale, window ordering, Quartz events, window numbers and modifier keys: PASS");
} }
