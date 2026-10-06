#import "TouchGamepad.h"
#include <math.h>

CGPoint AKTouchGamepadStickPosition(CGPoint point, CGSize size) {
    if (!isfinite(point.x) || !isfinite(point.y) || !isfinite(size.width) || !isfinite(size.height) ||
        size.width <= 0 || size.height <= 0) return CGPointZero;
    CGFloat radius = MIN(size.width,size.height) / 2;
    CGFloat x = (point.x - size.width / 2) / radius, y = (size.height / 2 - point.y) / radius;
    CGFloat length = hypot(x,y);
    if (!isfinite(x) || !isfinite(y) || !isfinite(length)) return CGPointZero;
    if (length < 0.10) return CGPointZero;
    CGFloat scale = MIN(1,(length - 0.10) / 0.90) / length;
    return CGPointMake(x * scale,y * scale);
}

@interface AKGamepadButton : UIButton
@property(nonatomic, copy) NSString *element;
@property(nonatomic, readonly) BOOL pressed;
@property(nonatomic) NSInteger sector;
- (void)releaseInput;
@end
@implementation AKGamepadButton { CAShapeLayer *_sectorLayer; UIBezierPath *_sectorPath; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _sector = -1;
        self.exclusiveTouch = NO;
        self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        self.layer.cornerRadius = 22; self.layer.borderWidth = 1;
        self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor;
        self.backgroundColor = [UIColor colorWithWhite:0.13 alpha:0.64];
        [self setTitleColor:[UIColor colorWithWhite:1 alpha:0.95] forState:UIControlStateNormal];
        [self addTarget:self action:@selector(pressInput) forControlEvents:UIControlEventTouchDown|UIControlEventTouchDragEnter];
        [self addTarget:self action:@selector(releaseInput) forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside|UIControlEventTouchCancel|UIControlEventTouchDragExit];
    }
    return self;
}
- (void)setPressed:(BOOL)pressed {
    if (_pressed == pressed) return;
    _pressed = pressed;
    UIColor *color = pressed ? [UIColor colorWithRed:0.1 green:0.55 blue:0.65 alpha:0.8] : [UIColor colorWithWhite:0.13 alpha:0.64];
    if (_sector >= 0) _sectorLayer.fillColor = color.CGColor; else self.backgroundColor = color;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (void)setSector:(NSInteger)sector {
    _sector = sector; self.backgroundColor = UIColor.clearColor; self.layer.borderWidth = 0;
    if (!_sectorLayer) { _sectorLayer = [CAShapeLayer layer]; [self.layer insertSublayer:_sectorLayer atIndex:0]; }
    _sectorLayer.fillColor = [UIColor colorWithWhite:0.13 alpha:0.64].CGColor;
    _sectorLayer.strokeColor = [UIColor colorWithWhite:1 alpha:0.3].CGColor; _sectorLayer.lineWidth = 1;
    [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews]; if (_sector < 0) return;
    CGPoint center = CGPointMake(self.bounds.size.width/2,self.bounds.size.height/2);
    CGFloat angle = (_sector - 1) * M_PI_2, start = angle - M_PI_4 + 0.045, end = angle + M_PI_4 - 0.045;
    UIBezierPath *path = [UIBezierPath bezierPath];
    [path addArcWithCenter:center radius:104 startAngle:start endAngle:end clockwise:YES];
    [path addArcWithCenter:center radius:60 startAngle:end endAngle:start clockwise:NO]; [path closePath];
    _sectorPath = path; _sectorLayer.frame = self.bounds; _sectorLayer.path = path.CGPath;
    self.titleLabel.frame = CGRectMake(center.x+82*cos(angle)-26,center.y+82*sin(angle)-18,52,36);
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    if (_sector >= 0) return [_sectorPath containsPoint:point];
    return [super pointInside:point withEvent:event];
}
- (CGPoint)accessibilityActivationPoint {
    if (_sector < 0 || !self.window) return super.accessibilityActivationPoint;
    CGPoint point = [self convertPoint:self.titleLabel.center toView:self.window];
    return [self.window convertPoint:point toCoordinateSpace:self.window.screen.coordinateSpace];
}
- (void)pressInput { [self setPressed:YES]; }
- (void)releaseInput { [self setPressed:NO]; }
@end

@interface AKGamepadStick : UIControl
@property(nonatomic, copy) NSString *element;
@property(nonatomic, readonly) CGPoint position;
- (void)reset;
@end
@implementation AKGamepadStick { UIView *_knob; }
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.exclusiveTouch = NO;
        self.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.48];
        self.layer.borderWidth = 1; self.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.25].CGColor;
        _knob = [UIView new]; _knob.userInteractionEnabled = NO;
        _knob.backgroundColor = [UIColor colorWithWhite:0.8 alpha:0.55]; [self addSubview:_knob];
        self.isAccessibilityElement = YES;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews]; CGFloat diameter = MIN(self.bounds.size.width,self.bounds.size.height);
    self.layer.cornerRadius = diameter/2;
    _knob.bounds = CGRectMake(0,0,diameter*0.42,diameter*0.42); _knob.layer.cornerRadius = diameter*0.21;
    _knob.center = CGPointMake(self.bounds.size.width/2 + _position.x*diameter*0.27,
                               self.bounds.size.height/2 - _position.y*diameter*0.27);
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    return hypot(point.x-self.bounds.size.width/2,point.y-self.bounds.size.height/2) <= MIN(self.bounds.size.width,self.bounds.size.height)/2;
}
- (void)updatePosition:(CGPoint)position {
    if (CGPointEqualToPoint(_position,position)) return;
    _position = position; [self setNeedsLayout]; [self sendActionsForControlEvents:UIControlEventValueChanged];
}
- (BOOL)beginTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    (void)event; [self updatePosition:AKTouchGamepadStickPosition([touch locationInView:self],self.bounds.size)]; return YES;
}
- (BOOL)continueTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event {
    (void)event; [self updatePosition:AKTouchGamepadStickPosition([touch locationInView:self],self.bounds.size)]; return YES;
}
- (void)endTrackingWithTouch:(UITouch *)touch withEvent:(UIEvent *)event { (void)touch; (void)event; [self reset]; }
- (void)cancelTrackingWithEvent:(UIEvent *)event { (void)event; [self reset]; }
- (void)reset { [self updatePosition:CGPointZero]; }
@end

