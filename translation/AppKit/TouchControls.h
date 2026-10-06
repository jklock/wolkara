#import <UIKit/UIKit.h>

@protocol AKTouchControlsDelegate <NSObject>
- (void)touchMoveBy:(CGPoint)delta;
- (void)touchScrollBy:(CGPoint)delta;
- (void)touchButton:(unsigned)button pressed:(BOOL)pressed;
- (void)touchInsertText:(NSString *)text;
- (void)touchSpecialKey:(unsigned short)code characters:(NSString *)characters;
- (void)touchTrackpadChanged:(BOOL)enabled;
- (void)touchKeyboardVisibilityChanged:(BOOL)visible;
- (void)touchGamepadPreferenceChanged:(BOOL)enabled;
- (void)touchControlSettings;
@end

// Lives above the guest layer, but only the toolbar buttons intercept hit testing.
// The host supplies direct touches; hardware mouse input stays on its old path.
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
