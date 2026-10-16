// Wolkara: the Voice screen, in full.
//
// Laid out as rows rather than a table, matching how the rest of the launcher is
// built. The mapping row is the interesting one: it does not offer a list of
// supported controllers — it asks the user to press the button, and whichever
// event arrives becomes the trigger. That is what makes it work for hardware we
// have never seen.

#import "VoiceViewController.h"

#import <GameController/GameController.h>

#import "VoiceSettings.h"
#import "Trigger.h"
#import "../Input/InputRouter.h"

@interface AKVoiceViewController ()
@property (nonatomic, strong) UILabel *mappingValue;
@property (nonatomic, strong) UILabel *mappingHint;
@property (nonatomic, strong) UIButton *mapButton;
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) UISwitch *autoSubmitSwitch;
@property (nonatomic, strong) UISwitch *trailingSpaceSwitch;
@property (nonatomic, strong) UITextField *dictionaryField;
@end

@implementation AKVoiceViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Key / Button Configuration";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UIStackView *rows = [[UIStackView alloc] init];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 14;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:rows];

    UILabel *intro = [self label:@"Anything you press can start dictation: a button on a controller, a key, a mouse button. The game keeps its own use of that button."];
    [rows addArrangedSubview:intro];

    // --- Which button -------------------------------------------------------
    [rows addArrangedSubview:[self heading:@"Button"]];
    self.mappingValue = [self label:@"Not set"];
    self.mappingValue.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    [rows addArrangedSubview:self.mappingValue];
    self.mapButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.mapButton setTitle:@"Map a button…" forState:UIControlStateNormal];
    [self.mapButton addTarget:self action:@selector(beginMapping) forControlEvents:UIControlEventTouchUpInside];
    [rows addArrangedSubview:self.mapButton];
    self.mappingHint = [self label:@"Tap Map, then press the button you want to use."];
    [rows addArrangedSubview:self.mappingHint];

    // --- How it behaves -----------------------------------------------------
    [rows addArrangedSubview:[self heading:@"Mode"]];
    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Hold to talk", @"Press to start and stop"]];
    self.modeControl.selectedSegmentIndex = AKVoiceSettings.shared.mode == AKVoiceModeHold ? 0 : 1;
    [self.modeControl addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    [rows addArrangedSubview:self.modeControl];
    [rows addArrangedSubview:[self label:@"Hold to talk needs a button whose press and release both reach us. A button Apple keeps for itself, like Share, can only press to start and stop."]];

    // --- What happens to the words ------------------------------------------
    [rows addArrangedSubview:[self heading:@"After transcribing"]];
    [rows addArrangedSubview:[self switchRow:@"Send it straight away"
                                 isAutoSubmit:YES
                                      action:@selector(autoSubmitChanged)]];
    [rows addArrangedSubview:[self switchRow:@"Add a space after the text"
                                 isAutoSubmit:NO
                                      action:@selector(trailingSpaceChanged)]];

    // --- Dictionary ---------------------------------------------------------
    [rows addArrangedSubview:[self heading:@"Words to expect"]];
    self.dictionaryField = [[UITextField alloc] init];
    self.dictionaryField.borderStyle = UITextBorderStyleRoundedRect;
    self.dictionaryField.placeholder = @"Names, places, game terms — separated by commas";
    self.dictionaryField.text = [AKVoiceSettings.shared.customWords componentsJoinedByString:@", "];
    self.dictionaryField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.dictionaryField.autocorrectionType = UITextAutocorrectionTypeNo;
    [self.dictionaryField addTarget:self action:@selector(dictionaryChanged) forControlEvents:UIControlEventEditingDidEnd];
    [rows addArrangedSubview:self.dictionaryField];
    [rows addArrangedSubview:[self label:@"These bias the recogniser, so a name comes out spelled the way you mean it."]];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [rows.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [rows.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [rows.topAnchor constraintEqualToAnchor:safe.topAnchor constant:20],
    ]];

    // The switch rows are built by the helper, which keeps them next to the
    // switch it created for each setting.
    self.autoSubmitSwitch.on = AKVoiceSettings.shared.autoSubmit;
    self.trailingSpaceSwitch.on = AKVoiceSettings.shared.trailingSpace;

    [self refreshMapping];

    __weak AKVoiceViewController *weakSelf = self;
    AKInputRouter.shared.onLearned = ^(AKTrigger *trigger, NSString *device) {
        (void)trigger;
        [AKVoiceSettings.shared setLearnedElement:trigger.element forDevice:device];
        [weakSelf refreshMapping];
        weakSelf.mappingHint.text = @"Saved. It applies whenever that controller is connected.";
    };
}

#pragma mark - The mapping row

- (nullable NSString *)targetDevice {
    GCController *pad = GCController.controllers.firstObject;
    return pad.vendorName;
}

- (void)beginMapping {
    self.mappingHint.text = @"Press the button you want to use now…";
    self.mapButton.enabled = NO;
    [AKInputRouter.shared beginLearning];
    // Learning also takes the first event, so if nothing arrives the button
    // comes back rather than leaving the screen stuck.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!AKInputRouter.shared.learning) return;
        self.mappingHint.text = @"Nothing arrived. Tap Map and try again.";
        self.mapButton.enabled = YES;
    });
}

- (void)refreshMapping {
    self.mapButton.enabled = !AKInputRouter.shared.learning;
    NSString *summary = [AKVoiceSettings.shared mappingSummaryForDevice:[self targetDevice]];
    GCController *pad = GCController.controllers.firstObject;
    self.mappingValue.text = pad
        ? [NSString stringWithFormat:@"%@ — %@", summary, pad.vendorName]
        : [NSString stringWithFormat:@"%@ — no controller connected", summary];
}

#pragma mark - The other rows

- (void)modeChanged {
    AKVoiceSettings.shared.mode = self.modeControl.selectedSegmentIndex == 0 ? AKVoiceModeHold : AKVoiceModeToggle;
}
- (void)autoSubmitChanged { AKVoiceSettings.shared.autoSubmit = self.autoSubmitSwitch.on; }
- (void)trailingSpaceChanged { AKVoiceSettings.shared.trailingSpace = self.trailingSpaceSwitch.on; }

- (void)dictionaryChanged {
    NSMutableArray<NSString *> *words = [NSMutableArray array];
    for (NSString *word in [self.dictionaryField.text componentsSeparatedByString:@","]) {
        NSString *trimmed = [word stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (trimmed.length) [words addObject:trimmed];
    }
    AKVoiceSettings.shared.customWords = words;
}

#pragma mark - Small pieces

- (UILabel *)label:(NSString *)text {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = UIColor.secondaryLabelColor;
    return label;
}

- (UILabel *)heading:(NSString *)text {
    UILabel *label = [self label:text];
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    label.text = text.uppercaseString;
    return label;
}

// Builds a row and, as a side effect, stores its switch, so the settings can be
// read and written without hunting through the view tree.
- (UIView *)switchRow:(NSString *)title isAutoSubmit:(BOOL)isAutoSubmit action:(SEL)action {
    UILabel *label = [self label:title];
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.textColor = UIColor.labelColor;
    UISwitch *toggle = [[UISwitch alloc] init];
    [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    if (isAutoSubmit) self.autoSubmitSwitch = toggle;
    else self.trailingSpaceSwitch = toggle;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, toggle]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

@end
