// Isolated UIKit fixture: synthetic metadata, empty library, no network or guest execution.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#include <assert.h>
#import "../launcher/WoW/WoWViewController.h"
#import "../launcher/WoW/Client.h"

@interface TKEmptyLibrary : NSObject
- (NSArray *)apps;
@end
@implementation TKEmptyLibrary
- (NSArray *)apps { return @[]; }
@end

static atomic_uint requests;
static NSDictionary *Version(id self, SEL selector, NSString *product, NSString *region, NSError **error) {
    (void)self; (void)selector; (void)region; (void)error;
    // A slow first response exercises the controller's stale-result guard.
    unsigned request=atomic_fetch_add(&requests,1);
    [NSThread sleepForTimeInterval:request==0?0.5:0.02];
    return @{@"VersionsName":[@"Synthetic / " stringByAppendingString:product],
        @"BuildConfig":TKWoWMD5([@"build" dataUsingEncoding:NSUTF8StringEncoding]),
        @"CDNConfig":TKWoWMD5([@"cdn" dataUsingEncoding:NSUTF8StringEncoding])};
}
static NSDictionary *Plan(id self, SEL selector, NSString *product, NSString *region, NSString *locale, NSError **error) {
    (void)selector;
    return @{@"version":Version(self,NULL,product,region,error),@"product":product,@"region":region,@"locale":locale,
        @"files":@[@{@"path":@"Synthetic.app/Contents/MacOS/Synthetic"}],@"installFileBytes":@4096,@"complete":@NO};
}
@interface TKWoWFixtureDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic) UIWindow *window;
@property(nonatomic) TKWoWViewController *controller;
@end
@implementation TKWoWFixtureDelegate
- (void)chooseRow:(NSInteger)row section:(NSInteger)section {
    [self.controller tableView:self.controller.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]];
}
- (NSString *)status {
    return [self.controller tableView:self.controller.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:2]].textLabel.text;
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    method_setImplementation(class_getInstanceMethod(TKWoWClient.class,@selector(versionForProduct:region:error:)),(IMP)Version);
    method_setImplementation(class_getInstanceMethod(TKWoWClient.class,@selector(planForProduct:region:locale:error:)),(IMP)Plan);
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WoWProduct"];
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.controller=[[TKWoWViewController alloc] initWithLibrary:(TKAppLibrary *)(id)[TKEmptyLibrary new]];
    self.controller.title=@"WoW · synthetic preview";
    self.controller.startApp=^(TKApp *app) { (void)app; assert(!"An empty installation must never launch."); };
    self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:self.controller];
    [self.window makeKeyAndVisible];
    [self performSelector:@selector(changeSelection) withObject:nil afterDelay:0.1];
    return YES;
}
- (void)changeSelection {
    [self chooseRow:1 section:0];
    [self performSelector:@selector(checkSelection) withObject:nil afterDelay:0.8];
}
- (void)checkSelection {
    assert([[self status] containsString:@"wow_classic_era"]);
    [self chooseRow:2 section:2];
    [self performSelector:@selector(checkPlan) withObject:nil afterDelay:0.3];
}
- (void)checkPlan {
    assert([[self status] containsString:@"1 macOS installation files"]);
    [self chooseRow:4 section:2];
    [self performSelector:@selector(checkBlocked) withObject:nil afterDelay:0.3];
}
- (void)checkBlocked {
    assert([[self status] containsString:@"No matching imported installation"]);
    puts("WoW UIKit fixture PASS: selection race, verified-plan display, missing-installation launch blocked."); fflush(stdout);
    [self.controller.tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:2] atScrollPosition:UITableViewScrollPositionTop animated:NO];
    if (![NSProcessInfo.processInfo.arguments containsObject:@"--preview"]) exit(0);
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(TKWoWFixtureDelegate.class)); }
}
