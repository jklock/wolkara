// UIKit launcher: imports an unchanged macOS executable the user owns, runs
// diagnostics, and starts it through the translation runtime.
#import <UIKit/UIKit.h>
#import "GuestImage.h"
#import "MemoryProbe.h"
#import "HostExecutionProbe.h"
#import "NativeGuest.h"
#import "ShaderPauseProbe.h"
#import "SignedCodeProbe.h"
#import "SignedFileProbe.h"
#import "LocalShaderProbe.h"
#import "GuestModule.h"
#import "CPUProbe.h"
#import "ExecutionMode.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include <errno.h>
#include <stdint.h>
#include <stdlib.h>
#include <unistd.h>
#if TOLKARA_INTEGRATED_AUTH
#import "LocalAuthorization.h"
#import "Tolkara-Swift.h"
#endif

@interface AKHostSceneDelegate : UIResponder <UIWindowSceneDelegate, UIDocumentPickerDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UIButton *importButton;
@property(nonatomic) BOOL consumedImportArgument;
// This launch's execution mode and where it came from (logged; never a path).
@property(nonatomic) TKExecutionMode executionMode;
@property(nonatomic,copy) NSString *executionModeSource;
#if TOLKARA_INTEGRATED_AUTH
@property(nonatomic,strong) TKLocalAuthorization *localAuthorization;
@property(nonatomic,strong) UIButton *playButton, *modeButton;
@property(nonatomic) BOOL localGameAttempted;
#endif
@end

