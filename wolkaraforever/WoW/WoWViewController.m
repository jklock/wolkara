#import "WoWViewController.h"
#import "Client.h"
#import "AddonManager.h"
#import "../Voice/VoiceViewController.h"
#import "../Voice/VoiceTestViewController.h"
#import "../App/WolkaraForeverLog.h"
#import "../App/WolkaraForeverTheme.h"
#import "Installation.h"
#import "ForeverUI.h"
#import "Updater.h"
#import "../App/LaunchProgressView.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static UIColor *Gold(void) { return [UIColor colorWithRed:0.88 green:0.73 blue:0.43 alpha:1]; }
static UIColor *Muted(void) { return [UIColor colorWithRed:0.66 green:0.72 blue:0.78 alpha:1]; }
static UILabel *Label(CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *label=[UILabel new]; label.numberOfLines=0; label.textColor=color;
    label.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont systemFontOfSize:size weight:weight]];
    label.adjustsFontForContentSizeCategory=YES;
    [label setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisVertical];
    return label;
}
static UIStackView *Stack(NSArray<UIView *> *views, CGFloat spacing) {
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis=UILayoutConstraintAxisVertical; stack.spacing=spacing; return stack;
}
// The Forever UI file operations are disk work: a backup reads the whole WTF and
// Interface trees, and a restore extracts and checks them. None of it belongs on
// the main thread, so every one runs here and reports back on the main thread.
static dispatch_queue_t TKForeverUIQueue(void) {
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue=dispatch_queue_create("org.tolkara.forever-ui", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
// The touch layout store's key and change notification, by value. The Touch
// module owns both, but WoW must not import it: the layer gate keeps these
// modules apart. Writing the dictionary read-modify-write is what preserves the
// layout's own values, which the store then reads back unchanged.
static NSString *const TKForeverLayoutKey = @"WolkaraForeverTouchLayoutV1";
static NSNotificationName const TKForeverLayoutDidChange = @"AKGamepadLayoutDidChange";

@interface TKWoWViewController () <UIDocumentPickerDelegate>
@end

@implementation TKWoWViewController {
    TKAppLibrary *_library;
    TKWoWClient *_client;
    NSDictionary *_product, *_plan;
    TKWoWInstallation *_installation;
    NSString *_region, *_locale;
    NSError *_error;
    NSDate *_checkedAt;
    NSUInteger _generation;
    BOOL _busy, _updating, _updateError, _starting;
    // A Forever UI file operation is running (backup, reset, restore, gamepad).
    // The rows are disabled while it runs and every handler rechecks it.
    BOOL _uiOperation;
    BOOL _gamepadEnabled, _overlayEnabled;
    // The game files are read once, when the launcher first appears. Not on every
    // appearance: leaving a popup used to send us straight back to the network.
    BOOL _checkedThisLaunch;
    NSString *_startupFailure;
    UILabel *_updatesLabel;
    NSString *_updatePhase;
    uint64_t _updateDone, _updateTotal;
    UIProgressView *_progressBar;
    CAGradientLayer *_background;
    UIStackView *_columns;
    NSLayoutConstraint *_markWidth;
    UIStackView *_gridRow1, *_gridRow2;
    UILabel *_stateLabel, *_detailLabel, *_versionLabel, *_startupLabel, *_compatibilityLabel;
    UIButton *_editionButton, *_preferencesButton, *_addonsButton, *_addonsDirectoryButton,
        *_voiceButton, *_voiceTestButton, *_permissionsButton, *_primaryButton,
        *_macEverButton, *_backupButton, *_resetButton, *_restoreButton, *_gamepadButton,
        *_overlayButton, *_settingsFolderButton;
    UIView *_markView;
    NSLayoutConstraint *_markCap;
    UIBarButtonItem *_refreshItem;
    UIActivityIndicatorView *_activity;
}
- (instancetype)initWithLibrary:(TKAppLibrary *)library {
    if (!(self=[super initWithNibName:nil bundle:nil])) return nil;
    _library=library; self.title=@"";
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    _product=TKWoWProducts()[0];
    for (NSDictionary *p in TKWoWProducts()) if ([p[@"id"] isEqual:[defaults stringForKey:@"WoWProduct"]]) _product=p;
    _region=[defaults stringForKey:@"WoWRegion"]?:@"eu";
    if (![@[@"eu",@"us",@"kr",@"tw"] containsObject:_region]) _region=@"eu";
    _locale=[defaults stringForKey:@"WoWLocale"]?:@"enUS";
    if (![@[@"enUS",@"esES"] containsObject:_locale]) _locale=@"enUS";
    return self;
}
- (UIButton *)button:(NSString *)identifier action:(SEL)action {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    button.accessibilityIdentifier=identifier;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}
// The page's own section heading: the small uppercase label the edition line
// always used, now naming each group of rows.
- (UILabel *)heading:(NSString *)text {
    UILabel *label=Label(11,UIFontWeightSemibold,Muted());
    label.text=text.uppercaseString;
    return label;
}
// One section, in its own box: the heading and its rows share a panel with the
// page's own border and fill, so the eye can find a group without a long column
// of loose rows.
- (UIView *)sectionBoxWithTitle:(NSString *)title identifier:(NSString *)identifier rows:(NSArray<UIView *> *)rows {
    UIView *box=[UIView new];
    box.accessibilityIdentifier=identifier;
    box.translatesAutoresizingMaskIntoConstraints=NO;
    box.backgroundColor=[UIColor colorWithRed:0.055 green:0.085 blue:0.125 alpha:1];
    box.layer.cornerRadius=14;
    box.layer.borderWidth=1;
    box.layer.borderColor=[Gold() colorWithAlphaComponent:0.18].CGColor;
    UILabel *heading=[self heading:title];
    heading.accessibilityIdentifier=[identifier stringByReplacingOccurrencesOfString:@"wow.box."
                                                                          withString:@"wow.heading."];
    UIStackView *stack=Stack([@[heading] arrayByAddingObjectsFromArray:rows],8);
    stack.translatesAutoresizingMaskIntoConstraints=NO;
    // A box in the taller row is stretched to match its neighbour; without a
    // spacer the extra height would be shared out among the rows and drift them
    // apart. The spacer takes all of it, so the rows stay together at the top.
    UIView *spacer=[UIView new];
    spacer.accessibilityIdentifier=@"wow.box.spacer";
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [spacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [stack addArrangedSubview:spacer];
    [box addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:box.topAnchor constant:14],
        [stack.leadingAnchor constraintEqualToAnchor:box.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:box.trailingAnchor constant:-16],
        [stack.bottomAnchor constraintEqualToAnchor:box.bottomAnchor constant:-14],
    ]];
    return box;
}
// Two boxes side by side on a wide screen, stacked when there is no room.
- (UIStackView *)boxRow:(NSArray<UIView *> *)boxes {
    UIStackView *row=[[UIStackView alloc] initWithArrangedSubviews:boxes];
    row.axis=UILayoutConstraintAxisHorizontal;
    row.distribution=UIStackViewDistributionFillEqually;
    row.alignment=UIStackViewAlignmentFill;
    row.spacing=16;
    return row;
}
// The layer's mark, where the wordmark used to sit. It is drawn at the top
// row's width, so it grows and shrinks with the window, with one cap: it may
// never take more than a fifth of the height, so the boxes below it always have
// room. The aspect constraint is optional for that reason — when the cap
// applies, the picture letterboxes rather than fighting the column's width.
//
// The cap spans this view and the controller's, so it can only be activated once
// the two share an ancestor. Here the picture is still unattached, and UIKit
// raises "no common ancestor" for exactly that — which aborts the app at launch,
// measured on 2026-10-16. The cap is therefore kept and switched on from
// -viewDidLayoutSubviews, by which time the column has been added to the scroll
// view.
- (UIView *)markView {
    UIImage *image=[UIImage imageNamed:@"WolkaraForeverLogo"];
    if (image) {
        UIImageView *view=[[UIImageView alloc] initWithImage:image];
        view.contentMode=UIViewContentModeScaleAspectFit;
        view.accessibilityIdentifier=@"wow.logo";
        view.accessibilityLabel=@"WolkaraForever";
        // The picture's own pixel size is far larger than the column, so its
        // intrinsic size must not be allowed to argue with the constraints below.
        [view setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
        [view setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
        NSLayoutConstraint *aspect=[view.widthAnchor constraintEqualToAnchor:view.heightAnchor
            multiplier:image.size.width/image.size.height];
        aspect.priority=999;
        aspect.active=YES;
        _markCap=[view.heightAnchor constraintLessThanOrEqualToAnchor:self.view.heightAnchor
            multiplier:0.20];
        return view;
    }
    // No artwork in this build: say the name rather than show an empty gap.
    UILabel *label=Label(37,UIFontWeightBold,Gold()); label.text=@"WOLKAREFOREVER";
    label.numberOfLines=1;
    label.adjustsFontSizeToFitWidth=YES;
    label.minimumScaleFactor=0.45;
    UIFontDescriptor *serif=[[UIFont systemFontOfSize:37 weight:UIFontWeightBold].fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignSerif];
    if (serif) label.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleLargeTitle] scaledFontForFont:[UIFont fontWithDescriptor:serif size:37]];
    label.accessibilityIdentifier=@"wow.title";
    return label;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.view.backgroundColor=[UIColor colorWithRed:0.025 green:0.045 blue:0.075 alpha:1];
    _background=[CAGradientLayer layer];
    _background.colors=@[(id)[UIColor colorWithRed:0.035 green:0.085 blue:0.13 alpha:1].CGColor,
        (id)[UIColor colorWithRed:0.02 green:0.03 blue:0.055 alpha:1].CGColor];
    _background.startPoint=CGPointMake(0,0); _background.endPoint=CGPointMake(1,1);
    [self.view.layer insertSublayer:_background atIndex:0];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"gearshape"]
        style:UIBarButtonItemStylePlain target:self action:@selector(settings)];
    self.navigationItem.rightBarButtonItem.accessibilityLabel=@"Settings";
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier=@"wow.settings";
    self.navigationItem.backButtonTitle=@"Back";
    _refreshItem=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]
        style:UIBarButtonItemStylePlain target:self action:@selector(refresh)];
    _refreshItem.accessibilityLabel=@"Check for updates";
    _refreshItem.accessibilityIdentifier=@"wow.refresh";
    self.navigationItem.leftBarButtonItem=_refreshItem;

    // Identity and the play surface share the top of the page; the four
    // sections sit in boxes underneath both, so the whole page fits without
    // scrolling on an iPad instead of a column that has to be scrolled.
    _markView=[self markView];
    _editionButton=[self button:@"wow.edition" action:@selector(chooseEdition)];
    _preferencesButton=[self button:@"wow.preferences" action:@selector(preferences)];
    _addonsButton=[self button:@"wow.addons.manage" action:@selector(manageAddons)];
    [_addonsButton setTitle:@"Install Addons (Curse & Direct)" forState:UIControlStateNormal];
    // Mac-Ever is a Forever-compatible add-on that is downloaded from CurseForge
    // by the person using Safari, then installed with the row above. No scrape,
    // no embedded download URL, and opening the page is not an installation.
    _macEverButton=[self button:@"wow.addons.macEver" action:@selector(downloadMacEver)];
    [_macEverButton setTitle:@"Download Mac-Ever" forState:UIControlStateNormal];
    _addonsDirectoryButton=[self button:@"wow.addons.directory" action:@selector(openAddonDirectory)];
    [_addonsDirectoryButton setTitle:@"Open Add-on Directory" forState:UIControlStateNormal];
    // Straight to this app's own page in Settings, which is where the Microphone and Speech Recognition
    // switches live. Available before the game is installed, because it is a setting and not a game
    // action - and it is the only place those switches can be changed.
    _permissionsButton=[self button:@"wow.permissions" action:@selector(openPermissions)];
    [_permissionsButton setTitle:@"Toggle Permissions (Mic & Speech)" forState:UIControlStateNormal];
    _voiceButton=[self button:@"wow.voice" action:@selector(manageVoice)];
    [_voiceButton setTitle:@"Key / Button Configuration" forState:UIControlStateNormal];
    _voiceTestButton=[self button:@"wow.voice.test" action:@selector(testVoice)];
    [_voiceTestButton setTitle:@"Test Voice & Dictation" forState:UIControlStateNormal];
    _compatibilityLabel=Label(12,UIFontWeightRegular,Muted());
    _backupButton=[self button:@"wow.performance.backup" action:@selector(backupUI)];
    [_backupButton setTitle:@"Backup WoW UI Configuration" forState:UIControlStateNormal];
    _resetButton=[self button:@"wow.performance.reset" action:@selector(resetGraphics)];
    [_resetButton setTitle:@"Reset to Default Graphical Settings" forState:UIControlStateNormal];
    _restoreButton=[self button:@"wow.performance.restore" action:@selector(restoreUI)];
    [_restoreButton setTitle:@"Restore WoW UI Configuration" forState:UIControlStateNormal];
    _gamepadButton=[self button:@"wow.performance.gamepad" action:@selector(enableGamepad)];
    [_gamepadButton setTitle:@"Enable Gamepad UI" forState:UIControlStateNormal];
    _overlayButton=[self button:@"wow.performance.overlay" action:@selector(togglePerformanceOverlay)];
    [_overlayButton setTitle:@"Enable Performance Overlay" forState:UIControlStateNormal];
    _settingsFolderButton=[self button:@"wow.performance.settingsFolder" action:@selector(openSettingsFolder)];
    [_settingsFolderButton setTitle:@"Open Settings Folder" forState:UIControlStateNormal];

    // The four sections, as boxes. Their order is the order they are read in.
    // The compatibility note belongs to the edition it is about, so it lives in
    // that box rather than loose on the page.
    UIView *editionBox=[self sectionBoxWithTitle:@"Game Edition" identifier:@"wow.box.edition"
        rows:@[_editionButton,_preferencesButton,_compatibilityLabel]];
    UIView *addonsBox=[self sectionBoxWithTitle:@"Add-On Manager" identifier:@"wow.box.addons"
        rows:@[_addonsButton,_macEverButton,_addonsDirectoryButton]];
    UIView *voiceBox=[self sectionBoxWithTitle:@"Voice Manager" identifier:@"wow.box.voice"
        rows:@[_permissionsButton,_voiceButton,_voiceTestButton]];
    UIView *performanceBox=[self sectionBoxWithTitle:@"Performance & UI Manager" identifier:@"wow.box.performance"
        rows:@[_backupButton,_resetButton,_restoreButton,_gamepadButton,_overlayButton,_settingsFolderButton]];

    _activity=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _activity.color=Gold(); _activity.hidesWhenStopped=YES;
    _stateLabel=Label(23,UIFontWeightSemibold,UIColor.whiteColor); _stateLabel.accessibilityIdentifier=@"wow.status";
    UIStackView *stateRow=[[UIStackView alloc] initWithArrangedSubviews:@[_activity,_stateLabel]];
    stateRow.axis=UILayoutConstraintAxisHorizontal; stateRow.spacing=10;
    // A hidden activity indicator retains its 20pt intrinsic height. Center
    // it rather than stretching/compressing both views to that same height.
    stateRow.alignment=UIStackViewAlignmentCenter;
    [_activity setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _detailLabel=Label(15,UIFontWeightRegular,Muted()); _detailLabel.accessibilityIdentifier=@"wow.detail";
    _versionLabel=Label(12,UIFontWeightRegular,Muted()); _versionLabel.accessibilityIdentifier=@"wow.version";
    _progressBar=[[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressBar.progressTintColor=Gold(); _progressBar.accessibilityIdentifier=@"wow.progress";
    _launchProgress=[TKLaunchProgressView new];
    _launchProgress.accessibilityIdentifier=@"wow.elapsed";
    _diagnosticsButton=[self button:@"wow.diagnostics" action:@selector(diagnostics)];
    [_diagnosticsButton setTitle:@"Diagnostics and logs" forState:UIControlStateNormal];
    _diagnosticsButton.tintColor=Gold(); _diagnosticsButton.hidden=YES;
    UIStackView *status=Stack(@[stateRow,_detailLabel,_progressBar,_launchProgress,_versionLabel,_diagnosticsButton],10);
    status.layoutMargins=UIEdgeInsetsMake(20,20,20,20); status.layoutMarginsRelativeArrangement=YES;
    status.backgroundColor=[UIColor colorWithRed:0.07 green:0.105 blue:0.15 alpha:1];
    status.layer.cornerRadius=16; status.layer.borderWidth=1;
    status.layer.borderColor=[Gold() colorWithAlphaComponent:0.24].CGColor;
    _primaryButton=[self button:@"wow.primary" action:@selector(primaryAction)];
    [_primaryButton.heightAnchor constraintGreaterThanOrEqualToConstant:52].active=YES;
    _updatesLabel=Label(12,UIFontWeightRegular,Muted()); _updatesLabel.accessibilityIdentifier=@"wow.updates";
    _updatesLabel.text=@"Updates automatically. Keep this app open while downloading.";
    _startupLabel=Label(12,UIFontWeightRegular,Muted()); _startupLabel.accessibilityIdentifier=@"wow.startup";
    UIStackView *right=Stack(@[status,_primaryButton,_updatesLabel,_startupLabel],12);
    // The top of the page: the mark on the left, what the launcher is doing and
    // the Play button on the right. The boxes go underneath both.
    UIStackView *top=[[UIStackView alloc] initWithArrangedSubviews:@[_markView,right]];
    top.axis=UILayoutConstraintAxisHorizontal; top.spacing=28; top.alignment=UIStackViewAlignmentTop;
    top.accessibilityIdentifier=@"wow.top";
    _markWidth=[_markView.widthAnchor constraintEqualToAnchor:top.widthAnchor multiplier:0.30];
    _markWidth.active=YES;
    _gridRow1=[self boxRow:@[editionBox,addonsBox]];
    _gridRow2=[self boxRow:@[voiceBox,performanceBox]];
    UIStackView *grid=Stack(@[_gridRow1,_gridRow2],16);
    grid.accessibilityIdentifier=@"wow.grid";
    _columns=Stack(@[top,grid],20); _columns.accessibilityIdentifier=@"wow.columns";
    _columns.alignment=UIStackViewAlignmentFill;

    UIScrollView *scroll=[UIScrollView new]; scroll.accessibilityIdentifier=@"wow.scroll";
    scroll.translatesAutoresizingMaskIntoConstraints=NO; [self.view addSubview:scroll];
    _columns.translatesAutoresizingMaskIntoConstraints=NO; [scroll addSubview:_columns];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
        [_columns.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:16],
        [_columns.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [_columns.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:24],
        [_columns.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-24],
        [_columns.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-48]
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(foreground:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(background:)
        name:UIApplicationWillResignActiveNotification object:nil];
    [self render];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    UINavigationBarAppearance *appearance=[UINavigationBarAppearance new]; [appearance configureWithOpaqueBackground];
    appearance.backgroundColor=[UIColor colorWithRed:0.025 green:0.045 blue:0.075 alpha:1];
    appearance.titleTextAttributes=@{NSForegroundColorAttributeName:Gold()};
    self.navigationItem.standardAppearance=appearance; self.navigationItem.scrollEdgeAppearance=appearance;
    self.navigationItem.compactAppearance=appearance;
    self.navigationController.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.navigationController.navigationBar.prefersLargeTitles=NO;
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.navigationController.navigationBar.tintColor=Gold();
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _background.frame=self.view.bounds;
    // The mark's height cap was made in -markView, before the picture had a
    // superview. Now it does, so the two ends have an ancestor and it can be
    // switched on; once only, because switching it on lays out again.
    if (_markCap && !_markCap.active) _markCap.active=YES;
    BOOL horizontal=self.view.bounds.size.width>=700 && !UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    // Two boxes side by side when there is room, one column otherwise. The page
    // itself is always a single vertical column, and the boxes keep their order.
    _gridRow1.axis=horizontal?UILayoutConstraintAxisHorizontal:UILayoutConstraintAxisVertical;
    _gridRow2.axis=_gridRow1.axis;
    _gridRow1.distribution=horizontal?UIStackViewDistributionFillEqually:UIStackViewDistributionFill;
    _gridRow2.distribution=_gridRow1.distribution;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // Once per launch, and not again. This used to run on every appearance, so
    // closing the add-on or the voice popup sent the launcher back for a full
    // manifest check and the home page sat busy again - every single time, for a
    // page the user had only looked at. The refresh button and Try again still ask
    // for a check on purpose, and that is now the only way to get a second one.
    if (_checkedThisLaunch || _busy || _sessionUsed || _starting) return;
    _checkedThisLaunch=YES;
    WKLog("ui", @"home: first appearance, checking the game files");
    [self refresh];
}
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self cancel]; }
- (void)foreground:(NSNotification *)note {
    (void)note;
    // Deliberately no check here. Coming back to the app is not a reason to re-read
    // every manifest, and the check above has already happened for this launch.
    WKLog("ui", @"home: back in front");
}
- (void)background:(NSNotification *)note { (void)note; [self cancel]; }
- (void)cancel { [_client cancel]; _client=nil; _generation++; _busy=NO; }
- (void)setExecutionMode:(TKExecutionMode)mode { _executionMode=mode; if (self.isViewLoaded) [self render]; }
- (void)setSessionUsed:(BOOL)used { _sessionUsed=used; if (used) [self cancel]; if (self.isViewLoaded) [self render]; }
- (void)selectProduct:(NSDictionary *)product {
    if (_starting || _sessionUsed) return;
    if (![TKWoWProducts() containsObject:product]) return;
    _product=product;
    [NSUserDefaults.standardUserDefaults setObject:product[@"id"] forKey:@"WoWProduct"];
    [self refresh];
}
- (void)refresh {
    // Asked for on purpose: the refresh button, Try again, or a changed edition.
    // The check that happens by itself runs once per launch; see -viewDidAppear:.
    WKLog("wow", @"a check was asked for");
    [self checkForUpdatesAndLaunch:NO];
}
- (void)checkForUpdatesAndLaunch:(BOOL)launch { [self checkForUpdatesAndLaunch:launch install:NO]; }
- (void)checkForUpdatesAndLaunch:(BOOL)launch install:(BOOL)install {
    if (_starting || _sessionUsed) return;
    NSString *installKey=[@"WoWInstallRequested." stringByAppendingString:_product[@"id"]];
    NSString *repairKey=[@"WoWRepairRequested." stringByAppendingString:_product[@"id"]];
    if(install && _installation.state==TKWoWInstallationNeedsRepair)
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:repairKey];
    if(install)[NSUserDefaults.standardUserDefaults setBool:YES forKey:installKey];
    install=install || [NSUserDefaults.standardUserDefaults boolForKey:installKey];
    BOOL repair=[NSUserDefaults.standardUserDefaults boolForKey:repairKey];
    [self cancel]; _plan=nil; _installation=nil; _error=nil; _checkedAt=nil; _startupFailure=nil;
    _updating=NO; _updateError=NO; _updatePhase=nil; _updateDone=0; _updateTotal=0;
    _client=[TKWoWClient new]; _busy=YES; [self render];
    WKLog("wow", @"checking %@ %@/%@ install=%d launch=%d", _product[@"id"], _region, _locale, install, launch);
    TKWoWClient *client=_client; NSUInteger generation=_generation;
    NSDictionary *product=_product; NSString *region=_region, *locale=_locale;
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once,^{ queue=dispatch_queue_create("org.tolkara.wow-updates",DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue,^{
        [self->_library discover];
        NSError *error=nil;
        NSDictionary *plan=[client planForProduct:product[@"id"] region:region locale:locale error:&error];
        TKWoWInstallation *installation=plan?TKWoWInspectInstallation(self->_library,product,plan):nil;
        BOOL updateAttempted=plan && (install || installation.state==TKWoWInstallationOutdated) && !client.cancelled;
        if(updateAttempted) {
            __block NSString *lastPhase=nil;
            void (^progress)(NSString *,uint64_t,uint64_t)=^(NSString *phase,uint64_t done,uint64_t total) {
                if(![lastPhase isEqual:phase]) {
                    lastPhase=phase;NSLog(@"[wow-update] Phase: %@",phase);
                }
                dispatch_async(dispatch_get_main_queue(),^{
                    if(generation!=self->_generation)return;
                    self->_plan=plan;self->_installation=installation;self->_updating=YES;
                    self->_updatePhase=phase;self->_updateDone=done;self->_updateTotal=total;[self render];
                });
            };
            progress(@"snapshot",0,0);
            NSString *directory=installation.app?[self->_library workingDirectoryForApp:installation.app error:&error]:nil;
            NSString *root=directory?directory.stringByDeletingLastPathComponent:
                [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject stringByAppendingPathComponent:@"World of Warcraft"];
            TKWoWUpdater *updater=[[TKWoWUpdater alloc] initWithClient:client];
            updater.fullVerification=repair;
            if([updater updatePlan:plan root:root progress:progress error:&error]) {
                [self->_library discover];installation=TKWoWInspectInstallation(self->_library,product,plan);error=nil;
                // Editions without a bundled compatibility profile still need a
                // library entry after their first download. Register only the
                // original executable already verified by the install manifest.
                if(installation.state==TKWoWInstallationMissing) {
                    NSMutableArray *executables=[NSMutableArray new];
                    for(NSDictionary *file in plan[@"files"])if([file[@"path"] hasSuffix:@".app/Contents/MacOS/World of Warcraft"])
                        [executables addObject:[[root stringByAppendingPathComponent:product[@"folder"]] stringByAppendingPathComponent:file[@"path"]]];
                    if(executables.count==1 && [self->_library importExecutable:executables[0] copy:NO error:&error])
                        installation=TKWoWInspectInstallation(self->_library,product,plan);
                }
                if(installation.state==TKWoWInstallationReady) {
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:installKey];
                    [NSUserDefaults.standardUserDefaults removeObjectForKey:repairKey];
                }
                else error=error?:installation.error?:TKWoWError(@"The downloaded installation could not be registered in the library.");
            }
            if(error)NSLog(@"[wow-update] Interrupted during %@: %@ (%@:%ld)",lastPhase?:@"preparation",
                error.localizedDescription,error.domain,(long)error.code);
            NSLog(@"[wow-update] Verification bytes read=%llu reused=%llu",updater.verificationBytesRead,updater.verificationBytesReused);
        }

        // Before the home page is exposed again: finish or roll back a restore
        // that a previous launch interrupted. This is the one place that runs
        // early enough to be ahead of the page, and it runs only for Forever.
        if(installation.state==TKWoWInstallationReady && installation.app &&
           [self->_product[@"id"] isEqual:TKForeverUIEdition]) {
            NSString *directory=[self->_library workingDirectoryForApp:installation.app error:NULL];
            if(directory && ![TKForeverUI recoverInterruptedRestoreInWorkingDirectory:directory error:NULL])
                NSLog(@"[wow-ui] an interrupted restore could not be resolved; the game files were left as they were");
        }
        dispatch_async(dispatch_get_main_queue(),^{
            if (generation!=self->_generation) return;
            self->_plan=plan; self->_installation=installation; self->_error=error;
            self->_checkedAt=plan?NSDate.date:nil; self->_busy=NO; self->_updating=NO; self->_updateError=updateAttempted && error; [self render];
            WKLog("wow", @"checked: state=%ld error=%@", (long)installation.state, error.localizedDescription ?: @"none");
            // Returning from the background or changing edition invalidates this request.
            if (launch && !error && !client.cancelled && installation.state==TKWoWInstallationReady && installation.app && !self->_sessionUsed &&
                self.view.window && self.navigationController.topViewController==self && self.startApp) self.startApp(installation.app);
        });
    });
}
- (void)primaryAction {
    if (_busy || _sessionUsed || _starting) return;
    if (_startupFailure) { _startupFailure=nil; [self render]; }
    if (_error || !_plan) { [self refresh]; return; }
    if (_installation.state==TKWoWInstallationMissing || _installation.state==TKWoWInstallationNeedsRepair) {
        [self checkForUpdatesAndLaunch:NO install:YES];return;
    }
    if (_installation.state!=TKWoWInstallationReady) return;
    if (_executionMode==TKExecutionModeNone) return;
    [self checkForUpdatesAndLaunch:YES];
}
- (void)repairInstallation {
    if(_busy || _starting || _sessionUsed || !_installation.app)return;
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:[@"WoWRepairRequested." stringByAppendingString:_product[@"id"]]];
    [self checkForUpdatesAndLaunch:NO install:YES];
}
- (void)configureButton:(UIButton *)button title:(NSString *)title filled:(BOOL)filled {
    UIButtonConfiguration *configuration=filled?UIButtonConfiguration.filledButtonConfiguration:UIButtonConfiguration.plainButtonConfiguration;
    configuration.title=title; configuration.cornerStyle=UIButtonConfigurationCornerStyleMedium;
    configuration.baseBackgroundColor=Gold(); configuration.baseForegroundColor=filled?[UIColor colorWithRed:0.08 green:0.065 blue:0.035 alpha:1]:Gold();
    configuration.contentInsets=NSDirectionalEdgeInsetsMake(filled?14:8,12,filled?14:8,12);
    button.configuration=configuration;
    [button setTitle:title forState:UIControlStateNormal];
}
- (void)render {
    if (!self.isViewLoaded) return;
    [self configureButton:_editionButton title:[_product[@"name"] stringByAppendingString:@"  ▾"] filled:NO];
    _editionButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
    _editionButton.backgroundColor=[UIColor colorWithWhite:1 alpha:0.055]; _editionButton.layer.cornerRadius=10;
    [self configureButton:_preferencesButton title:[NSString stringWithFormat:@"%@  ·  %@  ▾",_region.uppercaseString,[_locale isEqual:@"esES"]?@"Spanish":@"English"] filled:NO];
    _preferencesButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
    [self configureButton:_addonsButton title:_installation.app?@"Install Addons (Curse & Direct)":@"Install Addons (Curse & Direct) (install game first)" filled:NO];
    _addonsButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
    _addonsButton.enabled=_installation.app && !_busy && !_starting && !_sessionUsed;
    [self configureButton:_macEverButton title:@"Download Mac-Ever" filled:NO];
    _macEverButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
    // Navigation only: the page is opened for the user to download the ZIP.
    _macEverButton.enabled=YES;
    [self configureButton:_addonsDirectoryButton title:_installation.app?@"Open Add-on Directory":@"Open Add-on Directory (install game first)" filled:NO];
    _addonsDirectoryButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
    _addonsDirectoryButton.enabled=_addonsButton.enabled;
    [self configureButton:_voiceButton title:@"Key / Button Configuration" filled:NO];
    _voiceButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
    // Available before the game is installed: it is a setting, not a game action.
    _voiceButton.enabled=!_busy && !_starting;
    [self configureButton:_voiceTestButton title:@"Test Voice & Dictation" filled:NO];
    _voiceTestButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
    _voiceTestButton.enabled=_voiceButton.enabled;
    [self configureButton:_permissionsButton title:@"Toggle Permissions (Mic & Speech)" filled:NO];
    _permissionsButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
    // Never disabled: opening Settings is always allowed, even while the game is busy.
    _permissionsButton.enabled=YES;
    // Performance & UI Manager. The Forever file rows need a ready Forever
    // installation - and the selected edition must be Forever, because they must
    // never read or write another edition's files - no download, start or
    // session, and no other UI operation in flight. The overlay is a
    // WolkaraForever runtime feature and follows the launcher's non-busy rule.
    NSString *foreverDirectory=[self foreverWorkingDirectory];
    BOOL foreverReady=foreverDirectory && !_busy && !_starting && !_sessionUsed && !_uiOperation;
    _gamepadEnabled=foreverDirectory?[TKForeverUI gamepadEnabledInWorkingDirectory:foreverDirectory]:NO;
    NSDictionary *layout=[NSUserDefaults.standardUserDefaults objectForKey:TKForeverLayoutKey];
    _overlayEnabled=[layout isKindOfClass:NSDictionary.class] && [layout[@"performanceOverlayEnabled"] boolValue];
    for (UIButton *button in @[_backupButton,_resetButton,_restoreButton,_settingsFolderButton]) {
        button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
        button.enabled=foreverReady;
    }
    [self configureButton:_backupButton title:@"Backup WoW UI Configuration" filled:NO];
    [self configureButton:_resetButton title:@"Reset to Default Graphical Settings" filled:NO];
    [self configureButton:_restoreButton title:@"Restore WoW UI Configuration" filled:NO];
    [self configureButton:_settingsFolderButton title:@"Open Settings Folder" filled:NO];
    _gamepadButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
    [self configureButton:_gamepadButton title:_gamepadEnabled?@"Gamepad UI Enabled":@"Enable Gamepad UI" filled:NO];
    _gamepadButton.enabled=foreverReady;
    _overlayButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
    [self configureButton:_overlayButton title:_overlayEnabled?@"Performance Overlay Enabled":@"Enable Performance Overlay" filled:NO];
    _overlayButton.enabled=!_busy && !_starting;
    _compatibilityLabel.text=([_product[@"id"] isEqual:@"wow"] || [_product[@"id"] isEqual:@"wow_beta"] || [_product[@"id"] isEqual:@"wow_classic"])?
        @"Compatibility with this edition is not yet verified.":
        @"";
    _compatibilityLabel.hidden=!_compatibilityLabel.text.length;
    _editionButton.enabled=!_busy && !_starting && !_sessionUsed;
    _preferencesButton.enabled=_editionButton.enabled;
    self.navigationItem.rightBarButtonItem.enabled=!_updating && !_starting;
    _primaryButton.hidden=_starting || _sessionUsed;
    _updatesLabel.hidden=_starting || _sessionUsed;
    _startupLabel.hidden=_starting || _sessionUsed;
    _progressBar.hidden=!_updating || !_updateTotal;
    _progressBar.progress=_updateTotal?(float)((double)_updateDone/_updateTotal):0;
    NSString *title=nil, *detail=nil, *action=nil;
    BOOL enabled=NO;
    if (_starting) {
        title=@"Starting…";
        detail=_detailLabel.text.length?_detailLabel.text:@"Preparing to launch. Keep this app open.";
        action=@"Starting…";
    } else if (_startupFailure) {
        title=@"Could not start";
        detail=_sessionUsed?@"Close this app from the app switcher, then reopen it to try again. Details are available in Diagnostics and logs.":@"Try again. Details are available in Diagnostics and logs.";
        action=_sessionUsed?@"Reopen to retry":@"Try again"; enabled=!_sessionUsed;
    } else if (_sessionUsed) {
        title=@"Reopen to start again";
        detail=@"Close the app from the app switcher before starting another session.";
        action=@"Session ended";
    } else if (_busy && _updating) {
        title=@"Updating your game…";
        NSDictionary *phases=@{@"snapshot":@"Preparing the installation",
            @"manifests":@"Reading the update",
            @"verify":@"Checking existing data",
            @"reuse":@"Comparing installed content",
            @"indices":@"Locating download files",
            @"download":@"Downloading new data",
            @"files":@"Installing game files",
            @"activate":@"Finishing the update",
            @"complete":@"Update complete"};
        detail=phases[_updatePhase]?:@"Preparing…";
        if(_updateTotal) {
            BOOL bytes=[_updatePhase isEqual:@"verify"] || [_updatePhase isEqual:@"download"];
            NSString *done=bytes?[NSByteCountFormatter stringFromByteCount:(int64_t)_updateDone countStyle:NSByteCountFormatterCountStyleFile]:@(_updateDone).stringValue;
            NSString *total=bytes?[NSByteCountFormatter stringFromByteCount:(int64_t)_updateTotal countStyle:NSByteCountFormatterCountStyleFile]:@(_updateTotal).stringValue;
            detail=[detail stringByAppendingFormat:@" · %@ / %@",done,total];
        }
        action=@"Updating…";
    } else if (_busy) {
        title=@"Checking for updates…";
        detail=@"Checking the latest version and your installed copy.";
        action=@"Checking…";
    } else if (_error || !_plan) {
        title=_updateError?@"Update interrupted":@"Could not check this edition";
        detail=_updateError?@"Your installed copy is preserved. Try again to resume the update; see Settings for details.":@"We cannot confirm that your game is up to date. Check your connection and try again.";
        action=@"Try again"; enabled=YES;
    } else {
        switch (_installation.state) {
        case TKWoWInstallationMissing:
            title=@"Not installed";
            detail=@"Install this edition on your device. The download may require several gigabytes.";
            action=@"Install"; enabled=YES; break;
        case TKWoWInstallationOutdated:
            title=@"Update required";
            detail=@"A newer build is available. The update starts automatically.";
            action=@"Update needed to play"; break;
        case TKWoWInstallationNeedsRepair:
            title=@"Your copy needs attention";
            detail=@"We could not verify all game files. Repair downloads the original files and keeps your settings and addons.";
            action=@"Repair installation"; enabled=YES; break;
        case TKWoWInstallationReady:
            title=@"Ready to play";
            detail=@"Your game is up to date.";
            action=_executionMode==TKExecutionModeNone?@"Startup unavailable":@"Play"; enabled=_executionMode!=TKExecutionModeNone; break;
        }
    }
    _stateLabel.text=title; _detailLabel.text=detail;
    [self configureButton:_primaryButton title:action filled:YES]; _primaryButton.enabled=enabled;
    _refreshItem.enabled=!_busy && !_sessionUsed && !_starting;
    if (_busy) [_activity startAnimating]; else [_activity stopAnimating];
    if (_checkedAt) {
        NSString *time=[NSDateFormatter localizedStringFromDate:_checkedAt dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];
        NSString *available=_plan[@"version"][@"VersionsName"];
        _versionLabel.text=[_installation.installedVersion isEqual:available]?
            [NSString stringWithFormat:@"Version %@ · Checked %@",available,time]:
            [NSString stringWithFormat:@"Installed %@ · Available %@",_installation.installedVersion?:@"—",available];
    } else _versionLabel.text=nil;
    _versionLabel.hidden=!_versionLabel.text.length;
    switch (_executionMode) {
    case TKExecutionModeDeveloperService:
        _startupLabel.text=@"Starting can take a few minutes each time."; break;
    case TKExecutionModeLocalSigning:
        _startupLabel.text=@"Startup requires a signed container matching this version."; break;
    case TKExecutionModeExternalJIT:
        _startupLabel.text=@"Enable JIT before starting a new session."; break;
    case TKExecutionModeNone:
        _startupLabel.text=@"This build cannot start the game. See Diagnostics and logs."; break;
    }
}
// The launcher's own pages open over it rather than being pushed away to. The
// columns behind stay where they are, closing one puts the user back on the page
// they left instead of animating them through a stack, and nothing about the home
// page has to be rebuilt for having visited a setting - which is also why the
// game files are not re-read when one closes. See -viewDidAppear:.
- (void)presentPage:(UIViewController *)page {
    UINavigationController *frame=[[UINavigationController alloc] initWithRootViewController:page];
    frame.modalPresentationStyle=UIModalPresentationPageSheet;
    frame.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    frame.navigationBar.tintColor=WKGold();
    WKLog("ui", @"opening %@ over the home page", NSStringFromClass(page.class));
    [self presentViewController:frame animated:YES completion:nil];
}
- (void)presentSheet:(UIAlertController *)sheet anchor:(UIView *)anchor {
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    if (anchor) { sheet.popoverPresentationController.sourceView=anchor; sheet.popoverPresentationController.sourceRect=anchor.bounds; }
    else sheet.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)chooseEdition {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"Choose your edition" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *product in TKWoWProducts()) [sheet addAction:[UIAlertAction actionWithTitle:product[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; [self selectProduct:product];
    }]];
    [self presentSheet:sheet anchor:_editionButton];
}
- (void)choosePreference:(BOOL)region {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:region?@"Region":@"Download language" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *values=region?@[@"eu",@"us",@"kr",@"tw"]:@[@"enUS",@"esES"];
    NSDictionary *names=@{@"eu":@"Europe",@"us":@"Americas",@"kr":@"Korea",@"tw":@"Taiwan",@"enUS":@"English",@"esES":@"Spanish"};
    for (NSString *value in values) [sheet addAction:[UIAlertAction actionWithTitle:names[value] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; if (region) self->_region=value; else self->_locale=value;
        [NSUserDefaults.standardUserDefaults setObject:value forKey:region?@"WoWRegion":@"WoWLocale"]; [self refresh];
    }]];
    [self presentSheet:sheet anchor:_preferencesButton];
}
- (void)preferences {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"Download preferences"
        message:@"These settings do not change your game's login region." preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Region" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { (void)a; [self choosePreference:YES]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Language" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { (void)a; [self choosePreference:NO]; }]];
    [self presentSheet:sheet anchor:_preferencesButton];
}
- (void)settings {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"Settings"
        message:@"Updates install automatically while this app is open. Settings and addons are preserved. Startup preparation is separate from downloading updates." preferredStyle:UIAlertControllerStyleActionSheet];
    if(!_busy && !_starting && !_sessionUsed && _installation.app) {
        [sheet addAction:[UIAlertAction actionWithTitle:@"Manage add-ons" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a; [self manageAddons];
        }]];
        [sheet addAction:[UIAlertAction actionWithTitle:@"Verify and repair game files" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            (void)a; [self repairInstallation];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Diagnostics and logs" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a; [self diagnostics];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"About and open-source licenses" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a; [self about];
    }]];
    if (_startupFailure || _error || _installation.error) [sheet addAction:[UIAlertAction actionWithTitle:@"Technical details" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        UIAlertController *details=[UIAlertController alertControllerWithTitle:@"Details" message:self->_startupFailure?:(self->_error?:self->_installation.error).localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [details addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:details animated:YES completion:nil];
    }]];
    [self presentSheet:sheet anchor:nil];
}
// Everything about dictation lives on its own screen: the button, the mode, and
// what happens to the words afterwards.
- (void)manageVoice {
    [self presentPage:[AKVoiceViewController new]];
}

