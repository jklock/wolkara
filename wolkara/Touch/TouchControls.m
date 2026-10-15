#import "TouchControls.h"
#import "AKSupport.h"
#import "TouchTrackpad.h"
#import "TouchGamepadLayout.h"
#import "TouchGamepad.h"
#import "TouchHaptics.h"
#import <objc/message.h>

NSNotificationName const AKTouchKeyboardRequestNotification = @"AKTouchKeyboardRequestNotification";
// The keys the launcher's and the platform's switches read. The trackpad string
// is the one the platform already stored, so an existing choice carries over.
NSString *const AKTouchControlsDefaultsKey = @"AKTouchControls";
static NSString *const AKTouchTrackpadDefaultsKey = @"TKTouchTrackpadEnabled";
// A software keyboard's keys are several hundred points tall; a keyboard frame
// this small is the shortcut bar alone, which is what iPadOS shows for a
// hardware keyboard. Its microphone key is part of the keys that are hidden.
static CGFloat const AKKeyboardKeysHeight = 150;
static NSString *const AKComposerDefaultLabel = @"Draft · Replaces the field; empty clears it";
// GameController's own class, asked by name: this adapter's headers carry a
// GCKeyboard of their own for the guest.
static BOOL hardwareKeyboardAttached(void) {
    Class cls = NSClassFromString(@"GCKeyboard"); if (!cls) return NO;
    SEL sel = NSSelectorFromString(@"coalescedKeyboard"); if (![cls respondsToSelector:sel]) return NO;
    id (*call)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return call((id)cls, sel) != nil;
}

@interface AKTouchControls (KeyboardState)
- (void)updateKeyboardButton;
- (void)updateDraftButtons;
- (void)replaceGameText:(NSString *)text;
// YES while the user has asked for the draft keyboard and it has not been
// dismissed: the draft editor uses it to decide whether to take focus back when
// a system panel (dictation) has finished with it.
- (BOOL)keyboardRequested;
@end

// A normal, visible UIKit document. Editing and dictation stay local until
// Replace is requested; never reset the text context on every keyboard callback.
@interface AKKeyboardTextView : UITextView <UITextViewDelegate>
@property (nonatomic, weak) AKTouchControls *inputOwner;
- (BOOL)forwardCommittedText;
- (void)discardDraft;
- (BOOL)canModifyDraft;
- (BOOL)canReplaceField;
@end

