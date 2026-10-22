#import "AKPerformanceOverlay.h"
#import <mach/mach.h>
#import <os/proc.h>
#import <dlfcn.h>

// Position and expansion are remembered separately from the touch layout: the
// layout store owns whether the overlay is enabled, and normalizing the
// position against the safe area is the HUD's own business.
static NSString *const PositionKey = @"WolkaraForeverPerformanceOverlayPosition";
static NSString *const ExpandedKey = @"WolkaraForeverPerformanceOverlayExpanded";

typedef double (*AKMetalFPSFunc)(void);
typedef double (*AKMetalFrameTimeFunc)(void);

// The Metal adapter publishes these when a frame is presented. They are looked
// up at runtime because the adapters are separate compatibility libraries: the
// AppKit one may run without the Metal one (and the Metal one without a
// window), and a missing symbol must mean "no frames yet", not a link failure.
static double ReadMetalFPS(void) {
    static AKMetalFPSFunc func = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ func = (AKMetalFPSFunc)dlsym(RTLD_DEFAULT, "AKMetalCurrentFPS"); });
    return func ? func() : 0.0;
}

static double ReadMetalFrameTimeMs(void) {
    static AKMetalFrameTimeFunc func = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ func = (AKMetalFrameTimeFunc)dlsym(RTLD_DEFAULT, "AKMetalLastFrameTimeMs"); });
    return func ? func() : 0.0;
}

@implementation AKPerformanceOverlay {
    UIStackView *_compactStack;
    UIStackView *_expandedStack;
    UILabel *_fpsLabel;
    UIView *_thermalDot;
    UILabel *_thermalLabel;
    UILabel *_compactSeparator;
    UILabel *_batteryLabel;

    UILabel *_expandedFPSLabel;
    UILabel *_expandedThermalLabel;
    UILabel *_expandedMemoryLabel;
    UILabel *_expandedBatteryLabel;
    UILabel *_expandedPowerLabel;

    NSTimer *_pollTimer;
    CADisplayLink *_displayLink;
    CFTimeInterval _lastDisplayLinkTimestamp;
    double _displayLinkFPS;

    CGPoint _panStartCenter;
    // The last position the user chose, as a fraction of the superview's safe
    // area. Kept so a rotation or a split-view resize can put the HUD back where
    // it was, relative to the new safe area, instead of leaving it off-screen.
    CGPoint _normalizedPosition;
    BOOL _hasNormalizedPosition;
    BOOL _dragging;
    BOOL _restored;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        self.backgroundColor = [UIColor colorWithRed:0.06 green:0.08 blue:0.12 alpha:0.88];
        self.layer.cornerRadius = 15;
        self.layer.borderWidth = 1.0;
        self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.2].CGColor;
        self.layer.shadowColor = UIColor.blackColor.CGColor;
        self.layer.shadowOpacity = 0.45;
        self.layer.shadowRadius = 8;
        self.layer.shadowOffset = CGSizeMake(0, 2);
        self.clipsToBounds = YES;
        self.accessibilityIdentifier = @"wolkaraforever.overlay.performance";
        self.accessibilityLabel = @"Performance overlay";
        self.isAccessibilityElement = YES;

        // Battery monitoring is process-wide and cheap; the readings are only
        // read while the HUD is updating.
        [UIDevice currentDevice].batteryMonitoringEnabled = YES;

        _expanded = [NSUserDefaults.standardUserDefaults boolForKey:ExpandedKey];
        [self buildSubviews];
        [self applyExpansion];
        [self setupGestures];

        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(thermalStateChanged:)
            name:NSProcessInfoThermalStateDidChangeNotification object:nil];
    }
    return self;
}