// The same settings, exercised: a box the transcript lands in, driven by the
// button the user mapped, so it can be tried without starting the game.
- (void)testVoice {
    [self presentPage:[AKVoiceTestViewController new]];
}

// This app's own page in Settings: the Microphone and Speech Recognition switches for WolkaraForever.
//
// iOS gives an app no way to grant, reset or re-prompt for its own privacy permission - the decision
// belongs to the person using the device. This project has been bitten by exactly that: tccd answers
// "allowed" and then fails to issue the microphone sandbox extension to the installed binary, so audio
// never arrives while the permission reads granted. The one supported remedy is the person changing it
// in Settings, so the launcher takes them to that exact page instead of describing where it is.
- (void)openPermissions {
    NSURL *url=[NSURL URLWithString:UIApplicationOpenSettingsURLString];
    UIApplication *app=UIApplication.sharedApplication;
    if(!url || ![app canOpenURL:url]) {
        WKLog("host", @"permissions: this system will not open the app's settings page");
        return;
    }
    [app openURL:url options:@{} completionHandler:^(BOOL opened) {
        WKLog("host", @"permissions: opened this app's settings page: %@", opened?@"yes":@"no");
    }];
}

// The game's add-on folder, in the file browser. The picker is the documented way
// to start Files at a directory; an alert with a path would be a worse answer to
// the same request, because the user came here to put files in it.
- (void)openAddonDirectory {
    NSError *error=nil;
    NSString *addons=[self addOnsDirectoryWithError:&error];
    if (!addons) { [self presentAddonsUnavailable:error]; return; }
    // The game makes this folder on its first run. Until then there is nothing to
    // open, so make it rather than refuse.
    NSFileManager *files=NSFileManager.defaultManager;
    if (![files fileExistsAtPath:addons]) {
        [files createDirectoryAtPath:addons withIntermediateDirectories:YES attributes:nil error:&error];
        if (![files fileExistsAtPath:addons]) { [self presentAddonsUnavailable:error]; return; }
    }
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeFolder]];
    picker.directoryURL=[NSURL fileURLWithPath:addons isDirectory:YES];
    picker.allowsMultipleSelection=NO;
    picker.delegate=self;
    [self presentViewController:picker animated:YES completion:nil];
}
// Nothing to take from the picker: the folder was opened so the user can put files
// in it with the browser's own controls, and the game reads the list from disk.
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller; (void)urls;
}
#pragma mark - Forever UI file operations

