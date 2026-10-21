#import <UIKit/UIKit.h>
#import "../App/AppLibrary.h"
#import "../App/ExecutionMode.h"

NS_ASSUME_NONNULL_BEGIN
@class TKLaunchProgressView;
@interface TKWoWViewController : UIViewController
- (instancetype)initWithLibrary:(TKAppLibrary *)library;
@property(nonatomic, copy, nullable) void (^startApp)(TKApp *app);
@property(nonatomic, copy, nullable) void (^showDiagnostics)(void);
@property(nonatomic) TKExecutionMode executionMode;
@property(nonatomic) BOOL sessionUsed;
// Opening an external page (Download Mac-Ever). Injectable so a test can prove
// the exact URL is requested without a browser opening on the simulator.
@property(nonatomic, copy, nullable) void (^openExternalURL)(NSURL *url);
// The folder the Settings browser would open. Injectable for the same reason:
// a fixture proves the destination without a system file provider.
@property(nonatomic, copy, nullable) void (^openSettingsFolderURL)(NSURL *url);
// Reuse this home screen throughout startup; the runtime retains its execution path.
@property(nonatomic, readonly) UILabel *startupStatusLabel;
@property(nonatomic, readonly) TKLaunchProgressView *launchProgress;
@property(nonatomic, readonly) UIButton *diagnosticsButton;
- (void)beginStartup;
- (void)finishStartupWithMessage:(NSString *)message failed:(BOOL)failed;
@end
NS_ASSUME_NONNULL_END