- (void)buildSubviews {
    _fpsLabel = [UILabel new];
    _fpsLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightBold];
    _fpsLabel.textColor = UIColor.whiteColor;
    _fpsLabel.text = @"-- FPS";

    _thermalDot = [UIView new];
    _thermalDot.layer.cornerRadius = 4;
    _thermalDot.backgroundColor = UIColor.systemGreenColor;
    _thermalDot.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [_thermalDot.widthAnchor constraintEqualToConstant:8],
        [_thermalDot.heightAnchor constraintEqualToConstant:8],
    ]];

    _thermalLabel = [UILabel new];
    _thermalLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    _thermalLabel.textColor = UIColor.whiteColor;
    _thermalLabel.text = @"Nominal";

    _compactSeparator = [UILabel new];
    _compactSeparator.font = [UIFont systemFontOfSize:12 weight:UIFontWeightLight];
    _compactSeparator.textColor = [UIColor colorWithWhite:1.0 alpha:0.5];
    _compactSeparator.text = @"·";

    _batteryLabel = [UILabel new];
    _batteryLabel.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightMedium];
    _batteryLabel.textColor = UIColor.whiteColor;
    _batteryLabel.text = @"";

    _compactStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        _fpsLabel, _compactSeparator, _thermalDot, _thermalLabel, _batteryLabel
    ]];
    _compactStack.axis = UILayoutConstraintAxisHorizontal;
    _compactStack.alignment = UIStackViewAlignmentCenter;
    _compactStack.spacing = 6;
    _compactStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_compactStack];

    UILabel *header = [UILabel new];
    header.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    header.textColor = UIColor.systemCyanColor;
    header.text = @"PERFORMANCE & THERMALS";

    _expandedFPSLabel = [self detailLabel];
    _expandedThermalLabel = [self detailLabel];
    _expandedMemoryLabel = [self detailLabel];
    _expandedBatteryLabel = [self detailLabel];
    _expandedPowerLabel = [self detailLabel];

    UILabel *hint = [UILabel new];
    hint.font = [UIFont systemFontOfSize:10 weight:UIFontWeightRegular];
    hint.textColor = [UIColor colorWithWhite:1.0 alpha:0.55];
    hint.text = @"Tap to collapse · Drag to reposition";

    _expandedStack = [[UIStackView alloc] initWithArrangedSubviews:@[
        header,
        _expandedFPSLabel,
        _expandedThermalLabel,
        _expandedMemoryLabel,
        _expandedBatteryLabel,
        _expandedPowerLabel,
        hint
    ]];
    _expandedStack.axis = UILayoutConstraintAxisVertical;
    _expandedStack.alignment = UIStackViewAlignmentLeading;
    _expandedStack.spacing = 5;
    _expandedStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_expandedStack];

    [NSLayoutConstraint activateConstraints:@[
        [_compactStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [_compactStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [_compactStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],

        [_expandedStack.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [_expandedStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14],
        [_expandedStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-14],
        [_expandedStack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-10],
    ]];
}

- (UILabel *)detailLabel {
    UILabel *label = [UILabel new];
    label.font = [UIFont monospacedDigitSystemFontOfSize:12 weight:UIFontWeightRegular];
    label.textColor = UIColor.whiteColor;
    label.numberOfLines = 1;
    return label;
}

- (void)setupGestures {
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap:)];
    [self addGestureRecognizer:tap];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePan:)];
    [self addGestureRecognizer:pan];
}

#pragma mark - Expansion

- (void)applyExpansion {
    _compactStack.hidden = _expanded;
    _expandedStack.hidden = !_expanded;
    self.layer.cornerRadius = _expanded ? 16 : 15;
}

- (void)setExpanded:(BOOL)expanded {
    [self setExpanded:expanded animated:NO];
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
    if (_expanded == expanded) return;
    _expanded = expanded;
    [NSUserDefaults.standardUserDefaults setBool:expanded forKey:ExpandedKey];

    void (^changes)(void) = ^{
        [self applyExpansion];
        [self updateMetrics];
        [self sizeToFit];
        self->_restored = YES;
        [self applyCenter];
    };
    void (^done)(BOOL) = ^(BOOL finished) {
        (void)finished;
        [self setNeedsLayout];
    };

    if (animated) {
        [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.82 initialSpringVelocity:0
            options:UIViewAnimationOptionCurveEaseInOut animations:changes completion:done];
    } else {
        changes();
        done(YES);
    }
}

- (void)handleTap:(UITapGestureRecognizer *)tap {
    (void)tap;
    [self setExpanded:!self.isExpanded animated:YES];
}