// The working directory of the inspected Forever installation, or nil when the
// selected edition is not Forever or is not ready. These rows are about Forever
// only: another edition's files are never read or written by them.
- (nullable NSString *)foreverWorkingDirectory {
    if (![_product[@"id"] isEqualToString:TKForeverUIEdition]) return nil;
    if (_installation.state!=TKWoWInstallationReady || !_installation.app) return nil;
    return [_library workingDirectoryForApp:_installation.app error:NULL];
}
- (BOOL)foreverActionAllowed {
    return [self foreverWorkingDirectory]!=nil && !_busy && !_starting && !_sessionUsed && !_uiOperation;
}
- (void)presentMessage:(NSString *)title message:(nullable NSString *)message {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
// A snapshot of the complete Forever UI. It is an explicit user action here, and
// it is also the rollback point the two destructive rows make for themselves.
- (void)backupUI {
    if (![self foreverActionAllowed]) return;
    NSString *directory=[self foreverWorkingDirectory];
    if (!directory) return;
    WKLog("ui", @"backup: starting");
    _uiOperation=YES; [self render];
    __weak TKWoWViewController *weakSelf=self;
    dispatch_async(TKForeverUIQueue(), ^{
        NSError *error=nil;
        NSString *name=[TKForeverUI createUIBackupInWorkingDirectory:directory edition:TKForeverUIEdition error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            TKWoWViewController *self=weakSelf; if(!self) return;
            self->_uiOperation=NO; [self render];
            if (name) {
                WKLog("ui", @"backup: wrote a snapshot");
                [self presentMessage:@"Backup complete" message:[NSString stringWithFormat:@"Saved %@ in the game's WTF/Backups folder.",name]];
            } else {
                WKLog("ui", @"backup: failed: %@", error.localizedDescription?:@"unknown reason");
                [self presentMessage:@"Backup failed" message:error.localizedDescription?:@"The backup could not be created."];
            }
        });
    });
}
// Destructive, so it is confirmed first. Forever regenerates its graphics
// defaults on the next launch; everything else in the UI is backable and kept.
- (void)resetGraphics {
    if (![self foreverActionAllowed]) return;
    NSString *directory=[self foreverWorkingDirectory];
    if (!directory) return;
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"Reset to default graphics settings?"
        message:@"Forever will regenerate its graphics defaults when it next starts. A complete backup of WTF and Interface is made first, and Restore WoW UI Configuration can bring everything back."
        preferredStyle:UIAlertControllerStyleAlert];
    __weak TKWoWViewController *weakSelf=self;
    [sheet addAction:[UIAlertAction actionWithTitle:@"Reset graphics" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action; [weakSelf performGraphicsReset:directory];
    }]];
    [self presentSheet:sheet anchor:_resetButton];
}
- (void)performGraphicsReset:(NSString *)directory {
    if (_busy || _starting || _sessionUsed || _uiOperation) return;
    _uiOperation=YES; [self render];
    __weak TKWoWViewController *weakSelf=self;
    dispatch_async(TKForeverUIQueue(), ^{
        NSError *error=nil;
        // No backup, no reset: the destructive half never runs alone.
        NSString *backup=[TKForeverUI createUIBackupInWorkingDirectory:directory edition:TKForeverUIEdition error:&error];
        BOOL reset=backup?[TKForeverUI resetGraphicsInWorkingDirectory:directory error:&error]:NO;
        dispatch_async(dispatch_get_main_queue(), ^{
            TKWoWViewController *self=weakSelf; if(!self) return;
            self->_uiOperation=NO; [self render];
            if (!backup) {
                WKLog("ui", @"reset: aborted, no backup: %@", error.localizedDescription?:@"unknown reason");
                [self presentMessage:@"Nothing was changed" message:[NSString stringWithFormat:@"The backup could not be created, so the graphics settings were left alone. %@",error.localizedDescription?:@""]];
            } else if (!reset) {
                WKLog("ui", @"reset: backup kept, settings not reset: %@", error.localizedDescription?:@"unknown reason");
                [self presentMessage:@"Reset incomplete" message:[NSString stringWithFormat:@"The backup is %@, but the graphics settings could not be reset. %@",backup,error.localizedDescription?:@""]];
            } else {
                WKLog("ui", @"reset: graphics removed, backup kept");
                [self presentMessage:@"Graphics reset" message:[NSString stringWithFormat:@"Default graphics settings take effect when Forever next launches. Backup: %@.",backup]];
            }
        });
    });
}
// One click, newest valid snapshot. A fresh snapshot of the current state is
// made first, so a restore can itself be undone.
- (void)restoreUI {
    if (![self foreverActionAllowed]) return;
    NSString *directory=[self foreverWorkingDirectory];
    if (!directory) return;
    _uiOperation=YES; [self render];
    __weak TKWoWViewController *weakSelf=self;
    dispatch_async(TKForeverUIQueue(), ^{
        NSError *error=nil;
        NSString *newest=[TKForeverUI newestUIBackupInWorkingDirectory:directory error:&error];
        NSString *fresh=nil;
        BOOL restored=NO;
        if (newest) {
            fresh=[TKForeverUI createUIBackupInWorkingDirectory:directory edition:TKForeverUIEdition error:&error];
            if (!fresh) {
                error=[NSError errorWithDomain:TKForeverUIErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"A safety backup could not be created, so nothing was restored. %@",error.localizedDescription?:@""]}];
            } else {
                restored=[TKForeverUI restoreUIBackupNamed:newest inWorkingDirectory:directory edition:TKForeverUIEdition error:&error];
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            TKWoWViewController *self=weakSelf; if(!self) return;
            self->_uiOperation=NO; [self render];
            if (restored) {
                WKLog("ui", @"restore: completed from the newest snapshot");
                [self presentMessage:@"Restore complete" message:[NSString stringWithFormat:@"Restored %@. Your complete Forever UI - settings, bindings, SavedVariables, gamepad configuration and add-ons - applies the next time it starts. A snapshot of the previous state was saved as %@.",newest,fresh]];
            } else {
                WKLog("ui", @"restore: not completed: %@", error.localizedDescription?:@"unknown reason");
                [self presentMessage:newest?@"Restore failed":@"No backup to restore" message:error.localizedDescription?:@"Run Backup WoW UI Configuration first."];
            }
        });
    });
}
// Exactly one `SET GamePadEnable "1"` in the active Config.wtf. It changes no
// bindings and touches neither GamePadConfig_*.json nor gamecontrollerdb.txt.
- (void)enableGamepad {
    if (![self foreverActionAllowed]) return;
    NSString *directory=[self foreverWorkingDirectory];
    if (!directory) return;
    _uiOperation=YES; [self render];
    __weak TKWoWViewController *weakSelf=self;
    dispatch_async(TKForeverUIQueue(), ^{
        NSError *error=nil;
        BOOL enabled=[TKForeverUI enableGamepadInWorkingDirectory:directory error:&error];
        dispatch_async(dispatch_get_main_queue(), ^{
            TKWoWViewController *self=weakSelf; if(!self) return;
            self->_uiOperation=NO; [self render];
            if (enabled) [self presentMessage:@"Gamepad UI enabled" message:@"It takes effect when Forever next starts."];
            else [self presentMessage:@"Gamepad UI not changed" message:error.localizedDescription?:@"The setting could not be stored."];
        });
    });
}
// The HUD preference lives in the touch layout store. Read-modify-write keeps
// every existing value (opacity, scales, haptics, positions) and the change
// notification is what the in-game settings page and the host view listen to.
- (void)togglePerformanceOverlay {
    if (_busy || _starting) return;
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    id stored=[defaults objectForKey:TKForeverLayoutKey];
    NSMutableDictionary *layout=[stored isKindOfClass:NSDictionary.class]?[stored mutableCopy]:[NSMutableDictionary new];
    BOOL enabled=![layout[@"performanceOverlayEnabled"] boolValue];
    layout[@"performanceOverlayEnabled"]=@(enabled);
    [defaults setObject:layout forKey:TKForeverLayoutKey];
    [NSNotificationCenter.defaultCenter postNotificationName:TKForeverLayoutDidChange object:defaults];
    WKLog("ui", @"performance overlay: %@", enabled?@"enabled":@"disabled");
    [self render];
}
// Navigation only: the Files browser opens at Forever's WTF folder. The folder is
// created only here, only for a ready Forever installation, and nothing else is.
- (void)openSettingsFolder {
    if (![self foreverActionAllowed]) return;
    NSString *directory=[self foreverWorkingDirectory];
    if (!directory) return;
    NSError *error=nil;
    NSString *wtf=[TKForeverUI wtfDirectoryInWorkingDirectory:directory create:YES error:&error];
    if (!wtf) { [self presentMessage:@"Settings folder unavailable" message:error.localizedDescription?:@"The game's settings folder could not be opened."]; return; }
    NSURL *folder=[NSURL fileURLWithPath:wtf isDirectory:YES];
    if (self.openSettingsFolderURL) { self.openSettingsFolderURL(folder); return; }
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc]
        initForOpeningContentTypes:@[UTTypeFolder]];
    picker.directoryURL=folder;
    picker.allowsMultipleSelection=NO;
    picker.delegate=self;
    [self presentViewController:picker animated:YES completion:nil];
}
// Mac-Ever's CurseForge page, in the browser. The user downloads the ZIP there
// and comes back to Install Addons (Curse & Direct); opening the page is not an
// installation and is never reported as one.
- (void)downloadMacEver {
    NSURL *url=[NSURL URLWithString:@"https://www.curseforge.com/wow/addons/mac-ever"];
    if (!url) return;
    if (self.openExternalURL) { self.openExternalURL(url); return; }
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL opened) {
        WKLog("host", @"mac-ever: download page opened: %@", opened?@"yes":@"no");
    }];
}
- (void)presentAddonsUnavailable:(nullable NSError *)error {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Add-ons unavailable"
        message:error.localizedDescription?:@"The game's folder could not be opened."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (nullable NSString *)addOnsDirectoryWithError:(NSError **)error {
    NSString *directory=[_library workingDirectoryForApp:_installation.app error:error];
    return directory?[directory stringByAppendingPathComponent:@"Interface/AddOns"]:nil;
}

- (void)manageAddons {
    NSError *error=nil;
    NSString *addons=[self addOnsDirectoryWithError:&error];
    if (!addons) { [self presentAddonsUnavailable:error]; return; }
    TKWoWAddonManagerViewController *manager=[[TKWoWAddonManagerViewController alloc] initWithAddOnsDirectory:addons edition:_product[@"name"]];
    [self presentPage:manager];
}
- (UILabel *)startupStatusLabel { [self loadViewIfNeeded]; return _detailLabel; }
- (void)beginStartup {
    [self loadViewIfNeeded];
    [self cancel]; _starting=YES; _startupFailure=nil;
    _detailLabel.text=@"Preparing to launch. Keep this app open.";
    _diagnosticsButton.hidden=YES;
    [self render]; [_launchProgress start];
    [self.view layoutIfNeeded];
}
- (void)finishStartupWithMessage:(NSString *)message failed:(BOOL)failed {
    _starting=NO; _startupFailure=failed?message:nil;
    [_launchProgress stop]; _diagnosticsButton.hidden=!failed;
    [self render];
}
- (void)diagnostics { if (self.showDiagnostics) self.showDiagnostics(); }
- (void)about {
    UIViewController *controller=[UIViewController new]; controller.title=@"About";
    controller.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    UITextView *text=[UITextView new]; text.editable=NO;
    text.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody]; text.adjustsFontForContentSizeCategory=YES;
    text.textContainerInset=UIEdgeInsetsMake(20,20,20,20);
    NSMutableString *credits=[@"WolkaraForever — an independent World of Warcraft launcher built on Tolkara. Not affiliated with or endorsed by Blizzard Entertainment. World of Warcraft belongs to Blizzard Entertainment.\n\n" mutableCopy];
    // Four documents, and which is which matters. This app is a fork that ships upstream's
    // code, so it carries its own licence and notice and it keeps theirs; they are told
    // apart by name, which is why ours are prefixed in the bundle. The first version
    // listed two names and quietly showed whatever it found, which was upstream's
    // documents under our attribution - and when nothing matched it showed nothing at
    // all, silently. The list itself lives beside the log line that reports it, so the two
    // cannot disagree, and a missing document says so on the page.
    for (NSArray<NSString *> *document in WKBundledDocuments()) {
        NSString *name=document[1];
        NSString *path=[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:name];
        NSString *notice=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        if (notice) [credits appendFormat:@"\n\n———— %@ ————\n%@\n",document[0],notice];
        else [credits appendFormat:@"\n\n———— %@ ————\n%@ is missing from this build.\n",document[0],name];
    }
    text.text=credits; controller.view=text;
    [self.navigationController pushViewController:controller animated:YES];
}
@end
