#import "TouchControls.h"
#import "TouchTrackpad.h"

@interface AKTouchControls (KeyboardState)
- (void)updateKeyboardButton;
@end

// UIKit needs a real UITextInput client to start system dictation. Keep its
// document local to the current composition; never mirror the guest's text.
@interface AKKeyboardTextView : UITextView <UITextViewDelegate>
@property (nonatomic, weak) AKTouchControls *inputOwner;
@end

@implementation AKKeyboardTextView {
    NSUInteger _editingDepth;
    NSMutableSet *_dictationPlaceholders;
    BOOL _acceptingInput, _clearing;
}
- (instancetype)initWithFrame:(CGRect)frame textContainer:(NSTextContainer *)container {
    if ((self = [super initWithFrame:frame textContainer:container])) {
        self.delegate = self;
        _dictationPlaceholders = [NSMutableSet new];
        self.backgroundColor = UIColor.clearColor;
        self.textColor = UIColor.clearColor;
        self.tintColor = UIColor.clearColor;
        self.accessibilityElementsHidden = YES;
        self.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.autocorrectionType = UITextAutocorrectionTypeNo;
        self.spellCheckingType = UITextSpellCheckingTypeNo;
        self.smartQuotesType = UITextSmartQuotesTypeNo;
        self.smartDashesType = UITextSmartDashesTypeNo;
        self.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
        self.secureTextEntry = NO;
    }
    return self;
}
- (UIView *)inputAccessoryView { return self.inputOwner.inputAccessoryView; }
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)point; (void)event;
    return NO;
}
- (void)clearComposition {
    _clearing = YES;
    [super setText:@""];
    self.selectedRange = NSMakeRange(0, 0);
    [self.undoManager removeAllActions];
    _clearing = NO;
}
- (void)forwardCommittedText {
    if (_editingDepth || _clearing || _dictationPlaceholders.count || self.markedTextRange) return;
    if (!_acceptingInput) { [self clearComposition]; return; }
    if (!self.text.length) return;
    NSString *text = [self.text copy];
    [self clearComposition];
    [self.inputOwner insertText:text];
}
- (BOOL)becomeFirstResponder {
    _acceptingInput = YES;
    BOOL accepted = [super becomeFirstResponder];
    _acceptingInput = accepted;
    [self.inputOwner updateKeyboardButton];
    return accepted;
}
- (BOOL)resignFirstResponder {
    _acceptingInput = NO;
    [_dictationPlaceholders removeAllObjects];
    [self clearComposition];
    BOOL accepted = [super resignFirstResponder];
    // UIKit can re-enter becomeFirstResponder while finishing composition.
    _acceptingInput = !accepted && self.isFirstResponder;
    [self.inputOwner updateKeyboardButton];
    return accepted;
}
- (void)textViewDidChange:(UITextView *)textView {
    (void)textView;
    [self forwardCommittedText];
}
- (void)insertText:(NSString *)text {
    if (!_acceptingInput) return;
    _editingDepth++;
    [super insertText:text];
    _editingDepth--;
    [self forwardCommittedText];
}
- (void)replaceRange:(UITextRange *)range withText:(NSString *)text {
    if (!_acceptingInput) return;
    _editingDepth++;
    [super replaceRange:range withText:text];
    _editingDepth--;
    [self forwardCommittedText];
}
- (void)setMarkedText:(NSString *)text selectedRange:(NSRange)range {
    if (!_acceptingInput) return;
    _editingDepth++;
    [super setMarkedText:text selectedRange:range];
    _editingDepth--;
    [self forwardCommittedText];
}
- (void)unmarkText {
    _editingDepth++;
    [super unmarkText];
    _editingDepth--;
    [self forwardCommittedText];
}
- (void)deleteBackward {
    if (!_acceptingInput) return;
    if (!self.hasText && !self.markedTextRange) { [self.inputOwner deleteBackward]; return; }
    _editingDepth++;
    [super deleteBackward];
    _editingDepth--;
    [self forwardCommittedText];
}
- (id)insertDictationResultPlaceholder {
    if (!_acceptingInput) return nil;
    _editingDepth++;
    id placeholder = [super insertDictationResultPlaceholder];
    if (placeholder) [_dictationPlaceholders addObject:placeholder];
    _editingDepth--;
    return placeholder;
}
- (void)removeDictationResultPlaceholder:(id)placeholder willInsertResult:(BOOL)willInsert {
    if (![_dictationPlaceholders containsObject:placeholder]) return;
    _editingDepth++;
    [super removeDictationResultPlaceholder:placeholder willInsertResult:willInsert];
    [_dictationPlaceholders removeObject:placeholder];
    _editingDepth--;
    [self forwardCommittedText];
}
- (void)dictationRecognitionFailed {
    // This is an optional UITextInput callback, not implemented by UITextView.
    _editingDepth++;
    [_dictationPlaceholders removeAllObjects];
    [self clearComposition];
    _editingDepth--;
}
@end

