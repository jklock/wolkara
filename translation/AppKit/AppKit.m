#import "AppKit.h"
#import "Images.h"
#import "TextInput.h"
#import <GameController/GameController.h>
#import <objc/runtime.h>

NSApplication *NSApp;

#pragma mark - NSResponder

@implementation NSResponder
- (void)interpretKeyEvents:(NSArray<NSEvent *> *)events {
    for(NSEvent *event in events) if(event.type==NSEventTypeKeyDown) AKInterpretTextKey(self,event.characters,event.keyCode,event.modifierFlags);
}
- (void)insertText:(id)text { [self.nextResponder insertText:text]; }
- (void)doCommandBySelector:(SEL)selector {
    if([self respondsToSelector:selector]) ((void (*)(id,SEL,id))[self methodForSelector:selector])(self,selector,nil);
    else [self.nextResponder doCommandBySelector:selector];
}
- (BOOL)acceptsFirstResponder { return NO; }
- (BOOL)becomeFirstResponder { return YES; }
- (BOOL)resignFirstResponder { return YES; }
#define PASS(sel) - (void)sel(NSEvent *)e { [self.nextResponder sel e]; }
PASS(keyDown:) PASS(keyUp:) PASS(flagsChanged:) PASS(mouseDown:) PASS(mouseUp:) PASS(mouseMoved:)
PASS(mouseDragged:) PASS(rightMouseDown:) PASS(rightMouseUp:) PASS(rightMouseDragged:) PASS(scrollWheel:)
@end

@implementation NSEvent
- (NSString *)description { return [NSString stringWithFormat:@"<NSEvent type=%lu loc=%@ key=%d>", (unsigned long)_type, NSStringFromCGPoint(_locationInWindow), _keyCode]; }
@end

#pragma mark - NSView

@implementation NSView { NSMutableArray<NSView *> *_subviews; NSMutableArray<NSDictionary *> *_cursorRects; __weak NSView *_superview; }
- (instancetype)init { return [self initWithFrame:CGRectZero]; }
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super init])) { _frame = frame; _bounds = (CGRect){CGPointZero, frame.size}; _subviews = [NSMutableArray new]; _cursorRects=[NSMutableArray new]; }
    return self;
}
- (CALayer *)makeBackingLayer { return [CALayer layer]; }
- (void)setWantsLayer:(BOOL)w {
    _wantsLayer = w;
    if (w && !_layer) { self.layer = [self makeBackingLayer]; }
}
- (void)setLayer:(CALayer *)l {
    _layer = l;
    l.frame = _frame; l.delegate = nil;
}
- (void)setFrame:(NSRect)f {
    _frame = f; _bounds.size = f.size;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _layer.frame = f;
    [CATransaction commit];
}
- (void)setFrameSize:(NSSize)s { self.frame = (CGRect){_frame.origin, s}; }
- (NSView *)superview { return _superview; }
- (NSArray<NSView *> *)subviews { return [_subviews copy]; }
- (void)addSubview:(NSView *)v {
    [v removeFromSuperview];
    [_subviews addObject:v]; v->_superview = self; v.nextResponder = self; v.window = _window;
    if (!_layer) self.wantsLayer = YES;
    if (!v.layer) v.wantsLayer = YES;
    [_layer addSublayer:v.layer];
}
- (void)removeFromSuperview {
    [_layer removeFromSuperlayer];
    if (_superview) [_superview->_subviews removeObject:self]; _superview = nil;
}
- (void)setWindow:(NSWindow *)w {
    _window = w;
    for (NSView *v in _subviews) v.window = w;
    [self viewDidMoveToWindow];
}
- (void)viewDidMoveToWindow {}
- (void)discardCursorRects { [_cursorRects removeAllObjects]; }
- (void)resetCursorRects { [self discardCursorRects]; }
- (void)addCursorRect:(NSRect)rect cursor:(NSCursor *)cursor { if(cursor) [_cursorRects addObject:@{@"rect":[NSValue valueWithCGRect:rect],@"cursor":cursor}]; }
- (NSCursor *)ak_cursorAtPoint:(NSPoint)point {
    for(NSDictionary *entry in _cursorRects.reverseObjectEnumerator) if(CGRectContainsPoint([entry[@"rect"] CGRectValue],point)) return entry[@"cursor"];
    return nil;
}
- (NSPoint)convertPointToBacking:(NSPoint)p { NSSize s=[self convertSizeToBacking:CGSizeMake(p.x,p.y)]; return CGPointMake(s.width,s.height); }
- (NSPoint)convertPointFromBacking:(NSPoint)p { NSSize s=[self convertSizeFromBacking:CGSizeMake(p.x,p.y)]; return CGPointMake(s.width,s.height); }
- (NSSize)convertSizeFromBacking:(NSSize)s { CGFloat f = self.window.backingScaleFactor ?: UIScreen.mainScreen.nativeScale; return CGSizeMake(s.width/f,s.height/f); }
- (NSSize)convertSizeToBacking:(NSSize)s { CGFloat f = self.window.backingScaleFactor ?: UIScreen.mainScreen.nativeScale; return CGSizeMake(s.width*f,s.height*f); }
- (NSRect)convertRectFromBacking:(NSRect)r { NSSize p=[self convertSizeFromBacking:(NSSize){r.origin.x,r.origin.y}]; return (NSRect){{p.width,p.height},[self convertSizeFromBacking:r.size]}; }
- (NSRect)convertRectToBacking:(NSRect)r { NSSize p=[self convertSizeToBacking:(NSSize){r.origin.x,r.origin.y}]; return (NSRect){{p.width,p.height},[self convertSizeToBacking:r.size]}; }
- (NSPoint)ak_originInWindow { NSPoint o = _frame.origin; for (NSView *v = _superview; v; v = v->_superview) { o.x += v->_frame.origin.x; o.y += v->_frame.origin.y; } return o; }
- (NSPoint)convertPoint:(NSPoint)p fromView:(NSView *)v {
    NSPoint a = [self ak_originInWindow], b = v ? [v ak_originInWindow] : CGPointZero;
    return CGPointMake(p.x + b.x - a.x, p.y + b.y - a.y);
}
- (NSPoint)convertPoint:(NSPoint)p toView:(NSView *)v {
    NSPoint a = [self ak_originInWindow], b = v ? [v ak_originInWindow] : CGPointZero;
    return CGPointMake(p.x + a.x - b.x, p.y + a.y - b.y);
}
@end