- (CGSize)sizeThatFits:(CGSize)size {
    (void)size;
    if (_expanded) {
        CGSize stack = [_expandedStack systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
        return CGSizeMake(MAX(220, stack.width + 28), stack.height + 20);
    }
    CGSize stack = [_compactStack systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    return CGSizeMake(stack.width + 24, 30);
}

#pragma mark - Position

- (CGRect)safeBounds {
    UIView *parent = self.superview;
    if (!parent) return CGRectZero;
    return UIEdgeInsetsInsetRect(parent.bounds, parent.safeAreaInsets);
}

- (CGPoint)clampedCenterForProposedCenter:(CGPoint)proposed {
    UIView *parent = self.superview;
    if (!parent) return proposed;
    CGRect safe = [self safeBounds];
    if (safe.size.width <= 0 || safe.size.height <= 0) return proposed;
    CGFloat halfW = self.bounds.size.width / 2.0;
    CGFloat halfH = self.bounds.size.height / 2.0;
    CGFloat minX = safe.origin.x + halfW + 6;
    CGFloat maxX = CGRectGetMaxX(safe) - halfW - 6;
    CGFloat minY = safe.origin.y + halfH + 6;
    CGFloat maxY = CGRectGetMaxY(safe) - halfH - 6;
    if (minX > maxX) minX = maxX = CGRectGetMidX(safe);
    if (minY > maxY) minY = maxY = CGRectGetMidY(safe);
    return CGPointMake(MAX(minX, MIN(maxX, proposed.x)), MAX(minY, MIN(maxY, proposed.y)));
}

// Puts the HUD at the remembered fraction of the safe area, clamped to it.
// This is what makes a rotation or a resized window keep the HUD reachable.
- (void)applyCenter {
    if (!self.superview || !_hasNormalizedPosition) {
        self.center = [self clampedCenterForProposedCenter:self.center];
        return;
    }
    CGRect safe = [self safeBounds];
    if (safe.size.width <= 0 || safe.size.height <= 0) return;
    CGPoint proposed = CGPointMake(safe.origin.x + _normalizedPosition.x * safe.size.width,
                                   safe.origin.y + _normalizedPosition.y * safe.size.height);
    CGPoint clamped = [self clampedCenterForProposedCenter:proposed];
    if (!CGPointEqualToPoint(clamped, self.center)) self.center = clamped;
}

- (void)savePosition {
    CGRect safe = [self safeBounds];
    if (safe.size.width <= 0 || safe.size.height <= 0) return;
    _normalizedPosition = CGPointMake((self.center.x - safe.origin.x) / safe.size.width,
                                      (self.center.y - safe.origin.y) / safe.size.height);
    _normalizedPosition.x = MAX(0, MIN(1, _normalizedPosition.x));
    _normalizedPosition.y = MAX(0, MIN(1, _normalizedPosition.y));
    _hasNormalizedPosition = YES;
    [NSUserDefaults.standardUserDefaults setObject:@[@(_normalizedPosition.x), @(_normalizedPosition.y)]
        forKey:PositionKey];
}

- (void)restorePosition {
    if (!self.superview) return;
    [self sizeToFit];
    id saved = [NSUserDefaults.standardUserDefaults objectForKey:PositionKey];
    if ([saved isKindOfClass:NSArray.class] && [(NSArray *)saved count] == 2) {
        CGFloat x = [[(NSArray *)saved objectAtIndex:0] doubleValue];
        CGFloat y = [[(NSArray *)saved objectAtIndex:1] doubleValue];
        if (isfinite(x) && isfinite(y)) {
            _normalizedPosition = CGPointMake(MAX(0, MIN(1, x)), MAX(0, MIN(1, y)));
            _hasNormalizedPosition = YES;
            [self applyCenter];
            return;
        }
    }
    // First run: the upper right corner inside the safe area. The fraction is
    // remembered (but not written) so a later rotation keeps the same corner.
    CGRect safe = [self safeBounds];
    if (safe.size.width <= 0 || safe.size.height <= 0) return;
    CGFloat x = CGRectGetMaxX(safe) - self.bounds.size.width / 2.0 - 12;
    CGFloat y = safe.origin.y + self.bounds.size.height / 2.0 + 8;
    self.center = [self clampedCenterForProposedCenter:CGPointMake(x, y)];
    _normalizedPosition = CGPointMake((self.center.x - safe.origin.x) / safe.size.width,
                                      (self.center.y - safe.origin.y) / safe.size.height);
    _hasNormalizedPosition = YES;
}

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    if (!self.superview) return;
    switch (pan.state) {
    case UIGestureRecognizerStateBegan:
        _dragging = YES;
        _panStartCenter = self.center;
        break;
    case UIGestureRecognizerStateChanged: {
        CGPoint translation = [pan translationInView:self.superview];
        self.center = [self clampedCenterForProposedCenter:
            CGPointMake(_panStartCenter.x + translation.x, _panStartCenter.y + translation.y)];
        break;
    }
    case UIGestureRecognizerStateEnded:
    case UIGestureRecognizerStateCancelled:
        _dragging = NO;
        _restored = YES;
        [self savePosition];
        break;
    default:
        break;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Bounds and safe area are what the remembered fraction is measured against.
    // Reapplying it here is what keeps the HUD on screen after a rotation, a
    // split-view resize or a keyboard-driven safe-area change - the defect the
    // contribution left open.
    if (self.superview && !self.hidden && !_dragging && _hasNormalizedPosition) [self applyCenter];
}

#pragma mark - Metrics

- (void)updateMetrics {
    double metalFPS = ReadMetalFPS();
    double frameTimeMs = ReadMetalFrameTimeMs();
    double fps = metalFPS > 0.0 ? metalFPS : _displayLinkFPS;
    if (frameTimeMs <= 0.0 && fps > 0.0) frameTimeMs = 1000.0 / fps;

    NSProcessInfoThermalState thermal = NSProcessInfo.processInfo.thermalState;
    NSString *thermalName = @"Nominal";
    NSString *thermalDetail = @"Cool";
    UIColor *thermalColor = UIColor.systemGreenColor;
    switch (thermal) {
        case NSProcessInfoThermalStateFair:
            thermalName = @"Fair"; thermalDetail = @"Warm"; thermalColor = UIColor.systemYellowColor; break;
        case NSProcessInfoThermalStateSerious:
            thermalName = @"Serious"; thermalDetail = @"Throttling active"; thermalColor = UIColor.systemOrangeColor; break;
        case NSProcessInfoThermalStateCritical:
            thermalName = @"Critical"; thermalDetail = @"Heavy throttle"; thermalColor = UIColor.systemRedColor; break;
        case NSProcessInfoThermalStateNominal:
        default:
            break;
    }

    UIDevice *device = UIDevice.currentDevice;
    float level = device.batteryLevel;
    UIDeviceBatteryState state = device.batteryState;
    BOOL charging = (state == UIDeviceBatteryStateCharging || state == UIDeviceBatteryStateFull);
    NSString *batteryCompact = @"";
    NSString *batteryExpanded = @"Battery: AC power";
    if (level >= 0.0f) {
        int percent = (int)(level * 100.0f + 0.5f);
        batteryCompact = [NSString stringWithFormat:@"%d%%%@", percent, charging ? @" ⚡" : @""];
        batteryExpanded = [NSString stringWithFormat:@"Battery: %d%% (%@)", percent, charging ? @"Charging" : @"Unplugged"];
    }

    size_t available = 0;
    if (@available(iOS 13.0, *)) available = os_proc_available_memory();
    size_t footprint = 0;
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) == KERN_SUCCESS)
        footprint = (size_t)info.phys_footprint;
    double usedMB = (double)footprint / (1024.0 * 1024.0);
    double freeMB = (double)available / (1024.0 * 1024.0);

    BOOL lowPower = NSProcessInfo.processInfo.isLowPowerModeEnabled;

    _fpsLabel.text = fps > 0.0 ? [NSString stringWithFormat:@"%.1f FPS", fps] : @"-- FPS";
    _thermalDot.backgroundColor = thermalColor;
    _thermalLabel.text = thermalName;
    _batteryLabel.text = batteryCompact;
    _compactSeparator.hidden = batteryCompact.length == 0;

    _expandedFPSLabel.text = fps > 0.0
        ? [NSString stringWithFormat:@"Frame Rate: %.1f FPS (%.1f ms)", fps, frameTimeMs]
        : @"Frame Rate: Waiting for frames…";
    _expandedThermalLabel.text = [NSString stringWithFormat:@"Thermal State: %@ (%@)", thermalName, thermalDetail];
    _expandedMemoryLabel.text = available > 0
        ? [NSString stringWithFormat:@"RAM Footprint: %.0f MB · Headroom: %.0f MB", usedMB, freeMB]
        : [NSString stringWithFormat:@"RAM Footprint: %.0f MB", usedMB];
    _expandedBatteryLabel.text = batteryExpanded;
    _expandedPowerLabel.text = [NSString stringWithFormat:@"Low Power Mode: %@", lowPower ? @"On" : @"Off"];

    self.accessibilityValue = [NSString stringWithFormat:@"%.1f FPS, thermal %@, %.0f MB used", fps, thermalName, usedMB];
}

