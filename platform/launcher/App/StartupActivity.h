#pragma once
#import <UIKit/UIKit.h>
#import "StartupActivityText.h"

NS_ASSUME_NONNULL_BEGIN
// What startup is doing, and the file the app wrote last in its folder:
// redrawn every second from a background queue with Core Animation, because
// application code may hold the main thread for minutes while starting.
@interface TKStartupActivityView : UIView
// step runs on a background queue: the current step, and its seconds so far.
- (void)startInFolder:(NSString *)folder step:(NSString *_Nullable (^)(NSTimeInterval *seconds))step;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
