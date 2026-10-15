#import <Foundation/Foundation.h>

FOUNDATION_EXPORT NSNotificationName const NSWindowWillEnterFullScreenNotification;
FOUNDATION_EXPORT NSNotificationName const NSWindowDidEnterFullScreenNotification;
FOUNDATION_EXPORT NSNotificationName const NSWindowWillExitFullScreenNotification;
FOUNDATION_EXPORT NSNotificationName const NSWindowDidExitFullScreenNotification;

@protocol AKFullscreenWindow <NSObject>
@property NSUInteger styleMask;
@property(weak) id delegate;
- (void)ak_layoutFullscreenWindow;
@end

// UIKit owns the scene's geometry. Complete the AppKit transition within that
// viewport, with its style bit, delegate callbacks and public notifications.
void AKToggleFullscreenWindow(id<AKFullscreenWindow> window);