#pragma mark - UIKit host side

// HID usage -> macOS virtual key code (kVK_*). 0xFF = unmapped.
static unsigned short AKKeyCode(UIKeyboardHIDUsage u) {
    static const unsigned char letters[26] = {0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6};
    static const unsigned char digits[10] = {18,19,20,21,23,22,26,28,25,29};
    static const unsigned char fkeys[12] = {122,120,99,118,96,97,98,100,101,109,103,111};
    if (u >= 0x04 && u <= 0x1D) return letters[u - 0x04];
    if (u >= 0x1E && u <= 0x27) return digits[u - 0x1E];
    if (u >= 0x3A && u <= 0x45) return fkeys[u - 0x3A];
    switch ((int)u) {
        case 0x28: return 36; case 0x29: return 53; case 0x2A: return 51; case 0x2B: return 48; case 0x2C: return 49;
        case 0x2D: return 27; case 0x2E: return 24; case 0x2F: return 33; case 0x30: return 30; case 0x31: return 42;
        case 0x33: return 41; case 0x34: return 39; case 0x35: return 50; case 0x36: return 43; case 0x37: return 47;
        case 0x38: return 44; case 0x39: return 57; case 0x4A: return 115; case 0x4B: return 116; case 0x4C: return 117;
        case 0x4D: return 119; case 0x4E: return 121; case 0x4F: return 124; case 0x50: return 123; case 0x51: return 125;
        case 0x52: return 126; case 0xE0: return 59; case 0xE1: return 56; case 0xE2: return 58; case 0xE3: return 55;
        case 0xE4: return 62; case 0xE5: return 60; case 0xE6: return 61; case 0xE7: return 54;
    }
    return 0xFF;
}

static NSEventModifierFlags AKMods(UIKeyModifierFlags f) {
    NSEventModifierFlags m = 0;
    if (f & UIKeyModifierAlphaShift) m |= NSEventModifierFlagCapsLock;
    if (f & UIKeyModifierShift) m |= NSEventModifierFlagShift;
    if (f & UIKeyModifierControl) m |= NSEventModifierFlagControl;
    if (f & UIKeyModifierAlternate) m |= NSEventModifierFlagOption;
    if (f & UIKeyModifierCommand) m |= NSEventModifierFlagCommand;
    return m;
}

@interface AKHostView : UIView <UIPointerInteractionDelegate>
@property (weak) NSWindow *nsWindow;
@end

