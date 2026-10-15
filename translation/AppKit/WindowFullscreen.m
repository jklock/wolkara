#import "WindowFullscreen.h"
#import <objc/runtime.h>
#import <objc/message.h>

NSNotificationName const NSWindowWillEnterFullScreenNotification = @"NSWindowWillEnterFullScreenNotification";
NSNotificationName const NSWindowDidEnterFullScreenNotification = @"NSWindowDidEnterFullScreenNotification";
NSNotificationName const NSWindowWillExitFullScreenNotification = @"NSWindowWillExitFullScreenNotification";
NSNotificationName const NSWindowDidExitFullScreenNotification = @"NSWindowDidExitFullScreenNotification";
static char transitionKey;
static const NSUInteger fullscreenMask = 1UL << 14;

static void notify(id<AKFullscreenWindow> window,NSString *name,SEL selector) {
    NSNotification *notification=[NSNotification notificationWithName:name object:window];
    id delegate=window.delegate;
    if([delegate respondsToSelector:selector])
        ((void (*)(id,SEL,id))objc_msgSend)(delegate,selector,notification);
    [NSNotificationCenter.defaultCenter postNotification:notification];
}
void AKToggleFullscreenWindow(id<AKFullscreenWindow> window) {
    if(!window)return;
    if(!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(),^{ AKToggleFullscreenWindow(window); });
        return;
    }
    if(objc_getAssociatedObject(window,&transitionKey))return;
    objc_setAssociatedObject(window,&transitionKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    BOOL entering=!(window.styleMask&fullscreenMask);
    @try {
        notify(window,entering?NSWindowWillEnterFullScreenNotification:NSWindowWillExitFullScreenNotification,
               entering?@selector(windowWillEnterFullScreen:):@selector(windowWillExitFullScreen:));
        window.styleMask=entering ? window.styleMask|fullscreenMask : window.styleMask&~fullscreenMask;
        [window ak_layoutFullscreenWindow];
    } @catch(id exception) {
        objc_setAssociatedObject(window,&transitionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        @throw exception;
    }
    // AppKit completes this after toggleFullScreen: returns. Give callers time
    // to enter their event loop before delivering the completion notification.
    dispatch_async(dispatch_get_main_queue(),^{
        @try {
            notify(window,entering?NSWindowDidEnterFullScreenNotification:NSWindowDidExitFullScreenNotification,
                   entering?@selector(windowDidEnterFullScreen:):@selector(windowDidExitFullScreen:));
        } @finally {
            objc_setAssociatedObject(window,&transitionKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    });
}
