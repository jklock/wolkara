#import <UIKit/UIKit.h>

// Posted when the guest asks for the draft keyboard - the AppKit adapter's
// dictation trigger, a key combination the game itself never sees.
extern NSNotificationName const AKTouchKeyboardRequestNotification;
// Posted with the game's own text view as the object, when it is created. Shell/main.m
// observes it and hands the view to dictation, which types into that view and nowhere
// else. Kept as a notification because this module and the voice module cannot include
// each other without spelling out the prepared tree's layout.
extern NSNotificationName const AKTouchGameTextInputDidAppearNotification;
// Whether the controls are wanted at all. The platform's install path asks this
// before adding them, and the launcher's On-Screen Controls switch stores its
// choice under this key.
extern NSString *const AKTouchControlsDefaultsKey;   // "AKTouchControls"

@protocol AKTouchControlsDelegate <NSObject>
- (void)touchMoveBy:(CGPoint)delta;
- (void)touchScrollBy:(CGPoint)delta;
- (void)touchButton:(unsigned)button pressed:(BOOL)pressed;
- (void)touchInsertText:(NSString *)text;
- (void)touchSpecialKey:(unsigned short)code characters:(NSString *)characters;
- (void)touchTrackpadChanged:(BOOL)enabled;
// Optional: a host with no draft panel, no gamepad and no settings of ours leaves
// these out, and the class asks before calling them. The adapter's older host
// implements the six above and nothing more.
@optional
// Explicit user-requested replacement of the focused field; no text is read.
- (void)touchReplaceText:(NSString *)text;
- (void)touchKeyboardVisibilityChanged:(BOOL)visible;
- (void)touchGamepadPreferenceChanged:(BOOL)enabled;
- (void)touchControlSettings;
@end

// Toolbar above the guest layer, with a separate native draft panel above
// the keyboard. The host supplies direct touches; hardware mouse is unchanged.
@interface AKTouchControls : UIView <UIKeyInput>
// On unless the launcher's switch stored otherwise: this product wants the
// toolbar wherever it runs, not only on iPhone as the platform defaults to.
@property (class, nonatomic, readonly) BOOL enabled;
@property (nonatomic, weak) id<AKTouchControlsDelegate> delegate;
@property (nonatomic) BOOL trackpadEnabled;
@property (nonatomic, readonly) BOOL gamepadEnabled;
- (void)setGamepadVisible:(BOOL)visible;
@property (nonatomic, readonly) BOOL keyboardVisible;
- (void)processTouches:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event;
- (void)cancelTouches;
- (void)toggleKeyboard;
- (void)dismissKeyboard;
@end