@implementation AKKeyboardTextView {
    NSMutableSet *_dictationPlaceholders;
    BOOL _acceptingInput, _didSubmitDraft, _resignedForDictation;
    NSUInteger _session;
}
- (instancetype)initWithFrame:(CGRect)frame textContainer:(NSTextContainer *)container {
    if ((self = [super initWithFrame:frame textContainer:container])) {
        self.delegate = self;
        _dictationPlaceholders = [NSMutableSet new];
        self.backgroundColor = [UIColor colorWithWhite:0.2 alpha:1];
        self.textColor = UIColor.whiteColor;
        self.tintColor = UIColor.systemCyanColor;
        self.font = [UIFont systemFontOfSize:17];
        self.layer.cornerRadius = 8;
        self.accessibilityLabel = @"Replacement text";
        self.accessibilityHint = @"Tap Replace to replace the selected game field, or leave this empty to clear it. Existing game text is not shown here.";
        self.accessibilityIdentifier = @"wolkara.keyboard.draft";
        self.autocapitalizationType = UITextAutocapitalizationTypeNone;
        self.autocorrectionType = UITextAutocorrectionTypeNo;
        self.spellCheckingType = UITextSpellCheckingTypeNo;
        self.smartQuotesType = UITextSmartQuotesTypeNo;
        self.smartDashesType = UITextSmartDashesTypeNo;
        self.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
        self.returnKeyType = UIReturnKeyDone;
        self.secureTextEntry = NO;
    }
    return self;
}
- (UIView *)inputAccessoryView { return self.inputOwner.inputAccessoryView; }
- (BOOL)canModifyDraft { return _acceptingInput && !_dictationPlaceholders.count && !self.markedTextRange; }
- (BOOL)canReplaceField { return [self canModifyDraft] && (self.hasText || !_didSubmitDraft); }
- (void)textViewDidChange:(UITextView *)view {
    (void)view;
    _didSubmitDraft = NO;
    [self.inputOwner updateDraftButtons];
}
- (void)textViewDidChangeSelection:(UITextView *)view { (void)view; [self.inputOwner updateDraftButtons]; }
- (void)discardDraft {
    [super setText:@""];
    [self.undoManager removeAllActions];
    [self.inputOwner updateDraftButtons];
}
- (BOOL)forwardCommittedText {
    if (![self canReplaceField]) return NO;
    // Drafts cannot send Return/Tab or other control keys by pasting text.
    // Those keys remain explicit actions in the accessory bar.
    NSString *text = [[self.text componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet]
        componentsJoinedByString:@" "];
    [self discardDraft];
    // Once cleared after submission, repeated taps/queued Done callbacks must
    // not turn a successful replacement into an accidental empty replacement.
    _didSubmitDraft = YES;
    [self.inputOwner updateDraftButtons];
    [self.inputOwner replaceGameText:text];
    return YES;
}
- (BOOL)becomeFirstResponder {
    if (!self.isFirstResponder) _didSubmitDraft = NO;
    _acceptingInput = YES;
    BOOL accepted = [super becomeFirstResponder];
    _acceptingInput = accepted;
    [self.inputOwner updateKeyboardButton];
    return accepted;
}
- (BOOL)resignFirstResponder {
    BOOL accepted = [super resignFirstResponder];
    if (accepted) {
        _session++;
        if (_dictationPlaceholders.count) {
            // The system dictation UI takes focus while the microphone listens.
            // The draft and the pending result are the user's: keep both, and
            // take focus back when the session ends (endDictationSessionIfIdle).
            // Only a pending dictation placeholder says so: text a keyboard is
            // still composing is discarded like any other draft.
            _resignedForDictation = YES;
            AKLog(@"draft editor resigned with dictation pending; keeping the draft");
        } else {
            _acceptingInput = NO;
            [_dictationPlaceholders removeAllObjects];
            [self discardDraft];
        }
    }
    [self.inputOwner updateKeyboardButton];
    return accepted;
}
// The dictation session has finished. If it left the editor without focus, take
// it back so the dictated draft is visible and Replace works, as it was before.
- (void)endDictationSessionIfIdle {
    if (_dictationPlaceholders.count || self.markedTextRange || !_resignedForDictation) return;
    _resignedForDictation = NO;
    if (!self.inputOwner.keyboardRequested) return;
    AKLog(@"dictation session ended without focus; restoring the draft keyboard");
    __weak AKKeyboardTextView *weakSelf = self;
    [NSRunLoop.mainRunLoop performInModes:@[NSRunLoopCommonModes] block:^{
        AKKeyboardTextView *input = weakSelf;
        if (input && input.inputOwner.keyboardRequested && !input.isFirstResponder) [input becomeFirstResponder];
    }];
}
- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    (void)textView; (void)range;
    if ([text isEqual:@"\n"]) {
        // Done replaces the field without pressing Return in the game. Defer
        // until UIKit finishes this edit; do not mutate its document here.
        NSUInteger session = _session;
        __weak AKKeyboardTextView *weakSelf = self;
        [NSRunLoop.mainRunLoop performInModes:@[NSRunLoopCommonModes] block:^{
            AKKeyboardTextView *input = weakSelf;
            if (input && input->_session == session) [input forwardCommittedText];
        }];
        return NO;
    }
    return _acceptingInput;
}
- (void)insertText:(NSString *)text { if (_acceptingInput) [super insertText:text]; }
- (void)replaceRange:(UITextRange *)range withText:(NSString *)text {
    if (_acceptingInput) [super replaceRange:range withText:text];
}
- (void)setMarkedText:(NSString *)text selectedRange:(NSRange)range {
    if (_acceptingInput) [super setMarkedText:text selectedRange:range];
}
- (void)unmarkText { if (_acceptingInput) [super unmarkText]; }
- (id)insertDictationResultPlaceholder {
    // Dictation can start while the system panel, not this editor, holds focus:
    // the result is still the user's draft, so accept it from here on. UIKit also
    // requires a placeholder for the session to start at all: refusing it is how
    // "the microphone is visible but tapping it does nothing" looks.
    _acceptingInput = YES;
    id placeholder = [super insertDictationResultPlaceholder];
    if (placeholder) [_dictationPlaceholders addObject:placeholder];
    AKLog(@"dictation placeholder inserted=%d pending=%lu accepting=%d", placeholder != nil, (unsigned long)_dictationPlaceholders.count, _acceptingInput);
    [self.inputOwner updateDraftButtons];
    return placeholder;
}
- (void)removeDictationResultPlaceholder:(id)placeholder willInsertResult:(BOOL)willInsert {
    if (![_dictationPlaceholders containsObject:placeholder]) return;
    [super removeDictationResultPlaceholder:placeholder willInsertResult:willInsert];
    [_dictationPlaceholders removeObject:placeholder];
    AKLog(@"dictation placeholder removed willInsertResult=%d pending=%lu", willInsert, (unsigned long)_dictationPlaceholders.count);
    [self.inputOwner updateDraftButtons];
    [self endDictationSessionIfIdle];
}
// Lengths only: never log or retain what was dictated.
- (void)insertDictationResult:(NSArray<UIDictationPhrase *> *)dictationResult {
    NSUInteger characters = 0;
    for (UIDictationPhrase *phrase in dictationResult) characters += phrase.text.length;
    AKLog(@"dictation result: %lu phrases, %lu characters", (unsigned long)dictationResult.count, (unsigned long)characters);
    [super insertDictationResult:dictationResult];
}
- (void)dictationRecognitionFailed {
    AKLog(@"dictation recognition failed (markedText=%d, placeholders=%lu)", self.markedTextRange != nil, (unsigned long)_dictationPlaceholders.count);
    // UITextView does not implement this optional callback. Preserve the
    // completed draft; only discard the provisional recognition segment.
    if (self.markedTextRange) {
        [super setMarkedText:@"" selectedRange:NSMakeRange(0, 0)];
        [super unmarkText];
    }
    [_dictationPlaceholders removeAllObjects];
    [self.inputOwner updateDraftButtons];
    [self endDictationSessionIfIdle];
}
@end

