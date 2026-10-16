// Wolkara: the Voice settings screen, in full.
//
// Laid out as cards, matching how the rest of the launcher is built, and drawn from
// WolkaraTheme so it is the same navy and the same gold as the Add-on Manager it
// sits beside. It used to be built out of system colours, which made it the one
// page in the launcher that did not look like the launcher.
//
// The mapping row is the interesting one: it does not offer a list of supported
// controllers — it asks the user to press the button, and whichever event arrives
// becomes the trigger. That is what makes it work for hardware we have never seen.

#import "VoiceViewController.h"

#import <GameController/GameController.h>

#import "VoiceSettings.h"
#import "Trigger.h"
#import "../Input/InputRouter.h"
#import "../App/WolkaraLog.h"
#import "../App/WolkaraTheme.h"

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
    self.title = @"Key / Button Configuration".uppercaseString;
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.view.backgroundColor = WKInk();
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Done"
        style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.leftBarButtonItem.tintColor = WKGold();

    UIScrollView *scroll = [UIScrollView new];
    scroll.accessibilityIdentifier = @"voice.settings.scroll";
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:scroll];

    UIStackView *rows = [[UIStackView alloc] init];
    rows.axis = UILayoutConstraintAxisVertical;
    rows.spacing = 26;
    rows.translatesAutoresizingMaskIntoConstraints = NO;
    [scroll addSubview:rows];

    [rows addArrangedSubview:WKNote(@"Anything you press can start dictation: a button on a controller, a key, a mouse button. The game keeps its own use of that button.")];

    // --- Which button -------------------------------------------------------
    [rows addArrangedSubview:WKHeading(@"Button")];
    self.mappingValue = WKLabel(16, UIFontWeightSemibold, UIColor.whiteColor);
    self.mappingValue.accessibilityIdentifier = @"voice.mapping";
    self.mapButton = [self filledButton:@"voice.map" title:@"Map a button…" action:@selector(beginMapping)];
    self.mappingHint = WKNote(@"Tap Map, then press the button you want to use.");
    [rows addArrangedSubview:[self card:@[self.mappingValue, self.mapButton, self.mappingHint]]];

    // --- How it behaves -----------------------------------------------------
    [rows addArrangedSubview:WKHeading(@"Mode")];
    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Hold to talk", @"Press to start and stop"]];
    self.modeControl.accessibilityIdentifier = @"voice.mode";
    self.modeControl.selectedSegmentIndex = AKVoiceSettings.shared.mode == AKVoiceModeHold ? 0 : 1;
    self.modeControl.selectedSegmentTintColor = WKGold();
    [self.modeControl setTitleTextAttributes:@{NSForegroundColorAttributeName: WKOnGold()} forState:UIControlStateSelected];
    [self.modeControl setTitleTextAttributes:@{NSForegroundColorAttributeName: WKMuted()} forState:UIControlStateNormal];
    [self.modeControl addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    [rows addArrangedSubview:[self card:@[self.modeControl,
        WKNote(@"Hold to talk needs a button whose press and release both reach us. A button Apple keeps for itself, like Share, can only press to start and stop.")]]];

    // --- What happens to the words ------------------------------------------
    [rows addArrangedSubview:WKHeading(@"After transcribing")];
    [rows addArrangedSubview:[self card:@[
        [self switchRow:@"Send it straight away" isAutoSubmit:YES action:@selector(autoSubmitChanged)],
        [self switchRow:@"Add a space after the text" isAutoSubmit:NO action:@selector(trailingSpaceChanged)]
    ]]];

    // --- Dictionary ---------------------------------------------------------
    [rows addArrangedSubview:WKHeading(@"Words to expect")];
    [rows addArrangedSubview:[self card:@[self.dictionaryField, WKNote(@"These bias the recogniser, so a name comes out spelled the way you mean it.")]]];

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

    // The switch rows are built by the helper, which keeps them next to the
    // switch it created for each setting.
    self.autoSubmitSwitch.on = AKVoiceSettings.shared.autoSubmit;
    self.trailingSpaceSwitch.on = AKVoiceSettings.shared.trailingSpace;

    [self refreshMapping];

    __weak AKVoiceViewController *weakSelf = self;
    AKInputRouter.shared.onLearned = ^(AKTrigger *trigger, NSString *device) {
        [AKVoiceSettings.shared setLearnedElement:trigger.element forDevice:device];
        WKLog("voice", @"mapped %@ for %@", trigger.element, device);
        [weakSelf refreshMapping];
        weakSelf.mappingHint.text = @"Saved. It applies whenever that controller is connected.";
    };
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // The popup is built once and reused, so the current mapping is re-read here
    // rather than going stale behind it.
    [self refreshMapping];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Leaving the page must not leave the mapper armed: the next press anywhere
    // would otherwise be taken as the mapping and saved.
    [AKInputRouter.shared cancelLearning];
    AKInputRouter.shared.onLearned = nil;
}

