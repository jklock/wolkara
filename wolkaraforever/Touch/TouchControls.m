#import "TouchControls.h"
#import "AKSupport.h"
#import "TouchTrackpad.h"
#import "TouchGamepadLayout.h"
#import "TouchGamepad.h"
#import "TouchHaptics.h"
#import <objc/message.h>

// Null until the app's shell says which keys are the user's; null means "nothing is owned",
// which is the behaviour without the feature and what a fixture that links only the adapter
// gets.
BOOL (*AKTouchKeyIsTakenForVoice)(unsigned short usage) = NULL;

NSNotificationName const AKTouchOwnedKeyUsagesDidChangeNotification = @"AKTouchOwnedKeyUsagesDidChange";
NSString *const AKTouchOwnedKeyUsagesKey = @"usages";

// The usages the user has taken, kept here because this file is where the answer is needed:
// the adapter asks about a key it is about to post to the guest.
static NSSet<NSNumber *> *AKTouchOwnedKeyUsages = nil;

static BOOL AKTouchUsageIsTaken(unsigned short usage) {
    return [AKTouchOwnedKeyUsages containsObject:@(usage)];
}

// Posted when the game's own text view exists, with that view as the object. Dictation
// types into it and nowhere else; the alternative - searching every window in every
// scene for something that answers a private selector - is not a thing to do while a
// game is running. Shell/main.m is the observer, because it is what knows about both
// this adapter and the voice module.
NSNotificationName const AKTouchGameTextInputDidAppearNotification = @"AKTouchGameTextInputDidAppear";

NSNotificationName const AKTouchKeyboardRequestNotification = @"AKTouchKeyboardRequestNotification";
// Posted when the user has asked to leave twice and the guest still refused to quit: the shell,
// which owns the session and what it has to flush, closes WolkaraForever. Named as a string on the
// shell's side for the same reason as the two notifications above - the adapter is a dylib the
// app does not link.
NSNotificationName const AKTouchCloseAppNotification = @"AKTouchCloseAppNotification";
// The microphone key on the layer's own keyboard. The voice module is not this one's to
// include, and the shell is the only place that links both, so the key announces and the
// shell starts or stops dictation.
NSNotificationName const AKTouchDictationToggleNotification = @"AKTouchDictationToggleNotification";
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
// Brings up the layer's own keys when iPadOS has no software keyboard to give.
- (void)showLayerKeyboard;
// YES while the user has asked for the draft keyboard and it has not been
// dismissed: the draft editor uses it to decide whether to take focus back when
// a system panel (dictation) has finished with it.
- (BOOL)keyboardRequested;
@end

// What the layer's keyboard asks its owner to do. Words go to the game the same
// way dictation's do; the special keys are the guest's own key events.
@protocol AKTouchKeyboardSink <NSObject>
- (void)keyboardViewType:(NSString *)text;
- (void)keyboardViewBackspace;
- (void)keyboardViewReturn;
- (void)keyboardViewShowSystemKeyboard;
- (void)keyboardViewToggleDictation;
@end

