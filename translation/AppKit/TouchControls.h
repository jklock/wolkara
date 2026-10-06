#import <UIKit/UIKit.h>

@protocol AKTouchControlsDelegate <NSObject>
- (void)touchMoveBy:(CGPoint)delta;
- (void)touchScrollBy:(CGPoint)delta;
- (void)touchButton:(unsigned)button pressed:(BOOL)pressed;
- (void)touchInsertText:(NSString *)text;
// Explicit user-requested replacement of the focused field; no text is read.
- (void)touchReplaceText:(NSString *)text;
- (void)touchSpecialKey:(unsigned short)code characters:(NSString *)characters;
- (void)touchTrackpadChanged:(BOOL)enabled;
- (void)touchKeyboardVisibilityChanged:(BOOL)visible;
- (void)touchGamepadPreferenceChanged:(BOOL)enabled;
- (void)touchControlSettings;
@end

// Toolbar above the guest layer, with a separate native draft panel above
// the keyboard. The host supplies direct touches; hardware mouse is unchanged.
@interface AKTouchControls : UIView <UIKeyInput>
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
