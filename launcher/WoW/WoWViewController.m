#import "WoWViewController.h"
#import "Client.h"
#import "Installation.h"

static NSString *L(NSString *english, NSString *spanish) {
    return [NSLocale.preferredLanguages.firstObject hasPrefix:@"es"] ? spanish : english;
}
static UIColor *Gold(void) { return [UIColor colorWithRed:0.88 green:0.73 blue:0.43 alpha:1]; }
static UIColor *Muted(void) { return [UIColor colorWithRed:0.66 green:0.72 blue:0.78 alpha:1]; }
static UILabel *Label(CGFloat size, UIFontWeight weight, UIColor *color) {
    UILabel *label=[UILabel new]; label.numberOfLines=0; label.textColor=color;
    label.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleBody] scaledFontForFont:[UIFont systemFontOfSize:size weight:weight]];
    label.adjustsFontForContentSizeCategory=YES; return label;
}
static UIStackView *Stack(NSArray<UIView *> *views, CGFloat spacing) {
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:views];
    stack.axis=UILayoutConstraintAxisVertical; stack.spacing=spacing; return stack;
}

@implementation TKWoWViewController {
    TKAppLibrary *_library;
    TKWoWClient *_client;
    NSDictionary *_product, *_plan;
    TKWoWInstallation *_installation;
    NSString *_region, *_locale;
    NSError *_error;
    NSDate *_checkedAt;
    NSUInteger _generation;
    BOOL _busy;
    CAGradientLayer *_background;
    UIStackView *_columns;
    NSLayoutConstraint *_leftWidth;
    UILabel *_stateLabel, *_detailLabel, *_versionLabel, *_startupLabel, *_compatibilityLabel;
    UIButton *_editionButton, *_preferencesButton, *_primaryButton;
    UIBarButtonItem *_refreshItem;
    UIActivityIndicatorView *_activity;
}
- (instancetype)initWithLibrary:(TKAppLibrary *)library {
    if (!(self=[super initWithNibName:nil bundle:nil])) return nil;
    _library=library; self.title=@"World of Warcraft";
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
    self.navigationItem.rightBarButtonItem.accessibilityLabel=L(@"Settings",@"Ajustes");
    self.navigationItem.rightBarButtonItem.accessibilityIdentifier=@"wow.settings";
    self.navigationItem.backButtonTitle=@"WoW";
    _refreshItem=[[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]
        style:UIBarButtonItemStylePlain target:self action:@selector(refresh)];
    _refreshItem.accessibilityLabel=L(@"Check for updates",@"Buscar actualizaciones");
    _refreshItem.accessibilityIdentifier=@"wow.refresh";
    self.navigationItem.leftBarButtonItem=_refreshItem;

    UILabel *eyebrow=Label(11,UIFontWeightBold,Gold()); eyebrow.text=L(@"TOLKARA  /  PREVIEW",@"TOLKARA  /  EN DESARROLLO");
    UILabel *title=Label(37,UIFontWeightBold,Gold()); title.text=@"WORLD OF\nWARCRAFT";
    UIFontDescriptor *serif=[[UIFont systemFontOfSize:37 weight:UIFontWeightBold].fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignSerif];
    if (serif) title.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleLargeTitle] scaledFontForFont:[UIFont fontWithDescriptor:serif size:37]];
    UILabel *tagline=Label(16,UIFontWeightRegular,Muted()); tagline.text=L(@"Choose your next adventure.",@"Elige tu próxima aventura.");
    _editionButton=[self button:@"wow.edition" action:@selector(chooseEdition)];
    _preferencesButton=[self button:@"wow.preferences" action:@selector(preferences)];
    _compatibilityLabel=Label(12,UIFontWeightRegular,Muted());
    UIStackView *left=Stack(@[eyebrow,title,tagline,_editionButton,_preferencesButton,_compatibilityLabel],12);
    [left setCustomSpacing:20 afterView:tagline];

    _activity=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _activity.color=Gold(); _activity.hidesWhenStopped=YES;
    _stateLabel=Label(23,UIFontWeightSemibold,UIColor.whiteColor); _stateLabel.accessibilityIdentifier=@"wow.status";
    UIStackView *stateRow=[[UIStackView alloc] initWithArrangedSubviews:@[_activity,_stateLabel]];
    stateRow.axis=UILayoutConstraintAxisHorizontal; stateRow.spacing=10;
    [_activity setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _detailLabel=Label(15,UIFontWeightRegular,Muted()); _detailLabel.accessibilityIdentifier=@"wow.detail";
    _versionLabel=Label(12,UIFontWeightRegular,Muted()); _versionLabel.accessibilityIdentifier=@"wow.version";
    UIStackView *status=Stack(@[stateRow,_detailLabel,_versionLabel],10);
    status.layoutMargins=UIEdgeInsetsMake(20,20,20,20); status.layoutMarginsRelativeArrangement=YES;
    status.backgroundColor=[UIColor colorWithRed:0.07 green:0.105 blue:0.15 alpha:1];
    status.layer.cornerRadius=16; status.layer.borderWidth=1;
    status.layer.borderColor=[Gold() colorWithAlphaComponent:0.24].CGColor;
    _primaryButton=[self button:@"wow.primary" action:@selector(primaryAction)];
    [_primaryButton.heightAnchor constraintGreaterThanOrEqualToConstant:52].active=YES;
    UILabel *updates=Label(12,UIFontWeightRegular,Muted()); updates.accessibilityIdentifier=@"wow.updates";
    updates.text=L(@"Updates are checked on opening. Installation is still manual.",
        @"Busca actualizaciones al abrir. Por ahora se instalan manualmente.");
    _startupLabel=Label(12,UIFontWeightRegular,Muted()); _startupLabel.accessibilityIdentifier=@"wow.startup";
    UIStackView *right=Stack(@[status,_primaryButton,updates,_startupLabel],12);
    _columns=Stack(@[left,right],32); _columns.accessibilityIdentifier=@"wow.columns";
    _columns.alignment=UIStackViewAlignmentTop;
    _leftWidth=[left.widthAnchor constraintEqualToAnchor:_columns.widthAnchor multiplier:0.38];

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
    self.navigationController.navigationBar.prefersLargeTitles=NO;
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.navigationController.navigationBar.tintColor=Gold();
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _background.frame=self.view.bounds;
    BOOL horizontal=self.view.bounds.size.width>=700 && !UIContentSizeCategoryIsAccessibilityCategory(self.traitCollection.preferredContentSizeCategory);
    _leftWidth.active=horizontal;
    _columns.axis=horizontal?UILayoutConstraintAxisHorizontal:UILayoutConstraintAxisVertical;
    _columns.alignment=horizontal?UIStackViewAlignmentTop:UIStackViewAlignmentFill;
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; if (!_busy && !_sessionUsed) [self refresh]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self cancel]; }
- (void)foreground:(NSNotification *)note {
    (void)note;
    if (self.isViewLoaded && self.view.window && self.navigationController.topViewController==self && !_busy && !_sessionUsed) [self refresh];
}
- (void)background:(NSNotification *)note { (void)note; [self cancel]; }
- (void)cancel { [_client cancel]; _client=nil; _generation++; _busy=NO; }
- (void)setExecutionMode:(TKExecutionMode)mode { _executionMode=mode; if (self.isViewLoaded) [self render]; }
- (void)setSessionUsed:(BOOL)used { _sessionUsed=used; if (used) [self cancel]; if (self.isViewLoaded) [self render]; }
- (void)selectProduct:(NSDictionary *)product {
    if (![TKWoWProducts() containsObject:product]) return;
    _product=product;
    [NSUserDefaults.standardUserDefaults setObject:product[@"id"] forKey:@"WoWProduct"];
    [self refresh];
}
- (void)refresh { [self checkForUpdatesAndLaunch:NO]; }
- (void)checkForUpdatesAndLaunch:(BOOL)launch {
    [self cancel]; _plan=nil; _installation=nil; _error=nil; _checkedAt=nil;
    _client=[TKWoWClient new]; _busy=YES; [self render];
    TKWoWClient *client=_client; NSUInteger generation=_generation;
    NSDictionary *product=_product; NSString *region=_region, *locale=_locale;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        [self->_library discover];
        NSError *error=nil;
        NSDictionary *plan=[client planForProduct:product[@"id"] region:region locale:locale error:&error];
        TKWoWInstallation *installation=plan?TKWoWInspectInstallation(self->_library,product,plan):nil;
        dispatch_async(dispatch_get_main_queue(),^{
            if (generation!=self->_generation) return;
            self->_plan=plan; self->_installation=installation; self->_error=error;
            self->_checkedAt=plan?NSDate.date:nil; self->_busy=NO; [self render];
            // Returning from the background or changing edition invalidates this request.
            if (launch && installation.state==TKWoWInstallationReady && installation.app && !self->_sessionUsed &&
                self.view.window && self.navigationController.topViewController==self && self.startApp) self.startApp(installation.app);
        });
    });
}
- (void)primaryAction {
    if (_busy || _sessionUsed) return;
    if (_error || !_plan) { [self refresh]; return; }
    if (_installation.state!=TKWoWInstallationReady) return;
    if (_executionMode==TKExecutionModeNone) { if (self.showStartupOptions) self.showStartupOptions(); return; }
    [self checkForUpdatesAndLaunch:YES];
}
- (void)configureButton:(UIButton *)button title:(NSString *)title filled:(BOOL)filled {
    UIButtonConfiguration *configuration=filled?UIButtonConfiguration.filledButtonConfiguration:UIButtonConfiguration.plainButtonConfiguration;
    configuration.title=title; configuration.cornerStyle=UIButtonConfigurationCornerStyleMedium;
    configuration.baseBackgroundColor=Gold(); configuration.baseForegroundColor=filled?[UIColor colorWithRed:0.08 green:0.065 blue:0.035 alpha:1]:Gold();
    configuration.contentInsets=NSDirectionalEdgeInsetsMake(filled?14:6,12,filled?14:6,12);
    button.configuration=configuration;
}
- (void)render {
    if (!self.isViewLoaded) return;
    [self configureButton:_editionButton title:[_product[@"name"] stringByAppendingString:@"  ▾"] filled:NO];
    _editionButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
    _editionButton.backgroundColor=[UIColor colorWithWhite:1 alpha:0.055]; _editionButton.layer.cornerRadius=10;
    [self configureButton:_preferencesButton title:[NSString stringWithFormat:@"%@  ·  %@  ▾",_region.uppercaseString,[_locale isEqual:@"esES"]?@"Español":@"English"] filled:NO];
    _preferencesButton.contentHorizontalAlignment=UIControlContentHorizontalAlignmentLeading;
    _compatibilityLabel.text=([_product[@"id"] isEqual:@"wow"] || [_product[@"id"] isEqual:@"wow_beta"] || [_product[@"id"] isEqual:@"wow_classic"])?
        L(@"Compatibility with this edition is not yet verified.",@"La compatibilidad con esta edición aún no está verificada."):
        L(@"Experimental support on iPhone and iPad.",@"Soporte experimental en iPhone y iPad.");
    NSString *title=nil, *detail=nil, *action=nil;
    BOOL enabled=NO;
    if (_sessionUsed) {
        title=L(@"Reopen to start again",@"Vuelve a abrir la app");
        detail=L(@"Close the app from the app switcher before starting another session.",@"Ciérrala desde el selector de apps antes de iniciar otra sesión.");
        action=L(@"Session ended",@"Sesión finalizada");
    } else if (_busy) {
        title=L(@"Checking your adventure…",@"Comprobando tu aventura…");
        detail=L(@"Checking the latest version and your installed copy.",@"Buscando actualizaciones y comprobando tu copia instalada.");
        action=L(@"Checking…",@"Comprobando…");
    } else if (_error || !_plan) {
        title=L(@"Could not check this edition",@"No se ha podido comprobar");
        detail=L(@"We cannot confirm that your game is up to date. Check your connection and try again.",@"No podemos confirmar que el juego esté al día. Comprueba la conexión y vuelve a intentarlo.");
        action=L(@"Try again",@"Reintentar"); enabled=YES;
    } else {
        switch (_installation.state) {
        case TKWoWInstallationMissing:
            title=L(@"Not installed",@"Sin instalar");
            detail=L(@"This edition is not on your device. Full game downloads are still in development.",@"Esta edición no está en tu dispositivo. La descarga del juego completo aún está en desarrollo.");
            action=L(@"Installation coming later",@"Instalación aún no disponible"); break;
        case TKWoWInstallationOutdated:
            title=L(@"Update required",@"Actualización pendiente");
            detail=L(@"A newer build is available. Update your copy from the Mac for now; automatic installation is not ready yet.",@"Hay una nueva versión. Por ahora, actualiza la copia desde el Mac; la instalación automática aún no está lista.");
            action=L(@"Update needed to play",@"Actualiza para jugar"); break;
        case TKWoWInstallationNeedsRepair:
            title=L(@"Your copy needs attention",@"Revisa tu instalación");
            detail=L(@"We found the game but could not verify its files. Use the advanced library to check or replace your copy.",@"Encontramos el juego, pero no pudimos verificar sus archivos. Revisa o sustituye la copia desde la biblioteca avanzada.");
            action=L(@"Installation not verified",@"Instalación sin verificar"); break;
        case TKWoWInstallationReady:
            title=L(@"Ready for your next adventure",@"Tu próxima aventura te espera");
            detail=L(@"Your game is up to date.",@"Tu juego está al día.");
            action=_executionMode==TKExecutionModeNone?L(@"Set up startup",@"Configurar inicio"):L(@"Play",@"Jugar"); enabled=YES; break;
        }
    }
    _stateLabel.text=title; _detailLabel.text=detail;
    [self configureButton:_primaryButton title:action filled:YES]; _primaryButton.enabled=enabled;
    _refreshItem.enabled=!_busy && !_sessionUsed;
    if (_busy) [_activity startAnimating]; else [_activity stopAnimating];
    if (_checkedAt) {
        NSString *time=[NSDateFormatter localizedStringFromDate:_checkedAt dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];
        _versionLabel.text=[NSString stringWithFormat:L(@"Installed: %@\nAvailable: %@ · Checked %@",@"Instalada: %@\nDisponible: %@ · Comprobado %@"),
            _installation.installedVersion?:L(@"—",@"—"),_plan[@"version"][@"VersionsName"],time];
    } else _versionLabel.text=nil;
    _versionLabel.hidden=!_versionLabel.text.length;
    switch (_executionMode) {
    case TKExecutionModeDeveloperService:
        _startupLabel.text=L(@"Startup preparation still takes several minutes on each opening.",@"Preparar el arranque aún tarda varios minutos en cada apertura."); break;
    case TKExecutionModeLocalSigning:
        _startupLabel.text=L(@"Startup: Local signing selected. A matching signed container must already be prepared.",@"Arranque: firma local seleccionada. Necesita un contenedor firmado y preparado previamente."); break;
    case TKExecutionModeExternalJIT:
        _startupLabel.text=L(@"Startup: external authorization is required for each new app process. Installing with AltStore does not enable it automatically.",@"Arranque: cada nueva sesión necesita autorización externa. Instalar desde AltStore no la activa automáticamente."); break;
    case TKExecutionModeNone:
        _startupLabel.text=L(@"Startup setup is still required in this preview. Open Settings → Startup options.",@"Esta versión aún necesita configurar el arranque. Abre Ajustes → Opciones de inicio."); break;
    }
}
- (void)presentSheet:(UIAlertController *)sheet anchor:(UIView *)anchor {
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"Cancel",@"Cancelar") style:UIAlertActionStyleCancel handler:nil]];
    if (anchor) { sheet.popoverPresentationController.sourceView=anchor; sheet.popoverPresentationController.sourceRect=anchor.bounds; }
    else sheet.popoverPresentationController.barButtonItem=self.navigationItem.rightBarButtonItem;
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)chooseEdition {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:L(@"Choose your edition",@"Elige tu edición") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSDictionary *product in TKWoWProducts()) [sheet addAction:[UIAlertAction actionWithTitle:product[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; [self selectProduct:product];
    }]];
    [self presentSheet:sheet anchor:_editionButton];
}
- (void)choosePreference:(BOOL)region {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:region?L(@"Region",@"Región"):L(@"Download language",@"Idioma de descarga") message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray *values=region?@[@"eu",@"us",@"kr",@"tw"]:@[@"enUS",@"esES"];
    NSDictionary *names=@{@"eu":L(@"Europe",@"Europa"),@"us":L(@"Americas",@"América"),@"kr":L(@"Korea",@"Corea"),@"tw":L(@"Taiwan",@"Taiwán"),@"enUS":@"English",@"esES":@"Español"};
    for (NSString *value in values) [sheet addAction:[UIAlertAction actionWithTitle:names[value] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action; if (region) self->_region=value; else self->_locale=value;
        [NSUserDefaults.standardUserDefaults setObject:value forKey:region?@"WoWRegion":@"WoWLocale"]; [self refresh];
    }]];
    [self presentSheet:sheet anchor:_preferencesButton];
}
- (void)preferences {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:L(@"Download preferences",@"Preferencias de descarga")
        message:L(@"These settings do not change your game's login region.",@"Estos ajustes no cambian la región de inicio de sesión del juego.") preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"Region",@"Región") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { (void)a; [self choosePreference:YES]; }]];
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"Language",@"Idioma") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { (void)a; [self choosePreference:NO]; }]];
    [self presentSheet:sheet anchor:_preferencesButton];
}
- (void)settings {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:L(@"Settings",@"Ajustes")
        message:L(@"This preview checks updates but does not install them yet. Automatic startup without preparation is also still under investigation.",
            @"Este prototipo comprueba actualizaciones, pero todavía no las instala. El inicio automático sin preparación también sigue en investigación.") preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"Startup options",@"Opciones de inicio") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a; if (self.showStartupOptions) self.showStartupOptions();
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:L(@"Advanced library and diagnostics",@"Biblioteca avanzada y diagnóstico") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a; if (self.showTools) self.showTools();
    }]];
    if (_error || _installation.error) [sheet addAction:[UIAlertAction actionWithTitle:L(@"Technical details",@"Detalles técnicos") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        UIAlertController *details=[UIAlertController alertControllerWithTitle:L(@"Details",@"Detalles") message:(self->_error?:self->_installation.error).localizedDescription preferredStyle:UIAlertControllerStyleAlert];
        [details addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:details animated:YES completion:nil];
    }]];
    [self presentSheet:sheet anchor:nil];
}
@end
