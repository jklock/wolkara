// Original fixture: tests our lifecycle with fake transports, then permits
// manual testing of Apple's real virtual controller. No game or network.
#import <UIKit/UIKit.h>
#import "../translation/AppKit/TouchGamepad.h"
#include <assert.h>
#include <math.h>

@interface AKTouchGamepad (FixtureSeams)
- (NSArray<GCController *> *)connectedControllers;
- (GCVirtualController *)makeController;
@end
@interface AKFixtureController : NSObject
@property BOOL isSnapshot;
@property id extendedGamepad;
@property id microGamepad;
@end
@implementation AKFixtureController
@end
@interface AKFixtureConnection : NSObject
@property GCController *controller;
@property(copy) void (^reply)(NSError *);
@property NSUInteger disconnects;
- (void)finish:(NSError *)error;
@end
@implementation AKFixtureConnection
- (void)connectWithReplyHandler:(void (^)(NSError *))reply { self.reply=reply; }
- (void)disconnect { self.disconnects++; self.controller=nil; }
- (void)finish:(NSError *)error {
    if (!error) {
        AKFixtureController *controller=[AKFixtureController new]; controller.extendedGamepad=@YES;
        self.controller=(id)controller;
    }
    void (^reply)(NSError *)=self.reply; self.reply=nil; reply(error);
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.03,false);
}
@end
@interface AKFixtureGamepad : AKTouchGamepad
@property NSArray<GCController *> *devices;
@property AKFixtureConnection *lastConnection;
@property NSUInteger connections;
@end
@implementation AKFixtureGamepad
- (NSArray<GCController *> *)connectedControllers { return self.devices?:@[]; }
- (GCVirtualController *)makeController {
    self.connections++; self.lastConnection=[AKFixtureConnection new]; return (id)self.lastConnection;
}
@end

// The simulator can forward a host controller after lazy discovery. This
// fixture-only option still uses Apple's real controller, but lets us inspect it
// without disconnecting the user's hardware. Production always prioritizes it.
@interface AKPreviewGamepad : AKTouchGamepad
@property GCVirtualController *created;
@end
@implementation AKPreviewGamepad
- (GCVirtualController *)makeController { self.created=[super makeController]; return self.created; }
- (NSArray<GCController *> *)connectedControllers {
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--ignore-other-controllers"] ||
        [NSProcessInfo.processInfo.arguments containsObject:@"--self-test-input"]) return @[];
    return [super connectedControllers];
}
@end