@implementation AKTouchControls {
    UIButton *_keyboardButton, *_trackpadButton;
    UIView *_accessory;
    NSTimer *_holdTimer;
    AKKeyboardTextView *_keyboardInput;
    AKTrackpad _pad;
}

static void AKEmitTouch(void *context, AKTrackpadAction action, double x, double y, unsigned button) {
    AKTouchControls *controls = (__bridge AKTouchControls *)context;
    switch (action) {
        case AKTrackpadMove: [controls.delegate touchMoveBy:CGPointMake(x, y)]; break;
        case AKTrackpadScroll: [controls.delegate touchScrollBy:CGPointMake(x, y)]; break;
        case AKTrackpadDown: [controls.delegate touchButton:button pressed:YES]; break;
        case AKTrackpadUp: [controls.delegate touchButton:button pressed:NO]; break;
    }
}

- (UIButton *)buttonWithSymbol:(NSString *)symbol label:(NSString *)label action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    button.tintColor = UIColor.whiteColor;
    button.backgroundColor = [UIColor.blackColor colorWithAlphaComponent:0.45];
    button.layer.cornerRadius = 22;
    button.layer.borderWidth = 0.5;
    button.layer.borderColor = [UIColor.whiteColor colorWithAlphaComponent:0.4].CGColor;
    button.accessibilityLabel = label;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self addSubview:button];
    return button;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.zPosition = 100001;
        _keyboardInput = [[AKKeyboardTextView alloc] initWithFrame:CGRectMake(0, 0, 1, 1) textContainer:nil];
        _keyboardInput.inputOwner = self;
        [self addSubview:_keyboardInput];
        _keyboardButton = [self buttonWithSymbol:@"keyboard" label:@"Show keyboard" action:@selector(toggleKeyboard)];
        _keyboardButton.accessibilityIdentifier = @"tolkara.keyboard";
        _trackpadButton = [self buttonWithSymbol:@"hand.draw" label:@"Enable touch trackpad" action:@selector(toggleTrackpad)];
        _trackpadButton.accessibilityIdentifier = @"tolkara.trackpad";
        _trackpadButton.accessibilityHint = @"One finger moves; tap to click. Two fingers scroll or tap for right click. Three fingers tap for middle click. Hold then slide to drag. Long-press this button for mouse buttons.";
        __weak AKTouchControls *weakSelf = self;
        NSMutableArray<UIAction *> *actions = [NSMutableArray new];
        NSArray<NSString *> *buttons = @[@"Left click", @"Right click", @"Middle click"];
        for (unsigned i = 0; i < buttons.count; i++) {
            [actions addObject:[UIAction actionWithTitle:buttons[i] image:nil identifier:nil handler:^(UIAction *action) {
                (void)action;
                AKTouchControls *controls = weakSelf;
                [controls cancelTouches];
                [controls.delegate touchButton:i pressed:YES];
                [controls.delegate touchButton:i pressed:NO];
            }]];
        }
        _trackpadButton.menu = [UIMenu menuWithTitle:@"Mouse buttons" children:actions];
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:@"TKTouchTrackpadEnabled"];
        self.trackpadEnabled = saved ? saved.boolValue : UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(suspendInput:) name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgroundInput:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowResigned:) name:UIWindowDidResignKeyNotification object:nil];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _trackpadButton.frame = CGRectMake(0, 0, 44, 44);
    _keyboardButton.frame = CGRectMake(52, 0, 44, 44);
}
- (void)setTrackpadEnabled:(BOOL)enabled {
    [self cancelTouches];
    _trackpadEnabled = enabled;
    _trackpadButton.tintColor = enabled ? UIColor.systemCyanColor : UIColor.whiteColor;
    _trackpadButton.accessibilityLabel = enabled ? @"Disable touch trackpad" : @"Enable touch trackpad";
    _trackpadButton.accessibilityValue = enabled ? @"On" : @"Off";
    [self.delegate touchTrackpadChanged:enabled];
}
- (void)toggleTrackpad {
    self.trackpadEnabled = !self.trackpadEnabled;
    [NSUserDefaults.standardUserDefaults setBool:self.trackpadEnabled forKey:@"TKTouchTrackpadEnabled"];
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)keyboardVisible { return _keyboardInput.isFirstResponder; }
- (BOOL)becomeFirstResponder {
    BOOL accepted = [_keyboardInput becomeFirstResponder];
    [self updateKeyboardButton];
    return accepted;
}
- (BOOL)resignFirstResponder {
    BOOL accepted = [_keyboardInput resignFirstResponder];
    [self updateKeyboardButton];
    return accepted;
}
- (void)updateKeyboardButton {
    [_keyboardButton setImage:[UIImage systemImageNamed:self.keyboardVisible ? @"keyboard.chevron.compact.down" : @"keyboard"] forState:UIControlStateNormal];
    _keyboardButton.accessibilityLabel = self.keyboardVisible ? @"Hide keyboard" : @"Show keyboard";
}
- (void)toggleKeyboard {
    [self cancelTouches];
    if (self.keyboardVisible) [self dismissKeyboard];
    else [self becomeFirstResponder];
}
- (void)dismissKeyboard {
    if (self.keyboardVisible) {
        [self resignFirstResponder];
        [self.superview becomeFirstResponder];
    }
}
// The guest owns its text and selection. The native input view holds only
// uncommitted composition, then forwards it here and clears its document.
// Always allow a backspace request against the guest's text.
- (BOOL)hasText { return YES; }
- (void)insertText:(NSString *)text { [self.delegate touchInsertText:text]; }
- (void)deleteBackward { [self.delegate touchSpecialKey:51 characters:@"\x7f"]; }