@interface AKTouchControls () <AKTouchKeyboardSink>
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
        self.accessibilityIdentifier = @"wolkaraforever.keyboard.draft";
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
    // UITextView implements the dictation selectors on some systems and not on
    // others, and sending one it does not have aborts the app. Ask first, and
    // hand back our own token when the superclass has nothing, because the
    // session cannot start without a placeholder.
    id placeholder = nil;
    if ([UITextView instancesRespondToSelector:@selector(insertDictationResultPlaceholder)]) {
        placeholder = [super insertDictationResultPlaceholder];
    }
    if (!placeholder) placeholder = [[NSObject alloc] init];
    [_dictationPlaceholders addObject:placeholder];
    AKLog(@"dictation placeholder inserted=%d pending=%lu accepting=%d", placeholder != nil, (unsigned long)_dictationPlaceholders.count, _acceptingInput);
    [self.inputOwner updateDraftButtons];
    return placeholder;
}
- (void)removeDictationResultPlaceholder:(id)placeholder willInsertResult:(BOOL)willInsert {
    if (![_dictationPlaceholders containsObject:placeholder]) return;
    if ([UITextView instancesRespondToSelector:@selector(removeDictationResultPlaceholder:willInsertResult:)]) {
        [super removeDictationResultPlaceholder:placeholder willInsertResult:willInsert];
    }
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
    // UITextView does not implement this selector. UIKit sends it to whichever
    // responder holds the session's placeholder, so forwarding it to super
    // raises NSInvalidArgumentException and the app dies the instant dictation
    // finishes. Insert the phrases as ordinary input instead, the same way the
    // dictated text would have arrived.
    _acceptingInput = YES;
    for (UIDictationPhrase *phrase in dictationResult) {
        if (phrase.text.length) [self insertText:phrase.text];
    }
    [self.inputOwner updateDraftButtons];
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

// The layer's own keyboard.
//
// iPadOS hides the software keyboard when it believes a hardware keyboard is
// attached, and what it reports then is the shortcut bar alone or nothing at all.
// Measured on Dadpad, 2026-10-22: "system keyboard shown draftFirstResponder=1
// height=0", with the game's login field unable to take the @ an e-mail address
// needs, and no other route to type one. A custom input view is shown whatever
// the hardware says, so these keys are always there. They type through the same
// delegate dictation uses, which turns text into the guest's own key events, so
// the game's field sees ordinary typing. The system-keyboard key hands the input
// view back for dictation's microphone when iPadOS will show it.
@interface AKTouchKeyboardView : UIView
@property (nonatomic, weak) id<AKTouchKeyboardSink> sink;
@end

@implementation AKTouchKeyboardView {
    BOOL _shift, _symbols;
    UIStackView *_column;
    NSArray<NSDictionary *> *_specs;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0.12 alpha:1];
        _column = [UIStackView new];
        _column.axis = UILayoutConstraintAxisVertical;
        _column.spacing = 6;
        _column.distribution = UIStackViewDistributionFillEqually;
        _column.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_column];
        [NSLayoutConstraint activateConstraints:@[
            [_column.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
            [_column.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],
            [_column.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:8],
            [_column.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-8],
        ]];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self rebuild];
    }
    return self;
}
- (CGSize)intrinsicContentSize { return CGSizeMake(UIViewNoIntrinsicMetric, 236); }
- (void)rebuild {
    for (UIView *view in _column.arrangedSubviews) { [_column removeArrangedSubview:view]; [view removeFromSuperview]; }
    NSMutableArray<NSDictionary *> *specs = [NSMutableArray new];
    NSArray<NSArray<NSString *> *> *rows;
    if (_symbols) {
        rows = @[@[@"1", @"2", @"3", @"4", @"5", @"6", @"7", @"8", @"9", @"0"],
                 @[@"-", @"_", @"+", @"=", @"/", @":", @";", @"(", @")"],
                 @[@"#", @"$", @"%", @"&", @"*", @"\"", @"'", @"!", @"?"],
                 @[@"ABC", @" ", @"@", @".", @"🎤", @"⌨", @"↵"]];
    } else {
        NSString *top = _shift ? @"QWERTYUIOP" : @"qwertyuiop";
        NSString *home = _shift ? @"ASDFGHJKL" : @"asdfghjkl";
        NSString *bottom = _shift ? @"ZXCVBNM" : @"zxcvbnm";
        NSMutableArray<NSString *> *third = [NSMutableArray arrayWithObject:@"⇧"];
        for (NSUInteger i = 0; i < bottom.length; i++) [third addObject:[bottom substringWithRange:NSMakeRange(i, 1)]];
        [third addObject:@"⌫"];
        rows = @[[self keysIn:top], [self keysIn:home], third,
                 @[@"123", @" ", @"@", @".", @"🎤", @"⌨", @"↵"]];
    }
    for (NSArray<NSString *> *row in rows) {
        NSMutableArray<UIView *> *buttons = [NSMutableArray new];
        for (NSString *title in row) {
            UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
            [button setTitle:title forState:UIControlStateNormal];
            button.titleLabel.font = [UIFont systemFontOfSize:title.length > 1 ? 15 : 20];
            button.tintColor = UIColor.whiteColor;
            button.backgroundColor = [self actionTitle:title] ? [UIColor colorWithWhite:0.34 alpha:1]
                                                              : [UIColor colorWithWhite:0.26 alpha:1];
            button.layer.cornerRadius = 6;
            button.tag = (NSInteger)specs.count;
            button.accessibilityIdentifier = [@"wolkaraforever.layerkey." stringByAppendingString:
                [self actionTitle:title] ?: [self accessibilityNameFor:title]];
            button.accessibilityLabel = [self accessibilityNameFor:title];
            [button addTarget:self action:@selector(keyTapped:) forControlEvents:UIControlEventTouchUpInside];
            [specs addObject:@{@"title": title}];
            [buttons addObject:button];
        }
        UIStackView *line = [[UIStackView alloc] initWithArrangedSubviews:buttons];
        line.axis = UILayoutConstraintAxisHorizontal;
        line.spacing = 5;
        line.distribution = UIStackViewDistributionFillEqually;
        [_column addArrangedSubview:line];
    }
    _specs = specs;
}
- (NSArray<NSString *> *)keysIn:(NSString *)letters {
    NSMutableArray<NSString *> *keys = [NSMutableArray new];
    for (NSUInteger i = 0; i < letters.length; i++) [keys addObject:[letters substringWithRange:NSMakeRange(i, 1)]];
    return keys;
}
// The keys that are actions rather than characters, by the title drawn on them.
- (NSString *)actionTitle:(NSString *)title {
    if ([title isEqual:@"⇧"]) return @"shift";
    if ([title isEqual:@"⌫"]) return @"delete";
    if ([title isEqual:@"↵"]) return @"return";
    if ([title isEqual:@"🎤"]) return @"dictate";
    if ([title isEqual:@"⌨"]) return @"system";
    if ([title isEqual:@"123"]) return @"page";
    if ([title isEqual:@"ABC"]) return @"page";
    return nil;
}
- (NSString *)accessibilityNameFor:(NSString *)title {
    if ([title isEqual:@"⇧"]) return @"Shift";
    if ([title isEqual:@"⌫"]) return @"Backspace";
    if ([title isEqual:@"↵"]) return @"Return";
    if ([title isEqual:@"🎤"]) return @"Dictate";
    if ([title isEqual:@"⌨"]) return @"System keyboard";
    if ([title isEqual:@"123"]) return @"Numbers and symbols";
    if ([title isEqual:@"ABC"]) return @"Letters";
    if ([title isEqual:@" "]) return @"Space";
    return title;
}
- (void)keyTapped:(UIButton *)button {
    if (button.tag < 0 || button.tag >= (NSInteger)_specs.count) return;
    NSString *title = _specs[(NSUInteger)button.tag][@"title"];
    id<AKTouchKeyboardSink> sink = self.sink;
    if ([title isEqual:@"⇧"]) { _shift = !_shift; [self rebuild]; return; }
    if ([title isEqual:@"123"]) { _symbols = YES; [self rebuild]; return; }
    if ([title isEqual:@"ABC"]) { _symbols = NO; [self rebuild]; return; }
    if ([title isEqual:@"⌫"]) { [sink keyboardViewBackspace]; return; }
    if ([title isEqual:@"↵"]) { [sink keyboardViewReturn]; return; }
    if ([title isEqual:@"🎤"]) { [sink keyboardViewToggleDictation]; return; }
    if ([title isEqual:@"⌨"]) { [sink keyboardViewShowSystemKeyboard]; return; }
    [sink keyboardViewType:title];
    // A shifted letter is one capital, as on every other keyboard.
    if (_shift && !_symbols) { _shift = NO; [self rebuild]; }
}
@end