static UIView *Find(UIView *view, NSString *identifier) {
    if ([view.accessibilityIdentifier isEqual:identifier]) return view;
    for (UIView *child in view.subviews) { UIView *found=Find(child,identifier); if (found) return found; }
    return nil;
}
static UIControl *Button(UIView *host, NSString *name) {
    UIControl *control=(id)Find(host,[@"tolkara.gamepad." stringByAppendingString:name]);
    assert(control && !control.hidden); return control;
}
static void Drain(void) { CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.03,false); }
@interface AKFixtureTouch : UITouch
@property CGPoint point;
@end
@implementation AKFixtureTouch
- (CGPoint)locationInView:(UIView *)view { (void)view; return self.point; }
@end
static void TestNativeInput(UIView *host, AKPreviewGamepad *manager) {
    GCExtendedGamepad *pad=manager.created.controller.extendedGamepad;
    assert(pad && manager.visible);
    [host layoutIfNeeded];
    // Ring sectors own their visible area, leave the stick and separator gaps
    // untouched, and put + on the same row as the bottom labels.
    UIButton *top=(id)Button(host,@"dpad.up");
    CALayer *guestSurface=[CALayer layer];
    guestSurface.frame=host.bounds; [host.layer addSublayer:guestSurface];
    assert(top.superview.layer.zPosition > guestSurface.zPosition);
    [guestSurface removeFromSuperlayer];
    assert([top pointInside:CGPointMake(108,26) withEvent:nil]);
    assert(![top pointInside:CGPointMake(108,108) withEvent:nil]);
    assert(![top pointInside:CGPointMake(26,108) withEvent:nil]);
    assert(![top pointInside:CGPointMake(166,50) withEvent:nil]);
    UIButton *a=(id)Button(host,GCInputButtonA), *plus=(id)Button(host,GCInputButtonMenu);
    assert(fabs([a convertPoint:a.titleLabel.center toView:host].y-[plus convertPoint:plus.titleLabel.center toView:host].y)<1);
    assert(Find(host,@"tolkara.gamepad.minus")==nil);
    NSArray *names=@[GCInputButtonA,GCInputButtonB,GCInputButtonX,GCInputButtonY,GCInputLeftShoulder,
        GCInputRightShoulder,GCInputLeftTrigger,GCInputRightTrigger,GCInputButtonMenu];
    for (NSString *name in names) {
        UIControl *button=Button(host,name);
        assert(CGRectContainsRect(host.bounds,[button convertRect:button.bounds toView:host]));
        [button sendActionsForControlEvents:UIControlEventTouchDown]; Drain();
        assert(manager.created.controller.physicalInputProfile.buttons[name].value==1);
        [button sendActionsForControlEvents:UIControlEventTouchUpOutside]; Drain();
        assert(manager.created.controller.physicalInputProfile.buttons[name].value==0);
    }
    UIControl *up=Button(host,@"dpad.up"), *right=Button(host,@"dpad.right"), *left=Button(host,@"dpad.left");
    [up sendActionsForControlEvents:UIControlEventTouchDown];
    [right sendActionsForControlEvents:UIControlEventTouchDown]; Drain();
    assert(pad.dpad.xAxis.value==1 && pad.dpad.yAxis.value==1);
    [up sendActionsForControlEvents:UIControlEventTouchCancel]; Drain();
    assert(pad.dpad.xAxis.value==1 && pad.dpad.yAxis.value==0);
    [left sendActionsForControlEvents:UIControlEventTouchDown]; Drain(); assert(pad.dpad.xAxis.value==0);
    [left sendActionsForControlEvents:UIControlEventTouchUpInside];
    [right sendActionsForControlEvents:UIControlEventTouchUpInside]; Drain(); assert(pad.dpad.xAxis.value==0);
    UIControl *leftStick=(id)Find(host,@"tolkara.gamepad.leftStick"), *rightStick=(id)Find(host,@"tolkara.gamepad.rightStick");
    AKFixtureTouch *touch=[AKFixtureTouch new]; touch.point=CGPointMake(leftStick.bounds.size.width,leftStick.bounds.size.height/2);
    assert([leftStick beginTrackingWithTouch:touch withEvent:nil]);
    touch.point=CGPointZero; assert([rightStick beginTrackingWithTouch:touch withEvent:nil]);
    [Button(host,GCInputLeftShoulder) sendActionsForControlEvents:UIControlEventTouchDown];
    [Button(host,GCInputButtonA) sendActionsForControlEvents:UIControlEventTouchDown]; Drain();
    assert(pad.leftThumbstick.xAxis.value==1 && pad.leftThumbstick.yAxis.value==0);
    assert(pad.rightThumbstick.xAxis.value < -0.70 && pad.rightThumbstick.yAxis.value > 0.70);
    assert(pad.leftShoulder.pressed && pad.buttonA.pressed);
    // The empty surface continues to belong to the existing trackpad/guest.
    assert([host hitTest:CGPointMake(host.bounds.size.width/2,host.bounds.size.height/2) withEvent:nil]==host);
    manager.keyboardVisible=YES; Drain();
    assert(!manager.visible && !pad.leftShoulder.pressed && !pad.buttonA.pressed);
    assert(pad.leftThumbstick.xAxis.value==0 && pad.rightThumbstick.yAxis.value==0);
    [leftStick cancelTrackingWithEvent:nil]; [rightStick cancelTrackingWithEvent:nil];
    [manager invalidate];
    puts("TOUCH_GAMEPAD_INPUT_PASS: all nine buttons, D-pad diagonals/opposition/cancel, both sticks, held modifiers, neutral reset and trackpad passthrough.");
}
static void TestStickMapping(void) {
    CGSize size=CGSizeMake(100,100);
    assert(CGPointEqualToPoint(AKTouchGamepadStickPosition(CGPointMake(50,50),size),CGPointZero));
    assert(CGPointEqualToPoint(AKTouchGamepadStickPosition(CGPointMake(52,50),size),CGPointZero));
    CGPoint value=AKTouchGamepadStickPosition(CGPointMake(500,50),size); assert(value.x==1 && value.y==0);
    value=AKTouchGamepadStickPosition(CGPointMake(0,0),size); assert(fabs(hypot(value.x,value.y)-1)<0.0001 && value.y>0 && value.x<0);
    assert(CGPointEqualToPoint(AKTouchGamepadStickPosition(CGPointMake(NAN,1),size),CGPointZero));
    assert(CGPointEqualToPoint(AKTouchGamepadStickPosition(CGPointZero,CGSizeZero),CGPointZero));
    assert(CGPointEqualToPoint(AKTouchGamepadStickPosition(CGPointMake(CGFLOAT_MAX,CGFLOAT_MAX),CGSizeMake(0.001,0.001)),CGPointZero));
}

