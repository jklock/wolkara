#import <QuartzCore/CAMetalLayer.h>
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "AKSupport.h"

// A guest that keeps rendering while its window is off screen burns a whole core,
// and iPadOS kills a background app that exceeds its CPU budget (report 202,
// "cpu_resource") after two or three minutes. That is what ended sessions the
// moment the user switched to another app, even with the audio background mode
// keeping the process alive.
//
// The guest paces itself on the drawable - CAMetalLayer hands out a few at a time
// and nextDrawable waits for one - so capping frames here slows the guest's whole
// loop, network and timers included, instead of stopping it: the game stays
// connected and stays alive while another app is in front. Frames return to the
// display's own rate as soon as the app is active again, and nothing is capped
// while it is.
#define AKBackgroundFrameInterval 0.2

static id<CAMetalDrawable> (*originalNextDrawable)(id,SEL);
static double lastAcquired;
static BOOL throttling;

static IMP replace(Class cls,SEL selector,IMP implementation) {
    Method method=class_getInstanceMethod(cls,selector); if(!method) return NULL;
    IMP original=method_getImplementation(method);
    class_replaceMethod(cls,selector,implementation,method_getTypeEncoding(method)); return original;
}
static id<CAMetalDrawable> pacedNextDrawable(id layer,SEL selector) {
    BOOL hidden=UIApplication.sharedApplication.applicationState!=UIApplicationStateActive;
    if(hidden!=throttling) {
        throttling=hidden;
        if(hidden) AKLog(@"background pacing: frames capped to %.0f/s while another app is in front",1.0/AKBackgroundFrameInterval);
        else AKLog(@"background pacing: frames at the display's own rate again");
    }
    if(hidden) {
        double wait=AKBackgroundFrameInterval-(NSProcessInfo.processInfo.systemUptime-lastAcquired);
        if(wait>0) [NSThread sleepForTimeInterval:wait];
    }
    id<CAMetalDrawable> drawable=originalNextDrawable(layer,selector);
    lastAcquired=NSProcessInfo.processInfo.systemUptime;
    return drawable;
}
void AKInstallMetalBackgroundPacing(void) {
    static dispatch_once_t once;
    dispatch_once(&once,^{
        originalNextDrawable=(void *)replace(CAMetalLayer.class,@selector(nextDrawable),(IMP)pacedNextDrawable);
        if(!originalNextDrawable) AKLog(@"background pacing could not install");
    });
}

// Installed from here, not from a call site: this file is compiled into the Metal
// adapter, which the guest loads before it draws anything, and the platform's own
// files are used as they are. Loading the adapter is therefore the earliest and the
// only place this needs to happen, and the install is idempotent.
__attribute__((constructor)) static void AKBackgroundPacingLoad(void) {
    AKInstallMetalBackgroundPacing();
}