@implementation AKTouchControls {
    UIButton *_keyboardButton, *_trackpadButton, *_gamepadButton, *_settingsButton;
    UIButton *_insertDraftButton, *_clearDraftButton;
    UILabel *_composerLabel;
    BOOL _gamepadEnabled, _keyboardRequested, _systemKeyboardSeen;
    CGFloat _systemKeyboardHeight;
    UIView *_accessory, *_composer;
    NSTimer *_holdTimer;
    AKKeyboardTextView *_keyboardInput;
    AKTrackpad _pad;
    AKTouchHaptics *_haptics;
    AKTouchGamepad *_gamepad;
    BOOL _claimedPlace;
}

// The launcher's switch, and the platform's install path, ask this before the
// controls are added. A stored choice wins; without one they are on, because
// this product wants them on every device it runs on.
+ (BOOL)enabled {
    NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:AKTouchControlsDefaultsKey];
    return [saved isKindOfClass:NSNumber.class] ? saved.boolValue : YES;
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
    [button addTarget:self action:@selector(buttonTouchDown) forControlEvents:UIControlEventTouchDown];
    [self addSubview:button];
    return button;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.zPosition = 100001;
        _haptics = [AKTouchHaptics new];
        _keyboardInput = [[AKKeyboardTextView alloc] initWithFrame:CGRectMake(0, 0, 1, 1) textContainer:nil];
        _keyboardInput.inputOwner = self;
        [self buildComposer];
        _keyboardButton = [self buttonWithSymbol:@"keyboard" label:@"Show keyboard" action:@selector(toggleKeyboard)];
        _keyboardButton.accessibilityIdentifier = @"tolkara.keyboard";
        _trackpadButton = [self buttonWithSymbol:@"cursorarrow" label:@"Enable touch trackpad" action:@selector(toggleTrackpad)];
        // Optical centering for the left-leaning symbol; keep its hit area fixed.
        _trackpadButton.imageView.transform = CGAffineTransformMakeTranslation(4, 0);
        _trackpadButton.accessibilityIdentifier = @"tolkara.trackpad";
        _gamepadButton = [self buttonWithSymbol:@"gamecontroller" label:@"Automatic touch controller" action:@selector(toggleGamepad)];
        _gamepadButton.accessibilityIdentifier = @"tolkara.gamepad";
        _settingsButton = [self buttonWithSymbol:@"gearshape" label:@"Touch control settings" action:@selector(showControlSettings)];
        _settingsButton.accessibilityIdentifier = @"wolkara.controlSettings";
        _gamepadButton.accessibilityHint = @"Show touch controls when no physical controller is connected. Tap to turn off or restore automatic controls.";
        NSNumber *gamepad = [NSUserDefaults.standardUserDefaults objectForKey:@"TKTouchGamepadEnabled"];
        _gamepadEnabled = gamepad ? gamepad.boolValue : YES;
        [self setGamepadVisible:NO];
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
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:AKTouchTrackpadDefaultsKey];
        self.trackpadEnabled = saved ? saved.boolValue : UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(suspendInput:) name:UIApplicationWillResignActiveNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(backgroundInput:) name:UIApplicationDidEnterBackgroundNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(windowResigned:) name:UIWindowDidResignKeyNotification object:nil];
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(controlAppearanceChanged:)
            name:AKGamepadLayoutDidChangeNotification object:NSUserDefaults.standardUserDefaults];    // Whether the system keyboard (and so its dictation button) exists at all on
    // this device, and whether UIKit is talking to our draft editor when it does.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(systemKeyboardShown:) name:UIKeyboardDidShowNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(systemKeyboardHidden:) name:UIKeyboardDidHideNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardRequestedByGuest:) name:AKTouchKeyboardRequestNotification object:nil];        [self controlAppearanceChanged:nil];
    }
    return self;
}

