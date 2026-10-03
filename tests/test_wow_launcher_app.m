// Isolated UIKit fixture: our synthetic installation, no network or guest execution.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#import "../launcher/WoW/WoWViewController.h"
#import "../launcher/WoW/Client.h"
#import "../launcher/WoW/Updater.h"
#import "wow_installation_fixture.h"

@interface TKWoWViewController (Fixture)
- (void)selectProduct:(NSDictionary *)product;
- (void)refresh;
@end
static atomic_uint requests, revision, updates;
static atomic_bool failure, slow;
static TKFixtureLibrary *fixture;
static NSDictionary *Plan(id self, SEL selector, NSString *product, NSString *region, NSString *locale, NSError **error) {
    (void)self; (void)selector; (void)region; (void)locale;
    unsigned request=atomic_fetch_add(&requests,1);
    [NSThread sleepForTimeInterval:(request==0 || atomic_load(&slow))?0.5:0.02];
    if (atomic_load(&failure)) { if (error) *error=TKWoWError(@"Synthetic offline response"); return nil; }
    return [fixture planForProduct:product revision:atomic_load(&revision)];
}
static BOOL Update(id self, SEL selector, NSDictionary *plan, NSString *root,
                   void (^progress)(NSString *,uint64_t,uint64_t), NSError **error) {
    (void)self; (void)selector; (void)plan; (void)error;
    assert([root isEqual:fixture.root]);
    atomic_fetch_add(&updates,1); progress(@"download",50,100);
    [fixture writeMetadata:atomic_load(&revision) duplicate:NO];
    progress(@"complete",1,1); return YES;
}
static UIView *Find(UIView *view, NSString *identifier) {
    if ([view.accessibilityIdentifier isEqual:identifier]) return view;
    for (UIView *child in view.subviews) { UIView *match=Find(child,identifier); if (match) return match; }
    return nil;
}
@interface TKWoWFixtureDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow *window;
@property(nonatomic) TKWoWViewController *controller;
@property(nonatomic) NSUInteger launches, setups;
@end
@implementation TKWoWFixtureDelegate
- (UIButton *)primary { return (id)Find(self.controller.view,@"wow.primary"); }
- (NSString *)status { return [(UILabel *)Find(self.controller.view,@"wow.status") text]; }
- (void)tap { [[self primary] sendActionsForControlEvents:UIControlEventTouchUpInside]; }
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    method_setImplementation(class_getInstanceMethod(TKWoWClient.class,@selector(planForProduct:region:locale:error:)),(IMP)Plan);
    method_setImplementation(class_getInstanceMethod(TKWoWUpdater.class,@selector(updatePlan:root:progress:error:)),(IMP)Update);
    [NSUserDefaults.standardUserDefaults setObject:@"wow_classic_beta" forKey:@"WoWProduct"];
    fixture=[TKFixtureLibrary new];
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.controller=[[TKWoWViewController alloc] initWithLibrary:(id)fixture];
    __weak TKWoWFixtureDelegate *weakSelf=self;
    self.controller.startApp=^(TKApp *app) { assert(app==(id)fixture.apps[0]); weakSelf.launches++; };
    self.controller.showStartupOptions=^{ weakSelf.setups++; weakSelf.controller.executionMode=TKExecutionModeDeveloperService; };
    self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:self.controller];
    [self.window makeKeyAndVisible];
    [self performSelector:@selector(changeSelection) withObject:nil afterDelay:0.1];
    return YES;
}
- (void)changeSelection {
    [self.controller selectProduct:TKWoWProducts()[1]];
    [self performSelector:@selector(checkSelection) withObject:nil afterDelay:0.8];
}
- (void)checkSelection {
    assert([self primary].enabled);
    assert([[(UIButton *)Find(self.controller.view,@"wow.edition") configuration].title containsString:@"Classic Era"]);
    assert([[(UILabel *)Find(self.controller.view,@"wow.version") text] containsString:@"demo"]);
    [self.controller selectProduct:TKWoWProducts()[0]];
    [self performSelector:@selector(checkReady) withObject:nil afterDelay:0.3];
}
- (void)checkReady {
    assert([self primary].enabled);
    [self tap]; assert(self.setups==1 && self.launches==0);
    atomic_store(&revision,1); [self.controller refresh];
    [self performSelector:@selector(checkOutdated) withObject:nil afterDelay:0.3];
}
- (void)checkOutdated {
    assert([self primary].enabled && self.launches==0 && atomic_load(&updates)==1);
    atomic_store(&failure,true); [self.controller refresh];
    [self performSelector:@selector(checkOffline) withObject:nil afterDelay:0.3];
}
- (void)checkOffline {
    assert([self primary].enabled && self.launches==0);
    atomic_store(&failure,false); [self tap];
    [self performSelector:@selector(startThenBackground) withObject:nil afterDelay:0.3];
}
- (void)startThenBackground {
    assert([self primary].enabled);
    atomic_store(&slow,true); [self tap];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];
    [self performSelector:@selector(checkCancellation) withObject:nil afterDelay:0.7];
}
- (void)checkCancellation {
    assert(self.launches==0); atomic_store(&slow,false); [self.controller refresh];
    [self performSelector:@selector(captureAndLaunch) withObject:nil afterDelay:0.3];
}
- (void)captureAndLaunch {
    assert([self primary].enabled);
    [self.window layoutIfNeeded];
    CGRect button=[[self primary] convertRect:[self primary].bounds toView:self.window];
    assert(CGRectContainsRect(self.window.bounds,button));
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:self.window.bounds];
    UIImage *image=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context; [self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];
    }];
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    assert([UIImagePNGRepresentation(image) writeToFile:[documents stringByAppendingPathComponent:@"wow-home.png"] atomically:YES]);
    [self tap]; [self performSelector:@selector(checkLaunch) withObject:nil afterDelay:0.3];
}
- (void)checkLaunch {
    assert(self.launches==1); self.controller.sessionUsed=YES;
    assert(![self primary].enabled);
    puts("WoW UIKit PASS: automatic check, edition race, missing install action, automatic update without launch, startup choice, offline retry, background cancellation, verified launch and session end."); fflush(stdout);
    if (![NSProcessInfo.processInfo.arguments containsObject:@"--preview"]) exit(0);
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(TKWoWFixtureDelegate.class)); }
}