@implementation AKTouchControls {
    UIButton *_keyboardButton, *_trackpadButton, *_gamepadButton, *_settingsButton, *_leaveButton;
    UIButton *_insertDraftButton, *_clearDraftButton;
    UILabel *_composerLabel;
    BOOL _gamepadEnabled, _keyboardRequested, _systemKeyboardSeen, _ownKeyboard;
    CGFloat _systemKeyboardHeight;
    UIView *_accessory, *_composer;
    AKTouchKeyboardView *_layerKeyboard;
    NSTimer *_holdTimer;
    AKKeyboardTextView *_keyboardInput;
    AKTrackpad _pad;
    AKTouchHaptics *_haptics;
    AKTouchGamepad *_gamepad;
    BOOL _tookOwnPlace;
}

// This dylib is loaded by name, so nothing here can be called by the shell at link time. The
// one channel is the notification that says which keys the user has taken, where it is
// received - and the pointer is set here, because until it arrives nothing is owned and every
// key goes to the game.
+ (void)load {
    [NSNotificationCenter.defaultCenter addObserverForName:AKTouchOwnedKeyUsagesDidChangeNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(NSNotification *note) {
        id usages = note.userInfo[AKTouchOwnedKeyUsagesKey];
        if ([usages isKindOfClass:NSSet.class]) AKTouchOwnedKeyUsages = [usages copy];
        else if ([usages isKindOfClass:NSArray.class]) AKTouchOwnedKeyUsages = [NSSet setWithArray:usages];
        else AKTouchOwnedKeyUsages = nil;
        // Null when nothing is taken, so the check at the adapter's door is one nil test in
        // the common case rather than a set lookup per key.
        AKTouchKeyIsTakenForVoice = AKTouchOwnedKeyUsages.count ? AKTouchUsageIsTaken : NULL;
        AKLog(@"the user's keys: %lu taken (the game will not see those)",
              (unsigned long)AKTouchOwnedKeyUsages.count);
    }];
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
        // Announced, not reached for. The game's text input is this view, not the draft
        // editor: this one is the layer's UIKeyInput, and its delegate is what posts the
        // key events into the guest. The draft editor is a UITextView that holds words for
        // Replace and cannot reach the game at all. Announcing the wrong one is not a
        // cosmetic mistake - the first transcript sent to it aborted the app with
        // "-[AKKeyboardTextView touchInsertText:]: unrecognized selector" (measured on
        // Dadpad, 2026-10-21).
        [NSNotificationCenter.defaultCenter postNotificationName:AKTouchGameTextInputDidAppearNotification
                                                        object:self];
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
        _settingsButton.accessibilityIdentifier = @"wolkaraforever.controlSettings";
        // A way out of the game from any screen. Until this existed, a guest screen with no
        // quit of its own - the login screen is one - left the user with no control that
        // returned to WolkaraForever's launcher at all, and closing the app was the only exit
        // (reported on Dadpad, 2026-10-21). It closes WolkaraForever, which ends the guest with it.
        _leaveButton=[self buttonWithSymbol:@"house" label:@"Leave the game" action:@selector(leaveGame)];
        _leaveButton.accessibilityIdentifier=@"wolkaraforever.leaveGame";
        _leaveButton.accessibilityHint=@"Closes WolkaraForever and the game; anything the game has not saved is lost. Open WolkaraForever again to start it.";
        // Said once at build time so a device run can be read back without a tap.
        AKLog(@"toolbar: leave game control on the toolbar (house; asks the guest to terminate)");
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
    for (UIButton *button in @[_trackpadButton, _keyboardButton, _gamepadButton, _settingsButton, _leaveButton]) button.alpha = layout.opacity;
}
- (void)buttonTouchDown { [_haptics buttonPressed]; }

