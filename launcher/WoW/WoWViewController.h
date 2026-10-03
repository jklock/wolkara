#import <UIKit/UIKit.h>
#import "../App/AppLibrary.h"

NS_ASSUME_NONNULL_BEGIN
@interface TKWoWViewController : UITableViewController
- (instancetype)initWithLibrary:(TKAppLibrary *)library;
@property(nonatomic, copy, nullable) void (^startApp)(TKApp *app);
@end
NS_ASSUME_NONNULL_END