@interface AKGamepadOverlay : UIView
@property(nonatomic, readonly) NSDictionary<NSString *,AKGamepadButton *> *buttons;
@property(nonatomic, readonly) AKGamepadStick *leftStick;
@property(nonatomic, readonly) AKGamepadStick *rightStick;
- (void)reset;
@end
@implementation AKGamepadOverlay
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.multipleTouchEnabled = YES;
        // AppKit attaches the guest's rendering layer after creating its host.
        // Stay above that layer, below the cursor (100000) and toolbar (100001).
        self.layer.zPosition = 99999;
        NSArray *elements = @[GCInputButtonA,GCInputButtonB,GCInputButtonX,GCInputButtonY,
            GCInputLeftShoulder,GCInputLeftTrigger,GCInputRightTrigger,GCInputRightShoulder,
            GCInputButtonMenu,@"dpad.up",@"dpad.right",@"dpad.down",@"dpad.left"];
        NSArray *titles = @[@"A",@"B",@"X",@"Y",@"LB",@"LT",@"RT",@"RB",@"+",@"↑",@"→",@"↓",@"←"];
        NSMutableDictionary *buttons = [NSMutableDictionary new];
        for (NSUInteger i=0; i<elements.count; i++) {
            AKGamepadButton *button = [AKGamepadButton new]; button.element = elements[i];
            [button setTitle:titles[i] forState:UIControlStateNormal];
            button.accessibilityLabel = [@"Controller " stringByAppendingString:elements[i]];
            button.accessibilityIdentifier = [@"tolkara.gamepad." stringByAppendingString:elements[i]];
            buttons[elements[i]] = button; [self addSubview:button];
        }
        _buttons = buttons;
        _leftStick = [AKGamepadStick new]; _rightStick = [AKGamepadStick new];
        _leftStick.element = GCInputLeftThumbstick; _rightStick.element = GCInputRightThumbstick;
        _leftStick.accessibilityLabel = @"Controller left stick"; _rightStick.accessibilityLabel = @"Controller right stick";
        _leftStick.accessibilityIdentifier = @"tolkara.gamepad.leftStick"; _rightStick.accessibilityIdentifier = @"tolkara.gamepad.rightStick";
        [self addSubview:_leftStick]; [self addSubview:_rightStick];
    }
    return self;
}
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event]; return hit == self ? nil : hit;
}
- (void)layoutSubviews {
    [super layoutSubviews]; CGRect safe = UIEdgeInsetsInsetRect(self.bounds,self.safeAreaInsets);
    CGFloat left = CGRectGetMinX(safe)+6, right = CGRectGetMaxX(safe)-222;
    CGFloat bottom = CGRectGetMaxY(safe)-222, top = CGRectGetMinY(safe)+8;
    _leftStick.frame = CGRectMake(left+56,bottom+56,104,104);
    _rightStick.frame = CGRectMake(right+56,bottom+56,104,104);
    NSArray *leftNames = @[@"dpad.up",@"dpad.right",@"dpad.down",@"dpad.left"];
    NSArray *rightNames = @[GCInputButtonY,GCInputButtonB,GCInputButtonA,GCInputButtonX];
    for (NSUInteger i=0; i<4; i++) {
        AKGamepadButton *leftButton = _buttons[leftNames[i]], *rightButton = _buttons[rightNames[i]];
        if (leftButton.sector != (NSInteger)i) leftButton.sector = i;
        if (rightButton.sector != (NSInteger)i) rightButton.sector = i;
        leftButton.frame = CGRectMake(left,bottom,216,216); rightButton.frame = CGRectMake(right,bottom,216,216);
    }
    _buttons[GCInputLeftShoulder].frame = CGRectMake(left,top,56,44);
    _buttons[GCInputLeftTrigger].frame = CGRectMake(left+64,top,56,44);
    _buttons[GCInputRightTrigger].frame = CGRectMake(right+96,top,56,44);
    _buttons[GCInputRightShoulder].frame = CGRectMake(right+160,top,56,44);
    _buttons[GCInputButtonMenu].frame = CGRectMake(CGRectGetMidX(self.bounds)-22,bottom+168,44,44);
}
- (void)reset {
    for (AKGamepadButton *button in _buttons.allValues) [button releaseInput];
    [_leftStick reset]; [_rightStick reset];
}
@end

