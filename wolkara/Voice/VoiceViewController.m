// Wolkara: the Voice settings screen, in full.
//
// Laid out as cards, matching how the rest of the launcher is built, and drawn from
// WolkaraTheme so it is the same navy and the same gold as the Add-on Manager it sits
// beside.
//
// The order of the page is the order of the decisions, and the first one is whether to
// have the feature at all. The 2026-10-16 audit's first release blocker was a voice
// path that could start by itself, so nothing here is armed, and no element of the
// controller is touched, until the switch at the top is on and the user has pressed
// the button they want.

#import "VoiceViewController.h"

#import <GameController/GameController.h>

#import "VoiceSettings.h"
#import "Trigger.h"
#import "Dictation.h"
#import "../Input/InputRouter.h"
#import "../Input/InputElement.h"
#import "../Controller/ControllerInspector.h"
#import "../App/WolkaraLog.h"
#import "../App/WolkaraTheme.h"

@interface AKVoiceViewController ()
@property (nonatomic, strong) UISwitch *enabledSwitch;
@property (nonatomic, strong) UILabel *enabledNote;
@property (nonatomic, strong) UILabel *mappingValue;
@property (nonatomic, strong) UILabel *mappingHint;
@property (nonatomic, strong) UIButton *mapButton;
@property (nonatomic, strong) UIButton *clearButton;
@property (nonatomic, strong) UISwitch *takeButtonSwitch;
@property (nonatomic, strong) UIView *takeButtonCard;
@property (nonatomic, strong) UISegmentedControl *modeControl;
@property (nonatomic, strong) UISwitch *autoSubmitSwitch;
@property (nonatomic, strong) UISwitch *trailingSpaceSwitch;
@property (nonatomic, strong) UITextField *dictionaryField;
@property (nonatomic, strong) UIView *mappingCard;
@property (nonatomic, strong) UIView *modeCard;
@property (nonatomic, strong) UIView *afterCard;
@property (nonatomic, strong) UIView *wordsCard;
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

    [rows addArrangedSubview:WKNote(@"Nothing here happens on its own. Until this is switched on and a button is set, the microphone is never opened and no controller behaves any differently.")];

    // --- On, or off ---------------------------------------------------------
    [rows addArrangedSubview:WKHeading(@"Voice")];
    self.enabledSwitch = [self switchWithAction:@selector(enabledChanged)
                                         title:@"Use a button to talk"
                                    identifier:@"voice.enabled"];
    self.enabledNote = WKNote(@"");
    [rows addArrangedSubview:[self card:@[[self switchRow:@"Use a button to talk"
                                                  control:self.enabledSwitch], self.enabledNote]]];

    // --- Which button -------------------------------------------------------
    [rows addArrangedSubview:WKHeading(@"Button")];
    self.mappingValue = WKLabel(16, UIFontWeightSemibold, UIColor.whiteColor);
    self.mappingValue.accessibilityIdentifier = @"voice.mapping";
    self.mapButton = [self filledButton:@"voice.map" title:@"Map a button…" action:@selector(beginMapping)];
    self.clearButton = [self borderedButton:@"voice.clear" title:@"Clear" action:@selector(clearMapping)];
    self.mappingHint = WKNote(@"Tap Map, then press the button you want to use.");
    // The audit's finding, said where the mapping is made rather than in a document
    // reads: by default this feature listens to a button and does not take it from the game.
    // The switch below is how the user takes it, and it says which buttons that works for. It
    // carries an identifier because the voice fixture asserts the warning is still on the
    // page: a warning that can disappear without a test is the same as no warning.
    UILabel *collision = WKNote(@"The button you map still reaches the game unless you take it below. Nothing here takes it away from the game by itself, so choosing one the game already uses makes it do both things at once.");
    collision.accessibilityIdentifier = @"voice.mapping.collision";
    self.mappingCard = [self card:@[self.mappingValue, self.mapButton, self.clearButton, self.mappingHint, collision]];
    [rows addArrangedSubview:self.mappingCard];

    // Keep the game from seeing it: the user's explicit choice, off by default. With it on
    // a keyboard key the user has taken for dictation does not reach the game at all, which
    // is what "collision-free" means for the inputs this can be done for. The note says
    // which those are, because a pad button cannot be taken - iPadOS gives us the pad's
    // buttons as gamepad elements and the guest's key events cannot be traced back to them.
    self.takeButtonSwitch = [self switchWithAction:@selector(takeButtonChanged)
                                            title:@"Keep the game from seeing it"
                                       identifier:@"voice.takebutton"];
    self.takeButtonSwitch.on = AKVoiceSettings.shared.takeButtonFromGame;
    // The sentence about what cannot be taken carries an identifier for the same reason the
    // collision warning does: the fixture asserts it is still on the page. A limit that can
    // disappear without a test is not a stated limit.
    UILabel *padLimit = WKNote(@"On, a keyboard key you have mapped for dictation does not reach the game at all. A controller button cannot be taken this way, because iOS tells us about the pad's buttons in a form we cannot match to the game's own input - so for a pad, pick a button the game does not use.");
    padLimit.accessibilityIdentifier = @"voice.takebutton.note";
    self.takeButtonCard = [self card:@[[self switchRow:@"Keep the game from seeing it"
                                              control:self.takeButtonSwitch],
        padLimit]];
    [rows addArrangedSubview:self.takeButtonCard];

    // --- How it behaves -----------------------------------------------------
    [rows addArrangedSubview:WKHeading(@"Mode")];
    self.modeControl = [[UISegmentedControl alloc] initWithItems:@[@"Hold to talk", @"Press to start and stop"]];
    self.modeControl.accessibilityIdentifier = @"voice.mode";
    self.modeControl.selectedSegmentIndex = AKVoiceSettings.shared.mode == AKVoiceModeHold ? 0 : 1;
    self.modeControl.selectedSegmentTintColor = WKGold();
    [self.modeControl setTitleTextAttributes:@{NSForegroundColorAttributeName: WKOnGold()} forState:UIControlStateSelected];
    [self.modeControl setTitleTextAttributes:@{NSForegroundColorAttributeName: WKMuted()} forState:UIControlStateNormal];
    [self.modeControl addTarget:self action:@selector(modeChanged) forControlEvents:UIControlEventValueChanged];
    self.modeCard = [self card:@[self.modeControl,
        WKNote(@"Hold to talk needs a button whose press and release both reach us. A button Apple keeps for itself, like Share, can only press to start and stop.")]];
    [rows addArrangedSubview:self.modeCard];

    // --- What happens to the words ------------------------------------------
    [rows addArrangedSubview:WKHeading(@"After transcribing")];
    self.autoSubmitSwitch = [self switchWithAction:@selector(autoSubmitChanged)
                                           title:@"Send it straight away"
                                      identifier:@"voice.autosubmit"];
    self.trailingSpaceSwitch = [self switchWithAction:@selector(trailingSpaceChanged)
                                               title:@"Add a space after the text"
                                          identifier:@"voice.trailingspace"];
    self.afterCard = [self card:@[
        [self switchRow:@"Send it straight away" control:self.autoSubmitSwitch],
        [self switchRow:@"Add a space after the text" control:self.trailingSpaceSwitch]
    ]];
    [rows addArrangedSubview:self.afterCard];

    // --- Dictionary ---------------------------------------------------------
    [rows addArrangedSubview:WKHeading(@"Words to expect")];
    self.wordsCard = [self card:@[self.dictionaryField,
        WKNote(@"These bias the recogniser, so a name comes out spelled the way you mean it.")]];
    [rows addArrangedSubview:self.wordsCard];

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

    self.enabledSwitch.on = AKVoiceSettings.shared.enabled;
    self.autoSubmitSwitch.on = AKVoiceSettings.shared.autoSubmit;
    self.trailingSpaceSwitch.on = AKVoiceSettings.shared.trailingSpace;

    [self refreshMapping];
    [self refreshEnabledAppearance];

    __weak AKVoiceViewController *weakSelf = self;
    AKInputRouter.shared.onLearned = ^(AKTrigger *trigger, NSString *device) {
        AKVoiceSettings *settings = AKVoiceSettings.shared;
        // The element arrives as a canonical id, so what is stored is the same thing
        // that will be compared on the next press.
        [settings setLearnedElement:trigger.element forDevice:device];
        // Said in the log as well as on the page: this mapping does not take the button
        // away from the game, so a button the game uses does both. Stated at the moment it
        // is saved, which is when the user has just chosen it.
        WKLog("voice", @"mapped %@ for %@ (the game still receives it; a shared button does both)",
              trigger.element, device);
        [weakSelf refreshMapping];
        weakSelf.mappingHint.text = @"Saved. It applies whenever that controller is connected — and the game still receives that button.";
    };
    // The arming expires in the router, not here, but this is where the user is
    // looking when it does.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(learningExpired:)
                                               name:AKInputRouterLearningDidExpireNotification object:nil];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshMapping];
    [self refreshEnabledAppearance];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // Leaving the page must not leave the mapper armed: the next press anywhere would
    // otherwise be taken as the mapping and saved.
    [AKInputRouter.shared cancelLearning];
    AKInputRouter.shared.onLearned = nil;
}

