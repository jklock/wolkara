#import <UIKit/UIKit.h>

// Preferences contain only UI geometry; never controller or game state.
@interface AKGamepadLayout : NSObject
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
@property(nonatomic) CGFloat opacity;
@property(nonatomic) CGFloat rearScale;
@property(nonatomic) CGFloat frontScale;
- (CGRect)frameForItem:(NSString *)item defaultFrame:(CGRect)frame inBounds:(CGRect)bounds;
- (void)moveItem:(NSString *)item toFrame:(CGRect)frame inBounds:(CGRect)bounds;
- (void)save;
- (void)reset;
@end
