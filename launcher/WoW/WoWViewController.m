#import "WoWViewController.h"
#import "Client.h"
#import "Installation.h"
#import "Updater.h"

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
    BOOL _busy, _updating, _updateError;
    NSString *_updatePhase;
    uint64_t _updateDone, _updateTotal;
    UIProgressView *_progressBar;
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

    UILabel *title=Label(37,UIFontWeightBold,Gold()); title.text=@"WORLD OF\nWARCRAFT";
    UIFontDescriptor *serif=[[UIFont systemFontOfSize:37 weight:UIFontWeightBold].fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignSerif];
    if (serif) title.font=[[UIFontMetrics metricsForTextStyle:UIFontTextStyleLargeTitle] scaledFontForFont:[UIFont fontWithDescriptor:serif size:37]];
    UILabel *tagline=Label(16,UIFontWeightRegular,Muted()); tagline.text=L(@"Choose your next adventure.",@"Elige tu próxima aventura.");
    _editionButton=[self button:@"wow.edition" action:@selector(chooseEdition)];
    _preferencesButton=[self button:@"wow.preferences" action:@selector(preferences)];
    _compatibilityLabel=Label(12,UIFontWeightRegular,Muted());
    UIStackView *left=Stack(@[title,tagline,_editionButton,_preferencesButton,_compatibilityLabel],12);
    [left setCustomSpacing:20 afterView:tagline];

    _activity=[[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    _activity.color=Gold(); _activity.hidesWhenStopped=YES;
    _stateLabel=Label(23,UIFontWeightSemibold,UIColor.whiteColor); _stateLabel.accessibilityIdentifier=@"wow.status";
    UIStackView *stateRow=[[UIStackView alloc] initWithArrangedSubviews:@[_activity,_stateLabel]];
    stateRow.axis=UILayoutConstraintAxisHorizontal; stateRow.spacing=10;
    [_activity setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _detailLabel=Label(15,UIFontWeightRegular,Muted()); _detailLabel.accessibilityIdentifier=@"wow.detail";
    _versionLabel=Label(12,UIFontWeightRegular,Muted()); _versionLabel.accessibilityIdentifier=@"wow.version";
    _progressBar=[[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    _progressBar.progressTintColor=Gold(); _progressBar.accessibilityIdentifier=@"wow.progress";
    UIStackView *status=Stack(@[stateRow,_detailLabel,_progressBar,_versionLabel],10);
    status.layoutMargins=UIEdgeInsetsMake(20,20,20,20); status.layoutMarginsRelativeArrangement=YES;
    status.backgroundColor=[UIColor colorWithRed:0.07 green:0.105 blue:0.15 alpha:1];
    status.layer.cornerRadius=16; status.layer.borderWidth=1;
    status.layer.borderColor=[Gold() colorWithAlphaComponent:0.24].CGColor;
    _primaryButton=[self button:@"wow.primary" action:@selector(primaryAction)];
    [_primaryButton.heightAnchor constraintGreaterThanOrEqualToConstant:52].active=YES;
    UILabel *updates=Label(12,UIFontWeightRegular,Muted()); updates.accessibilityIdentifier=@"wow.updates";
    updates.text=L(@"Updates install automatically on opening. Keep the app open; interrupted downloads resume next time.",
        @"Instala las actualizaciones al abrir. Mantén la app abierta; si sales, la descarga se reanuda al volver.");
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
- (void)checkForUpdatesAndLaunch:(BOOL)launch { [self checkForUpdatesAndLaunch:launch install:NO]; }
- (void)checkForUpdatesAndLaunch:(BOOL)launch install:(BOOL)install {
    NSString *installKey=[@"WoWInstallRequested." stringByAppendingString:_product[@"id"]];
    if(install)[NSUserDefaults.standardUserDefaults setBool:YES forKey:installKey];
    install=install || [NSUserDefaults.standardUserDefaults boolForKey:installKey];
    [self cancel]; _plan=nil; _installation=nil; _error=nil; _checkedAt=nil;
    _updating=NO; _updateError=NO; _updatePhase=nil; _updateDone=0; _updateTotal=0;
    _client=[TKWoWClient new]; _busy=YES; [self render];
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
            void (^progress)(NSString *,uint64_t,uint64_t)=^(NSString *phase,uint64_t done,uint64_t total) {
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
                if(installation.state==TKWoWInstallationReady)[NSUserDefaults.standardUserDefaults removeObjectForKey:installKey];
                else error=error?:installation.error?:TKWoWError(@"The downloaded installation could not be registered in the library.");
            }
        }

        dispatch_async(dispatch_get_main_queue(),^{
            if (generation!=self->_generation) return;
            self->_plan=plan; self->_installation=installation; self->_error=error;
            self->_checkedAt=plan?NSDate.date:nil; self->_busy=NO; self->_updating=NO; self->_updateError=updateAttempted && error; [self render];
            // Returning from the background or changing edition invalidates this request.
            if (launch && !error && !client.cancelled && installation.state==TKWoWInstallationReady && installation.app && !self->_sessionUsed &&
                self.view.window && self.navigationController.topViewController==self && self.startApp) self.startApp(installation.app);
        });
    });
}
- (void)primaryAction {
    if (_busy || _sessionUsed) return;
    if (_error || !_plan) { [self refresh]; return; }
    if (_installation.state==TKWoWInstallationMissing || _installation.state==TKWoWInstallationNeedsRepair) {
        [self checkForUpdatesAndLaunch:NO install:YES];return;
    }
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
    _editionButton.enabled=!_updating;_preferencesButton.enabled=!_updating;
    self.navigationItem.rightBarButtonItem.enabled=!_updating;
    _progressBar.hidden=!_updating || !_updateTotal;
    _progressBar.progress=_updateTotal?(float)((double)_updateDone/_updateTotal):0;
    NSString *title=nil, *detail=nil, *action=nil;
    BOOL enabled=NO;
    if (_sessionUsed) {
        title=L(@"Reopen to start again",@"Vuelve a abrir la app");
        detail=L(@"Close the app from the app switcher before starting another session.",@"Ciérrala desde el selector de apps antes de iniciar otra sesión.");
        action=L(@"Session ended",@"Sesión finalizada");
    } else if (_busy && _updating) {
        title=L(@"Updating your game…",@"Actualizando el juego…");
        NSDictionary *phases=@{@"snapshot":L(@"Preparing the installation",@"Preparando la instalación"),
            @"manifests":L(@"Reading the update",@"Consultando la actualización"),
            @"verify":L(@"Checking existing data",@"Comprobando los datos existentes"),
            @"indices":L(@"Locating download files",@"Localizando los archivos de descarga"),
            @"download":L(@"Downloading new data",@"Descargando los datos nuevos"),
            @"files":L(@"Installing game files",@"Instalando los archivos del juego"),
            @"activate":L(@"Finishing the update",@"Terminando la actualización"),
            @"complete":L(@"Update complete",@"Actualización completada")};
        detail=phases[_updatePhase]?:L(@"Preparing…",@"Preparando…");
        if(_updateTotal) {
            BOOL bytes=[_updatePhase isEqual:@"verify"] || [_updatePhase isEqual:@"download"];
            NSString *done=bytes?[NSByteCountFormatter stringFromByteCount:(int64_t)_updateDone countStyle:NSByteCountFormatterCountStyleFile]:@(_updateDone).stringValue;
            NSString *total=bytes?[NSByteCountFormatter stringFromByteCount:(int64_t)_updateTotal countStyle:NSByteCountFormatterCountStyleFile]:@(_updateTotal).stringValue;
            detail=[detail stringByAppendingFormat:@" · %@ / %@",done,total];
        }
        action=L(@"Updating…",@"Actualizando…");
    } else if (_busy) {
        title=L(@"Checking your adventure…",@"Comprobando tu aventura…");
        detail=L(@"Checking the latest version and your installed copy.",@"Buscando actualizaciones y comprobando tu copia instalada.");
        action=L(@"Checking…",@"Comprobando…");
    } else if (_error || !_plan) {
        title=_updateError?L(@"Update interrupted",@"Actualización interrumpida"):L(@"Could not check this edition",@"No se ha podido comprobar");
        detail=_updateError?[_error.localizedDescription stringByAppendingString:L(@" Your installed copy is preserved.",@" Tu copia instalada se conserva.")]:L(@"We cannot confirm that your game is up to date. Check your connection and try again.",@"No podemos confirmar que el juego esté al día. Comprueba la conexión y vuelve a intentarlo.");
        action=L(@"Try again",@"Reintentar"); enabled=YES;
    } else {
        switch (_installation.state) {
        case TKWoWInstallationMissing:
            title=L(@"Not installed",@"Sin instalar");
            detail=L(@"Install this edition on your device. The download may require several gigabytes.",@"Instala esta edición en tu dispositivo. La descarga puede ocupar varios gigabytes.");
            action=L(@"Install",@"Instalar"); enabled=YES; break;
        case TKWoWInstallationOutdated:
            title=L(@"Update required",@"Actualización pendiente");
            detail=L(@"A newer build is available. The update starts automatically.",@"Hay una nueva versión. La actualización comienza automáticamente.");
            action=L(@"Update needed to play",@"Actualiza para jugar"); break;
        case TKWoWInstallationNeedsRepair:
            title=L(@"Your copy needs attention",@"Revisa tu instalación");
            detail=L(@"We could not verify all game files. Repair downloads the original files and keeps your settings and addons.",@"No pudimos verificar todos los archivos. Reparar descarga los originales y conserva tus ajustes y addons.");
            action=L(@"Repair installation",@"Reparar instalación"); enabled=YES; break;
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
        message:L(@"Updates install automatically while this app is open. Settings and addons are preserved. Startup preparation is separate from downloading updates.",
            @"Las actualizaciones se instalan automáticamente con la app abierta. Se conservan los ajustes y addons. La preparación del arranque es independiente de la descarga.") preferredStyle:UIAlertControllerStyleActionSheet];
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
