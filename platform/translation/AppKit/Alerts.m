#import "AppKit.h"
// Alert configuration is a desktop model and may be built on a worker thread.
// Only presentation creates UIKit objects, always on the main thread.
@interface AKAlertButton : AKStubObject
@property(copy) NSString *title, *keyEquivalent;
@property BOOL enabled;
@end
@implementation AKAlertButton
@end
@interface NSAlert : AKStubObject
@property(copy) NSString *messageText, *informativeText;
@property NSUInteger alertStyle;
@property(readonly) NSArray *buttons;
- (id)addButtonWithTitle:(NSString *)title;
- (NSInteger)runModal;
@end
@implementation NSAlert { NSMutableArray<AKAlertButton *> *_buttons; }
- (instancetype)init { if((self=[super init])) _buttons=[NSMutableArray new]; return self; }
- (NSArray *)buttons { return _buttons; }
- (id)addButtonWithTitle:(NSString *)title { AKAlertButton *button=[AKAlertButton new]; button.title=title; button.enabled=YES; [_buttons addObject:button]; return button; }
- (NSInteger)runModal {
    AKLog(@"guest alert: %@ — %@",self.messageText,self.informativeText);
    if(!_buttons.count) [self addButtonWithTitle:@"OK"];
    NSArray *buttons=[_buttons copy]; NSString *title=[self.messageText copy],*message=[self.informativeText copy];
    dispatch_semaphore_t completion=dispatch_semaphore_create(0);
    __block NSInteger result=-1001; // NSModalResponseAbort
    __block BOOL finished=NO;
    void (^present)(void)=^{
        UIViewController *presenter=nil;
        for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) if([scene isKindOfClass:UIWindowScene.class]) {
            for(UIWindow *window in ((UIWindowScene *)scene).windows) if(window.isKeyWindow) presenter=window.rootViewController;
        }
        while(presenter.presentedViewController) presenter=presenter.presentedViewController;
        if(!presenter) { finished=YES; dispatch_semaphore_signal(completion); return; }
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [buttons enumerateObjectsUsingBlock:^(AKAlertButton *button,NSUInteger index,BOOL *stop) {
            (void)stop;
            UIAlertAction *action=[UIAlertAction actionWithTitle:button.title style:UIAlertActionStyleDefault handler:^(UIAlertAction *selected) {
                (void)selected; result=1000+(NSInteger)index; finished=YES; dispatch_semaphore_signal(completion);
            }];
            action.enabled=button.enabled; [alert addAction:action];
        }];
        [presenter presentViewController:alert animated:YES completion:nil];
    };
    if(NSThread.isMainThread) {
        present(); while(!finished) CFRunLoopRunInMode(kCFRunLoopDefaultMode,.1,true);
    } else {
        dispatch_async(dispatch_get_main_queue(),present);
        dispatch_semaphore_wait(completion,DISPATCH_TIME_FOREVER);
    }
    return result;
}
@end