static void TestLifecycle(UIView *host) {
    TestStickMapping();
    AKFixtureGamepad *pad=[[AKFixtureGamepad alloc] initWithHostView:host];
    [pad refresh]; assert(pad.connections==1 && !pad.visible);
    AKFixtureController *physical=[AKFixtureController new]; physical.extendedGamepad=@YES;
    pad.devices=@[(id)physical]; [pad refresh];
    [pad.lastConnection finish:nil]; assert(!pad.visible && pad.lastConnection.disconnects);
    pad.devices=@[]; [pad refresh]; [pad.lastConnection finish:nil]; assert(pad.visible);
    // Our own connect event must never be mistaken for physical hardware.
    pad.devices=@[pad.lastConnection.controller];
    [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidConnectNotification object:pad.lastConnection.controller];
    CFRunLoopRunInMode(kCFRunLoopDefaultMode,0.03,false);
    assert(pad.visible && pad.connections==2);
    pad.devices=@[]; pad.keyboardVisible=YES; assert(!pad.visible && pad.lastConnection.disconnects);
    pad.keyboardVisible=NO; [pad.lastConnection finish:nil]; assert(pad.visible);
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];
    assert(!pad.visible);
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    // Keyboard opening while connect is pending cancels a late success.
    pad.keyboardVisible=YES; [pad.lastConnection finish:nil]; assert(!pad.visible);
    NSUInteger count=pad.connections;
    [pad refresh]; assert(pad.connections==count);
    pad.keyboardVisible=NO;
    [pad.lastConnection finish:[NSError errorWithDomain:@"Fixture" code:1 userInfo:nil]];
    assert(!pad.visible); count=pad.connections;
    [pad refresh]; [pad refresh]; assert(pad.connections==count); // no retry loop
    pad.enabled=NO; pad.enabled=YES; [pad.lastConnection finish:nil]; assert(pad.visible);
    pad.devices=@[(id)physical]; [pad refresh]; assert(!pad.visible);
    physical.isSnapshot=YES; [pad refresh]; [pad.lastConnection finish:nil]; assert(pad.visible);
    host.hidden=YES; [pad refresh]; assert(!pad.visible);
    host.hidden=NO; [pad refresh];
    [pad invalidate]; [pad.lastConnection finish:nil]; assert(!pad.visible);
    count=pad.connections; [pad refresh]; assert(pad.connections==count);
    puts("TOUCH_GAMEPAD_LIFECYCLE_PASS: physical priority, own/snapshot filtering, keyboard/focus cancellation, late replies, failure, retry and teardown.");
}

