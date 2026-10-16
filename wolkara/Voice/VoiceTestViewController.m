// Wolkara: trying the voice button before the game is started, in full.
//
// This screen is deliberately only an output. The button does not get its own
// copy of the routing: Shell/main.m already sends the mapped trigger to the
// microphone, so what is exercised here is the same path the game will use. All
// this screen does is take the words instead of the game, and say what it heard.

#import "VoiceTestViewController.h"

#import <GameController/GameController.h>

#import "Dictation.h"
#import "VoiceSettings.h"
#import "Trigger.h"

@interface AKVoiceTestViewController ()
@property (nonatomic, strong) UILabel *buttonLabel;
@property (nonatomic, strong) UILabel *stateLabel;
@property (nonatomic, strong) UITextView *box;
@property (nonatomic, strong) UILabel *hint;
@end

@implementation AKVoiceTestViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Test Voice";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UIStackView *rows = [[UIStackView alloc] init];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 12;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:rows];

    [rows addArrangedSubview:[self note:@"Press the button you set up on the Key / Button Configuration page. What you say appears below, exactly as the game would receive it — nothing is typed into the game from here."]];

    self.buttonLabel = [self label:@""];
    self.buttonLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.buttonLabel.textColor = UIColor.labelColor;
    [rows addArrangedSubview:self.buttonLabel];

    self.stateLabel = [self label:@""];
    self.stateLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
    [rows addArrangedSubview:self.stateLabel];

    self.box = [[UITextView alloc] init];
    self.box.accessibilityIdentifier = @"voice.test.box";
    self.box.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    self.box.adjustsFontForContentSizeCategory = YES;
    self.box.layer.cornerRadius = 12;
    self.box.layer.borderWidth = 1;
    self.box.layer.borderColor = UIColor.separatorColor.CGColor;
    self.box.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    // Editable on purpose: the text that arrived is theirs to correct, and doing
    // that here is how the dictionary and the mode get judged.
    [self.box.heightAnchor constraintGreaterThanOrEqualToConstant:200].active = YES;
    [rows addArrangedSubview:self.box];

    self.hint = [self note:@""];
    [rows addArrangedSubview:self.hint];

    UIButton *clear = [UIButton buttonWithType:UIButtonTypeSystem];
    [clear setTitle:@"Clear" forState:UIControlStateNormal];
    [clear addTarget:self action:@selector(clearBox) forControlEvents:UIControlEventTouchUpInside];
    clear.accessibilityIdentifier = @"voice.test.clear";
    [rows addArrangedSubview:clear];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [rows.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [rows.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [rows.topAnchor constraintEqualToAnchor:safe.topAnchor constant:20],
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
    self.stateLabel.textColor = listening ? self.view.tintColor : UIColor.secondaryLabelColor;
}

#pragma mark - Small pieces

- (UILabel *)label:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.numberOfLines = 0;
    return label;
}

- (UILabel *)note:(NSString *)text {
    UILabel *label = [self label:text];
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = UIColor.secondaryLabelColor;
    return label;
}

@end