- (void)done { WKDismissPage(self); }

#pragma mark - The device

// The controller the user is holding, and the identity a mapping is remembered
// against. Identity, not the vendor name: two pads from one vendor are two pads.
- (nullable GCController *)pad { return GCController.controllers.firstObject; }
- (nullable NSString *)deviceIdentity { GCController *pad = self.pad; return pad ? AKControllerIdentity(pad) : nil; }

#pragma mark - On, or off

- (void)takeButtonChanged {
    AKVoiceSettings.shared.takeButtonFromGame = self.takeButtonSwitch.on;
    // Said in the log as well as on the page: this is the one setting that changes what the
    // game itself receives.
    WKLog("voice", @"the game %s see a mapped keyboard key",
          self.takeButtonSwitch.on ? "will not" : "will still");
}

- (void)enabledChanged {
    AKVoiceSettings.shared.enabled = self.enabledSwitch.on;
    if (!self.enabledSwitch.on) {
        // The router gives every system gesture back on this notification; the words
        // stop here as well, so switching off is never half done.
        [AKInputRouter.shared cancelLearning];
        [AKDictation.shared cancel];
    }
    [self refreshEnabledAppearance];
}

- (void)refreshEnabledAppearance {
    BOOL on = AKVoiceSettings.shared.enabled;
    NSString *device = self.pad.vendorName;
    self.enabledNote.text = on
        ? (device ? [NSString stringWithFormat:@"On. The button below applies to %@.", device]
                  : @"On. Connect a controller and map a button.")
        : @"Off. The microphone is not opened and no controller is affected.";
    for (UIView *card in @[self.mappingCard, self.takeButtonCard, self.modeCard, self.afterCard, self.wordsCard]) {
        card.alpha = on ? 1.0 : 0.4;
        card.userInteractionEnabled = on;
    }
    self.mapButton.enabled = on && !AKInputRouter.shared.learning;
    self.clearButton.enabled = on;
    self.modeControl.enabled = on;
    self.takeButtonSwitch.enabled = on;
    self.autoSubmitSwitch.enabled = on;
    self.trailingSpaceSwitch.enabled = on;
    self.dictionaryField.enabled = on;
}

