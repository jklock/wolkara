// Standalone UIKit fixture: no guest code, authorization or game input.
#import <UIKit/UIKit.h>
#import "LaunchProgressView.h"

@interface ProgressProbe : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
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
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.leadingAnchor constant:32],
        [label.trailingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.trailingAnchor constant:-32],
        [label.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
        [progress.leadingAnchor constraintEqualToAnchor:label.leadingAnchor],
        [progress.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:20],
    ]];
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    [progress start];
}
@end
@interface ProbeApplication : UIResponder <UIApplicationDelegate>
@end
@implementation ProbeApplication
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(ProbeApplication.class)); }
}