@implementation AKHostView { CGPoint _last; NSEventModifierFlags _mods; BOOL _pressedRight, _pressedLeft, _pointerInside, _softwareCursor; UIImageView *_cursorView; UIPointerInteraction *_pointer; UIPointerStyle *_gamePointerStyle; unsigned _hoverUpdates, _pointerUpdates, _cursorVisibilityReasons; NSTimeInterval _pointerReportTime; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        self.multipleTouchEnabled = NO;
        _softwareCursor=[NSProcessInfo.processInfo.arguments containsObject:@"--software-cursor"];
        AKLog(@"cursor presentation=%@",_softwareCursor?@"software overlay":@"native iPad pointer");
        _cursorView=[UIImageView new]; _cursorView.userInteractionEnabled=NO;
        _cursorView.layer.zPosition=100000; _cursorView.hidden=YES; [self addSubview:_cursorView];
        _pointer=[[UIPointerInteraction alloc] initWithDelegate:self]; [self addInteraction:_pointer];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(cursorChanged:) name:@"AKCursorDidChange" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(captureChanged:) name:@"AKMouseCaptureDidChange" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(anchorChanged:) name:@"AKMouseAnchorChanged" object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(mouseConnected:) name:GCMouseDidConnectNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(captureChanged:) name:GCMouseDidDisconnectNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(lockChanged:) name:UIPointerLockStateDidChangeNotification object:nil];
        for(GCMouse *mouse in GCMouse.mice)[self installMouse:mouse];
        [self addGestureRecognizer:[[UIHoverGestureRecognizer alloc] initWithTarget:self action:@selector(hover:)]];
    }
    return self;
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (void)layoutSubviews { [super layoutSubviews]; [self.nsWindow ak_hostBoundsChanged:self.bounds]; }
- (BOOL)usesRelativeMouse { return AKMouseIsCaptured() && GCMouse.mice.count>0; }
- (void)captureChanged:(NSNotification *)notification {
    (void)notification;
    if(!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{[self captureChanged:nil];});return; }
    [self.window.rootViewController setNeedsUpdateOfPrefersPointerLocked];
    AKLog(@"mouse capture requested=%d raw_devices=%lu",AKMouseIsCaptured(),(unsigned long)GCMouse.mice.count);
}
- (void)lockChanged:(NSNotification *)notification { (void)notification; AKLog(@"pointer lock active=%d",self.window.windowScene.pointerLockState.locked); }
- (void)anchorChanged:(NSNotification *)notification {
    if(!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{[self anchorChanged:notification];});return; }
    _last=CGPointMake([notification.userInfo[@"x"] doubleValue],[notification.userInfo[@"y"] doubleValue]);
    self.nsWindow.ak_mouseLocation=CGPointMake(_last.x,self.bounds.size.height-_last.y);
}
- (void)mouseConnected:(NSNotification *)notification { [self installMouse:notification.object]; [self captureChanged:nil]; }
- (void)installMouse:(GCMouse *)mouse {
    mouse.handlerQueue=dispatch_get_main_queue();
    __weak AKHostView *weakSelf=self;
    mouse.mouseInput.mouseMovedHandler=^(GCMouseInput *input,float dx,float dy) {
        (void)input; AKHostView *view=weakSelf;
        if(!view || !view.window.isKeyWindow || ![view usesRelativeMouse])return;
        NSEvent *event=[NSEvent new];event.window=view.nsWindow;event.modifierFlags=view->_mods;
        event.type=view->_pressedRight?NSEventTypeRightMouseDragged:view->_pressedLeft?NSEventTypeLeftMouseDragged:NSEventTypeMouseMoved;
        event.buttonNumber=view->_pressedRight?1:0;event.locationInWindow=view.nsWindow.ak_mouseLocation;
        event.deltaX=dx;event.deltaY=-dy;event.timestamp=NSProcessInfo.processInfo.systemUptime;
        [NSApp postEvent:event atStart:NO];
    };
    mouse.mouseInput.leftButton.pressedChangedHandler=^(GCControllerButtonInput *button,float value,BOOL pressed) { (void)button;(void)value;[weakSelf rawButton:0 pressed:pressed]; };
    mouse.mouseInput.rightButton.pressedChangedHandler=^(GCControllerButtonInput *button,float value,BOOL pressed) { (void)button;(void)value;[weakSelf rawButton:1 pressed:pressed]; };
    mouse.mouseInput.scroll.valueChangedHandler=^(GCControllerDirectionPad *pad,float x,float y) {
        (void)pad;AKHostView *view=weakSelf;if(!view || !view.window.isKeyWindow)return;
        NSEvent *event=[NSEvent new];event.window=view.nsWindow;event.type=NSEventTypeScrollWheel;
        event.locationInWindow=view.nsWindow.ak_mouseLocation;event.modifierFlags=view->_mods;
        event.deltaX=event.scrollingDeltaX=x;event.deltaY=event.scrollingDeltaY=y;
        event.timestamp=NSProcessInfo.processInfo.systemUptime;[NSApp postEvent:event atStart:NO];
    };
    AKLog(@"raw mouse input installed");
}
- (void)rawButton:(NSInteger)button pressed:(BOOL)pressed {
    if(!self.window.isKeyWindow)return;
    BOOL previous=button?_pressedRight:_pressedLeft;
    if(previous==pressed || (pressed && ![self usesRelativeMouse]))return;
    NSEventType type=button?(pressed?NSEventTypeRightMouseDown:NSEventTypeRightMouseUp):(pressed?NSEventTypeLeftMouseDown:NSEventTypeLeftMouseUp);
    [self postMouse:type at:_last button:button];
}

