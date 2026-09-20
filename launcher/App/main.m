// UIKit launcher: imports an unchanged macOS executable the user owns, runs
// diagnostics, and starts it through the translation runtime.
#import <UIKit/UIKit.h>
#import "GuestImage.h"
#import "MemoryProbe.h"
#import "HostExecutionProbe.h"
#import "NativeGuest.h"
#import "ShaderPauseProbe.h"
#import "SignedCodeProbe.h"
#import "LocalShaderProbe.h"
#import "GuestModule.h"
#import "CPUProbe.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
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
#if TOLKARA_INTEGRATED_AUTH
@property(nonatomic,strong) TKLocalAuthorization *localAuthorization;
@property(nonatomic,strong) UIButton *playButton;
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
static NSString *AppDisplayName(void) { return ProfileString(@"name")?:@"imported app"; }

@implementation AKHostSceneDelegate
- (UISceneWindowingControlStyle *)preferredWindowingControlStyleForScene:(UIWindowScene *)scene API_AVAILABLE(ios(26.0)) {
    (void)scene;
    return UISceneWindowingControlStyle.minimalStyle;
}
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)s options:(UISceneConnectionOptions *)o {
    static BOOL started;
    if (started) return;
    started = YES;
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
    [self.playButton addTarget:self action:@selector(launchLocalGame) forControlEvents:UIControlEventTouchUpInside];
    self.playButton.translatesAutoresizingMaskIntoConstraints=NO;
    self.playButton.hidden=YES;
    [controller.view addSubview:self.playButton];
    [NSLayoutConstraint activateConstraints:@[
        [self.playButton.topAnchor constraintEqualToAnchor:self.importButton.bottomAnchor constant:24],
        [self.playButton.centerXAnchor constraintEqualToAnchor:controller.view.centerXAnchor],
    ]];
    UIButton *setup=[UIButton buttonWithType:UIButtonTypeSystem];
    [setup setTitle:@"Local launch setup…" forState:UIControlStateNormal];
    [setup addTarget:self action:@selector(localLaunchSetup) forControlEvents:UIControlEventTouchUpInside];
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
- (void)startLocalGame { [self runNativeGame:YES]; }
- (void)localLaunchSetup {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Local launch development"
        message:@"The local route connects this app to the iPad’s development service. New shader translation is still under development."
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
- (void)runNativeGame:(BOOL)fullStartup {
    NSArray<NSString *> *arguments=NSProcessInfo.processInfo.arguments;
    self.importButton.hidden=YES;
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    NSString *directory = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *logPath = [directory stringByAppendingPathComponent:@"native-guest.log"];
    FILE *log = fopen(logPath.fileSystemRepresentation, "w");
    if (!log) { self.status.text = @"Cannot open native runtime log."; return; }
    dup2(fileno(log), STDERR_FILENO);
    dup2(fileno(log), STDOUT_FILENO);
    setvbuf(stdout, NULL, _IOLBF, 0);
    for (NSString *argument in arguments) if ([argument hasPrefix:@"--probe-run-id="]) fprintf(log,"%s\n",argument.UTF8String);
    NSString *path = guest_module_selected(self.moduleRoot,NULL);
    NSString *map = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Guest/libraries.json"];
    if (fullStartup) {
        NSString *relativeDirectory=ProfileString(@"workingDirectory"), *relativeExecutable=ProfileString(@"executable");
        NSString *game = relativeDirectory ? [directory stringByAppendingPathComponent:relativeDirectory] : nil;
        NSString *original = game && relativeExecutable ? [game stringByAppendingPathComponent:relativeExecutable] : nil;
        if (original && [NSFileManager.defaultManager fileExistsAtPath:original]) {
            path = original;
            if (chdir(game.fileSystemRepresentation)) fprintf(log,"[host] app working directory failed: %s\n",strerror(errno));
            else fprintf(log,"[host] app working directory=%s\n",game.fileSystemRepresentation);
        }
    }
    if (!path) {
        self.status.text=@"Import the original executable before running the development loader.";
        UIApplication.sharedApplication.idleTimerDisabled=NO;
        self.importButton.hidden=NO;
        return;
    }
    BOOL ok = ng_initialize(path.fileSystemRepresentation, NSBundle.mainBundle.privateFrameworksPath.fileSystemRepresentation, map.fileSystemRepresentation, log, fullStartup);
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
    if([arguments containsObject:@"--local-game-startup"]) { [self launchLocalGame];return; }
    if(arguments.count==1 && [NSFileManager.defaultManager fileExistsAtPath:[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"Guest/libraries.json"]]) {
        self.status.text=[AppDisplayName() stringByAppendingString:@"\nReady for local launch."];
        self.playButton.hidden=NO;return;
    }
#endif
    if ([arguments containsObject:@"--native-initializer"] || [arguments containsObject:@"--native-startup"]) {
        [self runNativeGame:[arguments containsObject:@"--native-startup"]];return;
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
