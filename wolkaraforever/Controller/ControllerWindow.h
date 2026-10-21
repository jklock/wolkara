// WolkaraForever layer: the app's window, watching what arrives at the responder chain.
//
// Why: the GameSir pad sends its Share button as the Print Screen key, and
// iPadOS spends that key on the screenshot and screen-recording gestures. Our
// host view never saw it. But holding Share produced a permission prompt from
// inside the app, which means the key is being routed here — through the window
// and the responder chain — and not simply dropped before it reaches us.
//
// So this window logs every press it is given, with the key's own description,
// and offers a key command for that key so it can be claimed rather than spent.
// It changes nothing else: every press is passed on exactly as before.

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AKControllerWindow : UIWindow
@end

NS_ASSUME_NONNULL_END
