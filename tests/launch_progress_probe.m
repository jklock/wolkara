// Standalone UIKit fixture: no guest code, authorization or game input.
#import <UIKit/UIKit.h>
#import "LaunchProgressView.h"
#import "StartupActivity.h"

@interface ProgressProbe : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) TKStartupActivityView *activity;
@end
@implementation ProgressProbe
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    UIViewController *controller = [UIViewController new];
    controller.overrideUserInterfaceStyle = [NSProcessInfo.processInfo.arguments containsObject:@"--dark"]
        ? UIUserInterfaceStyleDark : UIUserInterfaceStyleLight;
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [UILabel new];
    label.numberOfLines = 0;
    label.font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightRegular];
    label.text = @"Preparing Cyberpunk 2077\nSetting up 222 MiB of execution memory.\nThis step can take a few minutes. Keep Tolkara open.";
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:label];
    TKLaunchProgressView *progress = [TKLaunchProgressView new];
    progress.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:progress];
    TKStartupActivityView *activity = [TKStartupActivityView new];
    activity.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:activity];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.leadingAnchor constant:32],
        [label.trailingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.trailingAnchor constant:-32],
        [label.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
        [progress.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [progress.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:20],
        [activity.topAnchor constraintEqualToAnchor:progress.bottomAnchor constant:12],
        [activity.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [activity.trailingAnchor constraintEqualToAnchor:label.trailingAnchor],
    ]];
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    [progress start];
    self.activity = activity;
    [self performSelector:@selector(startAndHold) withObject:nil afterDelay:4];
}
// As the launcher does: start the activity, then let an app's code hold the
// main thread (here 6 s) while it counts a step and grows a report.
- (void)startAndHold {
    NSString *folder = [NSTemporaryDirectory() stringByAppendingPathComponent:@"startup-activity"];
    [NSFileManager.defaultManager removeItemAtPath:folder error:NULL];
    [NSFileManager.defaultManager createDirectoryAtPath:[folder stringByAppendingPathComponent:@"Errors"]
                            withIntermediateDirectories:YES attributes:nil error:NULL];
    NSString *report = [folder stringByAppendingPathComponent:@"Errors/2026-09-27_18.55.04_Error_40749.txt"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSMutableData *data = [NSMutableData data];
        for (unsigned i = 0; i < 30; ++i) { [data increaseLengthBy:11000]; [data writeToFile:report atomically:NO]; sleep(1); }
    });
    CFTimeInterval started = CACurrentMediaTime();
    [self.activity startInFolder:folder step:^NSString *(NSTimeInterval *seconds) {
        *seconds = CACurrentMediaTime() - started;
        return TKStartupStepText("running the app's startup code", (unsigned long long)(*seconds * 1000), 13287);
    }];
    sleep(6);
}
@end
@interface ProbeApplication : UIResponder <UIApplicationDelegate>
@end
@implementation ProbeApplication
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeApplication.class)); }
}