- (void)displayLinkFired:(CADisplayLink *)link {
    if (_lastDisplayLinkTimestamp > 0.0) {
        CFTimeInterval delta = link.timestamp - _lastDisplayLinkTimestamp;
        if (delta > 0.001) {
            double current = 1.0 / delta;
            _displayLinkFPS = _displayLinkFPS > 0.0 ? (_displayLinkFPS * 0.9 + current * 0.1) : current;
        }
    }
    _lastDisplayLinkTimestamp = link.timestamp;
}

- (void)thermalStateChanged:(NSNotification *)note {
    (void)note;
    __weak AKPerformanceOverlay *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf updateMetrics]; });
}

#pragma mark - Lifecycle

// Monitoring runs only while the HUD is actually on screen: a hidden overlay in
// a window must not wake the process twice a second, which is the other defect
// the contribution left open.
- (void)updateMonitoring {
    if (self.window && !self.hidden) [self startMonitoring];
    else [self stopMonitoring];
}

- (void)startMonitoring {
    if (!_pollTimer) {
        __weak AKPerformanceOverlay *weakSelf = self;
        _pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
            (void)timer;
            [weakSelf updateMetrics];
        }];
    }
    if (!_displayLink) {
        _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkFired:)];
        [_displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
    [self updateMetrics];
}

- (void)stopMonitoring {
    [_pollTimer invalidate];
    _pollTimer = nil;
    [_displayLink invalidate];
    _displayLink = nil;
    _lastDisplayLinkTimestamp = 0.0;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (self.window && !_restored) {
        _restored = YES;
        [self restorePosition];
    }
    [self updateMonitoring];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [self updateMonitoring];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self stopMonitoring];
}

@end