- (void)postMouse:(NSEventType)t at:(CGPoint)p button:(NSInteger)b {
    if(t==NSEventTypeLeftMouseDown)_pressedLeft=YES;
    if(t==NSEventTypeLeftMouseUp)_pressedLeft=NO;
    if(t==NSEventTypeRightMouseDown)_pressedRight=YES;
    if(t==NSEventTypeRightMouseUp)_pressedRight=NO;
    NSEvent *e = [NSEvent new];
    e.type = t; e.window = self.nsWindow; e.modifierFlags = _mods; e.buttonNumber = b; e.clickCount = 1;
    e.timestamp = NSProcessInfo.processInfo.systemUptime;
    e.locationInWindow = CGPointMake(p.x, self.bounds.size.height - p.y); self.nsWindow.ak_mouseLocation=e.locationInWindow;   // AppKit: bottom-left origin
    e.deltaX = p.x - _last.x; e.deltaY = p.y - _last.y; _last = p;
    NSView *view=self.nsWindow.contentView;
    NSCursor *cursor=[view ak_cursorAtPoint:[view convertPoint:e.locationInWindow fromView:nil]];
    if(cursor && cursor!=NSCursor.currentCursor) [cursor set];
    [self positionCursor];
    static unsigned loggedMouse; if(loggedMouse<8 && t!=NSEventTypeMouseMoved) { loggedMouse++; AKLog(@"mouse event type=%lu point=(%g,%g)",(unsigned long)t,e.locationInWindow.x,e.locationInWindow.y); }
    [NSApp postEvent:e atStart:NO];
}
- (void)cursorChanged:(NSNotification *)notification {
    (void)notification;
    if(!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{ [self cursorChanged:nil]; }); return; }
    NSCursor *cursor=NSCursor.currentCursor;
    CGImageRef image=[cursor.image CGImageForProposedRect:NULL context:nil hints:nil];
    _cursorView.image=_softwareCursor && image ? [UIImage imageWithCGImage:image] : nil;
    _gamePointerStyle=nil;
    if(!_softwareCursor && image) {
        CGPathRef path=AKCreateCursorPath(image,cursor.image.size,cursor.hotSpot);
        if(path) {
            _gamePointerStyle=[UIPointerStyle styleWithShape:[UIPointerShape shapeWithPath:[UIBezierPath bezierPathWithCGPath:path]] constrainedAxes:UIAxisNeither];
            CGPathRelease(path);
        }
    }
    _cursorView.bounds=(CGRect){CGPointZero,cursor.image.size};
    [self positionCursor]; [_pointer invalidate];
}
- (void)positionCursor {
    NSCursor *cursor=NSCursor.currentCursor;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _cursorView.frame=(CGRect){CGPointMake(_last.x-cursor.hotSpot.x,_last.y-cursor.hotSpot.y),cursor.image.size};
    unsigned reasons=(!_pointerInside?1:0) | (AKCursorIsHidden()?2:0) | (!_cursorView.image?4:0);
    _cursorView.hidden=!_softwareCursor || reasons!=0;
    if(reasons!=_cursorVisibilityReasons) { _cursorVisibilityReasons=reasons; AKLog(@"cursor visibility hidden=%d outside=%d game_hidden=%d no_image=%d",reasons!=0,!!(reasons&1),!!(reasons&2),!!(reasons&4)); }
    [CATransaction commit];
    // The desktop client owns a nested event loop. UIKit's outer-loop commit
    // can wait until pointer tracking ends; publish each cursor update now.
    [CATransaction flush];
}
- (UIPointerStyle *)pointerInteraction:(UIPointerInteraction *)interaction styleForRegion:(UIPointerRegion *)region {
    (void)interaction; (void)region;
    if(AKCursorIsHidden())return UIPointerStyle.hiddenPointerStyle;
    if(_softwareCursor && NSCursor.currentCursor.image)return UIPointerStyle.hiddenPointerStyle;
    return _gamePointerStyle ?: UIPointerStyle.systemPointerStyle;
}
- (UIPointerRegion *)pointerInteraction:(UIPointerInteraction *)interaction regionForRequest:(UIPointerRegionRequest *)request defaultRegion:(UIPointerRegion *)defaultRegion {
    (void)interaction;
    // UIKit requests a region as the hardware pointer moves. Feed this direct
    // location into the desktop bridge as well as the hover recognizer, whose
    // recognition can be deferred by the client's nested event loop.
    _pointerUpdates++;
    _mods=AKMods(request.modifiers);
    [self moveHoverTo:request.location inside:YES];
    return defaultRegion;
}
- (void)moveHoverTo:(CGPoint)point inside:(BOOL)inside {
    if([self usesRelativeMouse])return;
    BOOL changed=_pointerInside!=inside || !CGPointEqualToPoint(_last,point);
    _pointerInside=inside;
    if(changed) [self postMouse:_pressedRight?NSEventTypeRightMouseDragged:_pressedLeft?NSEventTypeLeftMouseDragged:NSEventTypeMouseMoved at:point button:_pressedRight?1:0];
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(now-_pointerReportTime>=2) {
        // Counts only: no keys, text, screen contents or pointer coordinates.
        AKLog(@"pointer delivery hover=%u region=%u",_hoverUpdates,_pointerUpdates);
        _hoverUpdates=0; _pointerUpdates=0; _pointerReportTime=now;
    }
}
- (void)hover:(UIHoverGestureRecognizer *)g {
    _hoverUpdates++;
    CGPoint point=[g locationInView:self];
    // A cancelled recognizer does not establish that the hardware pointer left
    // the window. Keep visibility tied to its actual in-window location.
    [self moveHoverTo:point inside:CGRectContainsPoint(self.bounds,point)];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
static BOOL AKIsRight(UIEvent *ev) { return (ev.buttonMask & UIEventButtonMaskSecondary) != 0; }
- (void)touchesBegan:(NSSet<UITouch *> *)t withEvent:(UIEvent *)ev {
    BOOL r = AKIsRight(ev);if(r?_pressedRight:_pressedLeft)return; _last = [t.anyObject locationInView:self];
    [self postMouse:r ? NSEventTypeRightMouseDown : NSEventTypeLeftMouseDown at:_last button:r];
}
- (void)touchesMoved:(NSSet<UITouch *> *)t withEvent:(UIEvent *)ev {
    if([self usesRelativeMouse])return;
    BOOL r = _pressedRight;
    CGPoint point=[t.anyObject locationInView:self];if(CGPointEqualToPoint(point,_last))return;
    [self postMouse:r ? NSEventTypeRightMouseDragged : NSEventTypeLeftMouseDragged at:point button:r];
}
- (void)touchesEnded:(NSSet<UITouch *> *)t withEvent:(UIEvent *)ev {
    if(!_pressedRight && !_pressedLeft)return;
    [self postMouse:_pressedRight ? NSEventTypeRightMouseUp : NSEventTypeLeftMouseUp at:[self usesRelativeMouse]?_last:[t.anyObject locationInView:self] button:_pressedRight];
}
- (void)touchesCancelled:(NSSet<UITouch *> *)t withEvent:(UIEvent *)ev { [self touchesEnded:t withEvent:ev]; }

- (void)postKeys:(NSSet<UIPress *> *)presses down:(BOOL)down {
    for (UIPress *p in presses) {
        UIKey *k = p.key; if (!k) continue;
        NSEvent *e = [NSEvent new];
        e.window = self.nsWindow; e.keyCode = AKKeyCode(k.keyCode); e.timestamp = p.timestamp;
        e.modifierFlags = _mods = AKMods(k.modifierFlags);
        BOOL isMod = k.keyCode >= 0xE0 && k.keyCode <= 0xE7;
        e.type = isMod || k.keyCode == 0x39 ? NSEventTypeFlagsChanged : down ? NSEventTypeKeyDown : NSEventTypeKeyUp;
        e.characters = k.characters; e.charactersIgnoringModifiers = k.charactersIgnoringModifiers;
        static unsigned loggedKeys; if(loggedKeys<8) { loggedKeys++; AKLog(@"keyboard event type=%lu",(unsigned long)e.type); }
        [NSApp postEvent:e atStart:NO];
    }
}
- (void)pressesBegan:(NSSet<UIPress *> *)p withEvent:(UIPressesEvent *)e { [self postKeys:p down:YES]; }
- (void)pressesEnded:(NSSet<UIPress *> *)p withEvent:(UIPressesEvent *)e { [self postKeys:p down:NO]; }
- (void)pressesCancelled:(NSSet<UIPress *> *)p withEvent:(UIPressesEvent *)e { [self postKeys:p down:NO]; }
@end

@interface AKHostViewController : UIViewController
@end
@implementation AKHostViewController
- (void)loadView { self.view = [[AKHostView alloc] initWithFrame:UIScreen.mainScreen.bounds]; self.view.backgroundColor = UIColor.blackColor; }
- (BOOL)prefersStatusBarHidden { return YES; }
// Ask UIKit to require a deliberate repeat of edge gestures while gaming.
// This is an immersive preference, not a device-wide kiosk lock.
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (BOOL)prefersPointerLocked { return AKMouseIsCaptured() && GCMouse.mice.count>0; }
- (void)viewDidAppear:(BOOL)a { [super viewDidAppear:a]; [self.view becomeFirstResponder]; }
@end

#pragma mark - NSWindow

static void logLayer(CALayer *layer,unsigned depth) {
    if(depth>5) return;
    AKLog(@"layer depth=%u ptr=%p class=%@ frame=%@ bounds=%@ hidden=%d opacity=%g super=%p",depth,layer,NSStringFromClass(layer.class),NSStringFromCGRect(layer.frame),NSStringFromCGRect(layer.bounds),layer.hidden,layer.opacity,layer.superlayer);
    for(CALayer *child in layer.sublayers) logLayer(child,depth+1);
}
@implementation NSWindow { UIWindow *_uiWindow; AKHostView *_host; NSRect _contentRect; NSResponder *_firstResponder; }
- (instancetype)initWithContentRect:(NSRect)r styleMask:(NSUInteger)m backing:(NSUInteger)b defer:(BOOL)d {
    if ((self = [super init])) { _contentRect = r; _styleMask=m; self.nextResponder = NSApp; }
    return self;
}
- (instancetype)initWithContentRect:(NSRect)r styleMask:(NSUInteger)m backing:(NSUInteger)b defer:(BOOL)d screen:(id)s {
    return [self initWithContentRect:r styleMask:m backing:b defer:d];
}
- (id)screen { return NSScreen.mainScreen; }
- (BOOL)isMiniaturized { return NO; }
- (void)invalidateCursorRectsForView:(NSView *)view { [view discardCursorRects]; [view resetCursorRects]; }
- (void)setContentSize:(NSSize)size { _contentRect.size=size; [_contentView setFrameSize:size]; }
- (void)setFrame:(NSRect)frame display:(BOOL)display animate:(BOOL)animate {
    (void)display; (void)animate;
    _contentRect=frame;
    // UIKit owns the scene's available geometry. Translate desktop sizing into
    // that viewport, and notify the guest of the actual content dimensions.
    if(_host) [self ak_hostBoundsChanged:_host.bounds];
    else _contentView.frame=(NSRect){CGPointZero,frame.size};
}
- (void)setFrame:(NSRect)frame display:(BOOL)display { [self setFrame:frame display:display animate:NO]; }
- (NSRect)frame { return _host ? (CGRect){CGPointZero, _host.bounds.size} : _contentRect; }
- (CGFloat)backingScaleFactor { return (_uiWindow.screen ?: UIScreen.mainScreen).nativeScale; }
- (BOOL)isKeyWindow { return _uiWindow.isKeyWindow; }
- (BOOL)isVisible { return _uiWindow && !_uiWindow.hidden; }
- (NSUInteger)occlusionState { return self.isVisible && _uiWindow.windowScene.activationState!=UISceneActivationStateBackground ? 2 : 0; }
- (NSPoint)mouseLocationOutsideOfEventStream { return _ak_mouseLocation; }
- (NSResponder *)firstResponder { return _firstResponder ?: self; }
- (BOOL)makeFirstResponder:(NSResponder *)r {
    if (r && ![r acceptsFirstResponder]) return NO;
    [_firstResponder resignFirstResponder];
    _firstResponder = r; [r becomeFirstResponder];
    return YES;
}
- (void)setContentView:(NSView *)v {
    [_contentView.layer removeFromSuperlayer];
    _contentView = v; v.window = self; v.nextResponder = self;
    if (!v.layer) v.wantsLayer = YES;
    if (_host) [self ak_attach];
}
- (void)ak_attach {
    [_host.layer addSublayer:_contentView.layer];
    [self ak_hostBoundsChanged:_host.bounds];
}
- (void)ak_hostBoundsChanged:(CGRect)b {
    if (CGSizeEqualToSize(b.size, CGSizeZero)) return;
    _contentView.layer.contentsScale = self.backingScaleFactor;
    BOOL resized = !CGSizeEqualToSize(_contentView.frame.size, b.size);
    _contentView.frame = b;
    if (resized) {
        AKLog(@"window content size -> %.0fx%.0f @%.0fx", b.size.width, b.size.height, self.backingScaleFactor);
        if ([_delegate respondsToSelector:@selector(windowDidResize:)])
            [_delegate performSelector:@selector(windowDidResize:) withObject:[NSNotification notificationWithName:@"NSWindowDidResizeNotification" object:self]];
        [NSNotificationCenter.defaultCenter postNotificationName:@"NSWindowDidResizeNotification" object:self];
    }
}
- (void)makeKeyAndOrderFront:(id)sender {
    BOOL wasKey=self.keyWindow;
    if (!_uiWindow) {
        UIWindowScene *scene = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
            if ([s isKindOfClass:UIWindowScene.class]) { scene = (UIWindowScene *)s; break; }
        if (!scene) { AKLog(@"makeKeyAndOrderFront: no UIWindowScene connected"); return; }
        _uiWindow = [[UIWindow alloc] initWithWindowScene:scene];
        AKHostViewController *vc = [AKHostViewController new];
        _uiWindow.rootViewController = vc;
        _host = (AKHostView *)vc.view; _host.nsWindow = self;
        if (_contentView) [self ak_attach];
    }
    [_uiWindow makeKeyAndVisible];
    [_host cursorChanged:nil];
    if (![NSApp.windows containsObject:self]) [(NSMutableArray *)NSApp.windows addObject:self];
    if(!wasKey && self.keyWindow) {
        [self ak_notify:@"NSWindowDidBecomeKeyNotification" selector:@selector(windowDidBecomeKey:)];
        [self ak_notify:@"NSWindowDidBecomeMainNotification" selector:@selector(windowDidBecomeMain:)];
        [NSApp activateIgnoringOtherApps:YES];
    }
    AKLog(@"window '%@' on screen", self.title);
}
- (void)ak_notify:(NSString *)name selector:(SEL)selector {
    NSNotification *notification=[NSNotification notificationWithName:name object:self];
    if([_delegate respondsToSelector:selector]) ((void (*)(id,SEL,id))[_delegate methodForSelector:selector])(_delegate,selector,notification);
    [NSNotificationCenter.defaultCenter postNotification:notification];
}
- (void)ak_logLayers {
    AKLog(@"window diagnostic visible=%d key=%d scene=%ld view=%p viewLayer=%p",self.visible,self.keyWindow,(long)_uiWindow.windowScene.activationState,_contentView,_contentView.layer);
    for(UIWindow *window in _uiWindow.windowScene.windows) AKLog(@"UIKit window %@ hidden=%d key=%d level=%g root=%@",window,window.hidden,window.keyWindow,window.windowLevel,window.rootViewController);
    logLayer(_uiWindow.layer,0);
}
- (void)orderFront:(id)s { [self makeKeyAndOrderFront:s]; }
- (void)orderOut:(id)sender { _uiWindow.hidden = YES; }
- (void)close { [self orderOut:nil]; [(NSMutableArray *)NSApp.windows removeObject:self]; }
- (void)sendEvent:(NSEvent *)e {
    switch (e.type) {
        case NSEventTypeKeyDown: [self.firstResponder keyDown:e]; break;
        case NSEventTypeKeyUp: [self.firstResponder keyUp:e]; break;
        case NSEventTypeFlagsChanged: [self.firstResponder flagsChanged:e]; break;
        // Single full-window content view for now; hit-testing of subviews comes with the first guest that needs it.
        case NSEventTypeLeftMouseDown: [_contentView mouseDown:e]; break;
        case NSEventTypeLeftMouseUp: [_contentView mouseUp:e]; break;
        case NSEventTypeLeftMouseDragged: [_contentView mouseDragged:e]; break;
        case NSEventTypeRightMouseDragged: [_contentView rightMouseDragged:e]; break;
        case NSEventTypeRightMouseDown: [_contentView rightMouseDown:e]; break;
        case NSEventTypeRightMouseUp: [_contentView rightMouseUp:e]; break;
        case NSEventTypeMouseMoved: if (_acceptsMouseMovedEvents) [self.firstResponder mouseMoved:e]; break;
        case NSEventTypeScrollWheel: [_contentView scrollWheel:e]; break;
    }
}
@end

#pragma mark - NSApplication

@implementation NSApplication { NSMutableArray<NSEvent *> *_queue; NSMutableArray<NSWindow *> *_windows; NSEvent *_currentEvent; BOOL _launched, _inRun, _active, _terminating, _terminationPending, _terminationApproved; }
+ (NSApplication *)sharedApplication {
    if (NSApp) return NSApp; // Super init publishes the singleton before subclass init callbacks.
    static dispatch_once_t once;
    dispatch_once(&once, ^{ NSApp = [self new]; });
    return NSApp;
}
- (instancetype)init {
    if ((self = [super init])) {
        NSApp=self; _queue = [NSMutableArray new]; _windows = [NSMutableArray new];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ak_becameActive:) name:UIApplicationDidBecomeActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(ak_resignedActive:) name:UIApplicationWillResignActiveNotification object:nil];
    }
    return self;
}
- (NSArray<NSWindow *> *)windows { return _windows; }
- (NSEvent *)currentEvent { return _currentEvent; }
- (NSWindow *)keyWindow { return _windows.lastObject; }
- (NSWindow *)mainWindow { return _windows.lastObject; }
- (BOOL)setActivationPolicy:(NSInteger)p { return YES; }
- (BOOL)isActive { return _active; }
- (void)ak_becameActive:(NSNotification *)notification {
    (void)notification;
    if(!_active) { _active=YES; AKLog(@"application became active"); [self ak_notify:@"NSApplicationDidBecomeActiveNotification" sel:@selector(applicationDidBecomeActive:)]; }
}
- (void)ak_resignedActive:(NSNotification *)notification {
    (void)notification;
    if(_active) { _active=NO; [self ak_notify:@"NSApplicationDidResignActiveNotification" sel:@selector(applicationDidResignActive:)]; }
}
- (void)activateIgnoringOtherApps:(BOOL)f { (void)f; if(UIApplication.sharedApplication.applicationState==UIApplicationStateActive) [self ak_becameActive:nil]; }
- (void)ak_notify:(NSString *)name sel:(SEL)sel {
    NSNotification *n = [NSNotification notificationWithName:name object:self];
    if ([_delegate respondsToSelector:sel]) ((void (*)(id, SEL, id))[_delegate methodForSelector:sel])(_delegate, sel, n);
    [NSNotificationCenter.defaultCenter postNotification:n];
}
- (void)finishLaunching {
    if (_launched) return; _launched = YES;
    [self ak_notify:@"NSApplicationWillFinishLaunchingNotification" sel:@selector(applicationWillFinishLaunching:)];
    [self ak_notify:@"NSApplicationDidFinishLaunchingNotification" sel:@selector(applicationDidFinishLaunching:)];
}
// The guest calls this from its main(), which the host entered from a run loop
// timer callout on the UIKit main thread. We never return; we pump the same
// run loop re-entrantly, which keeps UIKit, CADisplayLink, timers and the main
// dispatch queue alive underneath the guest's stack frame.
- (void)run {
    [self finishLaunching];
    _running = YES; _inRun = YES;
    AKLog(@"-[NSApplication run]: pumping main run loop re-entrantly");
    while (_running) {
        @autoreleasepool {
            [NSRunLoop.currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:NSDate.distantFuture];
            [self ak_drain];
        }
    }
    _inRun = NO;
}
- (void)ak_drain { while (_queue.count) { NSEvent *e = _queue.firstObject; [_queue removeObjectAtIndex:0]; _currentEvent=e; [self sendEvent:e]; } }
- (void)stop:(id)sender { _running = NO; }
- (void)terminate:(id)sender {
    (void)sender;
    if(!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{[self terminate:nil];});return; }
    if(_terminating)return;
    _terminating=YES;
    NSUInteger reply=1;
    SEL selector=@selector(applicationShouldTerminate:);
    if([_delegate respondsToSelector:selector])reply=((NSUInteger (*)(id,SEL,id))[_delegate methodForSelector:selector])(_delegate,selector,self);
    AKLog(@"termination delegate reply=%lu",(unsigned long)reply);
    if(reply==2) {
        _terminationPending=YES;_terminationApproved=NO;
        while(_terminationPending)CFRunLoopRunInMode(kCFRunLoopDefaultMode,.01,false);
        reply=_terminationApproved?1:0;
    }
    if(reply!=1) { _terminating=NO;return; }
    [self ak_notify:@"NSApplicationWillTerminateNotification" sel:@selector(applicationWillTerminate:)];
    AKLog(@"terminate: requested by guest"); exit(0);
}
- (void)replyToApplicationShouldTerminate:(BOOL)shouldTerminate {
    if(!NSThread.isMainThread) { dispatch_async(dispatch_get_main_queue(),^{[self replyToApplicationShouldTerminate:shouldTerminate];});return; }
    if(_terminationPending) { _terminationApproved=shouldTerminate;_terminationPending=NO; }
}
- (void)postEvent:(NSEvent *)e atStart:(BOOL)atStart {
    // Preserve button/key boundaries, but combine consecutive motion samples.
    // This prevents a fast pointer from queuing stale movement ahead of key-up.
    NSEvent *last=_queue.lastObject;
    BOOL motion=e.type==NSEventTypeMouseMoved || e.type==NSEventTypeLeftMouseDragged || e.type==NSEventTypeRightMouseDragged;
    if(!atStart && motion && last.type==e.type && last.window==e.window && last.modifierFlags==e.modifierFlags && last.buttonNumber==e.buttonNumber) {
        e.deltaX+=last.deltaX;e.deltaY+=last.deltaY;[_queue removeLastObject];
    }
    if (atStart) [_queue insertObject:e atIndex:0]; else [_queue addObject:e];
    if (_inRun) [self ak_drain];   // guest left the loop to us; deliver right away
}
- (void)sendEvent:(NSEvent *)e { _currentEvent=e; [(e.window ?: self.keyWindow) sendEvent:e]; }
- (NSEvent *)nextEventMatchingMask:(NSUInteger)mask untilDate:(NSDate *)date inMode:(NSString *)mode dequeue:(BOOL)dq {
    static NSTimeInterval nextDiagnostic; static unsigned diagnostics;
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(diagnostics<3 && now>=nextDiagnostic && [NSProcessInfo.processInfo.arguments containsObject:@"--sample-native"]) {
        diagnostics++; nextDiagnostic=now+15; [self.keyWindow ak_logLayers];
    }
    for (BOOL pumped = NO;; pumped = YES) {
        for (NSUInteger i = 0; i < _queue.count; i++) {
            NSEvent *e = _queue[i];
            if (mask & (1ULL << e.type)) {
                if (dq) {
                    [_queue removeObjectAtIndex:i]; _currentEvent=e;
                    if(e.type==NSEventTypeKeyUp) {
                        double age=NSProcessInfo.processInfo.systemUptime-e.timestamp;
                        if(age>.05) AKLog(@"key release queue age_ms=%.1f pending=%lu",age*1000,(unsigned long)_queue.count);
                    }
                }
                return e;
            }
        }
        NSTimeInterval left = date ? date.timeIntervalSinceNow : 0;
        if (pumped && left <= 0) return nil;
        // A zero-duration poll can starve UIKit's deferred gesture/key work
        // when the desktop loop polls continuously. Allow a short complete
        // UIKit turn for nonblocking polls; blocking polls still wake on input.
        if(left<=0) CFRunLoopRunInMode(kCFRunLoopDefaultMode,.001,false);
        else CFRunLoopRunInMode(kCFRunLoopDefaultMode,MIN(left,.25),true);
    }
}
@end

int NSApplicationMain(int argc, const char *argv[]) {
    // No nib loading: a guest relying on MainMenu.nib for its delegate is not supported yet.
    [[NSApplication sharedApplication] run];
    return 0;
}
