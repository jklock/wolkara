#import "AppKit.h"
@implementation NSScreen
+ (NSScreen *)mainScreen { static NSScreen *s; static dispatch_once_t once; dispatch_once(&once, ^{s=[self new];}); return s; }
+ (NSArray *)screens { return @[self.mainScreen]; }
- (NSRect)frame { return UIScreen.mainScreen.bounds; }
- (NSRect)auxiliaryTopLeftArea { return CGRectZero; }
- (NSRect)auxiliaryTopRightArea { return CGRectZero; }
- (NSRect)convertRectFromBacking:(NSRect)r { CGFloat f=self.backingScaleFactor; return CGRectMake(r.origin.x/f,r.origin.y/f,r.size.width/f,r.size.height/f); }
- (NSRect)convertRectToBacking:(NSRect)r { CGFloat f=self.backingScaleFactor; return CGRectMake(r.origin.x*f,r.origin.y*f,r.size.width*f,r.size.height*f); }
- (NSRect)visibleFrame { return self.frame; }
- (CGFloat)backingScaleFactor { return UIScreen.mainScreen.nativeScale; }
- (NSDictionary *)deviceDescription { return @{@"NSScreenNumber":@1,@"NSDeviceSize":[NSValue valueWithCGSize:self.frame.size],@"NSDeviceResolution":[NSValue valueWithCGSize:CGSizeMake(72,72)],@"NSDeviceBitsPerSample":@8,@"NSDeviceColorSpaceName":@"NSCalibratedRGBColorSpace"}; }
- (NSInteger)maximumFramesPerSecond { return UIScreen.mainScreen.maximumFramesPerSecond; }
- (NSString *)localizedName { return @"iPad display"; }
@end