- (void)controlAppearanceChanged:(NSNotification *)notification {
    (void)notification;
    AKGamepadLayout *layout = [[AKGamepadLayout alloc] initWithDefaults:NSUserDefaults.standardUserDefaults];
    _haptics.enabled = layout.hapticsEnabled;
    for (UIButton *button in @[_trackpadButton, _keyboardButton, _gamepadButton, _settingsButton]) button.alpha = layout.opacity;
}
- (void)buttonTouchDown { [_haptics buttonPressed]; }

- (void)layoutSubviews {
    [super layoutSubviews];
    _trackpadButton.frame = CGRectMake(0, 0, 44, 44);
    _keyboardButton.frame = CGRectMake(52, 0, 44, 44);
    _gamepadButton.frame = CGRectMake(104, 0, 44, 44);
    _settingsButton.frame = CGRectMake(156, 0, 44, 44);
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
    [NSUserDefaults.standardUserDefaults setBool:self.trackpadEnabled forKey:AKTouchTrackpadDefaultsKey];
}
- (BOOL)gamepadEnabled { return _gamepadEnabled; }
- (void)showControlSettings {
    [self cancelTouches]; [self dismissKeyboard];
    // The gamepad owns the settings sheet, so we open it here rather than asking a
    // host that may have no such thing.
    [_gamepad toggleSettings];
    if ([self.delegate respondsToSelector:@selector(touchControlSettings)]) [self.delegate touchControlSettings];
}
- (void)setGamepadVisible:(BOOL)visible {
    _gamepadButton.tintColor = visible ? UIColor.systemCyanColor : UIColor.whiteColor;
    _gamepadButton.accessibilityValue = _gamepadEnabled ? (visible ? @"Active" : @"Automatic") : @"Off";
}
- (void)toggleGamepad {
    _gamepadEnabled = !_gamepadEnabled;
    [NSUserDefaults.standardUserDefaults setBool:_gamepadEnabled forKey:@"TKTouchGamepadEnabled"];
    _gamepad.enabled = _gamepadEnabled;
    [self setGamepadVisible:_gamepad.visible];
    if ([self.delegate respondsToSelector:@selector(touchGamepadPreferenceChanged:)])
        [self.delegate touchGamepadPreferenceChanged:_gamepadEnabled];
}
- (BOOL)canBecomeFirstResponder { return YES; }
- (BOOL)keyboardVisible { return _keyboardInput.isFirstResponder; }
- (BOOL)becomeFirstResponder {
    _composer.hidden = NO;
    _gamepad.keyboardVisible = YES;
    if ([self.delegate respondsToSelector:@selector(touchKeyboardVisibilityChanged:)])
        [self.delegate touchKeyboardVisibilityChanged:YES];
    _keyboardRequested = YES;
    _systemKeyboardSeen = NO;
    BOOL accepted = [_keyboardInput becomeFirstResponder];
    [self updateKeyboardButton];
    // A hardware keyboard hides the software keyboard, and with it the dictation
    // button. Record it once instead of leaving a keyboard that cannot dictate,
    // and point at the keyboard key when only the shortcut bar is on screen.
    __weak AKTouchControls *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AKTouchControls *controls = weakSelf;
        if (!controls || !controls.keyboardVisible) return;
        AKLog(@"hardware keyboard %@", hardwareKeyboardAttached() ? @"attached" : @"absent");
        if (!controls->_systemKeyboardSeen) {
            AKLog(@"software keyboard did not appear (hardware keyboard attached?); it carries the dictation button");
        } else if (controls->_systemKeyboardHeight < AKKeyboardKeysHeight) {
            AKLog(@"software keyboard keys are not on screen (height %.0f, hardware keyboard attached?); pressing the keyboard key shows them", controls->_systemKeyboardHeight);
            controls->_composerLabel.text = @"Draft · Press the keyboard key (⌘K) for the keyboard's microphone; a hardware keyboard hides it";
        }
    });
    return accepted;
}
- (BOOL)keyboardRequested { return _keyboardRequested; }
- (BOOL)resignFirstResponder {
    BOOL accepted = [_keyboardInput resignFirstResponder];
    [self updateKeyboardButton];
    return accepted;
}
- (void)updateKeyboardButton {
    _composer.hidden = !self.keyboardVisible;
    [self updateDraftButtons];
    [_keyboardButton setImage:[UIImage systemImageNamed:self.keyboardVisible ? @"keyboard.chevron.compact.down" : @"keyboard"] forState:UIControlStateNormal];
    _keyboardButton.accessibilityLabel = self.keyboardVisible ? @"Hide keyboard" : @"Show keyboard";
    _gamepad.keyboardVisible = self.keyboardVisible;
    if ([self.delegate respondsToSelector:@selector(touchKeyboardVisibilityChanged:)])
        [self.delegate touchKeyboardVisibilityChanged:self.keyboardVisible];
}
- (void)toggleKeyboard {
    [self cancelTouches];
    if (self.keyboardVisible) [self dismissKeyboard];
    else [self becomeFirstResponder];
}
- (void)dismissKeyboard {
    _keyboardRequested = NO;
    if (self.keyboardVisible) {
        [self resignFirstResponder];
        [self.superview becomeFirstResponder];
    }
}
// The guest owns its text/selection. Explicit Replace replaces the field.
// Accessory keys still allow editing existing text directly in the guest.
- (BOOL)hasText { return YES; }
- (void)insertText:(NSString *)text { [self.delegate touchInsertText:text]; }
- (void)replaceGameText:(NSString *)text {
    // A host with no draft panel leaves this out; the button then does nothing
    // rather than crashing.
    if ([self.delegate respondsToSelector:@selector(touchReplaceText:)]) [self.delegate touchReplaceText:text];
}
- (void)deleteBackward { [self.delegate touchSpecialKey:51 characters:@"\x7f"]; }

