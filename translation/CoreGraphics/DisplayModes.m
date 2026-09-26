// Dictionary-backed descriptions of the UIKit screen exposed by Displays.m.
#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>
typedef CFDictionaryRef CGDisplayModeRef;
size_t CGDisplayModeGetWidth(CGDisplayModeRef m) { return [((__bridge NSDictionary *)m)[@"width"] unsignedLongValue]; }
size_t CGDisplayModeGetHeight(CGDisplayModeRef m) { return [((__bridge NSDictionary *)m)[@"height"] unsignedLongValue]; }
size_t CGDisplayModeGetPixelWidth(CGDisplayModeRef m) { return [((__bridge NSDictionary *)m)[@"pixelWidth"] unsignedLongValue]; }
size_t CGDisplayModeGetPixelHeight(CGDisplayModeRef m) { return [((__bridge NSDictionary *)m)[@"pixelHeight"] unsignedLongValue]; }
double CGDisplayModeGetRefreshRate(CGDisplayModeRef m) { return [((__bridge NSDictionary *)m)[@"refresh"] doubleValue]; }
uint32_t CGDisplayModeGetIOFlags(CGDisplayModeRef m) { return m ? 3 : 0; } // valid + safe
CFStringRef CGDisplayModeCopyPixelEncoding(CGDisplayModeRef m) { return m ? CFRetain(CFSTR("--------RRRRRRRRGGGGGGGGBBBBBBBB")) : NULL; }
void CGDisplayModeRelease(CGDisplayModeRef m) { if(m) CFRelease(m); }
bool CGDisplayModeIsUsableForDesktopGUI(CGDisplayModeRef mode) {
    return mode && CGDisplayModeGetWidth(mode)>0 && CGDisplayModeGetHeight(mode)>0;
}
