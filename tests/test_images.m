#import "Images.h"
#include <assert.h>
static NSBitmapImageRep *bitmap(unsigned char **planes, NSInteger width, NSInteger stride) {
    return [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:planes pixelsWide:width pixelsHigh:2 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:@"NSDeviceRGBColorSpace" bitmapFormat:2 bytesPerRow:stride bitsPerPixel:32];
}
int main(void) { @autoreleasepool {
    NSBitmapImageRep *rep=bitmap(NULL,3,16); assert(rep && rep.bytesPerPlane==32 && rep.bytesPerRow==16);
    for(int i=0;i<32;i++) assert(rep.bitmapData[i]==0);
    rep.bitmapData[0]=255; rep.bitmapData[3]=255;
    CGImageRef cg=rep.CGImage; assert(cg && CGImageGetWidth(cg)==3 && CGImageGetHeight(cg)==2);
    CFDataRef first=CGDataProviderCopyData(CGImageGetDataProvider(cg));
    rep.bitmapData[0]=42; cg=rep.CGImage;
    CFDataRef second=CGDataProviderCopyData(CGImageGetDataProvider(cg));
    assert(CFDataGetBytePtr(first)[0]==255 && CFDataGetBytePtr(second)[0]==42);
    CFRelease(first); CFRelease(second);
    unsigned char external[32]={0}, *planes[5]={external};
    @autoreleasepool { NSBitmapImageRep *borrowed=bitmap(planes,3,16); assert(borrowed.bitmapData==external); borrowed.bitmapData[0]=99; }
    assert(external[0]==99); assert(!bitmap(NULL,LONG_MAX,0)); assert(!bitmap(NULL,3,11)); assert(!bitmap(NULL,-1,0));
    [rep getBitmapDataPlanes:planes]; assert(planes[0]==rep.bitmapData && !planes[1] && !planes[4]);
    NSImage *image=[[NSImage alloc] initWithSize:CGSizeMake(3,2)]; [image addRepresentation:rep];
    assert(image.representations.count==1 && [image CGImageForProposedRect:NULL context:nil hints:nil]);
    NSCursor *cursor=[[NSCursor alloc] initWithImage:image hotSpot:CGPointMake(1,2)]; [cursor set];
    assert(NSCursor.currentCursor==cursor && cursor.image==image && cursor.hotSpot.y==2);
    CGPathRef silhouette=AKCreateCursorPath([image CGImageForProposedRect:NULL context:nil hints:nil],image.size,CGPointZero);
    assert(silhouette && CGPathContainsPoint(silhouette,NULL,CGPointMake(.5,.5),false));
    assert(!CGPathContainsPoint(silhouette,NULL,CGPointMake(.5,1.5),false));
    assert(!CGPathContainsPoint(silhouette,NULL,CGPointMake(1.5,.5),false));
    CGPathRelease(silhouette);
    // A transparent hole must remain transparent, and semitransparent shadows
    // should not turn the native cursor into a solid rectangular blob.
    NSBitmapImageRep *ring=[[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:3 pixelsHigh:3 bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:@"NSDeviceRGBColorSpace" bitmapFormat:2 bytesPerRow:12 bitsPerPixel:32];
    for(int i=0;i<9;i++)ring.bitmapData[i*4+3]=255;
    ring.bitmapData[4*4+3]=64;
    silhouette=AKCreateCursorPath(ring.CGImage,CGSizeMake(96,96),CGPointMake(3,6));
    CGRect bounds=CGPathGetBoundingBox(silhouette);
    assert(bounds.size.width==32 && bounds.size.height==32 && bounds.origin.x==-1 && bounds.origin.y==-2);
    assert(!CGPathContainsPoint(silhouette,NULL,CGPointMake(15,14),false));
    assert(CGPathContainsPoint(silhouette,NULL,CGPointMake(2,2),false));
    CGPathRelease(silhouette);
    assert(!AKCreateCursorPath(NULL,image.size,CGPointZero));
    assert(!AKCreateCursorPath(ring.CGImage,CGSizeZero,CGPointZero));
    assert(!AKCursorIsHidden()); [NSCursor hide]; [NSCursor hide]; [NSCursor unhide]; assert(AKCursorIsHidden()); [NSCursor unhide]; [NSCursor unhide]; assert(!AKCursorIsHidden());
    puts("bitmap storage, ownership, overflow, snapshot, cursor ABI and native silhouette: PASS");
} }
