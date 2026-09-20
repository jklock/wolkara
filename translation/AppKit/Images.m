#import "Images.h"
#include <limits.h>
#include <math.h>
CGPathRef AKCreateCursorPath(CGImageRef image, CGSize size, CGPoint hotSpot) {
    if(!image || !isfinite(size.width) || !isfinite(size.height) || size.width<=0 || size.height<=0 || !isfinite(hotSpot.x) || !isfinite(hotSpot.y))return NULL;
    // Keep conversion bounded even for malformed or oversized guest images.
    size_t width=MIN(CGImageGetWidth(image),64),height=MIN(CGImageGetHeight(image),64);
    if(!width || !height)return NULL;
    uint8_t alpha[64*64]={0};
    CGContextRef context=CGBitmapContextCreate(alpha,width,height,8,width,NULL,(CGBitmapInfo)kCGImageAlphaOnly);
    if(!context)return NULL;
    CGContextDrawImage(context,CGRectMake(0,0,width,height),image);
    CGContextRelease(context);
    CGFloat scale=MIN(1.0,32.0/MAX(size.width,size.height));
    CGFloat dx=size.width*scale/width,dy=size.height*scale/height;
    CGMutablePathRef runs=CGPathCreateMutable();
    for(size_t y=0;y<height;y++) {
        for(size_t x=0;x<width;) {
            if(alpha[y*width+x]<128) { x++;continue; }
            size_t start=x;while(x<width && alpha[y*width+x]>=128)x++;
            CGPathAddRect(runs,NULL,CGRectMake(start*dx-hotSpot.x*scale,y*dy-hotSpot.y*scale,(x-start)*dx,dy));
        }
    }
    // Merge adjacent scanlines so the system sees outlines, not pixel strips.
    CGPathRef path=CGPathIsEmpty(runs)?NULL:CGPathCreateCopyByNormalizing(runs,false);
    CGPathRelease(runs);return path;
}
@implementation NSImageRep
@end
@implementation NSBitmapImageRep {
    NSMutableData *_storage;
    unsigned char *_pixels;
    CGImageRef _snapshot;
}
- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes pixelsWide:(NSInteger)width pixelsHigh:(NSInteger)height bitsPerSample:(NSInteger)bits samplesPerPixel:(NSInteger)samples hasAlpha:(BOOL)alpha isPlanar:(BOOL)planar colorSpaceName:(NSString *)space bitmapFormat:(NSUInteger)format bytesPerRow:(NSInteger)rowBytes bitsPerPixel:(NSInteger)pixelBits {
    AKLog(@"bitmap %ldx%ld bits=%ld samples=%ld alpha=%d planar=%d format=%lu stride=%ld pixelBits=%ld space=%@",(long)width,(long)height,(long)bits,(long)samples,alpha,planar,(unsigned long)format,(long)rowBytes,(long)pixelBits,space);
    // Packed 8-bit RGB(A), including caller-owned planes. Reject other formats
    // explicitly instead of returning storage with an incompatible layout.
    if(width<=0 || height<=0 || bits!=8 || planar || samples!=(alpha ? 4 : 3) || (format & ~3UL) || ![space hasSuffix:@"RGBColorSpace"]) return nil;
    if(!pixelBits) pixelBits=bits*samples;
    if(pixelBits!=bits*samples || width>LONG_MAX/samples) return nil;
    NSInteger minimum=width*samples;
    if(!rowBytes) rowBytes=minimum;
    if(rowBytes<minimum || height>LONG_MAX/rowBytes) return nil;
    if((self=[super init])) {
        self.pixelsWide=width; self.pixelsHigh=height; self.bitsPerSample=bits;
        self.hasAlpha=alpha; self.colorSpaceName=space; self.size=CGSizeMake(width,height);
        _bytesPerRow=rowBytes; _bitsPerPixel=pixelBits; _samplesPerPixel=samples; _bitmapFormat=format;
        _numberOfPlanes=1; _bytesPerPlane=rowBytes*height;
        if(planes && planes[0]) _pixels=planes[0];
        else { _storage=[NSMutableData dataWithLength:(NSUInteger)_bytesPerPlane]; _pixels=_storage.mutableBytes; }
    }
    return self;
}
- (instancetype)initWithBitmapDataPlanes:(unsigned char **)planes pixelsWide:(NSInteger)width pixelsHigh:(NSInteger)height bitsPerSample:(NSInteger)bits samplesPerPixel:(NSInteger)samples hasAlpha:(BOOL)alpha isPlanar:(BOOL)planar colorSpaceName:(NSString *)space bytesPerRow:(NSInteger)rowBytes bitsPerPixel:(NSInteger)pixelBits {
    return [self initWithBitmapDataPlanes:planes pixelsWide:width pixelsHigh:height bitsPerSample:bits samplesPerPixel:samples hasAlpha:alpha isPlanar:planar colorSpaceName:space bitmapFormat:0 bytesPerRow:rowBytes bitsPerPixel:pixelBits];
}
- (unsigned char *)bitmapData { return _pixels; }
- (BOOL)isPlanar { return NO; }
- (void)getBitmapDataPlanes:(unsigned char **)planes { if(planes) { planes[0]=_pixels; for(int i=1;i<5;i++) planes[i]=NULL; } }
- (CGImageRef)CGImage {
    // Snapshot on every request: clients can modify bitmapData without notifying
    // the representation. The provider owns a copy, never the caller's plane.
    NSData *bytes=[NSData dataWithBytes:_pixels length:(NSUInteger)_bytesPerPlane];
    CGDataProviderRef provider=CGDataProviderCreateWithCFData((__bridge CFDataRef)bytes);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGImageAlphaInfo info=kCGImageAlphaNone;
    if(self.hasAlpha) info=(_bitmapFormat&1) ? ((_bitmapFormat&2) ? kCGImageAlphaFirst : kCGImageAlphaPremultipliedFirst) : ((_bitmapFormat&2) ? kCGImageAlphaLast : kCGImageAlphaPremultipliedLast);
    CGImageRef next=CGImageCreate(self.pixelsWide,self.pixelsHigh,8,_bitsPerPixel,_bytesPerRow,space,(CGBitmapInfo)info,provider,NULL,false,kCGRenderingIntentDefault);
    CGColorSpaceRelease(space); CGDataProviderRelease(provider);
    if(_snapshot) CGImageRelease(_snapshot); _snapshot=next;
    return _snapshot;
}
- (void)dealloc { if(_snapshot) CGImageRelease(_snapshot); }
@end
@implementation NSImage { NSMutableArray<NSImageRep *> *_reps; }
- (instancetype)init { return [self initWithSize:CGSizeZero]; }
- (instancetype)initWithSize:(CGSize)size { if((self=[super init])) { _size=size; _reps=[NSMutableArray new]; } return self; }
- (NSArray *)representations { return [_reps copy]; }
- (void)addRepresentation:(NSImageRep *)rep { if(rep) [_reps addObject:rep]; }
- (void)removeRepresentation:(NSImageRep *)rep { [_reps removeObject:rep]; }
- (CGImageRef)CGImageForProposedRect:(CGRect *)rect context:(id)context hints:(NSDictionary *)hints {
    (void)rect; (void)context; (void)hints;
    for(NSImageRep *rep in _reps) if([rep isKindOfClass:NSBitmapImageRep.class]) return ((NSBitmapImageRep *)rep).CGImage;
    return NULL;
}
- (BOOL)isValid { return _reps.count>0; }
@end
static NSCursor *currentCursor;
static void cursorChanged(void) { [NSNotificationCenter.defaultCenter postNotificationName:@"AKCursorDidChange" object:nil]; }
@implementation NSCursor
- (instancetype)initWithImage:(NSImage *)image hotSpot:(CGPoint)point { if((self=[super init])) { _image=image; _hotSpot=point; } return self; }
+ (NSCursor *)arrowCursor { static NSCursor *arrow; static dispatch_once_t once; dispatch_once(&once,^{ arrow=[[NSCursor alloc] initWithImage:nil hotSpot:CGPointZero]; }); return arrow; }
+ (NSCursor *)currentCursor { return currentCursor ?: self.arrowCursor; }
- (void)set { currentCursor=self; cursorChanged(); }
+ (void)hide { AKCursorHide(); cursorChanged(); }
+ (void)unhide { AKCursorUnhide(); cursorChanged(); }
@end
