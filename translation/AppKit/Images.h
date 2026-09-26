#import "AKSupport.h"
#import <CoreGraphics/CoreGraphics.h>
// Converts cursor alpha to a bounded vector silhouette for native pointer motion.
CGPathRef AKCreateCursorPath(CGImageRef image, CGSize size, CGPoint hotSpot) CF_RETURNS_RETAINED;
@interface NSImageRep : AKStubObject
@property CGSize size;
@property NSInteger pixelsWide, pixelsHigh, bitsPerSample;
@property BOOL hasAlpha;
@property(copy) NSString *colorSpaceName;
@end
@interface NSBitmapImageRep : NSImageRep
- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes pixelsWide:(NSInteger)width pixelsHigh:(NSInteger)height bitsPerSample:(NSInteger)bits samplesPerPixel:(NSInteger)samples hasAlpha:(BOOL)alpha isPlanar:(BOOL)planar colorSpaceName:(NSString *)space bitmapFormat:(NSUInteger)format bytesPerRow:(NSInteger)rowBytes bitsPerPixel:(NSInteger)pixelBits;
@property(readonly) unsigned char *bitmapData;
@property(readonly) NSInteger bytesPerRow, bitsPerPixel, samplesPerPixel, numberOfPlanes, bytesPerPlane;
@property(readonly) NSUInteger bitmapFormat;
@property(readonly, getter=isPlanar) BOOL planar;
@property(readonly) CGImageRef CGImage;
- (instancetype)initWithCGImage:(CGImageRef)image;
- (void)getBitmapDataPlanes:(unsigned char **)planes;
// Shim-internal: the pixel layout as Core Graphics names it.
@property(readonly) CGBitmapInfo ak_bitmapInfo;
@end
extern NSString *const NSImageNameApplicationIcon;
@interface NSImage : AKStubObject
@property CGSize size;
@property(getter=isTemplate) BOOL template;
@property(readonly) NSArray<NSImageRep *> *representations;
- (instancetype)initWithSize:(CGSize)size;
- (instancetype)initWithCGImage:(CGImageRef)image size:(CGSize)size;
- (void)addRepresentation:(NSImageRep *)representation;
- (CGImageRef)CGImageForProposedRect:(CGRect *)rect context:(id)context hints:(NSDictionary *)hints;
@end
@interface NSCursor : AKStubObject
@property(readonly) NSImage *image;
@property(readonly) CGPoint hotSpot;
- (instancetype)initWithImage:(NSImage *)image hotSpot:(CGPoint)point;
+ (NSCursor *)arrowCursor;
+ (NSCursor *)currentCursor;
- (void)set;
+ (void)hide;
+ (void)unhide;
@end
