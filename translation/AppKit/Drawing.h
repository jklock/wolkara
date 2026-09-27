#import "Images.h"
// Colours and drawing into bitmaps: what a guest draws with outside a view.
extern NSString *const NSCalibratedRGBColorSpace, *const NSDeviceRGBColorSpace;
extern NSString *const NSCalibratedWhiteColorSpace, *const NSDeviceWhiteColorSpace;
// UIKit has a private class of this name: ours registers as AKColor, and ldflags
// exports AppKit's symbol names for it, which is what guests bind to.
__attribute__((objc_runtime_name("AKColor"))) @interface NSColor : AKStubObject
@property(readonly) CGColorRef CGColor;
+ (NSColor *)colorWithCGColor:(CGColorRef)color;
+ (NSColor *)colorWithCalibratedRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha;
+ (NSColor *)colorWithDeviceRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha;
+ (NSColor *)colorWithSRGBRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha;
+ (NSColor *)colorWithCalibratedWhite:(CGFloat)white alpha:(CGFloat)alpha;
+ (NSColor *)blackColor;
+ (NSColor *)whiteColor;
+ (NSColor *)clearColor;
+ (NSColor *)windowBackgroundColor;
- (void)getRed:(CGFloat *)red green:(CGFloat *)green blue:(CGFloat *)blue alpha:(CGFloat *)alpha;
// Into the current graphics context: fill and stroke, or one of them.
- (void)set;
- (void)setFill;
- (void)setStroke;
@end
@interface NSGraphicsContext : AKStubObject
@property(readonly) CGContextRef CGContext;
@property(readonly) void *graphicsPort;
@property(readonly, getter=isFlipped) BOOL flipped;
// A bitmap the context draws into: packed 8-bit RGB with alpha or a padding byte.
+ (NSGraphicsContext *)graphicsContextWithBitmapImageRep:(NSBitmapImageRep *)rep;
+ (NSGraphicsContext *)graphicsContextWithCGContext:(CGContextRef)context flipped:(BOOL)flipped;
// Per thread, as in AppKit.
+ (NSGraphicsContext *)currentContext;
+ (void)setCurrentContext:(NSGraphicsContext *)context;
+ (void)saveGraphicsState;
+ (void)restoreGraphicsState;
- (void)saveGraphicsState;
- (void)restoreGraphicsState;
- (void)flushGraphics;
@end
// Replaces the rectangle's pixels with the current fill colour.
void NSRectFill(CGRect rect);
