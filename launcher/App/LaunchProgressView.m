#import "LaunchProgressView.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>

@implementation TKLaunchProgressView {
    CAShapeLayer *_ring;
    NSArray<CALayer *> *_digits;
    NSArray *_glyphs;
    CFTimeInterval _started;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hidden = YES;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Startup elapsed time";
    _ring = [CAShapeLayer layer];
    _ring.frame = CGRectMake(0, 7, 24, 24);
    _ring.path = [UIBezierPath bezierPathWithArcCenter:CGPointMake(12, 12) radius:10
        startAngle:0 endAngle:1.5 * M_PI clockwise:YES].CGPath;
    _ring.fillColor = UIColor.clearColor.CGColor;
    _ring.strokeColor = UIColor.grayColor.CGColor;
    _ring.lineWidth = 2;
    _ring.lineCap = kCALineCapRound;
    [self.layer addSublayer:_ring];
    UILabel *caption = [[UILabel alloc] initWithFrame:CGRectMake(38, 0, 70, 38)];
    caption.text = @"Elapsed";
    caption.font = [UIFont systemFontOfSize:17];
    caption.textColor = UIColor.secondaryLabelColor;
    [self addSubview:caption];
    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:24 weight:UIFontWeightMedium];
    NSMutableArray *glyphs = [NSMutableArray array];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(20, 38)];
    for (unsigned i = 0; i < 10; ++i) {
        UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            (void)context;
            [[NSString stringWithFormat:@"%u", i] drawAtPoint:CGPointMake(2, 4)
                // An opaque middle gray remains legible in both appearances;
                // the pre-rendered glyphs outlive the app's paused UI thread.
                withAttributes:@{NSFontAttributeName:font, NSForegroundColorAttributeName:UIColor.grayColor}];
        }];
        [glyphs addObject:(__bridge id)image.CGImage];
    }
    _glyphs = glyphs;
    NSMutableArray *digits = [NSMutableArray array];
    for (unsigned i = 0; i < 4; ++i) {
        CALayer *digit = [CALayer layer];
        digit.frame = CGRectMake(112 + i * 20 + (i >= 2 ? 8 : 0), 0, 20, 38);
        digit.contents = _glyphs[0];
        digit.contentsScale = ((UIGraphicsImageRendererFormat *)renderer.format).scale;
        [self.layer addSublayer:digit];
        [digits addObject:digit];
    }
    _digits = digits;
    UILabel *colon = [[UILabel alloc] initWithFrame:CGRectMake(152, 0, 8, 38)];
    colon.text = @":"; colon.font = font; colon.textColor = UIColor.secondaryLabelColor;
    [self addSubview:colon];
    return self;
}
- (CGSize)intrinsicContentSize { return CGSizeMake(200, 38); }
- (void)start {
    if (!self.hidden) return;
    self.hidden = NO;
    _started = CACurrentMediaTime();
    // These animate elapsed wall time only, never a completion percentage.
    const unsigned counts[] = {10, 10, 6, 10};
    const double periods[] = {6000, 600, 60, 10};
    for (unsigned i = 0; i < 4; ++i) {
        CAKeyframeAnimation *animation = [CAKeyframeAnimation animationWithKeyPath:@"contents"];
        animation.values = [_glyphs subarrayWithRange:NSMakeRange(0, counts[i])];
        NSMutableArray *times = [NSMutableArray array];
        for (unsigned j = 0; j < counts[i]; ++j) [times addObject:@((double)j / counts[i])];
        animation.keyTimes = times;
        animation.calculationMode = kCAAnimationDiscrete;
        animation.duration = periods[i];
        animation.repeatCount = HUGE_VALF;
        animation.beginTime = [_digits[i] convertTime:_started fromLayer:nil];
        [_digits[i] addAnimation:animation forKey:@"elapsed"];
    }
    if (!UIAccessibilityIsReduceMotionEnabled()) {
        CABasicAnimation *spin = [CABasicAnimation animationWithKeyPath:@"transform.rotation.z"];
        spin.fromValue = @0; spin.toValue = @(2 * M_PI);
        spin.duration = 1.2; spin.repeatCount = HUGE_VALF;
        [_ring addAnimation:spin forKey:@"activity"];
    }
}
- (NSString *)accessibilityValue {
    unsigned elapsed = (unsigned)MAX(0, CACurrentMediaTime() - _started);
    return [NSString stringWithFormat:@"%u minutes, %u seconds", elapsed / 60, elapsed % 60];
}
- (void)stop {
    self.hidden = YES;
    [_ring removeAllAnimations];
    for (CALayer *digit in _digits) [digit removeAllAnimations];
}
@end
