#import "Drawing.h"
#include <assert.h>
int main(void) { @autoreleasepool {
    // Wine's Mac driver reads the window background by filling a padded 1x1 RGB bitmap.
    unsigned char rgbx[4]={1,2,3,4}, *planes=rgbx;
    NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:&planes pixelsWide:1 pixelsHigh:1 bitsPerSample:8 samplesPerPixel:3
        hasAlpha:NO isPlanar:NO colorSpaceName:NSCalibratedRGBColorSpace bitmapFormat:0 bytesPerRow:4 bitsPerPixel:32];
    assert(bitmap && bitmap.bitmapData==rgbx && bitmap.bitsPerPixel==32 && !bitmap.hasAlpha);
    assert(!NSGraphicsContext.currentContext);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext *context=[NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
    assert(context && context.graphicsPort==context.CGContext && !context.isFlipped);
    [NSGraphicsContext setCurrentContext:context];
    assert(NSGraphicsContext.currentContext==context);
    [[NSColor windowBackgroundColor] set];
    NSRectFill(CGRectMake(0,0,1,1));
    [NSGraphicsContext restoreGraphicsState];
    assert(!NSGraphicsContext.currentContext);
    assert(rgbx[0]==236 && rgbx[1]==236 && rgbx[2]==236);
    CGImageRef image=bitmap.CGImage;
    assert(image && CGImageGetBitsPerPixel(image)==32 && CGImageGetAlphaInfo(image)==kCGImageAlphaNoneSkipLast);
    // Nested states restore the outer context and its colour; the fill replaces alpha too.
    NSBitmapImageRep *rgba=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:1 bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:0 bytesPerRow:8 bitsPerPixel:32];
    NSGraphicsContext *outer=[NSGraphicsContext graphicsContextWithBitmapImageRep:rgba];
    [NSGraphicsContext setCurrentContext:outer];
    [[NSColor colorWithCalibratedRed:1 green:0 blue:0 alpha:1] setFill];
    [NSGraphicsContext saveGraphicsState];
    [[NSColor clearColor] setFill];
    NSRectFill(CGRectMake(1,0,1,1));
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:nil];
    NSRectFill(CGRectMake(0,0,2,1));   // no context: nothing drawn
    [NSGraphicsContext restoreGraphicsState];
    assert(NSGraphicsContext.currentContext==outer);
    [NSGraphicsContext restoreGraphicsState];
    NSRectFill(CGRectMake(0,0,1,1));
    unsigned char *px=rgba.bitmapData;
    assert(px[0]==255 && px[1]==0 && px[2]==0 && px[3]==255 && px[4]==0 && px[7]==0);
    [NSGraphicsContext restoreGraphicsState];   // unbalanced: ignored
    [NSGraphicsContext setCurrentContext:nil];
    CGFloat r,g,b,a; [[NSColor whiteColor] getRed:&r green:&g blue:&b alpha:&a];
    assert(r>.99 && g>.99 && b>.99 && a==1);
    [[NSColor colorWithDeviceRed:.25 green:.5 blue:.75 alpha:.5] getRed:&r green:NULL blue:&b alpha:&a];
    assert(fabs(r-.25)<.01 && fabs(b-.75)<.01 && a==.5);
    // What Core Graphics cannot draw into gets no context; odd layouts no bitmap.
    NSBitmapImageRep *packed=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:2 pixelsHigh:1 bitsPerSample:8 samplesPerPixel:3
        hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:0 bytesPerRow:0 bitsPerPixel:0];
    assert(packed && packed.bytesPerRow==6 && ![NSGraphicsContext graphicsContextWithBitmapImageRep:packed]);
    assert(![[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1 pixelsHigh:1 bitsPerSample:8 samplesPerPixel:4
        hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:0 bytesPerRow:0 bitsPerPixel:40]);
    assert(![[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:1 pixelsHigh:1 bitsPerSample:8 samplesPerPixel:3
        hasAlpha:NO isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bitmapFormat:0 bytesPerRow:3 bitsPerPixel:32]);
    assert(![NSGraphicsContext graphicsContextWithCGContext:NULL flipped:YES] && ![NSColor colorWithCGColor:NULL]);
    assert([NSImageNameApplicationIcon isEqualToString:@"NSApplicationIcon"]);
    puts("colours, graphics contexts per thread, padded RGB bitmaps and NSRectFill: PASS");
} }