- (UIView *)inputAccessoryView {
    if (!_accessory) {
        UIStackView *row = [[UIStackView alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];
        row.distribution = UIStackViewDistributionFillEqually;
        row.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.96];
        NSArray<NSString *> *titles = @[@"Esc", @"Tab", @"←", @"→", @"⌫", @"↵", @"⌄"];
        for (NSUInteger i = 0; i < titles.count; i++) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            button.tag = (NSInteger)i;
            button.tintColor = UIColor.whiteColor;
            [button setTitle:titles[i] forState:UIControlStateNormal];
            button.accessibilityIdentifier = [NSString stringWithFormat:@"wolkara.keyboard.key.%lu", (unsigned long)i];
            button.accessibilityLabel = @[@"Escape", @"Tab", @"Left arrow", @"Right arrow", @"Game backspace", @"Return", @"Hide keyboard"][i];
            [button addTarget:self action:@selector(accessoryKey:) forControlEvents:UIControlEventTouchUpInside];
            [row addArrangedSubview:button];
        }
        _accessory = row;
        [self updateDraftButtons];
    }
    return _accessory;
}
- (void)accessoryKey:(UIButton *)button {
    if (button.tag == 6) { [self dismissKeyboard]; return; }
    // Replace and Return/Tab are deliberate separate steps. Do not accidentally
    // send an unfinished draft or switch the guest field during composition.
    if (_keyboardInput.text.length || ![_keyboardInput canModifyDraft]) return;
    const unsigned short codes[] = {53, 48, 123, 124, 51, 36};
    NSArray<NSString *> *characters = @[@"\x1b", @"\t", @"\uF702", @"\uF703", @"\x7f", @"\r"];
    if (button.tag >= 0 && button.tag < 6) [self.delegate touchSpecialKey:codes[button.tag] characters:characters[button.tag]];
}
- (void)insertDraft { [_keyboardInput forwardCommittedText]; }
- (void)clearDraft { if ([_keyboardInput canModifyDraft]) [_keyboardInput discardDraft]; }
- (void)updateDraftButtons {
    BOOL ready = [_keyboardInput canModifyDraft];
    _insertDraftButton.enabled = [_keyboardInput canReplaceField];
    _clearDraftButton.enabled = ready && _keyboardInput.hasText;
    for (UIButton *button in ((UIStackView *)_accessory).arrangedSubviews) {
        button.enabled = button.tag == 6 || (ready && !_keyboardInput.hasText);
    }
}
- (void)buildComposer {
    _composer = [[UIView alloc] initWithFrame:CGRectZero];
    _composer.hidden = YES;
    _composer.translatesAutoresizingMaskIntoConstraints = NO;
    _composer.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.98];
    _composer.layer.cornerRadius = 12;
    _composer.layer.zPosition = self.layer.zPosition;
    UILabel *label = _composerLabel = [UILabel new];
    label.text = AKComposerDefaultLabel;
    label.font = [UIFont systemFontOfSize:12];
    label.textColor = UIColor.lightGrayColor;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.75;
    UIButton *insert = _insertDraftButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [insert setTitle:@"Replace" forState:UIControlStateNormal];
    insert.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    insert.accessibilityIdentifier = @"wolkara.keyboard.insert";
    insert.accessibilityHint = @"Replaces the whole selected game field. An empty draft clears it. Does not press Return.";
    [insert addTarget:self action:@selector(insertDraft) forControlEvents:UIControlEventTouchUpInside];
    UIButton *clear = _clearDraftButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [clear setImage:[UIImage systemImageNamed:@"xmark.circle"] forState:UIControlStateNormal];
    clear.accessibilityLabel = @"Clear draft";
    clear.accessibilityIdentifier = @"wolkara.keyboard.clear";
    [clear addTarget:self action:@selector(clearDraft) forControlEvents:UIControlEventTouchUpInside];
    for (UIView *view in @[label, _keyboardInput, insert, clear]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [_composer addSubview:view];
    }
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:_composer.leadingAnchor constant:12],
        [label.topAnchor constraintEqualToAnchor:_composer.topAnchor constant:6],
        [label.trailingAnchor constraintEqualToAnchor:_composer.trailingAnchor constant:-12],
        [label.heightAnchor constraintEqualToConstant:16],
        [_keyboardInput.leadingAnchor constraintEqualToAnchor:_composer.leadingAnchor constant:8],
        [_keyboardInput.topAnchor constraintEqualToAnchor:label.bottomAnchor constant:4],
        [_keyboardInput.bottomAnchor constraintEqualToAnchor:_composer.bottomAnchor constant:-8],
        [_keyboardInput.trailingAnchor constraintEqualToAnchor:clear.leadingAnchor],
        [clear.widthAnchor constraintEqualToConstant:44],
        [clear.heightAnchor constraintEqualToConstant:44],
        [clear.centerYAnchor constraintEqualToAnchor:_keyboardInput.centerYAnchor],
        [clear.trailingAnchor constraintEqualToAnchor:insert.leadingAnchor],
        [insert.widthAnchor constraintEqualToConstant:84],
        [insert.heightAnchor constraintEqualToConstant:44],
        [insert.centerYAnchor constraintEqualToAnchor:_keyboardInput.centerYAnchor],
        [insert.trailingAnchor constraintEqualToAnchor:_composer.trailingAnchor constant:-8],
    ]];
}
- (void)didMoveToSuperview {
    [super didMoveToSuperview];
    [_composer removeFromSuperview];
    UIView *host = self.superview;
    if (!host) return;
    [host addSubview:_composer];
    // The editor follows the keyboard; the toolbar stays fixed at the top.
    // No resizing of the game's rendering surface or reading of game memory.
    NSLayoutConstraint *width = [_composer.widthAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.widthAnchor constant:-24];
    width.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [_composer.bottomAnchor constraintEqualToAnchor:host.keyboardLayoutGuide.topAnchor constant:-4],
        [_composer.centerXAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.centerXAnchor],
        width, [_composer.widthAnchor constraintLessThanOrEqualToConstant:800],
        [_composer.heightAnchor constraintEqualToConstant:82],
    ]];

    // The host may have laid us out the way its own controls were: a pair of small buttons
    // in a corner. Ours is a toolbar of five, and it belongs at the top centre - the top
    // left is where a game keeps its own controls. The host activates its constraints
    // just after adding us, so claim our place on the next runloop pass, not during this
    // one, or both sets end up live and the toolbar drifts into the corner.
    __weak AKTouchControls *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf claimToolbarPlaceIn:host]; });
    if (!_gamepad) {
        _gamepad = [[AKTouchGamepad alloc] initWithHostView:host];
        __weak AKTouchControls *weakSelf = self;
        _gamepad.visibilityChanged = ^(BOOL visible) {
            AKTouchControls *controls = weakSelf;
            if (!controls) return;
            [controls cancelTouches];
            [controls setGamepadVisible:visible];
        };
        _gamepad.enabled = _gamepadEnabled;
    }
    _gamepad.keyboardVisible = self.keyboardVisible;
    [_gamepad refresh];
}