#pragma mark - The mapping

- (void)beginMapping {
    WKLog("voice", @"waiting for a button to map");
    self.mappingHint.text = @"Press the button you want to use now…";
    self.mapButton.enabled = NO;
    [AKInputRouter.shared beginLearning];
}

- (void)clearMapping {
    [AKVoiceSettings.shared clearMappingForDevice:[self deviceIdentity]];
    [self refreshMapping];
    self.mappingHint.text = @"Cleared. Nothing will start dictation until a button is set again.";
}

- (void)learningExpired:(NSNotification *)notification {
    (void)notification;
    if (!AKVoiceSettings.shared.enabled) return;
    self.mappingHint.text = @"Nothing arrived, so nothing was set. Tap Map and try again.";
    [self refreshEnabledAppearance];
}

- (void)refreshMapping {
    NSString *device = [self deviceIdentity];
    NSString *summary = [AKVoiceSettings.shared mappingSummaryForDevice:device];
    GCController *pad = self.pad;
    self.mappingValue.text = pad
        ? [NSString stringWithFormat:@"%@ — %@", summary, pad.vendorName]
        : [NSString stringWithFormat:@"%@ — no controller connected", summary];
    self.clearButton.hidden = [summary isEqualToString:@"Not set"];
    self.mapButton.enabled = AKVoiceSettings.shared.enabled && !AKInputRouter.shared.learning;
}

#pragma mark - The other rows

- (void)modeChanged {
    AKVoiceSettings.shared.mode = self.modeControl.selectedSegmentIndex == 0 ? AKVoiceModeHold : AKVoiceModeToggle;
    // A pattern that was being learned was for the other mode.
    [AKInputRouter.shared cancelLearning];
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

- (UISwitch *)switchWithAction:(SEL)action title:(NSString *)title identifier:(NSString *)identifier {
    UISwitch *toggle = [self switchWithAction:action];
    // Both of these, on every switch, and not only the ones a test happens to look for. The
    // row's text is a separate label, so without this a screen reader announces "switch, on"
    // with no idea which switch it is - and nothing but a person would ever notice. The layout
    // fixture failed on it the first time it looked: two switches had no name at all.
    toggle.accessibilityIdentifier = identifier;
    toggle.accessibilityLabel = title;
    return toggle;
}

- (UISwitch *)switchWithAction:(SEL)action {
    UISwitch *toggle = [[UISwitch alloc] init];
    toggle.onTintColor = WKGold();
    [toggle addTarget:self action:action forControlEvents:UIControlEventValueChanged];
    return toggle;
}

- (UIView *)switchRow:(NSString *)title control:(UISwitch *)control {
    UILabel *label = WKLabel(16, UIFontWeightRegular, UIColor.whiteColor);
    label.text = title;
    [label setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[label, control]];
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    return row;
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

- (UIButton *)borderedButton:(NSString *)identifier title:(NSString *)title action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.accessibilityIdentifier = identifier;
    UIButtonConfiguration *configuration = UIButtonConfiguration.grayButtonConfiguration;
    configuration.title = title;
    configuration.cornerStyle = UIButtonConfigurationCornerStyleMedium;
    configuration.baseForegroundColor = WKGold();
    configuration.contentInsets = NSDirectionalEdgeInsetsMake(10, 12, 10, 12);
    button.configuration = configuration;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

@end