@interface AKGamepadFixtureScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@property AKTouchGamepad *gamepad;
@property UILabel *status;
@property UILabel *input;
@property NSUInteger events;
@property NSUInteger presses;
@property NSUInteger axisUpdates;
@end
@implementation AKGamepadFixtureScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *vc=[UIViewController new]; vc.view.backgroundColor=[UIColor colorWithRed:.04 green:.07 blue:.12 alpha:1];
    self.window.rootViewController=vc;
    self.status=[UILabel new]; self.input=[UILabel new];
    for (UILabel *label in @[self.status,self.input]) {
        label.textColor=UIColor.whiteColor; label.numberOfLines=0;
        label.font=[UIFont systemFontOfSize:18]; label.translatesAutoresizingMaskIntoConstraints=NO;
        [vc.view addSubview:label];
    }
    self.status.text=@"Touch controller test · Waiting for activation";
    self.input.text=@"Original input fixture — no game runs here";
    [NSLayoutConstraint activateConstraints:@[
        [self.status.topAnchor constraintEqualToAnchor:vc.view.safeAreaLayoutGuide.topAnchor constant:68],
        [self.status.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [self.status.widthAnchor constraintLessThanOrEqualToAnchor:vc.view.widthAnchor constant:-100],
        [self.input.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:10],
        [self.input.centerXAnchor constraintEqualToAnchor:vc.view.centerXAnchor],
        [self.input.widthAnchor constraintLessThanOrEqualToAnchor:vc.view.widthAnchor constant:-100]
    ]];
    [self.window makeKeyAndVisible];
    [self performSelector:@selector(start) withObject:nil afterDelay:.5];
}
- (void)start {
    BOOL test=[NSProcessInfo.processInfo.arguments containsObject:@"--self-test"];
    if (test) { TestLifecycle(self.window.rootViewController.view); fflush(stdout); exit(0); }
    self.gamepad=[[AKPreviewGamepad alloc] initWithHostView:self.window.rootViewController.view];
    __weak AKGamepadFixtureScene *weakSelf=self;
    self.gamepad.visibilityChanged=^(BOOL visible) {
        weakSelf.status.text=visible?@"Touch controller active":@"Touch controller hidden";
        NSLog(@"VIRTUAL_CONTROLLER_VISIBLE=%d",visible);
        if (visible && [NSProcessInfo.processInfo.arguments containsObject:@"--self-test-input"]) {
            [weakSelf performSelector:@selector(testInput) withObject:nil afterDelay:0.1]; return;
        }
        GCController *own=((AKPreviewGamepad *)weakSelf.gamepad).created.controller;
        if (visible) for (GCController *controller in own ? @[own] : @[]) {
            controller.extendedGamepad.valueChangedHandler=^(GCExtendedGamepad *pad, GCControllerElement *element) {
                BOOL press=[element isKindOfClass:GCControllerButtonInput.class] && ((GCControllerButtonInput *)element).isPressed;
                BOOL axis=[element isKindOfClass:GCControllerDirectionPad.class];
                dispatch_async(dispatch_get_main_queue(), ^{
                    weakSelf.events++; weakSelf.presses+=press; weakSelf.axisUpdates+=axis;
                    weakSelf.input.text=[NSString stringWithFormat:@"Events %lu · Presses %lu · Axes %lu\nA %.1f · B %.1f · X %.1f · Y %.1f · + %.1f\nL (%.2f, %.2f) · R (%.2f, %.2f) · Pad (%.0f, %.0f)",
                        (unsigned long)weakSelf.events,(unsigned long)weakSelf.presses,(unsigned long)weakSelf.axisUpdates,
                        pad.buttonA.value,pad.buttonB.value,pad.buttonX.value,pad.buttonY.value,
                        pad.buttonMenu.value,
                        pad.leftThumbstick.xAxis.value,pad.leftThumbstick.yAxis.value,
                        pad.rightThumbstick.xAxis.value,pad.rightThumbstick.yAxis.value,pad.dpad.xAxis.value,pad.dpad.yAxis.value];
                });
            };
        }
    };
    NSLog(@"FIXTURE_CONTROLLER_COUNT=%lu",(unsigned long)GCController.controllers.count);
    [self.gamepad refresh];
    [self performSelector:@selector(report) withObject:nil afterDelay:2];
}
- (void)testInput { TestNativeInput(self.window.rootViewController.view,(id)self.gamepad); fflush(stdout); exit(0); }
- (void)report {
    NSLog(@"FIXTURE_GAMEPAD: active=%d key=%d hidden=%d visible=%d controllers=%lu",UIApplication.sharedApplication.applicationState==UIApplicationStateActive,self.window.isKeyWindow,self.window.hidden,self.gamepad.visible,(unsigned long)GCController.controllers.count);
}
@end
@interface AKGamepadFixtureApp : UIResponder <UIApplicationDelegate>
@end
@implementation AKGamepadFixtureApp
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)app; (void)options;
    UISceneConfiguration *config=[[UISceneConfiguration alloc] initWithName:@"Gamepad fixture" sessionRole:session.role];
    config.delegateClass=AKGamepadFixtureScene.class; return config;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool {
        if ([NSProcessInfo.processInfo.arguments containsObject:@"--self-test"] || [NSProcessInfo.processInfo.arguments containsObject:@"--self-test-input"])
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
                fputs("TOUCH_GAMEPAD_LIFECYCLE_TIMEOUT\n",stderr); _Exit(1);
            });
        return UIApplicationMain(argc,argv,nil,NSStringFromClass(AKGamepadFixtureApp.class));
    }
}
