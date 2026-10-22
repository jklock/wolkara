#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// The optional Metal performance HUD (from the performance-overlay contribution,
// reworked here for the layer).
//
// It is observational only: frame rate and frame time come from the Metal
// adapter's presentation timestamps, and everything else from public system
// APIs. It never reads guest memory, never changes how the game renders and
// never enables a frame readback.
//
// The AppKit adapter's host view owns one and shows it when the persisted
// preference is on. That preference lives in the touch layout store - the same
// one the in-game settings page writes and the launcher's Performance & UI row
// writes - so all three agree.
@interface AKPerformanceOverlay : UIView

// Compact pill when NO, full card when YES. Tapping toggles it; the state is
// remembered on this device.
@property(nonatomic, assign, getter=isExpanded) BOOL expanded;

// Reads the sensors and the Metal adapter now, rather than waiting for the poll.
- (void)updateMetrics;

@end

NS_ASSUME_NONNULL_END
