#pragma once
#import <UIKit/UIKit.h>

// Elapsed time and indeterminate activity are rendered by Core Animation so
// they keep moving while the developer service pauses the app's threads.
@interface TKLaunchProgressView : UIView
- (void)start;
- (void)stop;
@end
