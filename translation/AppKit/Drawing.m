#import "Drawing.h"
NSString *const NSCalibratedRGBColorSpace=@"NSCalibratedRGBColorSpace", *const NSDeviceRGBColorSpace=@"NSDeviceRGBColorSpace";
NSString *const NSCalibratedWhiteColorSpace=@"NSCalibratedWhiteColorSpace", *const NSDeviceWhiteColorSpace=@"NSDeviceWhiteColorSpace";
// The iPad's display is sRGB: calibrated, device and sRGB components mean the same.
@implementation NSColor { CGColorRef _color; }
+ (NSColor *)colorWithCGColor:(CGColorRef)color {
    if(!color) return nil;
    NSColor *result=[self new]; result->_color=CGColorRetain(color); return result;
}
+ (NSColor *)colorWithSRGBRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha {
    CGColorRef color=CGColorCreateSRGB(red,green,blue,alpha);
    NSColor *result=[self colorWithCGColor:color]; CGColorRelease(color); return result;
}
+ (NSColor *)colorWithCalibratedRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha { return [self colorWithSRGBRed:red green:green blue:blue alpha:alpha]; }
+ (NSColor *)colorWithDeviceRed:(CGFloat)red green:(CGFloat)green blue:(CGFloat)blue alpha:(CGFloat)alpha { return [self colorWithSRGBRed:red green:green blue:blue alpha:alpha]; }
+ (NSColor *)colorWithCalibratedWhite:(CGFloat)white alpha:(CGFloat)alpha {
    CGColorRef color=CGColorCreateGenericGray(white,alpha);
    NSColor *result=[self colorWithCGColor:color]; CGColorRelease(color); return result;
}
+ (NSColor *)blackColor { return [self colorWithCalibratedWhite:0 alpha:1]; }
+ (NSColor *)whiteColor { return [self colorWithCalibratedWhite:1 alpha:1]; }
+ (NSColor *)clearColor { return [self colorWithCalibratedWhite:0 alpha:0]; }
// macOS's light appearance.
+ (NSColor *)windowBackgroundColor { return [self colorWithSRGBRed:236/255.0 green:236/255.0 blue:236/255.0 alpha:1]; }
- (CGColorRef)CGColor { return _color; }
- (void)getRed:(CGFloat *)red green:(CGFloat *)green blue:(CGFloat *)blue alpha:(CGFloat *)alpha {
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGColorRef rgb=CGColorCreateCopyByMatchingToColorSpace(space,kCGRenderingIntentDefault,_color,NULL);
    CGColorSpaceRelease(space);
    const CGFloat *c=rgb && CGColorGetNumberOfComponents(rgb)==4 ? CGColorGetComponents(rgb) : (const CGFloat[]){0,0,0,0};
    if(red) *red=c[0];
    if(green) *green=c[1];
    if(blue) *blue=c[2];
    if(alpha) *alpha=c[3];
    if(rgb) CGColorRelease(rgb);
}
- (void)set { [self setFill]; [self setStroke]; }
- (void)setFill { CGContextRef context=NSGraphicsContext.currentContext.CGContext; if(context) CGContextSetFillColorWithColor(context,_color); }
- (void)setStroke { CGContextRef context=NSGraphicsContext.currentContext.CGContext; if(context) CGContextSetStrokeColorWithColor(context,_color); }
- (void)dealloc { CGColorRelease(_color); }
@end

static NSString *const AKCurrentContext=@"AKGraphicsContext", *const AKSavedContexts=@"AKSavedGraphicsContexts";
@implementation NSGraphicsContext { CGContextRef _context; BOOL _flipped; NSBitmapImageRep *_rep; }
+ (NSGraphicsContext *)graphicsContextWithCGContext:(CGContextRef)context flipped:(BOOL)flipped {
    if(!context) return nil;
    NSGraphicsContext *result=[self new]; result->_context=CGContextRetain(context); result->_flipped=flipped; return result;
}
+ (NSGraphicsContext *)graphicsContextWithBitmapImageRep:(NSBitmapImageRep *)rep {
    // Core Graphics draws into 32-bit pixels only; other layouts get no context.
    if(!rep.bitmapData || rep.bitsPerPixel!=32) return nil;
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGContextRef context=CGBitmapContextCreate(rep.bitmapData,(size_t)rep.pixelsWide,(size_t)rep.pixelsHigh,8,(size_t)rep.bytesPerRow,space,rep.ak_bitmapInfo);
    CGColorSpaceRelease(space);
    NSGraphicsContext *result=[self graphicsContextWithCGContext:context flipped:NO];
    if(result) result->_rep=rep;   // the pixels live as long as the context
    CGContextRelease(context);
    return result;
}
+ (NSGraphicsContext *)currentContext { return NSThread.currentThread.threadDictionary[AKCurrentContext]; }
+ (void)setCurrentContext:(NSGraphicsContext *)context { NSThread.currentThread.threadDictionary[AKCurrentContext]=context; }
+ (void)saveGraphicsState {
    NSMutableDictionary *state=NSThread.currentThread.threadDictionary;
    NSMutableArray *saved=state[AKSavedContexts];
    if(!saved) state[AKSavedContexts]=saved=[NSMutableArray new];
    NSGraphicsContext *current=state[AKCurrentContext];
    [saved addObject:current?:NSNull.null];
    [current saveGraphicsState];
}
+ (void)restoreGraphicsState {
    NSMutableArray *saved=NSThread.currentThread.threadDictionary[AKSavedContexts];
    if(!saved.count) return;
    id context=saved.lastObject; [saved removeLastObject];
    if(context==NSNull.null) context=nil;
    [self setCurrentContext:context];
    [context restoreGraphicsState];
}
- (CGContextRef)CGContext { return _context; }
- (void *)graphicsPort { return _context; }
- (BOOL)isFlipped { return _flipped; }
- (void)saveGraphicsState { CGContextSaveGState(_context); }
- (void)restoreGraphicsState { CGContextRestoreGState(_context); }
- (void)flushGraphics { CGContextFlush(_context); }
- (void)dealloc { CGContextRelease(_context); }
@end

void NSRectFill(CGRect rect) {
    CGContextRef context=NSGraphicsContext.currentContext.CGContext;
    if(!context) return;
    CGContextSaveGState(context);
    CGContextSetBlendMode(context,kCGBlendModeCopy);
    CGContextFillRect(context,rect);
    CGContextRestoreGState(context);
}
