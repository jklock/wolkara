#import "TouchHaptics.h"
#include <math.h>

@implementation AKTouchHaptics {
    UIImpactFeedbackGenerator *_buttonFeedback, *_limitFeedback;
    BOOL _leftAtLimit, _rightAtLimit;
}
- (void)setEnabled:(BOOL)enabled {
    if (!enabled) [self reset];
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (enabled) {
        if (!_buttonFeedback) _buttonFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        if (!_limitFeedback) _limitFeedback = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleRigid];
        [_buttonFeedback prepare]; [_limitFeedback prepare];
    }
}
- (void)emitImpact:(BOOL)limit {
    // UIKit silently omits feedback when the hardware/system cannot provide it.
    UIImpactFeedbackGenerator *generator = limit ? _limitFeedback : _buttonFeedback;
    [generator impactOccurredWithIntensity:limit ? 0.65 : 0.55];
    [generator prepare];
}
- (void)buttonPressed { if (_enabled) [self emitImpact:NO]; }
- (void)stickMoved:(CGPoint)position left:(BOOL)left {
    if (!_enabled) return;
    BOOL *atLimit = left ? &_leftAtLimit : &_rightAtLimit;
    CGFloat radius = hypot(position.x,position.y);
    if (!isfinite(radius)) { *atLimit = NO; return; }
    // Hysteresis: moving around or jittering at the rim must not buzz. Pull
    // inward before another edge cue; each stick has its own latch.
    if (radius <= 0.85) *atLimit = NO;
    else if (!*atLimit && radius >= 0.995) {
        *atLimit = YES; [self emitImpact:YES];
    }
}
- (void)reset { _leftAtLimit = _rightAtLimit = NO; }
@end