@implementation AKTouchGamepad {
    __weak UIView *_host;
    GCVirtualController *_virtualController;
    AKGamepadOverlay *_overlay;
    BOOL _active, _connecting, _cancelConnect, _failed, _invalidated;
}
- (instancetype)initWithHostView:(UIView *)host {
    if ((self = [super init])) {
        _host = host; _enabled = YES;
        _overlay = [[AKGamepadOverlay alloc] initWithFrame:host.bounds];
        _overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        _overlay.hidden = YES; [host addSubview:_overlay];
        for (AKGamepadButton *button in _overlay.buttons.allValues)
            [button addTarget:self action:@selector(buttonChanged:) forControlEvents:UIControlEventValueChanged];
        [_overlay.leftStick addTarget:self action:@selector(stickChanged:) forControlEvents:UIControlEventValueChanged];
        [_overlay.rightStick addTarget:self action:@selector(stickChanged:) forControlEvents:UIControlEventValueChanged];
        _active = UIApplication.sharedApplication.applicationState == UIApplicationStateActive;
        NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
        for (NSString *name in @[GCControllerDidConnectNotification, GCControllerDidDisconnectNotification,
                                 UIWindowDidBecomeKeyNotification, UIWindowDidResignKeyNotification,
                                 UIWindowDidBecomeVisibleNotification, UIWindowDidBecomeHiddenNotification])
            [center addObserver:self selector:@selector(environmentChanged:) name:name object:nil];
        [center addObserver:self selector:@selector(activate:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [center addObserver:self selector:@selector(deactivate:) name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}
- (NSArray<GCController *> *)connectedControllers { return GCController.controllers; }
- (GCVirtualController *)makeController {
    GCVirtualControllerConfiguration *configuration = [GCVirtualControllerConfiguration new];
    configuration.hidden = YES;
    // The configuration still applies the standard overlay's restrictions:
    // declaring D-pad plus left stick (or Menu/Options) throws even when hidden.
    // The connected extended profile provides D-pad and Menu nonetheless;
    // the public setters for both are covered by the real-controller fixture.
    configuration.elements = [NSSet setWithArray:@[GCInputLeftThumbstick,GCInputRightThumbstick,
        GCInputButtonA,GCInputButtonB,GCInputButtonX,GCInputButtonY,
        GCInputLeftShoulder,GCInputRightShoulder,GCInputLeftTrigger,GCInputRightTrigger]];
    return [[GCVirtualController alloc] initWithConfiguration:configuration];
}
- (BOOL)hostIsActive {
    UIWindow *window = _host.window;
    return _active && window.isKeyWindow && !window.hidden && !_host.hidden;
}
- (BOOL)hasPhysicalController {
    GCController *own = _virtualController.controller;
    for (GCController *controller in [self connectedControllers]) {
        // Snapshots are app-created state, not connected hardware. Our own
        // connection notification must not cause us to disconnect ourselves.
        if (controller != own && !controller.isSnapshot &&
            (controller.extendedGamepad || controller.microGamepad)) return YES;
    }
    return NO;
}
- (BOOL)wantsController {
    return !_invalidated && _enabled && !_keyboardVisible && [self hostIsActive];
}
- (void)setVisible:(BOOL)visible {
    if (_visible == visible) return;
    _visible = visible; _overlay.hidden = !visible;
    if (self.visibilityChanged) self.visibilityChanged(visible);
}
- (void)buttonChanged:(AKGamepadButton *)button {
    if (!_visible) return;
    if ([button.element hasPrefix:@"dpad."]) {
        CGPoint value = CGPointMake(_overlay.buttons[@"dpad.right"].pressed - _overlay.buttons[@"dpad.left"].pressed,
                                    _overlay.buttons[@"dpad.up"].pressed - _overlay.buttons[@"dpad.down"].pressed);
        [_virtualController setPosition:value forDirectionPadElement:GCInputDirectionPad];
    } else [_virtualController setValue:button.pressed ? 1 : 0 forButtonElement:button.element];
}
- (void)stickChanged:(AKGamepadStick *)stick {
    if (_visible) [_virtualController setPosition:stick.position forDirectionPadElement:stick.element];
}
- (void)disconnectController {
    GCVirtualController *controller = _virtualController;
    // Explicitly release our held controls before removing the virtual device.
    // No value or handler on a physical controller is changed.
    [_overlay reset];
    _virtualController = nil;
    [controller disconnect];
    [self setVisible:NO];
}
- (void)refresh {
    NSAssert(NSThread.isMainThread, @"Touch controller lifecycle belongs on the main thread");
    if (_connecting) {
        // Wait for this attempt's reply before starting another one. A late
        // successful connect must not bring controls back after suspension.
        if (![self wantsController]) { _cancelConnect = YES; [_virtualController disconnect]; }
        return;
    }
    if (![self wantsController] || [self hasPhysicalController]) {
        [self disconnectController]; return;
    }
    if (_virtualController || _failed) return;
    _virtualController = [self makeController];
    _connecting = YES; _cancelConnect = NO;
    GCVirtualController *connecting = _virtualController;
    __weak AKTouchGamepad *weakSelf = self;
    [connecting connectWithReplyHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            AKTouchGamepad *self = weakSelf;
            if (!self) { [connecting disconnect]; return; }
            self->_connecting = NO;
            BOOL cancelled = self->_cancelConnect;
            self->_cancelConnect = NO;
            if (error || cancelled || ![self wantsController] || [self hasPhysicalController]) {
                if (error) NSLog(@"[TouchGamepad] Connection failed: %@ (%ld)",error.domain,(long)error.code);
                self->_failed = error != nil;
                [self disconnectController];
                if (cancelled && !error) [self refresh];
                return;
            }
            [self setVisible:YES];
        });
    }];
}
- (void)environmentChanged:(NSNotification *)note {
    (void)note;
    // GC notifications can precede connect's reply or arrive off-main. Defer
    // enumeration until the system finishes the connection transaction.
    __weak AKTouchGamepad *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refresh]; });
}
- (void)activate:(NSNotification *)note {
    (void)note; _active = YES; _failed = NO; [self refresh];
}
- (void)deactivate:(NSNotification *)note {
    (void)note; _active = NO; [self refresh];
}
- (void)setEnabled:(BOOL)enabled {
    _enabled = enabled; _failed = NO; [self refresh];
}
- (void)setKeyboardVisible:(BOOL)visible {
    _keyboardVisible = visible; [self refresh];
}
- (void)invalidate {
    _invalidated = YES;
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self refresh];
    [_overlay removeFromSuperview];
}
- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_virtualController disconnect];
}
@end