- (void)done { WKDismissPage(self); }

#pragma mark - The mapping row

- (nullable NSString *)targetDevice {
    GCController *pad = GCController.controllers.firstObject;
    return pad.vendorName;
}

- (void)beginMapping {
    WKLog("voice", @"waiting for a button to map");
    self.mappingHint.text = @"Press the button you want to use now…";
    self.mapButton.enabled = NO;
    [AKInputRouter.shared beginLearning];
    // Learning also takes the first event, so if nothing arrives the button
    // comes back rather than leaving the screen stuck.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!AKInputRouter.shared.learning) return;
        // Disarm, do not just re-enable the button. This used to say "nothing
        // arrived" and then keep listening, so the next unrelated press was saved
        // as the mapping without a word.
        [AKInputRouter.shared cancelLearning];
        WKLog("voice", @"nothing arrived to map after 20s; no longer listening");
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
    WKLog("voice", @"mode is now %@", self.modeControl.selectedSegmentIndex == 0 ? @"hold" : @"toggle");
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

// The dictionary field is built here rather than in -viewDidLoad because the card
// helper needs it ready, and because a rounded-rect field would draw its own
// background over the panel's.
- (UITextField *)dictionaryField {
    if (_dictionaryField) return _dictionaryField;
    _dictionaryField = [[UITextField alloc] init];
    _dictionaryField.accessibilityIdentifier = @"voice.words";
    _dictionaryField.borderStyle = UITextBorderStyleNone;
    _dictionaryField.backgroundColor = WKPanel();
    _dictionaryField.layer.cornerRadius = 10;
    _dictionaryField.layer.masksToBounds = YES;
    _dictionaryField.textColor = UIColor.whiteColor;
    _dictionaryField.tintColor = WKGold();
    _dictionaryField.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _dictionaryField.adjustsFontForContentSizeCategory = YES;
    _dictionaryField.attributedPlaceholder = [[NSAttributedString alloc]
        initWithString:@"Names, places, game terms — separated by commas"
        attributes:@{NSForegroundColorAttributeName: WKMuted()}];
    // Losing the border costs the field its own inset, so put one back.
    _dictionaryField.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 1)];
    _dictionaryField.leftViewMode = UITextFieldViewModeAlways;
    _dictionaryField.text = [AKVoiceSettings.shared.customWords componentsJoinedByString:@", "];
    _dictionaryField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _dictionaryField.autocorrectionType = UITextAutocorrectionTypeNo;
    [_dictionaryField addTarget:self action:@selector(dictionaryChanged) forControlEvents:UIControlEventEditingDidEnd];
    return _dictionaryField;
}

// A group of rows on the launcher's panel colour. The padding lives here so every
// card is the same shape without each caller repeating four constraints.
- (UIView *)card:(NSArray<UIView *> *)rows {
    UIView *panel = WKCard();
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:rows];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 12;
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

- (UIButton *)filledButton:(NSString *)identifier title:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.accessibilityIdentifier = identifier;
    UIButtonConfiguration *configuration = UIButtonConfiguration.filledButtonConfiguration;
    configuration.title = title;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    configuration.baseBackgroundColor = WKGold();
    configuration.baseForegroundColor = WKOnGold();
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(14, 12, 14, 12);
    button.configuration = configuration;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

// Builds a row and, as a side effect, stores its switch, so the settings can be
// read and written without hunting through the view tree.
- (UIView *)switchRow:(NSString *)title isAutoSubmit:(BOOL)isAutoSubmit action:(SEL)action {
    UILabel *label = WKLabel(16, UIFontWeightRegular, UIColor.whiteColor);
    label.text = title;
    [label setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.onTintColor = WKGold();
    [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    if (isAutoSubmit) self.autoSubmitSwitch = toggle;
    else self.trailingSpaceSwitch = toggle;
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, toggle]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
}

@end
