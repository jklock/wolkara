// Wolkara: trying the voice button before the game is started, in full.
//
// This screen is deliberately only an output. The button does not get its own copy of
// the routing: Shell/main.m sends the mapped trigger to the microphone, so what is
// exercised here is the same path the game will use. All this screen does is take the
// words instead of the game, and say what it heard.
//
// It is also the one place the *state* of a dictation session is visible, which is what
// the state machine added for the 2026-10-16 audit is for: authorizing, listening,
// finalizing. A session that never leaves "finalizing" and one that never starts look
// identical from the outside otherwise.
//
// Drawn from WolkaraTheme, so it is the same navy and gold as the settings screen and
// the Add-on Manager beside it.

#import "VoiceTestViewController.h"

#import <GameController/GameController.h>

#import "Dictation.h"
#import "VoiceSettings.h"
#import "Trigger.h"
#import "../Input/InputElement.h"
#import "../Controller/ControllerInspector.h"
#import "../App/WolkaraLog.h"
#import "../App/WolkaraTheme.h"

@interface AKVoiceTestViewController ()
@property (nonatomic, strong) UILabel *buttonLabel;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UITextView *box;
@property (nonatomic, strong) UILabel *hint;
@end

@implementation AKVoiceTestViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Test Voice".uppercaseString;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = WKInk();
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Done"
        style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.leftBarButtonItem.tintColor = WKGold();

    UIScrollView *scroll = [UIScrollView new];
    scroll.accessibilityIdentifier = @"voice.test.scroll";
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIStackView *rows = [[UIStackView alloc] init];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 20;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:rows];

    [rows addArrangedSubview:WKNote(@"Press the button you set up on the Key / Button Configuration page. What you say appears below, exactly as the game would receive it — nothing is typed into the game from here.")];

    self.buttonLabel = WKLabel(16, UIFontWeightSemibold, UIColor.whiteColor);
    self.buttonLabel.accessibilityIdentifier = @"voice.test.button";
    self.stateLabel = WKLabel(15, UIFontWeightRegular, WKMuted());
    self.stateLabel.accessibilityIdentifier = @"voice.test.state";
    [rows addArrangedSubview:[self card:@[self.buttonLabel, self.stateLabel]]];

    self.box = [[UITextView alloc] init];
    self.box.accessibilityIdentifier = @"voice.test.box";
    self.box.backgroundColor = WKPanel();
    self.box.textColor = UIColor.whiteColor;
    self.box.tintColor = WKGold();
    self.box.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.box.adjustsFontForContentSizeCategory = YES;
    self.box.layer.cornerRadius = 12;
    self.box.layer.borderWidth = 1;
    self.box.layer.borderColor = [WKGold() colorWithAlphaComponent:0.24].CGColor;
    self.box.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    // Editable on purpose: the text that arrived is theirs to correct, and doing that
    // here is how the dictionary and the mode get judged.
    [self.box.heightAnchor constraintGreaterThanOrEqualToConstant:200].active = YES;
    [rows addArrangedSubview:self.box];

    self.hint = WKNote(@"");
    self.hint.accessibilityIdentifier = @"voice.test.hint";
    [rows addArrangedSubview:self.hint];

    UIButton *clear = WKRowButton(@"voice.test.clear");
    [clear setTitle:@"Clear" forState:UIControlStateNormal];
    [clear addTarget:self action:@selector(clearBox) forControlEvents:UIControlEventTouchUpInside];
    [rows addArrangedSubview:clear];

    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [rows.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [rows.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-28],
        [rows.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [rows.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [rows.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
    ]];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    AKDictation *dictation = AKDictation.shared;
    __weak AKVoiceTestViewController *weakSelf = self;
    dictation.transcriptHandler = ^(NSString *text) {
        [weakSelf appendTranscript:text];
    };
    dictation.listeningChanged = ^(BOOL listening) {
        [weakSelf showListening:listening];
    };
    dictation.stateChanged = ^(AKDictationState state) {
        [weakSelf showState:state];
    };
    dictation.problemHandler = ^(NSString *message) {
        weakSelf.hint.text = message;
    };
    [self refreshButton];
    [self showState:dictation.state];
    WKLog("voice", @"test screen armed on %@", [AKVoiceSettings.shared mappingSummaryForDevice:[self deviceIdentity]]);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    AKDictation *dictation = AKDictation.shared;
    // Cancel, not end. Ending asks the recogniser for its last words and delivers them
    // - and the screen that asked for them is going away, so the words would be typed
    // into the game as the sheet closes. Nothing heard here is worth that.
    [dictation cancel];
    dictation.transcriptHandler = nil;
    dictation.listeningChanged = nil;
    dictation.stateChanged = nil;
    dictation.problemHandler = nil;
}

- (void)done { WKDismissPage(self); }

#pragma mark - What arrives

// Shown exactly as the game would receive it: the text, and the trailing space if that
// option is on. One utterance per line, because the box is read by eye.
- (void)appendTranscript:(NSString *)text {
    if (!text.length) {
        self.hint.text = @"Nothing was heard. Try again, a little closer to the iPad.";
        return;
    }
    if (AKVoiceSettings.shared.trailingSpace) text = [text stringByAppendingString:@" "];
    NSString *current = self.box.text ?: @"";
    self.box.text = current.length ? [current stringByAppendingFormat:@"\n%@", text] : text;
    NSMutableString *said = [NSMutableString stringWithFormat:@"Heard %lu characters.", (unsigned long)text.length];
    if (AKVoiceSettings.shared.autoSubmit) [said appendString:@" In the game, Return would follow."];
    self.hint.text = said;
    [self.box scrollRangeToVisible:NSMakeRange(self.box.text.length, 0)];
}

- (void)clearBox {
    self.box.text = @"";
    self.hint.text = nil;
}

#pragma mark - What to press, and what it is doing

- (nullable NSString *)deviceIdentity {
    GCController *pad = GCController.controllers.firstObject;
    return pad ? AKControllerIdentity(pad) : nil;
}

- (void)refreshButton {
    GCController *pad = GCController.controllers.firstObject;
    NSString *device = [self deviceIdentity];
    NSString *summary = [AKVoiceSettings.shared mappingSummaryForDevice:device];
    BOOL toggle = AKVoiceSettings.shared.mode == AKVoiceModeToggle;
    NSString *state = AKVoiceSettings.shared.enabled ? @"" : @"Voice is switched off, so nothing will start it. Turn it on in Key / Button Configuration.";
    self.buttonLabel.text = [NSString stringWithFormat:@"%@\n%@%@",
        pad ? [NSString stringWithFormat:@"%@ — %@", summary, pad.vendorName]
            : [NSString stringWithFormat:@"%@ — no controller connected", summary],
        toggle ? @"Press it once to start and again to stop."
               : @"Hold it while you speak, then let go.",
        state.length ? [@"\n" stringByAppendingString:state] : @""];
}

- (void)showListening:(BOOL)listening {
    // The coarse answer, kept because the switch from "off" to "on" is what the user
    // cares about most; showState: refines it.
    if (!listening) self.stateLabel.textColor = WKMuted();
}

- (void)showState:(AKDictationState)state {
    NSString *text = nil;
    switch (state) {
    case AKDictationStateIdle: text = @"Microphone off"; break;
    case AKDictationStateAuthorizing: text = @"Waiting for permission…"; break;
    case AKDictationStateListening: text = @"Listening…"; break;
    case AKDictationStateFinalizing: text = @"Finishing what it heard…"; break;
    }
    self.stateLabel.text = text;
    BOOL busy = state != AKDictationStateIdle;
    self.stateLabel.textColor = busy ? WKGold() : WKMuted();
    // While it is listening, what it is hearing: the user asked to see that the microphone is being
    // received rather than take the app's word for it. Ten cells, filled by the loudest sample seen
    // this session. Redrawn at most ten times a second, because the tap calls the handler about
    // forty-eight times a second and a label does not need to keep up with that.
    if (state == AKDictationStateListening) {
        static NSTimeInterval lastDrawn = 0;   // one test screen, one level: a file-scope clock is
                                              // enough to keep the redraw to something sane
        __weak typeof(self) weakSelf = self;
        AKDictation.shared.levelHandler = ^(float level) {
            if (AKDictation.shared.state != AKDictationStateListening) return;
            NSTimeInterval now = NSDate.date.timeIntervalSinceReferenceDate;
            if (now - lastDrawn < 0.1) return;
            lastDrawn = now;
            int cell = (int)(level * 10.0f);
            if (level > 0 && cell == 0) cell = 1;
            if (cell > 10) cell = 10;
            NSMutableString *bar = [NSMutableString stringWithString:@"Listening… "];
            for (int index = 0; index < 10; index++) [bar appendString:(index < cell ? @"▮" : @"▯")];
            weakSelf.stateLabel.text = bar;
        };
    } else if (state == AKDictationStateIdle) {
        AKDictation.shared.levelHandler = nil;
    }
}

#pragma mark - Small pieces

- (UIView *)card:(NSArray<UIView *> *)rows {
    UIView *panel = WKCard();
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:rows];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 8;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [panel addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:panel.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-16],
        [stack.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-16],
    ]];
    return panel;
}

@end