- (UIView *)inputAccessoryView {
    if (!_accessory) {
        UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
        row.distribution = UIStackViewDistributionFillEqually;
        row.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.96];
        NSArray<NSString *> *titles = @[@"Esc", @"Tab", @"←", @"→", @"↵", @"⌄"];
        for (NSUInteger i = 0; i < titles.count; i++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.tag = (NSInteger)i;
            button.tintColor = UIColor.whiteColor;
            [button setTitle:titles[i] forState:UIControlStateNormal];
            button.accessibilityLabel = @[@"Escape", @"Tab", @"Left arrow", @"Right arrow", @"Return", @"Hide keyboard"][i];
            [button addTarget:self action:@selector(accessoryKey:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:button];
        }
        _accessory = row;
    }
    return _accessory;
}
- (void)accessoryKey:(UIButton *)button {
    if (button.tag == 5) { [self dismissKeyboard]; return; }
    const unsigned short codes[] = {53, 48, 123, 124, 36};
    NSArray<NSString *> *characters = @[@"\x1b", @"\t", @"\uF702", @"\uF703", @"\r"];
    if (button.tag >= 0 && button.tag < 5) [self.delegate touchSpecialKey:codes[button.tag] characters:characters[button.tag]];
}

- (void)processTouches:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    if (!self.trackpadEnabled) return;
    for (UITouch *touch in touches) if (touch.phase == UITouchPhaseCancelled) [self cancelTouches];
    unsigned count = 0;
    CGPoint center = CGPointZero;
    for (UITouch *touch in event.allTouches) {
        if (touch.type != UITouchTypeDirect || touch.view != self.superview ||
            touch.phase == UITouchPhaseEnded || touch.phase == UITouchPhaseCancelled) continue;
        CGPoint point = [touch locationInView:self.superview];
        center.x += point.x; center.y += point.y; count++;
    }
    if (count) { center.x /= count; center.y /= count; }
    AKTrackpadUpdate(&_pad, count, center.x, center.y, event.timestamp, AKEmitTouch, (__bridge void *)self);
    [_holdTimer invalidate]; _holdTimer = nil;
    if (_pad.fingers && !_pad.blocked && !_pad.lifting && !_pad.dragging && _pad.travelled <= 8) {
        __weak AKTouchControls *weakSelf = self;
        _holdTimer = [NSTimer timerWithTimeInterval:MAX(0.01, _pad.started + 0.46 - NSProcessInfo.processInfo.systemUptime)
                                          repeats:NO block:^(NSTimer *timer) {
            (void)timer;
            AKTouchControls *controls = weakSelf;
            if (controls) AKTrackpadHold(&controls->_pad, NSProcessInfo.processInfo.systemUptime, AKEmitTouch, (__bridge void *)controls);
        }];
        [NSRunLoop.mainRunLoop addTimer:_holdTimer forMode:NSRunLoopCommonModes];
    }
}
- (void)cancelTouches {
    [_holdTimer invalidate]; _holdTimer = nil;
    AKTrackpadCancel(&_pad, AKEmitTouch, (__bridge void *)self);
    if (!_pad.fingers) _pad = (AKTrackpad){0};
}
- (void)suspendInput:(NSNotification *)notification {
    (void)notification;
    [self cancelTouches];
    _pad = (AKTrackpad){0};
    // Dictation and system permission panels temporarily take focus. Closing
    // the first responder here cancels dictation before its UI can appear.
}
- (void)backgroundInput:(NSNotification *)notification {
    [self suspendInput:notification];
    [self dismissKeyboard];
}
- (void)windowResigned:(NSNotification *)notification {
    if (notification.object == self.window) [self suspendInput:notification];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self backgroundInput:nil];
}
- (void)dealloc {
    [_holdTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
@end