// An optional app profile (profiles/*.json, packaged as Guest/profile.json)
// names the app and says where its imported files live under Documents. It
// carries no code and no app data. Without one, the imported module is used.
static NSDictionary *AppProfile(void) {
    static NSDictionary *profile; static dispatch_once_t once;
    dispatch_once(&once,^{
        NSData *data=[NSData dataWithContentsOfFile:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Guest/profile.json"]];
        id value=data.length<=65536?[NSJSONSerialization JSONObjectWithData:data?:NSData.data options:0 error:NULL]:nil;
        if([value isKindOfClass:NSDictionary.class]) profile=value;
    });
    return profile;
}
static NSString *ProfileString(NSString *key) {
    id value=AppProfile()[key];
    // Relative paths only: a profile must not reach outside Documents.
    if(![value isKindOfClass:NSString.class] || ![value length] || [value hasPrefix:@"/"] || [[value pathComponents] containsObject:@".."]) return nil;
    return value;
}
#if TOLKARA_INTEGRATED_AUTH
static NSString *AppDisplayName(void) { return ProfileString(@"name")?:@"imported app"; }
#endif
static const char *ModeIdentifier(TKExecutionMode mode) { return (TKExecutionModeIdentifier(mode)?:@"none").UTF8String; }
// Files shows the app's Documents under its bundle name (Tolkara or TolkaraDiagnostics).
static NSString *FilesFolderName(void) {
    NSDictionary *info=NSBundle.mainBundle.infoDictionary; id name=info[@"CFBundleDisplayName"]?:info[@"CFBundleName"];
    return [name isKindOfClass:NSString.class] && [name length] ? name : @"this app";
}
static NSString *LocalSigningNeeds(void) {
    return [NSString stringWithFormat:@"Local signing needs its page container at %@ (visible in Files > On My iPad > %@ > LocalSigning). "
        "Build it on a Mac with tools/build_signed_container.py and copy it there; see docs/BUILDING.md.",TKLocalSigningContainerDisplayPath(),FilesFolderName()];
}
// Show the folder in Files so the user can put the container there.
static void PrepareLocalSigningFolder(void) {
    [NSFileManager.defaultManager createDirectoryAtPath:TKLocalSigningContainerPath(NSHomeDirectory()).stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:NULL];
}

// Explicit execution-mode choice: two equal buttons, neither highlighted nor
// recommended. The first choice cannot be dismissed without choosing.
@interface TKExecutionModeChooser : UIViewController
- (instancetype)initWithApp:(NSString *)app current:(TKExecutionMode)current cancellable:(BOOL)cancellable chosen:(void (^)(TKExecutionMode))chosen;
@end
@implementation TKExecutionModeChooser {
    NSString *_app; TKExecutionMode _current; BOOL _cancellable; void (^_chosen)(TKExecutionMode);
}
- (instancetype)initWithApp:(NSString *)app current:(TKExecutionMode)current cancellable:(BOOL)cancellable chosen:(void (^)(TKExecutionMode))chosen {
    if (!(self=[super initWithNibName:nil bundle:nil])) return nil;
    _app=app;_current=current;_cancellable=cancellable;_chosen=[chosen copy];
    self.modalPresentationStyle=UIModalPresentationFormSheet;
    self.modalInPresentation=!cancellable;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemBackgroundColor;
    UILabel *title=[UILabel new], *line=[UILabel new];
    title.text=[NSString stringWithFormat:@"How should Tolkara run %@?",_app];
    title.font=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle1];
    line.text=@"Choose one. You can change it later with Execution mode.";
    line.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    line.textColor=UIColor.secondaryLabelColor;
    for (UILabel *label in @[title,line]) { label.numberOfLines=0; label.adjustsFontForContentSizeCategory=YES; }
    UIStackView *stack=[[UIStackView alloc] initWithArrangedSubviews:@[title,line]];
    stack.axis=UILayoutConstraintAxisVertical; stack.spacing=16;
    [stack setCustomSpacing:28 afterView:line];
    __weak TKExecutionModeChooser *weakSelf=self;
    for (NSNumber *each in @[@(TKExecutionModeDeveloperService),@(TKExecutionModeLocalSigning)]) {
        TKExecutionMode mode=each.integerValue; NSString *unavailable=nil;
        BOOL available=TKExecutionModeAvailable(mode,&unavailable);
        NSString *subtitle=TKExecutionModeSummary(mode);
        if (_cancellable && mode==_current) subtitle=[@"Current. " stringByAppendingString:subtitle];
        if (!available) subtitle=[subtitle stringByAppendingFormat:@"\n%@",unavailable];
        UIButtonConfiguration *configuration=UIButtonConfiguration.grayButtonConfiguration;
        configuration.title=TKExecutionModeName(mode); configuration.subtitle=subtitle;
        configuration.titleAlignment=UIButtonConfigurationTitleAlignmentLeading;
        configuration.titlePadding=8;
        configuration.contentInsets=NSDirectionalEdgeInsetsMake(20,20,20,20);
        configuration.titleTextAttributesTransformer=^NSDictionary<NSAttributedStringKey,id> *(NSDictionary<NSAttributedStringKey,id> *attributes) {
            NSMutableDictionary *result=attributes.mutableCopy; result[NSFontAttributeName]=[UIFont preferredFontForTextStyle:UIFontTextStyleTitle2]; return result;
        };
        configuration.subtitleTextAttributesTransformer=^NSDictionary<NSAttributedStringKey,id> *(NSDictionary<NSAttributedStringKey,id> *attributes) {
            NSMutableDictionary *result=attributes.mutableCopy; result[NSFontAttributeName]=[UIFont preferredFontForTextStyle:UIFontTextStyleBody]; return result;
        };
        UIButton *button=[UIButton buttonWithConfiguration:configuration primaryAction:[UIAction actionWithHandler:^(UIAction *action) {
            (void)action;[weakSelf choose:mode];
        }]];
        button.enabled=available;
        [stack addArrangedSubview:button];
    }
    if (_cancellable) {
        UIButtonConfiguration *configuration=UIButtonConfiguration.plainButtonConfiguration; configuration.title=@"Cancel";
        [stack addArrangedSubview:[UIButton buttonWithConfiguration:configuration primaryAction:[UIAction actionWithHandler:^(UIAction *action) {
            (void)action;[weakSelf.presentingViewController dismissViewControllerAnimated:YES completion:nil];
        }]]];
    }
    UIScrollView *scroll=[UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints=NO; stack.translatesAutoresizingMaskIntoConstraints=NO;
    [self.view addSubview:scroll]; [scroll addSubview:stack];
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:32],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-32],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:32],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-32],
    ]];
}
- (void)choose:(TKExecutionMode)mode {
    if (_chosen) _chosen(mode);
    [self.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}
@end

@implementation AKHostSceneDelegate
- (UISceneWindowingControlStyle *)preferredWindowingControlStyleForScene:(UIWindowScene *)scene API_AVAILABLE(ios(26.0)) {
    (void)scene;
    return UISceneWindowingControlStyle.minimalStyle;
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    static BOOL started;
    if (started) return;
    started = YES;
    // --execution-mode=<id> > saved choice > TOLKARA_MODE preselection > ask.
    NSString *source=nil;
    self.executionMode=TKExecutionModeResolve(NSProcessInfo.processInfo.arguments,NSUserDefaults.standardUserDefaults,
        [NSBundle.mainBundle objectForInfoDictionaryKey:TKExecutionModePreselectionKey],&source);
    self.executionModeSource=source;
    fprintf(stderr,"[host] execution mode=%s source=%s\n",ModeIdentifier(self.executionMode),source.UTF8String);
    // Any Local signing launch makes the container folder, so a fresh install
    // can receive the container (tools/install.sh launches once if needed).
    if (self.executionMode==TKExecutionModeLocalSigning) PrepareLocalSigningFolder();
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    self.status = [UILabel new];
    self.status.numberOfLines = 0;
    self.status.font = [UIFont monospacedSystemFontOfSize:18 weight:UIFontWeightRegular];
    self.status.text = @"Preparing original guest executable…";
    self.status.translatesAutoresizingMaskIntoConstraints = NO;
    [controller.view addSubview:self.status];
    self.importButton=[UIButton buttonWithType:UIButtonTypeSystem];
    [self.importButton setTitle:@"Import original executable…" forState:UIControlStateNormal];
    [self.importButton addTarget:self action:@selector(importModule) forControlEvents:UIControlEventTouchUpInside];
    self.importButton.translatesAutoresizingMaskIntoConstraints=NO;
    [controller.view addSubview:self.importButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.status.leadingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.leadingAnchor constant:32],
        [self.status.trailingAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.trailingAnchor constant:-32],
        [self.status.centerYAnchor constraintEqualToAnchor:controller.view.centerYAnchor],
        [self.importButton.topAnchor constraintEqualToAnchor:self.status.bottomAnchor constant:24],
        [self.importButton.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
    ]];
    self.window.rootViewController = controller;
#if TOLKARA_INTEGRATED_AUTH
    (void)[TKEnrollmentImport prepare];
    self.localAuthorization=[TKLocalAuthorization new];
    self.playButton=[UIButton buttonWithType:UIButtonTypeSystem];
    [self.playButton setTitle:[@"Play " stringByAppendingString:AppDisplayName()] forState:UIControlStateNormal];
    [self.playButton addTarget:self action:@selector(play) forControlEvents:UIControlEventTouchUpInside];
    self.playButton.translatesAutoresizingMaskIntoConstraints=NO;
    self.playButton.hidden=YES;
    [controller.view addSubview:self.playButton];
    self.modeButton=[UIButton buttonWithType:UIButtonTypeSystem];
    [self.modeButton setTitle:@"Execution mode…" forState:UIControlStateNormal];
    [self.modeButton addTarget:self action:@selector(changeExecutionMode) forControlEvents:UIControlEventTouchUpInside];
    self.modeButton.translatesAutoresizingMaskIntoConstraints=NO;
    self.modeButton.hidden=YES;
    [controller.view addSubview:self.modeButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.playButton.topAnchor constraintEqualToAnchor:self.importButton.bottomAnchor constant:24],
        [self.playButton.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
        [self.modeButton.topAnchor constraintEqualToAnchor:self.playButton.bottomAnchor constant:16],
        [self.modeButton.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
    ]];
    UIButton *setup=[UIButton buttonWithType:UIButtonTypeSystem];
    [setup setTitle:@"Developer service diagnostics…" forState:UIControlStateNormal];
    [setup addTarget:self action:@selector(developerServiceDiagnostics) forControlEvents:UIControlEventTouchUpInside];
    setup.translatesAutoresizingMaskIntoConstraints=NO;
    [controller.view addSubview:setup];
    [NSLayoutConstraint activateConstraints:@[
        [setup.bottomAnchor constraintEqualToAnchor:controller.view.safeAreaLayoutGuide.bottomAnchor constant:-24],
        [setup.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
    ]];
#endif
    [self.window makeKeyAndVisible];
    // Timer callout, not dispatch_async: the guest never returns from main(), and a
    // main-queue block that never returns would wedge the main dispatch queue.
    [self performSelector:@selector(startGuest) withObject:nil afterDelay:0];
}
#if TOLKARA_INTEGRATED_AUTH
// Tolkara's main screen: the app, its execution mode and Play. Without a mode
// the user must choose one first; nothing is chosen for them.
- (void)showMainScreen {
    NSString *source=self.executionModeSource;
    if ([source hasPrefix:TKExecutionModeSourceInvalidArgument]) {
        self.status.text=[NSString stringWithFormat:@"%@\nCannot start: %@.",AppDisplayName(),source];return;
    }
    NSString *text=[NSString stringWithFormat:@"%@\nExecution mode: %@",AppDisplayName(),TKExecutionModeName(self.executionMode)?:@"not chosen"];
    if ([source isEqualToString:TKExecutionModeSourceArgument]) text=[text stringByAppendingString:@" (this launch only)"];
    if (TKExecutionModeSourceIsInvalid(source)) text=[text stringByAppendingFormat:@"\nNot preselected: %@.",source];
    if (self.executionMode==TKExecutionModeLocalSigning) PrepareLocalSigningFolder();
    // One startup attempt per process: after it, only a restart can play or change mode.
    if (self.localGameAttempted) {
        self.status.text=[text stringByAppendingString:@"\nClose and reopen the app to start a new session."];
        self.playButton.hidden=YES; self.modeButton.hidden=YES; return;
    }
    self.status.text=text;
    self.playButton.hidden=!self.executionMode;
    // Always reachable: if the chooser below cannot be presented, this still is.
    self.modeButton.hidden=NO;
    if (!self.executionMode) [self chooseExecutionMode:NO];
}
- (void)chooseExecutionMode:(BOOL)cancellable {
    if ([self.window.rootViewController.presentedViewController isKindOfClass:TKExecutionModeChooser.class]) return;
    __weak AKHostSceneDelegate *weakSelf=self;
    TKExecutionModeChooser *chooser=[[TKExecutionModeChooser alloc] initWithApp:ProfileString(@"name")?:@"the imported app"
        current:self.executionMode cancellable:cancellable chosen:^(TKExecutionMode mode) {
        TKExecutionModeSave(NSUserDefaults.standardUserDefaults,mode);
        weakSelf.executionMode=mode;weakSelf.executionModeSource=@"chosen";
        [weakSelf showMainScreen];
    }];
    [self.window.rootViewController presentViewController:chooser animated:YES completion:nil];
}
// Cancellable once a mode is chosen; the first choice cannot be skipped.
- (void)changeExecutionMode { [self chooseExecutionMode:self.executionMode!=TKExecutionModeNone]; }
// Play in the chosen mode. Either way, a process gets one startup attempt.
- (void)play {
    NSString *unavailable=nil;
    if (!self.executionMode) { [self chooseExecutionMode:NO];return; }
    if (!TKExecutionModeAvailable(self.executionMode,&unavailable)) { self.status.text=unavailable;return; }
    if (self.executionMode==TKExecutionModeLocalSigning) { [self launchLocalSigning];return; }
    self.modeButton.hidden=YES;
    [self launchLocalGame];
}
// Local signing: the page container holds the guest's final code pages, signed
// with the user's own identity. Without it, say what is needed; Play stays.
- (void)launchLocalSigning {
    if(self.localGameAttempted) {self.status.text=@"Close and reopen the app to start a new session.";return;}
    NSString *container=TKLocalSigningContainerPath(NSHomeDirectory());
    if(![NSFileManager.defaultManager fileExistsAtPath:container]) {
        PrepareLocalSigningFolder();
        self.status.text=[NSString stringWithFormat:@"%@\nExecution mode: Local signing\n\n%@",AppDisplayName(),LocalSigningNeeds()];
        return;
    }
    self.localGameAttempted=YES;
    // As for Developer service: an uncached shader waits instead of failing.
    setenv("TOLKARA_WAIT_FOR_MISSING_SHADERS","1",1);
    self.playButton.hidden=YES;self.importButton.hidden=YES;self.modeButton.hidden=YES;
    UIApplication.sharedApplication.idleTimerDisabled=YES;
    self.status.text=[NSString stringWithFormat:@"Starting %@…\nKeep the app open. Startup currently takes a few minutes.",AppDisplayName()];
    // Guest main must enter from a timer callout, never a dispatch block.
    [self performSelector:@selector(startSignedGame:) withObject:container afterDelay:0];
}
- (void)startSignedGame:(NSString *)container { [self runNativeGame:YES container:container]; }
- (void)launchLocalGame {
    if(self.localGameAttempted) {self.status.text=@"Close and reopen the app to start a new session.";return;}
    self.localGameAttempted=YES;
    // Preserve responsiveness on an uncached shader while local translation
    // is being completed; a missing artifact must not become a nil library.
    setenv("TOLKARA_WAIT_FOR_MISSING_SHADERS","1",1);
    if([NSProcessInfo.processInfo.arguments containsObject:@"--local-shaders-only"])
        setenv("TOLKARA_LOCAL_SHADERS_ONLY","1",1);
    self.playButton.hidden=YES;self.importButton.hidden=YES;
    UIApplication.sharedApplication.idleTimerDisabled=YES;
    self.status.text=@"Preparing local launch…";
    [self.localAuthorization startAndPrepareLocalAuthorization:^(NSString *report) {
        [report writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/local-game-setup.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        if(!self.localAuthorization.localSessionReady || !ng_use_local_authorization()) {
            self.status.text=[@"Local launch could not prepare. Close and reopen the app to retry.\n" stringByAppendingString:report];
            UIApplication.sharedApplication.idleTimerDisabled=NO;return;
        }
        self.status.text=[NSString stringWithFormat:@"Starting %@…\nKeep the app open. Startup currently takes a few minutes.",AppDisplayName()];
        // Guest main must enter from a timer callout, never a dispatch block.
        [self performSelector:@selector(startLocalGame) withObject:nil afterDelay:0];
    }];
}
- (void)startLocalGame { [self runNativeGame:YES container:nil]; }
- (void)developerServiceDiagnostics {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Developer service diagnostics"
        message:@"The local route connects this app to the iPad’s developer service. New shader translation is still under development."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Check direct access" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;[TKLocalAuthorization probeDirectAccess:^(NSString *result) {self.status.text=result;}];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Start local route" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;[self.localAuthorization startLocalRoute:^(NSString *result) {self.status.text=result;}];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Check local route service" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;[TKLocalAuthorization probeLocalRouteService:^(NSString *result) {
            self.status.text=result;
            [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/local-route-service-probe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Stop local route" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        (void)action;[self.localAuthorization stopLocalRoute];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self.window.rootViewController presentViewController:alert animated:YES completion:nil];
}
#endif
- (NSString *)moduleRoot { return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/GuestModules"]; }
- (void)importModule {
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeItem] asCopy:NO];
    picker.delegate=self;
    [self.window.rootViewController presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSURL *url=urls.firstObject;
    if (!url) return;
    BOOL scoped=[url startAccessingSecurityScopedResource];
    self.importButton.enabled=NO;
    self.status.text=@"Verifying and importing original executable…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *error=nil;
        BOOL ok=guest_module_import(url.path,self.moduleRoot,&error);
        if (scoped) [url stopAccessingSecurityScopedResource];
        dispatch_async(dispatch_get_main_queue(),^{
            self.importButton.enabled=YES;
            // Enter from a run-loop callout, as at initial launch. Preparing
            // native memory pumps that loop; guest main may never return.
            // Neither can run while holding the main dispatch queue's block.
            if (ok) [self performSelector:@selector(startGuest) withObject:nil afterDelay:0];
            else self.status.text=error.localizedDescription;
        });
    });
}
// Documents/native-guest.log, this launch's runtime log. stdout and stderr
// follow it; the run id and the execution mode come first, never a path.
- (FILE *)openRuntimeLog {
    NSString *directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    FILE *log = fopen([directory stringByAppendingPathComponent:@"native-guest.log"].fileSystemRepresentation, "w");
    if (!log) return NULL;
    dup2(fileno(log), STDERR_FILENO);
    dup2(fileno(log), STDOUT_FILENO);
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (NSString *argument in NSProcessInfo.processInfo.arguments) if ([argument hasPrefix:@"--probe-run-id="]) fprintf(log,"%s\n",argument.UTF8String);
    fprintf(log,"[host] execution mode=%s source=%s\n",ModeIdentifier(self.executionMode),self.executionModeSource.UTF8String); fflush(log);
    return log;
}
// Refuse a native startup before it begins; the runtime log says why.
- (void)refuseNativeGame:(NSString *)reason {
    FILE *log=[self openRuntimeLog];
    if (log) { fprintf(log,"[host] native startup refused: %s\n",reason.UTF8String); fclose(log); }
    self.status.text=reason;
}
// Only an unusable --execution-mode stops a diagnostic launch. An invalid
// TOLKARA_MODE preselection just means no mode: the launch flags decide.
- (BOOL)refuseInvalidModeArgument {
    if (![self.executionModeSource hasPrefix:TKExecutionModeSourceInvalidArgument]) return NO;
    [self refuseNativeGame:[NSString stringWithFormat:@"Cannot start: %@.",self.executionModeSource]];
    return YES;
}
// A launch flag that decides the mode by itself. It replaces a saved choice or
// a preselection (the log keeps what it replaced), but a --execution-mode that
// says otherwise is refused: two explicit flags that disagree are not settled.
- (BOOL)forceExecutionMode:(TKExecutionMode)mode by:(NSString *)flag {
    NSString *source=self.executionModeSource;
    if (self.executionMode!=mode && [source isEqualToString:TKExecutionModeSourceArgument]) {
        [self refuseNativeGame:[NSString stringWithFormat:@"--execution-mode=%s conflicts with %@, which uses %@. Pass only one of them.",
            ModeIdentifier(self.executionMode),flag,TKExecutionModeName(mode)]];
        return NO;
    }
    self.executionModeSource=self.executionMode!=mode && ![source isEqualToString:TKExecutionModeSourceNone] ?
        [NSString stringWithFormat:@"%@ (overrides %s from %@)",flag,ModeIdentifier(self.executionMode),source] : flag;
    self.executionMode=mode;
    fprintf(stderr,"[host] execution mode=%s source=%s\n",ModeIdentifier(mode),self.executionModeSource.UTF8String);
    return YES;
}
// --native-initializer / --native-startup: the container from --signed-image=
// if given, else Local signing's default container when that is the mode,
// else the Developer-service/debugger path exactly as before modes existed.
- (void)startNativeDiagnostic:(BOOL)fullStartup {
    if ([self refuseInvalidModeArgument]) return;
    NSString *problem=nil, *container=TKSignedImagePath(NSProcessInfo.processInfo.arguments,NSHomeDirectory(),&problem);
    if (problem) { [self refuseNativeGame:[NSString stringWithFormat:@"--signed-image rejected: %@.",problem]];return; }
    if (container) { if (![self forceExecutionMode:TKExecutionModeLocalSigning by:@"--signed-image"]) return; }
    else if (self.executionMode==TKExecutionModeLocalSigning) {
        container=TKLocalSigningContainerPath(NSHomeDirectory());
        if (![NSFileManager.defaultManager fileExistsAtPath:container]) {
            PrepareLocalSigningFolder();
            // A saved choice or preselection is shared with the Tolkara app; say how to override it.
            NSString *reason=LocalSigningNeeds();
            if (![self.executionModeSource isEqualToString:TKExecutionModeSourceArgument])
                reason=[reason stringByAppendingFormat:@" (Local signing is the %@ execution mode; pass --execution-mode=developer-service for the debugger path.)",
                    [self.executionModeSource isEqualToString:TKExecutionModeSourceSaved]?@"saved":@"preselected"];
            [self refuseNativeGame:reason];return;
        }
    }
    [self runNativeGame:fullStartup container:container];
}
// container: Local signing's validated page container, or nil for the
// Developer-service/debugger path. Callers choose it; this only applies it.
- (void)runNativeGame:(BOOL)fullStartup container:(NSString *)container {
    self.importButton.hidden=YES;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    NSString *directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    FILE *log = [self openRuntimeLog];
    if (!log) { self.status.text = @"Cannot open native runtime log."; UIApplication.sharedApplication.idleTimerDisabled=NO; return; }
    NSString *path = guest_module_selected(self.moduleRoot,NULL);
    NSString *map = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Guest/libraries.json"];
    // Executable selection is identical for both backends: the runtime rejects a
    // signed container that does not match the executable it is remapped over.
    if (fullStartup) {
        NSString *relativeDirectory=ProfileString(@"workingDirectory"), *relativeExecutable=ProfileString(@"executable");
        NSString *game = relativeDirectory ? [directory stringByAppendingPathComponent:relativeDirectory] : nil;
        NSString *original = game && relativeExecutable ? [game stringByAppendingPathComponent:relativeExecutable] : nil;
        if (original && [NSFileManager.defaultManager fileExistsAtPath:original]) {
            path = original;
            if (chdir(game.fileSystemRepresentation)) fprintf(log,"[host] app working directory failed: %s\n",strerror(errno));
            else fprintf(log,"[host] app working directory=%s\n",TKHomeDisplayPath(game,NSHomeDirectory()).UTF8String);
        }
    }
    if (!path) {
        self.status.text=@"Import the original executable before running the development loader.";
        UIApplication.sharedApplication.idleTimerDisabled=NO;
        self.importButton.hidden=NO;
        return;
    }
    // Local signing: the runtime validates the container against this
    // executable and refuses it after Developer service was selected.
    if (container) {
        NSString *shown=TKHomeDisplayPath(container,NSHomeDirectory());
        char reason[256]={0};
        if(!ng_use_signed_image(container.fileSystemRepresentation,reason,sizeof reason)) {
            fprintf(log,"[host] signed-image rejected: %s (container=%s)\n",reason[0]?reason:"backend unavailable",shown.UTF8String); fflush(log);
            // One startup attempt per process, as for Developer service. Only
            // Play (Tolkara's main screen) has an Execution mode chooser.
            NSString *retry=@"Close and reopen the app to retry.";
#if TOLKARA_INTEGRATED_AUTH
            if(self.localGameAttempted) retry=@"Close and reopen the app to retry or to change the execution mode.";
#endif
            self.status.text=[NSString stringWithFormat:@"Local signing could not start: %s\n%@",reason[0]?reason:"see runtime log",retry];
            UIApplication.sharedApplication.idleTimerDisabled=NO;
            return;
        }
        fprintf(log,"[host] signed-image container=%s\n",shown.UTF8String); fflush(log);
    }
    BOOL ok = ng_initialize(path.fileSystemRepresentation, NSBundle.mainBundle.privateFrameworksPath.fileSystemRepresentation, map.fileSystemRepresentation, log, fullStartup);
    // The outcome as the host saw it (tools/run.sh requires "returned").
    fprintf(log,"[host] native %s %s\n",fullStartup?"startup":"first initializer",ok?"returned":"stopped"); fflush(log);
    self.status.text = ok ? (fullStartup ? @"App closed." : @"Original client first initializer returned.") : @"Native startup stopped. See runtime log.";
    UIApplication.sharedApplication.idleTimerDisabled = NO;
    // Runtime callbacks retain this log for the life of the guest.
}

- (void)startGuest {
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    self.importButton.hidden=NO;
    if([arguments containsObject:@"--local-shader-probe"]) {
        self.importButton.hidden=YES;self.status.text=@"Testing the local shader compiler…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *report=TKRunLocalShaderProbe([NSHomeDirectory() stringByAppendingPathComponent:@"Documents/LocalShaderProbe"]);
            [report writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/local-shader-probe.txt"] atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            dispatch_async(dispatch_get_main_queue(),^{self.status.text=report;});
        });
        return;
    }
#if TOLKARA_INTEGRATED_AUTH
    if([arguments containsObject:@"--prepare-authorization-import"]) {
        self.importButton.hidden=YES;
        self.status.text=[TKEnrollmentImport prepare]?@"Protected enrollment handoff directory ready.":@"Enrollment handoff directory unavailable.";
        return;
    }
    if([arguments containsObject:@"--import-authorization-enrollment"]) {
        self.importButton.hidden=YES;
        NSUInteger device=[arguments indexOfObject:@"--expected-device"];
        NSUInteger fingerprint=[arguments indexOfObject:@"--expected-enrollment-fingerprint"];
        NSString *result=@"Enrollment import arguments missing.";
        if(device!=NSNotFound && device+1<arguments.count && fingerprint!=NSNotFound && fingerprint+1<arguments.count)
            result=[TKEnrollmentImport importPendingWithDevice:arguments[device+1] fingerprint:arguments[fingerprint+1]];
        self.status.text=result;
        [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/authorization-import-result.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    if([arguments containsObject:@"--native-retry-probe"]) {
        self.importButton.hidden=YES;
        NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/native-retry-probe.txt"];
        FILE *log=fopen(path.fileSystemRepresentation,"w");
        if(!log) { self.status.text=@"Cannot open retry probe log.";return; }
        NSString *absent=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        BOOL first=ng_initialize(absent.fileSystemRepresentation,"","",log,false);
        BOOL second=ng_initialize(absent.fileSystemRepresentation,"","",log,false);
        BOOL passed=!first && !second && [NSProcessInfo.processInfo.arguments containsObject:@"--native-retry-probe"];
        fprintf(log,"Native retry guard %s; no guest executable loaded or run.\n",passed?"PASS":"FAIL");
        fclose(log);self.status.text=passed?@"Native retry guard passed; no game code executed.":@"Native retry guard failed.";
        return;
    }
    if([arguments containsObject:@"--local-connected-arena-probe"] || [arguments containsObject:@"--local-execution-probe"]) {
        BOOL executeProbe=[arguments containsObject:@"--local-execution-probe"];
        self.importButton.hidden=YES;
        self.status.text=@"Preparing the authenticated local debugger…";
        [self.localAuthorization startAndPrepareLocalAuthorization:^(NSString *setup) {
            NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:executeProbe?@"Documents/local-execution-probe.txt":@"Documents/local-connected-arena-probe.txt"];
            [setup writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            // Run outside the main queue: the target can be paused by its helper
            // while UIKit and provider IPC still need normal run-loop servicing.
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
                static NativeCodeMemory memory,quarantine;
                BOOL prepared=nc_create_managed(&memory,16384,TKPrepareLocalArena,NULL,&quarantine);
                NSString *outcome=prepared?@"Prepared and detached; no code executed.":
                    quarantine.quarantined?@"Preparation uncertain; memory retained, guest entry blocked, restart required.":
                    @"Preparation rejected; guest entry blocked.";
                if(prepared && executeProbe) {
                    // Our own two-instruction fixture: mov w0,#42; ret. No
                    // proprietary module is loaded, modified, signed or run.
                    const uint32_t fixture[]={0x52800540,0xd65f03c0};
                    if(nc_write(&memory,0,fixture,sizeof fixture)) {
                        [[setup stringByAppendingString:@"\nPrepared and detached; executing our return-42 fixture…"]
                            writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                        int answer=((int (*)(void))memory.executable)();
                        outcome=answer==42?@"PASS: locally prepared memory executed our return-42 function after confirmed detach.":@"FAIL: fixture returned an unexpected value.";
                    } else outcome=@"FAIL: prepared memory could not receive our fixture.";
                }
                nc_destroy(&memory);
                NSString *result=[setup stringByAppendingFormat:@"\n%@",outcome];
                [result writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
                dispatch_async(dispatch_get_main_queue(),^{self.status.text=result;});
            });
        }];
        return;
    }
    if([arguments containsObject:@"--local-arena-probe"]) {
        self.importButton.hidden=YES;
        self.status.text=@"Checking local memory preparation…";
        static NativeCodeMemory memory,quarantine;
        BOOL prepared=nc_create_managed(&memory,16384,TKPrepareLocalArena,NULL,&quarantine);
        NSString *result=prepared?@"Prepared and detached; no code executed.":
            quarantine.quarantined?@"Preparation uncertain; memory retained, guest entry blocked, restart required.":
            @"Preparation rejected; memory released, guest entry blocked. Local authorization is not configured.";
        nc_destroy(&memory);
        self.status.text=result;
        [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/local-arena-probe.txt"]
            atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        return;
    }
    if([arguments containsObject:@"--start-local-route-probe"]) {
        self.importButton.hidden=YES;
        self.status.text=@"Starting the approved local route…";
        [self.localAuthorization startAndProbeLocalRoute:^(NSString *result) {
            self.status.text=result;
            [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/start-local-route-probe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
        return;
    }
    if([arguments containsObject:@"--local-pairing-probe"]) {
        self.importButton.hidden=YES;
        self.status.text=@"Verifying the enrolled local identity…";
        [self.localAuthorization startAndVerifyPairing:^(NSString *result) {
            self.status.text=result;
            [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/local-pairing-probe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
        return;
    }
    if([arguments containsObject:@"--local-tunnel-probe"]) {
        self.importButton.hidden=YES;
        self.status.text=@"Verifying the encrypted local developer tunnel…";
        [self.localAuthorization startAndVerifyTunnel:^(NSString *result) {
            self.status.text=result;
            [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/local-tunnel-probe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
        return;
    }
    if([arguments containsObject:@"--local-route-service-probe"]) {
        self.importButton.hidden=YES;
        [TKLocalAuthorization probeLocalRouteService:^(NSString *result) {
            self.status.text=result;
            [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/local-route-service-probe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
        return;
    }
    if([arguments containsObject:@"--remote-pairing-service-probe"]) {
        self.importButton.hidden=YES;
        [TKLocalAuthorization probeRemotePairingService:^(NSString *result) {
            self.status.text=result;
            [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/remote-pairing-service-probe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
        return;
    }
    if([arguments containsObject:@"--direct-service-probe"]) {
        self.importButton.hidden=YES;
        [TKLocalAuthorization probeDirectService:^(NSString *result) {
            self.status.text=result;
            [result writeToFile:[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/direct-service-probe.txt"]
                atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }];
        return;
    }
    if([arguments containsObject:@"--direct-authorization-probe"]) {
        self.importButton.hidden=YES;
        [TKLocalAuthorization probeDirectAccess:^(NSString *result) {
            self.status.text=result;
            NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/direct-authorization-probe.txt"];
            [result writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
            fprintf(stderr,"[local-authorization] %s\n",result.UTF8String);
        }];
        return;
    }
#endif
    if ([arguments containsObject:@"--cpu-probe"]) {
        self.importButton.hidden=YES;
        self.status.text=@"Measuring execution through the signed runtime…";
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
            NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/cpu-probe.log"];
            FILE *log=fopen(path.fileSystemRepresentation,"w");
            BOOL ok=log && guest_cpu_probe(log,2000000);
            if (log) fclose(log);
            NSString *report=[NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
            fprintf(stderr,"%s",report.UTF8String?:"CPU probe log unavailable.");
            dispatch_async(dispatch_get_main_queue(),^{
                self.status.text=[NSString stringWithFormat:@"CPU interpreter probe %@\n\n%@",ok?@"passed":@"failed",report?:@""];
            });
        });
        return;
    }
    NSString *signedFilePath=nil, *signedFileMode=@"exec";
    unsigned signedFileExpect=0x12345678; BOOL signedFileExpectBad=NO;
    for (NSString *argument in arguments) {
        if ([argument hasPrefix:@"--signed-file-probe="]) signedFilePath=[argument substringFromIndex:20];
        if ([argument hasPrefix:@"--signed-file-probe-mode="]) signedFileMode=[argument substringFromIndex:25];
        if ([argument hasPrefix:@"--signed-file-probe-expect="]) {
            // Strict: reject garbage and values above UINT32_MAX instead of
            // silently probing against a wrong (or 0) expected value. Require a
            // leading digit: strtoul otherwise silently accepts a sign or
            // leading whitespace ('+5', '-0', ' 5'). A leading '0' still admits
            // hex 0x...; the errno/end/UINT32_MAX checks stay.
            const char *text=[argument substringFromIndex:27].UTF8String; char *end=NULL;
            errno=0; unsigned long parsed=strtoul(text,&end,0);
            if(text[0]>='0'&&text[0]<='9' && !*end && !errno && parsed<=UINT32_MAX) signedFileExpect=(unsigned)parsed;
            else signedFileExpectBad=YES;
        }
    }
    if(signedFilePath) {
        self.importButton.hidden=YES;
        if(signedFileExpectBad) { self.status.text=@"--signed-file-probe-expect must be an integer in [0, 0xFFFFFFFF]."; return; }
        if(![signedFilePath isAbsolutePath]) signedFilePath=[NSHomeDirectory() stringByAppendingPathComponent:signedFilePath];
        NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/signed-file-probe.log"];
        FILE *log=fopen(path.fileSystemRepresentation,"w");
        if(!log) { self.status.text=@"Cannot open signed-file probe log.";return; }
        for (NSString *argument in arguments) if ([argument hasPrefix:@"--probe-run-id="]) fprintf(log,"%s\n",argument.UTF8String);
        BOOL ok=HostSignedFileProbe(signedFilePath.fileSystemRepresentation,signedFileMode.UTF8String,signedFileExpect,log);
        fclose(log);
        self.status.text=ok?@"Signed file-mapped code executed natively.":@"Signed file probe failed. See probe log.";
        return;
    }
    if([arguments containsObject:@"--signed-cache-probe"]) {
        NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/signed-code-probe.log"];
        FILE *log=fopen(path.fileSystemRepresentation,"w");
        if(!log) { self.status.text=@"Cannot open signed-code probe log.";return; }
        BOOL ok=HostSignedCodeProbe(log);fclose(log);
        self.status.text=ok?@"Signed code-cache mapping passed.\nNo debugger or game code used.":@"Signed code-cache mapping unavailable. See probe log.";
        return;
    }
    if([arguments containsObject:@"--shader-pause-probe"]) {
        UIApplication.sharedApplication.idleTimerDisabled=YES;
        NSString *path=[NSHomeDirectory() stringByAppendingPathComponent:@"Documents/shader-pause-probe.log"];
        FILE *log=fopen(path.fileSystemRepresentation,"w");
        if(!log) { self.status.text=@"Cannot open shader probe log.";UIApplication.sharedApplication.idleTimerDisabled=NO;return; }
        BOOL ok=HostShaderPauseProbe(NSBundle.mainBundle.privateFrameworksPath,log);
        fclose(log);
        self.status.text=ok?@"Shader pause and recovery passed.\nNo game code was executed.":@"Shader pause test incomplete. See probe log.";
        UIApplication.sharedApplication.idleTimerDisabled=NO;
        return;
    }
    if ([arguments containsObject:@"--execution-probe=wx"] ||
        [arguments containsObject:@"--execution-probe=dual"] ||
        [arguments containsObject:@"--execution-probe=rwx"]) {
        BOOL previousIdleSetting = UIApplication.sharedApplication.idleTimerDisabled;
        UIApplication.sharedApplication.idleTimerDisabled = YES;
        BOOL rwx = [arguments containsObject:@"--execution-probe=rwx"];
        BOOL dual = [arguments containsObject:@"--execution-probe=dual"];
        NSString *directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString *logPath = [directory stringByAppendingPathComponent:@"execution-probe.log"];
        FILE *log = fopen(logPath.fileSystemRepresentation, "w");
        if (!log) {
            UIApplication.sharedApplication.idleTimerDisabled = previousIdleSetting;
            self.status.text = @"Cannot open execution probe log.";
            return;
        }
        for (NSString *argument in arguments) {
            if ([argument hasPrefix:@"--probe-run-id="]) fprintf(log, "[execution] %s\n", argument.UTF8String);
        }
        HPResult result = host_execution_probe(dual ? HP_DUAL_MAPPING : rwx ? HP_READ_WRITE_EXECUTE : HP_WRITE_THEN_EXECUTE, log);
        UIApplication.sharedApplication.idleTimerDisabled = previousIdleSetting;
        fclose(log);
        NSString *report = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:NULL];
        fprintf(stderr, "%s", report.UTF8String);
        self.status.text = [NSString stringWithFormat:
            @"Host-generated arm64 execution test\n\nMode: %@\nExecute: %@\nRewrite and execute: %@\n\nAllocation errno: %d\nProtection errno: %d\n\nThis tests host code only. No imported app code has been executed.",
            dual ? @"Shared RW / RX views" : rwx ? @"RWX" : @"RW → RX", result.executable ? @"PASS" : @"DENIED / FAILED",
            result.rewrite_executable ? @"PASS" : @"DENIED / FAILED",
            result.allocation_errno, result.protection_errno];
        return;
    }
#if TOLKARA_INTEGRATED_AUTH
    if([arguments containsObject:@"--local-game-startup"]) {
        // Always Developer service: it replaces a saved choice or preselection
        // (logged); an unusable or contradicting --execution-mode and any
        // --signed-image are refused.
        if([self refuseInvalidModeArgument] || ![self forceExecutionMode:TKExecutionModeDeveloperService by:@"--local-game-startup"]) return;
        NSString *problem=nil;
        if(TKSignedImagePath(arguments,NSHomeDirectory(),&problem) || problem) {
            [self refuseNativeGame:@"--signed-image is a Local signing container, but --local-game-startup always uses Developer service. Pass only one of them."];
            return;
        }
        [self launchLocalGame];return;
    }
    // A plain launch (at most a per-launch --execution-mode) shows the main screen.
    BOOL plain=YES;
    for(NSUInteger i=1;i<arguments.count;i++) if(![arguments[i] hasPrefix:TKExecutionModeArgumentPrefix]) plain=NO;
    if(plain && [NSFileManager.defaultManager fileExistsAtPath:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Guest/libraries.json"]]) {
        [self showMainScreen];return;
    }
#endif
    if ([arguments containsObject:@"--native-initializer"] || [arguments containsObject:@"--native-startup"]) {
        [self startNativeDiagnostic:[arguments containsObject:@"--native-startup"]];return;
    }
    NSString *runtime = [NSBundle.mainBundle objectForInfoDictionaryKey:@"TolkaraGuestRuntime"];
    if ([runtime isEqualToString:@"emulated"]) {
        BOOL importFromArguments=!self.consumedImportArgument;
        self.consumedImportArgument=YES;
        self.importButton.enabled=NO;
        // Read/allocate away from the UI thread. Never cast a guest VA to a host pointer.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            char error[2048];
            NSString *message;
            if (!guest_memory_probe(error, sizeof error)) {
                message = [NSString stringWithFormat:@"Memory emulation check failed:\n%s", error];
            } else {
                fprintf(stderr, "[softmmu] PASS: MAP_JIT, write protection, fetch, mprotect, fixed remap, munmap\n");
                NSError *moduleError=nil;
                NSString *path=guest_module_selected(self.moduleRoot,&moduleError);
                // Simulator/developer staging is separate from the installed app.
                if (importFromArguments) for (NSString *argument in arguments) if ([argument hasPrefix:@"--import-module="]) {
                    NSString *source=[argument substringFromIndex:16];
                    if (!source.isAbsolutePath) source=[NSHomeDirectory() stringByAppendingPathComponent:source];
                    if (guest_module_import(source,self.moduleRoot,&moduleError))
                        path=guest_module_selected(self.moduleRoot,&moduleError);
                }
                GuestImage image = {0};
                if (!path) {
                    message=[NSString stringWithFormat:@"Standalone runtime development\n\n%@\n\nThe signed app contains no game executable. Standalone game execution is not integrated yet.",moduleError.localizedDescription];
                } else if (!gi_load(path.fileSystemRepresentation, &image, error, sizeof error)) {
                    message = [NSString stringWithFormat:@"Original guest load failed:\n%s", error];
                } else {
                    gi_report(&image, stderr);
                    message = [NSString stringWithFormat:
                        @"Separate application module verified\nOriginal executable loaded unchanged\n\nGuest memory: %.1f MiB\nInitializers: %llu\nFirst initializer: 0x%llx\n\nMemory emulation checks passed.\n\nStandalone execution is not integrated yet.",
                        image.mapped_size / 1048576.0,
                        (unsigned long long)image.initializer_count,
                        (unsigned long long)image.first_initializer];
                    gi_destroy(&image);
                }
            }
            fprintf(stderr, "[host] %s\n", message.UTF8String);
            dispatch_async(dispatch_get_main_queue(), ^{ self.status.text = message; self.importButton.enabled=YES; });
        });
        return;
    }
    self.status.text = @"Unknown guest runtime configuration.";
}
@end

@interface AKHostAppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AKHostAppDelegate
- (UISceneConfiguration *)application:(UIApplication *)a configurationForConnectingSceneSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:s.role];
    c.delegateClass = AKHostSceneDelegate.class;
    return c;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AKHostAppDelegate.class)); }
}
