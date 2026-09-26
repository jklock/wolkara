#import <Foundation/Foundation.h>
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
typedef CFDictionaryRef CGDisplayModeRef;
extern size_t CGDisplayModeGetWidth(CGDisplayModeRef);
extern size_t CGDisplayModeGetHeight(CGDisplayModeRef);
extern size_t CGDisplayModeGetPixelWidth(CGDisplayModeRef);
extern size_t CGDisplayModeGetPixelHeight(CGDisplayModeRef);
extern double CGDisplayModeGetRefreshRate(CGDisplayModeRef);
extern uint32_t CGDisplayModeGetIOFlags(CGDisplayModeRef);
extern CFStringRef CGDisplayModeCopyPixelEncoding(CGDisplayModeRef);
extern void CGDisplayModeRelease(CGDisplayModeRef);
extern bool CGDisplayModeIsUsableForDesktopGUI(CGDisplayModeRef);
int main(void) { @autoreleasepool {
    NSDictionary *description=@{@"width":@1376,@"height":@1032,@"pixelWidth":@2752,@"pixelHeight":@2064,@"refresh":@120};
    CGDisplayModeRef mode=CFBridgingRetain(description);
    assert(CGDisplayModeIsUsableForDesktopGUI(mode));
    assert(CGDisplayModeGetWidth(mode)==1376 && CGDisplayModeGetHeight(mode)==1032);
    assert(CGDisplayModeGetPixelWidth(mode)==2752 && CGDisplayModeGetPixelHeight(mode)==2064);
    assert(CGDisplayModeGetRefreshRate(mode)==120 && (CGDisplayModeGetIOFlags(mode)&3)==3);
    CFStringRef encoding=CGDisplayModeCopyPixelEncoding(mode);
    assert(encoding && CFEqual(encoding,CFSTR("--------RRRRRRRRGGGGGGGGBBBBBBBB")));
    CFRelease(encoding);CGDisplayModeRelease(mode);
    assert(!CGDisplayModeIsUsableForDesktopGUI(NULL));
    assert(CGDisplayModeGetWidth(NULL)==0 && CGDisplayModeGetHeight(NULL)==0);
    assert(CGDisplayModeCopyPixelEncoding(NULL)==NULL && CGDisplayModeGetIOFlags(NULL)==0);
    CGDisplayModeRelease(NULL);
    assert(!CGDisplayModeIsUsableForDesktopGUI((__bridge CFDictionaryRef)@{}));
    assert(!CGDisplayModeIsUsableForDesktopGUI((__bridge CFDictionaryRef)@{@"width":@100,@"height":@0}));
    puts("PASS: virtual display GUI usability, logical/pixel dimensions, refresh, flags and mode ownership");
} }