// Place the toolbar from the host's own bounds: centred horizontally, just below the top.
//
// Measured on the device: centring on host.safeAreaLayoutGuide put the toolbar 103pt right of
// the screen centre, so the guide is not the screen here. The bounds are. Frame placement
// also settles the tug of war with the host's own constraints for us - they are dropped once,
// by collecting them and deactivating the collection, so the list being walked is not the one
// being changed.
- (void)placeToolbarInHost:(UIView *)host {
    if (self.superview != host) return;
    if (!_tookOwnPlace) {
        _tookOwnPlace = YES;
        NSMutableArray<NSLayoutConstraint *> *theirs = [NSMutableArray array];
        for (NSLayoutConstraint *constraint in host.constraints)
            if (constraint.firstItem == self || constraint.secondItem == self)
                [theirs addObject:constraint];
        for (NSLayoutConstraint *constraint in theirs) constraint.active = NO;
        self.translatesAutoresizingMaskIntoConstraints = YES;
    }
    static unsigned logged;
    CGFloat width = 252, height = 44;
    CGRect bounds = host.bounds;
    self.frame = CGRectMake(floor((bounds.size.width - width) / 2),
                            host.safeAreaInsets.top + 8, width, height);
    if (logged < 3) {
        logged++;
        AKLog(@"toolbar host bounds=%.0fx%.0f insets top=%.0f left=%.0f placed x=%.0f centre=%.0f (screen centre %.0f)",
              bounds.size.width, bounds.size.height, host.safeAreaInsets.top, host.safeAreaInsets.left,
              self.frame.origin.x, CGRectGetMidX(self.frame), bounds.size.width / 2);
    }
}


- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.superview) [self placeToolbarInHost:self.superview];
    _trackpadButton.frame = CGRectMake(0, 0, 44, 44);
    _keyboardButton.frame = CGRectMake(52, 0, 44, 44);
    _gamepadButton.frame = CGRectMake(104, 0, 44, 44);
    _settingsButton.frame = CGRectMake(156, 0, 44, 44);
    _leaveButton.frame = CGRectMake(208, 0, 44, 44);
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
// Leaving the game from a screen that has no quit of its own.
//
// The guest is a real Cocoa application in this process: asking its own NSApp to terminate
// runs its applicationShouldTerminate:/applicationWillTerminate: handlers first, which is how
// the game saves its settings, and only then does the translated AppKit end the process. That
// is the same path the game's own Exit item takes; nothing is killed and no memory is written.
//
// The confirmation says the rest plainly because there is no way around it: one guest per
// process, so WolkaraForever cannot put its launcher back afterwards - opening WolkaraForever again does.
- (void)leaveGame {
    [self cancelTouches]; [self dismissKeyboard];
    // One question, and no request to the guest.
    //
    // Asking the guest's own application object to terminate was tried first and is not kept.
    // The client answered `NSTerminateCancel`, so the tap did nothing at all - the exact dead
    // end this control exists to remove - and on the same run it faulted with EXC_BAD_ACCESS
    // shortly afterwards (ERROR #132, Dadpad, 2026-10-21): a half-asked shutdown that is then
    // cancelled is not a state to put a running client in for a UI convenience. WolkaraForever ends
    // its own process instead, and says plainly what that costs.
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Leave the game?"
        message:@"The game will close without saving its settings, and WolkaraForever ends with it. Open WolkaraForever again to start the game."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep playing" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Close WolkaraForever" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        AKLog(@"leave game: the user chose to close WolkaraForever");
        [NSNotificationCenter.defaultCenter postNotificationName:AKTouchCloseAppNotification object:nil];
    }]];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
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
    // button. When that happens the layer supplies the keys itself: a login field
    // that cannot be typed into is not a state to leave the user in.
    __weak AKTouchControls *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        AKTouchControls *controls = weakSelf;
        if (!controls || !controls.keyboardVisible || controls->_ownKeyboard) return;
        AKLog(@"hardware keyboard %@", hardwareKeyboardAttached() ? @"attached" : @"absent");
        if (!controls->_systemKeyboardSeen) {
            AKLog(@"software keyboard did not appear; showing the layer's own keys");
            [controls showLayerKeyboard];
        } else if (controls->_systemKeyboardHeight < AKKeyboardKeysHeight) {
            AKLog(@"software keyboard keys are not on screen (height %.0f); showing the layer's own keys", controls->_systemKeyboardHeight);
            [controls showLayerKeyboard];
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
// iPadOS has no software keyboard to give (it believes a hardware keyboard is
// attached), so the layer supplies the keys itself. A custom input view is shown
// whatever the hardware says, and it keeps the game's field usable: without it
// there is no way to type the @ an e-mail address needs at the login screen.
- (void)showLayerKeyboard {
    if (!_layerKeyboard) {
        _layerKeyboard = [[AKTouchKeyboardView alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, 236)];
        _layerKeyboard.sink = self;
    }
    _ownKeyboard = YES;
    _keyboardInput.inputView = _layerKeyboard;
    _composer.hidden = NO;
    BOOL focused = _keyboardInput.isFirstResponder || [_keyboardInput becomeFirstResponder];
    if (!focused) AKLog(@"the draft editor could not take focus (window=%@)", _keyboardInput.window ? @"yes" : @"no");
    [_keyboardInput reloadInputViews];
    // The layer's keys are the size of a keyboard's keys, so the "no keys on
    // screen" test must not read them as the shortcut bar next time.
    _systemKeyboardHeight = 0;
    [self updateKeyboardButton];
    AKLog(@"the layer's own keyboard is up (iPadOS has no software keyboard to give)");
}
- (void)keyboardViewType:(NSString *)text {
    // The same route dictation takes: the adapter turns the words into the
    // guest's own key events, so the field the game has focused takes them.
    if ([self.delegate respondsToSelector:@selector(touchInsertText:)]) {
        [self.delegate touchInsertText:text];
    } else {
        // No game behind the controls: keep the words in the draft instead.
        [_keyboardInput setText:[_keyboardInput.text stringByAppendingString:text]];
    }
}
- (void)keyboardViewBackspace { [self.delegate touchSpecialKey:51 characters:@"\x7f"]; }
- (void)keyboardViewReturn { [self.delegate touchSpecialKey:36 characters:@"\r"]; }
// The microphone key. Dictation belongs to the voice module, which this one cannot include;
// the shell links both and is what answers, exactly as it does for Leave game.
- (void)keyboardViewToggleDictation {
    AKLog(@"the layer's keyboard asked for dictation");
    [NSNotificationCenter.defaultCenter postNotificationName:AKTouchDictationToggleNotification object:self];
}
- (void)keyboardViewShowSystemKeyboard {
    _ownKeyboard = NO;
    _keyboardInput.inputView = nil;
    if (!_keyboardInput.isFirstResponder) [_keyboardInput becomeFirstResponder];
    [_keyboardInput reloadInputViews];
    [self updateKeyboardButton];
    AKLog(@"the keyboard is iPadOS's again (for dictation)");
}
- (void)dismissKeyboard {
    _keyboardRequested = NO;
    // Back to iPadOS's own keyboard for the next request: dictation's microphone
    // only exists on it.
    if (_ownKeyboard) { _ownKeyboard = NO; _keyboardInput.inputView = nil; [_keyboardInput reloadInputViews]; }
    if (self.keyboardVisible) {
        [self resignFirstResponder];
        [self.superview becomeFirstResponder];
    }
}
// The guest owns its text/selection. Explicit Replace replaces the field.
// Accessory keys still allow editing existing text directly in the guest.
// Touches pass through the toolbar except on its own chrome.
//
// The platform's version named the two buttons it had; this names every control the layer
// puts on the same strip, which is the same rule with the layer's controls in it. It was
// lost when the layer rewrote this file, and without it the toolbar claims every point in
// its frame - so a tap in the gap between two buttons goes to the toolbar instead of to the
// game. The platform's own test is what caught it.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    (void)event;
    for (UIView *control in @[_trackpadButton, _keyboardButton, _gamepadButton, _settingsButton, _leaveButton, _composer]) {
        if (control && !control.hidden && CGRectContainsPoint(control.frame, point)) return YES;
    }
    return NO;
}

