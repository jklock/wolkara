#import <UIKit/UIKit.h>

// Posted when the user chose to close WolkaraForever from the game's toolbar. Shell/main.m observes
// it, flushes what the session owns and ends the process. By name on the shell's side,
// because this module is built into a dylib the shell does not link against.
extern NSNotificationName const AKTouchCloseAppNotification;  // "AKTouchCloseAppNotification"
// Posted when the guest asks for the draft keyboard - the AppKit adapter's
// dictation trigger, a key combination the game itself never sees.
extern NSNotificationName const AKTouchKeyboardRequestNotification;
// Posted with the controls as the object, when they are created. They are the layer's
// UIKeyInput, so they are what reaches the guest; Shell/main.m observes it and hands the
// view to dictation, which types into that view and nowhere else. The draft editor is not
// announced: it is ours, and it cannot reach the game. Kept as a notification because
// this module and the voice module cannot include each other without spelling out the
// prepared tree's layout.
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
// Asked by the adapter at the one place it posts key events to the guest: has the user
// taken this key for dictation, to the point where the game must not see it?
//
// Set by this file's own observer from the notification below, and null until that arrives,
// which means "nothing is owned" - the behaviour without the feature. A function pointer
// rather than a call into the layer because the app never links this: the adapter is built
// as a signed dylib and loaded by name, so a notification is the only channel - the same
// reason the two notifications above exist. See `-[AKVoiceSettings ownsElement:]` for what
// can and cannot be owned.
extern BOOL (*AKTouchKeyIsTakenForVoice)(unsigned short usage);

// Posted by the app's shell whenever the set of keys the user has taken for dictation
// changes, with `AKTouchOwnedKeyUsagesKey` -> a set of `NSNumber` UIKeyboardHIDUsage values
// in userInfo. By name rather than by including the layer's header: this module is compiled
// into a dylib that the shell does not link against.
extern NSNotificationName const AKTouchOwnedKeyUsagesDidChangeNotification;  // "AKTouchOwnedKeyUsagesDidChange"
extern NSString *const AKTouchOwnedKeyUsagesKey;                             // "usages"

@interface AKTouchControls : UIView <UIKeyInput>
// On unless the launcher's switch stored otherwise: this product wants the
// toolbar wherever it runs, not only where the platform's default places it.
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
// What dictation sends the object it was told is the game's text input. Declared here
// because the announcement above promises them: both go straight to the delegate, which
// is what turns words into the guest's key events.
- (void)touchInsertText:(NSString *)text;
- (void)touchSpecialKey:(unsigned short)code characters:(NSString *)characters;
@end
