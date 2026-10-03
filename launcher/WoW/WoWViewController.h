#import <UIKit/UIKit.h>
#import "../App/AppLibrary.h"
#import "../App/ExecutionMode.h"

NS_ASSUME_NONNULL_BEGIN
@interface TKWoWViewController : UIViewController
- (instancetype)initWithLibrary:(TKAppLibrary *)library;
@property(nonatomic, copy, nullable) void (^startApp)(TKApp *app);
@property(nonatomic, copy, nullable) void (^showTools)(void);
@property(nonatomic, copy, nullable) void (^showStartupOptions)(void);
@property(nonatomic) TKExecutionMode executionMode;
@property(nonatomic) BOOL sessionUsed;
@end
NS_ASSUME_NONNULL_END
