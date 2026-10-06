#import <UIKit/UIKit.h>

// Native UI feedback only. Never sends game input or controller rumble.
@interface AKTouchHaptics : NSObject
@property(nonatomic) BOOL enabled;
- (void)buttonPressed;
- (void)stickMoved:(CGPoint)position left:(BOOL)left;
- (void)reset;
@end