// Drop the host's constraints for ourselves and stand where a toolbar belongs: centred at
// the top, wide enough for its buttons. Called once, after the host has finished adding
// us, so nothing puts us back in a corner.
- (void)claimToolbarPlaceIn:(UIView *)host {
    if (_claimedPlace || self.superview != host) return;
    _claimedPlace = YES;
    for (NSLayoutConstraint *constraint in host.constraints)
        if (constraint.firstItem == self || constraint.secondItem == self) constraint.active = NO;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [self.widthAnchor constraintEqualToConstant:200],
        [self.heightAnchor constraintEqualToConstant:44],
        [self.topAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.topAnchor constant:8],
        [self.centerXAnchor constraintEqualToAnchor:host.safeAreaLayoutGuide.centerXAnchor],
    ]];
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
    AKLog(@"input suspended (draftFirstResponder=%d)", _keyboardInput.isFirstResponder);
}
- (void)systemKeyboardShown:(NSNotification *)notification {
    NSValue *frame = notification.userInfo[UIKeyboardFrameEndUserInfoKey];
    _systemKeyboardHeight = [frame CGRectValue].size.height;
    _systemKeyboardSeen = YES;
    // With the keys on screen the microphone is one tap away again.
    if (_systemKeyboardHeight >= AKKeyboardKeysHeight) _composerLabel.text = AKComposerDefaultLabel;
    AKLog(@"system keyboard shown draftFirstResponder=%d markedText=%d height=%.0f", _keyboardInput.isFirstResponder, _keyboardInput.markedTextRange != nil, _systemKeyboardHeight);
}
- (void)systemKeyboardHidden:(NSNotification *)notification {
    (void)notification;
    _systemKeyboardHeight = 0;
    AKLog(@"system keyboard hidden draftFirstResponder=%d", _keyboardInput.isFirstResponder);
}
// A game macro or key combination asked for the draft keyboard: open it so the
// iOS keyboard (and its microphone) is one tap away. Never closes an open one.
- (void)keyboardRequestedByGuest:(NSNotification *)notification {
    (void)notification;
    [self cancelTouches];
    AKLog(@"draft keyboard requested from the guest");
    if (!self.keyboardVisible) [self becomeFirstResponder];
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
    [_composer removeFromSuperview];
    [_holdTimer invalidate];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}
@end
