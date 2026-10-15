#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// A data-only description of one user-supplied add-on folder. The launcher
// never interprets or modifies the add-on's Lua or game files.
@interface TKWoWAddon : NSObject
@property(nonatomic, readonly, copy) NSString *folder;
@property(nonatomic, readonly, copy) NSString *title;
@property(nonatomic, readonly, copy, nullable) NSString *version;
@property(nonatomic, readonly) NSUInteger fileCount;
@end

// Lists direct child folders of Interface/AddOns. Invalid or unreadable
// folders are skipped so a damaged add-on cannot prevent the manager opening.
NSArray<TKWoWAddon *> *TKWoWAddonsAtDirectory(NSString *directory);

@interface TKWoWAddonManagerViewController : UITableViewController
- (instancetype)initWithAddOnsDirectory:(NSString *)directory edition:(NSString *)edition;
@end

NS_ASSUME_NONNULL_END
