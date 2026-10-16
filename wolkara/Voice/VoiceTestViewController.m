// Wolkara: trying the voice button before the game is started, in full.
//
// This screen is deliberately only an output. The button does not get its own copy
// of the routing: Shell/main.m already sends the mapped trigger to the microphone,
// so what is exercised here is the same path the game will use. All this screen
// does is take the words instead of the game, and say what it heard.
//
// Drawn from WolkaraTheme, so it is the same navy and gold as the settings screen
// and the Add-on Manager beside it.

#import "VoiceTestViewController.h"

#import <GameController/GameController.h>

#import "Dictation.h"
#import "VoiceSettings.h"
#import "Trigger.h"
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
    // Editable on purpose: the text that arrived is theirs to correct, and doing
    // that here is how the dictionary and the mode get judged.
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
    [self refreshButton];
    [self showListening:dictation.listening];
    WKLog("voice", @"test screen armed on %@", [AKVoiceSettings.shared mappingSummaryForDevice:GCController.controllers.firstObject.vendorName]);
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    AKDictation *dictation = AKDictation.shared;
    // Stop first, while this screen still owns the words. Clearing the handler
    // first would send the half-heard utterance into the game's chat box on the
    // way out, which is the opposite of what the user asked for.
    if (dictation.listening) [dictation end];
    dictation.transcriptHandler = nil;
    dictation.listeningChanged = nil;
}

- (void)done { WKDismissPage(self); }

#pragma mark - What arrives

// Shown exactly as the game would receive it: the text, and the trailing space if
// that option is on. One utterance per line, because the box is read by eye.
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

#pragma mark - What to press

- (void)refreshButton {
    GCController *pad = GCController.controllers.firstObject;
    NSString *device = pad.vendorName;
    NSString *summary = [AKVoiceSettings.shared mappingSummaryForDevice:device];
    BOOL toggle = AKVoiceSettings.shared.mode == AKVoiceModeToggle;
    self.buttonLabel.text = [NSString stringWithFormat:@"%@\n%@",
        pad ? [NSString stringWithFormat:@"%@ — %@", summary, device]
            : [NSString stringWithFormat:@"%@ — no controller connected", summary],
        toggle ? @"Press it once to start and again to stop."
               : @"Hold it while you speak, then let go."];
}

- (void)showListening:(BOOL)listening {
    self.stateLabel.text = listening ? @"Listening…" : @"Microphone off";
    self.stateLabel.textColor = listening ? WKGold() : WKMuted();
}

#pragma mark - Small pieces

// A group of rows on the launcher's panel colour, padded the same way everywhere.
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
