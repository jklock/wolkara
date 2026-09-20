#import <UIKit/UIKit.h>
#include <stdint.h>
#import "AKSupport.h"
bool CGCursorIsVisible(void) { return !AKCursorIsHidden(); }
CGError CGAssociateMouseAndMouseCursorPosition(boolean_t connected) { AKMouseSetCaptured(!connected); return kCGErrorSuccess; }
CGError CGWarpMouseCursorPosition(CGPoint point) {
    if(!AKMouseIsCaptured())return kCGErrorNotImplemented;
    [NSNotificationCenter.defaultCenter postNotificationName:@"AKMouseAnchorChanged" object:nil userInfo:@{@"x":@(point.x),@"y":@(point.y)}];
    return kCGErrorSuccess;
}
typedef uint32_t CGDirectDisplayID;
typedef CFDictionaryRef CGDisplayModeRef;
typedef void (*DisplayCallback)(CGDirectDisplayID, uint32_t, void *);
static NSDictionary *mode(void) { UIScreen *s=UIScreen.mainScreen; return @{@"width":@(s.bounds.size.width),@"height":@(s.bounds.size.height),@"pixelWidth":@(s.bounds.size.width*s.nativeScale),@"pixelHeight":@(s.bounds.size.height*s.nativeScale),@"refresh":@(s.maximumFramesPerSecond)}; }
CGDirectDisplayID CGMainDisplayID(void) { return 1; }
CGError CGGetActiveDisplayList(uint32_t capacity,CGDirectDisplayID *displays,uint32_t *count) {
    if (!count || (capacity && !displays)) return kCGErrorIllegalArgument;
    *count=displays ? (capacity ? 1 : 0) : 1; if(displays && capacity) displays[0]=1; return kCGErrorSuccess;
}
CGRect CGDisplayBounds(CGDirectDisplayID d) { return d==1 ? UIScreen.mainScreen.bounds : CGRectZero; }
bool CGDisplayIsMain(CGDirectDisplayID d) { return d==1; }
size_t CGDisplayPixelsHigh(CGDirectDisplayID d) { return d==1 ? UIScreen.mainScreen.bounds.size.height*UIScreen.mainScreen.nativeScale : 0; }
CGDisplayModeRef CGDisplayCopyDisplayMode(CGDirectDisplayID d) { return d==1 ? CFBridgingRetain(mode()) : NULL; }
CFArrayRef CGDisplayCopyAllDisplayModes(CGDirectDisplayID d,CFDictionaryRef options) { (void)options; return d==1 ? CFBridgingRetain(@[mode()]) : NULL; }
size_t CGDisplayModeGetWidth(CGDisplayModeRef m) { return [((__bridge NSDictionary *)m)[@"width"] unsignedLongValue]; }
size_t CGDisplayModeGetHeight(CGDisplayModeRef m) { return [((__bridge NSDictionary *)m)[@"height"] unsignedLongValue]; }
size_t CGDisplayModeGetPixelWidth(CGDisplayModeRef m) { return [((__bridge NSDictionary *)m)[@"pixelWidth"] unsignedLongValue]; }
size_t CGDisplayModeGetPixelHeight(CGDisplayModeRef m) { return [((__bridge NSDictionary *)m)[@"pixelHeight"] unsignedLongValue]; }
double CGDisplayModeGetRefreshRate(CGDisplayModeRef m) { return [((__bridge NSDictionary *)m)[@"refresh"] doubleValue]; }
uint32_t CGDisplayModeGetIOFlags(CGDisplayModeRef m) { return m ? 3 : 0; } // valid + safe
CFStringRef CGDisplayModeCopyPixelEncoding(CGDisplayModeRef m) { return m ? CFRetain(CFSTR("--------RRRRRRRRGGGGGGGGBBBBBBBB")) : NULL; }
void CGDisplayModeRelease(CGDisplayModeRef m) { if(m) CFRelease(m); }
uint32_t CGDisplayVendorNumber(CGDirectDisplayID d) { return d==1 ? 0x610 : 0; }
uint32_t CGDisplayModelNumber(CGDirectDisplayID d) { (void)d; return 0; }
uint32_t CGDisplaySerialNumber(CGDirectDisplayID d) { (void)d; return 0; }
// UIKit owns the integrated display. Translate mode-change notifications to the
// single display exposed by the bridge, retaining callback registrations.
static NSMutableDictionary<NSString *,id> *observers;
static NSString *callbackKey(DisplayCallback callback,void *context) { return [NSString stringWithFormat:@"%p:%p",callback,context]; }
CGError CGDisplayRegisterReconfigurationCallback(DisplayCallback callback,void *context) {
    if(!callback) return kCGErrorIllegalArgument;
    @synchronized(UIScreen.class) {
        if(!observers) observers=[NSMutableDictionary new]; NSString *key=callbackKey(callback,context);
        if(!observers[key]) observers[key]=[NSNotificationCenter.defaultCenter addObserverForName:UIScreenModeDidChangeNotification object:UIScreen.mainScreen queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; callback(1,1<<4,context); }];
    }
    return kCGErrorSuccess;
}
CGError CGDisplayRemoveReconfigurationCallback(DisplayCallback callback,void *context) {
    @synchronized(UIScreen.class) { NSString *key=callbackKey(callback,context); id observer=observers[key]; if(observer) [NSNotificationCenter.defaultCenter removeObserver:observer]; [observers removeObjectForKey:key]; }
    return kCGErrorSuccess;
}