- (BOOL)hasText { return YES; }
// The text-input traits, carried over from the platform's version of this class. It is what
// makes iPadOS treat these controls as a text input and offer the layer's own accessory row
// for them, and the platform's test asserts the two that decide that. They were lost when
// the layer rewrote this file; restored verbatim, because none of the layer's changes need
// them to differ.
- (UITextAutocapitalizationType)autocapitalizationType { return UITextAutocapitalizationTypeNone; }
- (UITextAutocorrectionType)autocorrectionType { return UITextAutocorrectionTypeNo; }
- (UITextSpellCheckingType)spellCheckingType { return UITextSpellCheckingTypeNo; }
- (UITextSmartQuotesType)smartQuotesType { return UITextSmartQuotesTypeNo; }
- (UITextSmartDashesType)smartDashesType { return UITextSmartDashesTypeNo; }
- (UITextSmartInsertDeleteType)smartInsertDeleteType { return UITextSmartInsertDeleteTypeNo; }
- (UIKeyboardType)keyboardType { return UIKeyboardTypeDefault; }
- (UIReturnKeyType)returnKeyType { return UIReturnKeyDefault; }
// Secure, so the system never offers to remember or spell-check what is typed at the game.
- (BOOL)isSecureTextEntry { return YES; }
- (void)insertText:(NSString *)text { [self.delegate touchInsertText:text]; }
// Dictation types into whatever the controls announced as the game's text input, and it
// asks for these two selectors when it does. They are the adapter's own converter - the
// delegate turns text into key events and posts them to the guest - so this view says the
// same thing to the same place, once, and does nothing else with the words.
- (void)touchInsertText:(NSString *)text {
    if ([self.delegate respondsToSelector:@selector(touchInsertText:)]) [self.delegate touchInsertText:text];
}
- (void)touchSpecialKey:(unsigned short)code characters:(NSString *)characters {
    if ([self.delegate respondsToSelector:@selector(touchSpecialKey:characters:)])
        [self.delegate touchSpecialKey:code characters:characters];
}
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
            button.accessibilityIdentifier = [NSString stringWithFormat:@"wolkaraforever.keyboard.key.%lu", (unsigned long)i];
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
    insert.accessibilityIdentifier = @"wolkaraforever.keyboard.insert";
    insert.accessibilityHint = @"Replaces the whole selected game field. An empty draft clears it. Does not press Return.";
    [insert addTarget:self action:@selector(insertDraft) forControlEvents:UIControlEventTouchUpInside];
    UIButton *clear = _clearDraftButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [clear setImage:[UIImage systemImageNamed:@"xmark.circle"] forState:UIControlStateNormal];
    clear.accessibilityLabel = @"Clear draft";
    clear.accessibilityIdentifier = @"wolkaraforever.keyboard.clear";
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

    // Placement happens in layoutSubviews, by frame, from the host's own bounds - see
    // placeToolbarInHost. Constraints are the host's to set, and Apple says a view must
    // not set translatesAutoresizingMaskIntoConstraints on itself; frame placement from
    // the host's bounds is the one thing neither can argue with.
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
