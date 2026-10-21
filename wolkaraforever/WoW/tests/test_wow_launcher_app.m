// Isolated UIKit fixture: our synthetic installation, no network or guest execution.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <stdatomic.h>
#import "../launcher/WoW/WoWViewController.h"
#import "../launcher/WoW/AddonManager.h"
#import "../launcher/WoW/AddonStore.h"
#import "../launcher/WoW/AddonCredentialStore.h"
#import <Security/Security.h>
#import "../launcher/WoW/Client.h"
#import "../launcher/WoW/ForeverUI.h"
#import "../launcher/WoW/Updater.h"
#import "../launcher/App/LaunchProgressView.h"
#import "../launcher/App/WolkaraForeverLog.h"
#import "../launcher/Voice/VoiceViewController.h"
#import "../launcher/Voice/VoiceTestViewController.h"
#import "wow_installation_fixture.h"

@interface TKWoWViewController (Fixture)
- (void)selectProduct:(NSDictionary *)product;
- (void)refresh;
- (void)about;
- (void)repairInstallation;
- (void)manageAddons;
- (void)manageVoice;
- (void)testVoice;
- (void)performGraphicsReset:(NSString *)directory;
- (void)render;
- (BOOL)foreverActionAllowed;
- (NSString *)foreverWorkingDirectory;
@end
@interface TKWoWAddonManagerViewController (Fixture)
- (void)done;
@end
@interface AKVoiceViewController (Fixture)
- (void)done;
@end
@interface AKVoiceTestViewController (Fixture)
- (void)done;
@end
static atomic_uint requests, revision, updates, repairs;
static atomic_bool failure, slow, interruptRepair;
static unsigned requestsBeforePopup;
static BOOL keyboardShown;
static TKFixtureLibrary *fixture;
static NSDictionary *Plan(id self, SEL selector, NSString *product, NSString *region, NSString *locale, NSError **error) {
    (void)self; (void)selector; (void)region; (void)locale;
    unsigned request=atomic_fetch_add(&requests,1);
    [NSThread sleepForTimeInterval:(request==0 || atomic_load(&slow))?0.5:0.02];
    if (atomic_load(&failure)) { if (error) *error=TKWoWError(@"Synthetic offline response"); return nil; }
    return [fixture planForProduct:product revision:atomic_load(&revision)];
}
static BOOL Update(id self, SEL selector, NSDictionary *plan, NSString *root,
                   void (^progress)(NSString *,uint64_t,uint64_t), NSError **error) {
    (void)selector; (void)plan;
    assert([root isEqual:fixture.root]);
    if([(TKWoWUpdater *)self fullVerification]) {
        atomic_fetch_add(&repairs,1);
        if(atomic_exchange(&interruptRepair,false)) { if(error)*error=TKWoWError(@"Synthetic repair interruption");return NO; }
    }
    atomic_fetch_add(&updates,1); progress(@"download",50,100);
    [fixture writeMetadata:atomic_load(&revision) duplicate:NO];
    progress(@"complete",1,1); return YES;
}
static UIView *Find(UIView *view, NSString *identifier) {
    if ([view.accessibilityIdentifier isEqual:identifier]) return view;
    for (UIView *child in view.subviews) { UIView *match=Find(child,identifier); if (match) return match; }
    return nil;
}
// What the store does, without a network and without the unzipper.
//
// The audit's open-work note: the add-on subsystem had no automated coverage at all. The
// store itself - which folders count as add-ons, what the manifest says, what happens on a
// duplicate, an incompatible TOC, a missing TOC, what removal and disabling do - is all
// offline logic, and the extractor is looked up by name at runtime, so the fixture stands in
// for it and exercises everything except the unzipping itself.
//
// The extractor it stands in for is `wolkaraforever/WoW/AddonArchive.swift`, which is ours and uses
// ZIPFoundation. Testing it would mean building that package, so it is explicitly deferred
// in development/AUDIT.md and exercised on the device instead (importing a real add-on).
@interface TKAddonArchive : NSObject
+ (BOOL)extractArchiveAtURL:(NSURL *)url toDirectoryURL:(NSURL *)destination error:(NSError **)error;
@end

@implementation TKAddonArchive
+ (BOOL)extractArchiveAtURL:(NSURL *)url toDirectoryURL:(NSURL *)destination error:(NSError **)error {
    NSString *source = [url.path stringByAppendingString:@".extracted"];
    NSFileManager *files = NSFileManager.defaultManager;
    if (![files fileExistsAtPath:source]) {
        if (error) *error = [NSError errorWithDomain:@"test" code:1
                                            userInfo:@{NSLocalizedDescriptionKey: @"no such archive"}];
        return NO;
    }
    // The destination is the extractor's to create: the store makes the job directory and
    // leaves the extraction directory to whoever is doing the extracting.
    [files createDirectoryAtPath:destination.path withIntermediateDirectories:YES attributes:nil error:NULL];
    for (NSString *name in [files contentsOfDirectoryAtPath:source error:NULL]) {
        if (![files copyItemAtPath:[source stringByAppendingPathComponent:name]
                            toPath:[destination.path stringByAppendingPathComponent:name]
                             error:error]) return NO;
    }
    return YES;
}
@end

// The production backup component is Swift (ForeverUIArchive.swift) and is
// compiled into the app, not into this Objective-C fixture. The controller
// reaches it by name, so the fixture supplies a stand-in with the same
// selectors: the UI, the confirmation flow, the guard rails and the config
// writes are exercised here, and the real ZIP writer/restorer has its own
// targeted Swift test (tests/test_forever_ui_archive.swift).
static int stubBackups, stubRestores;
static NSString *stubNewest;
static NSString *stubLastRestored;
static NSMutableArray<NSString *> *stubNames;
@interface TKForeverUIArchive : NSObject
@end
@implementation TKForeverUIArchive
+ (NSString *)createBackupInWorkingDirectory:(NSString *)directory edition:(NSString *)edition error:(NSError **)error {
    (void)edition; (void)error;
    NSString *backups = [directory stringByAppendingPathComponent:@"WTF/Backups"];
    [NSFileManager.defaultManager createDirectoryAtPath:backups withIntermediateDirectories:YES attributes:nil error:NULL];
    stubBackups++;
    NSString *name = [NSString stringWithFormat:@"WoW-UI-2026-10-21T00-00-%02dZ.zip", stubBackups];
    assert([[@"stub snapshot" dataUsingEncoding:NSUTF8StringEncoding]
        writeToFile:[backups stringByAppendingPathComponent:name] atomically:YES]);
    stubNewest = name;
    if (!stubNames) stubNames = [NSMutableArray new];
    [stubNames addObject:name];
    return name;
}
+ (NSString *)newestBackupInWorkingDirectory:(NSString *)directory error:(NSError **)error {
    (void)directory;
    if (!stubNewest) {
        if (error) *error = [NSError errorWithDomain:@"test" code:1
            userInfo:@{NSLocalizedDescriptionKey: @"No complete backup was found. Run Backup first."}];
        return nil;
    }
    return stubNewest;
}
+ (BOOL)restoreBackupNamed:(NSString *)name inWorkingDirectory:(NSString *)directory edition:(NSString *)edition error:(NSError **)error {
    (void)directory; (void)edition; (void)error;
    assert([stubNames containsObject:name]);
    stubLastRestored = name;
    stubRestores++;
    return YES;
}
+ (BOOL)recoverInterruptedRestoreInWorkingDirectory:(NSString *)directory error:(NSError **)error {
    (void)directory; (void)error;
    return YES;
}
@end

// The record the store is currently holding for the package we imported. Each mutation
// reloads, so the object held before one is not the object to pass to the next - which is
// also what the launcher's own table has to do.
static TKAddonRecord *ManagedRecord(TKAddonStore *store) {
    for (TKAddonRecord *record in store.records) if (record.managed) return record;
    return nil;
}

static void WriteFile(NSString *path, NSString *contents) {
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                            withIntermediateDirectories:YES attributes:nil error:NULL];
    [contents writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

static void TestAddons(void) {
    NSFileManager *files = NSFileManager.defaultManager;
    NSString *root = [NSTemporaryDirectory() stringByAppendingPathComponent:@"wow-addon-tests"];
    [files removeItemAtPath:root error:NULL];
    NSString *addons = [root stringByAppendingPathComponent:@"Interface/AddOns"];

    // --- what counts as an add-on
    WriteFile([addons stringByAppendingPathComponent:@"MyAddon/MyAddon.toc"],
              @"## Title: My Addon\n## Version: 1.2.3\n## Interface: 16001\n");
    WriteFile([addons stringByAppendingPathComponent:@"MyAddon/core.lua"], @"-- lua\n");
    WriteFile([addons stringByAppendingPathComponent:@"NoTOC/readme.txt"], @"nothing here\n");
    WriteFile([addons stringByAppendingPathComponent:@"stray.txt"], @"not a folder\n");
    WriteFile([addons stringByAppendingPathComponent:@".hidden/Hidden.toc"], @"## Title: Hidden\n");

    NSArray<TKWoWAddon *> *found = TKWoWAddonsAtDirectory(addons);
    assert(found.count == 1);
    assert([found[0].title isEqualToString:@"My Addon"]);
    assert([found[0].version isEqualToString:@"1.2.3"]);
    assert(found[0].fileCount == 2);   // the .toc and the .lua, and not the directory itself

    // --- the store: import, keep a manifest, refuse a duplicate
    // The version AddonManager.m builds the store with. It is a constant inside that file,
    // so the fixture names it here rather than reaching into it.
    TKAddonStore *store = [[TKAddonStore alloc] initWithAddOnsDirectory:addons
                                                                product:@"wow_classic_beta"
                                                            gameVersion:@"1.60.1"];
    [store reload];
    assert(store.records.count == 1);
    assert([store.records[0].source isEqualToString:@"Existing"]);
    assert(!store.records[0].managed);   // found in the folder, not imported by us
    assert(store.records[0].pinned == NO);

    // The archive file the store reads and hashes, and beside it what the extractor would
    // have produced from it.
    NSString *package = [root stringByAppendingPathComponent:@"package.zip"];
    WriteFile(package, @"PK\x03\x04 not really a zip, but a real file\n");
    WriteFile([root stringByAppendingPathComponent:@"package.zip.extracted/Imported/Imported.toc"],
              @"## Title: Imported Addon\n## Version: 9.9\n## Interface: 16001\n");
    WriteFile([root stringByAppendingPathComponent:@"package.zip.extracted/Imported/extra.lua"], @"-- lua\n");
    NSError *error = nil;
    BOOL importedOK = [store importZIPAtURL:[NSURL fileURLWithPath:package] error:&error];
    if (!importedOK) NSLog(@"ADDON_IMPORT_FAILED: %@", error.localizedDescription);
    assert(importedOK);

    TKAddonRecord *imported = ManagedRecord(store);
    assert(imported != nil);
    assert([imported.name isEqualToString:@"Imported Addon"]);
    assert([imported.version isEqualToString:@"9.9"]);
    assert([imported.source isEqualToString:@"WolkaraForever import"]);
    assert([files fileExistsAtPath:[addons stringByAppendingPathComponent:@"Imported/Imported.toc"]]);
    assert([files fileExistsAtPath:[addons stringByAppendingPathComponent:@".wolkaraforever-addons.json"]]);

    // The same package twice: refused, and the first copy is *untouched*. It was not: the
    // store's failure cleanup removed every folder in the import, and the duplicate check
    // returns through that path, so asking to install an add-on you already have deleted the
    // one you had. Found by this fixture, which is the coverage the audit asked for.
    error = nil;
    assert(![store importZIPAtURL:[NSURL fileURLWithPath:package] error:&error]);
    assert([error.localizedDescription containsString:@"already exists"]);
    assert([files fileExistsAtPath:[addons stringByAppendingPathComponent:@"Imported/Imported.toc"]]);
    assert([files fileExistsAtPath:[addons stringByAppendingPathComponent:@"Imported/extra.lua"]]);
    assert(ManagedRecord(store) != nil);

    // A package with no TOC anywhere: refused with something a person can act on.
    NSString *tocless = [root stringByAppendingPathComponent:@"tocless.zip"];
    WriteFile(tocless, @"PK\x03\x04 no toc inside\n");
    WriteFile([root stringByAppendingPathComponent:@"tocless.zip.extracted/Whatever/notes.txt"], @"no toc\n");
    error = nil;
    assert(![store importZIPAtURL:[NSURL fileURLWithPath:tocless] error:&error]);
    assert([error.localizedDescription containsString:@"no add-on folder"]);

    // And an archive the extractor cannot read at all.
    error = nil;
    assert(![store importZIPAtURL:[NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"nope"]] error:&error]);
    assert(error != nil);

    // --- pinning, disabling, removing
    error = nil;
    BOOL pinnedOK = [store setPinned:YES record:imported error:&error];
    if (!pinnedOK) NSLog(@"ADDON_PIN_FAILED: %@", error.localizedDescription);
    assert(pinnedOK);
    assert(ManagedRecord(store).pinned);

    error = nil;
    BOOL disabledOK = [store setDisabled:YES record:ManagedRecord(store) error:&error];
    if (!disabledOK) NSLog(@"ADDON_DISABLE_FAILED: %@", error.localizedDescription);
    assert(disabledOK);
    // A disabled package keeps its record, so the user can turn it back on.
    TKAddonRecord *disabled = nil;
    for (TKAddonRecord *record in store.records) if ([record.identifier isEqualToString:@"Imported"]) disabled = record;
    assert(disabled != nil && disabled.disabled);

    error = nil;
    assert([store setDisabled:NO record:disabled error:&error]);

    error = nil;
    BOOL removedOK = [store removeRecord:ManagedRecord(store) error:&error];
    if (!removedOK) NSLog(@"ADDON_REMOVE_FAILED: %@", error.localizedDescription);
    assert(removedOK);
    assert(![files fileExistsAtPath:[addons stringByAppendingPathComponent:@"Imported"]]);
    assert(store.records.count == 1);   // only the one that was already there

    // An add-on this store did not install is not its to remove.
    error = nil;
    TKAddonRecord *existing = store.records[0];
    assert(![store removeRecord:existing error:&error]);
    assert([files fileExistsAtPath:[addons stringByAppendingPathComponent:@"MyAddon"]]);

    // --- the key
    TKAddonCredentialStore *credentials = [TKAddonCredentialStore new];
    assert([credentials curseForgeKey:NULL] == nil || [[credentials curseForgeKey:NULL] isKindOfClass:NSString.class]);
    NSError *keyError = nil;
    // This fixture is ad-hoc signed with no entitlements, so the keychain refuses it with
    // errSecMissingEntitlement (-34018). That is the fixture's limit, not the store's: the app
    // carries the keychain access group, and the round trip is exercised on the device. What
    // can and must be checked here is that a keychain which says no is *reported*: a key that
    // was not stored must never look stored.
    BOOL stored = [credentials storeCurseForgeKey:@"test-key-not-a-real-one" error:&keyError];
    if (stored) {
        assert([[credentials curseForgeKey:NULL] isEqualToString:@"test-key-not-a-real-one"]);
        assert([credentials removeCurseForgeKey:NULL]);
        assert([credentials curseForgeKey:NULL] == nil);
    } else {
        assert(keyError != nil);
        assert([credentials curseForgeKey:NULL] == nil);
        assert(keyError.code == errSecMissingEntitlement);
    }

    [files removeItemAtPath:root error:NULL];
}

@interface TKWoWFixtureDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic) UIWindow *window;
@property(nonatomic) TKWoWViewController *controller;
@property(nonatomic) UIWindow *probeWindow;
@property(nonatomic) UISearchBar *probeSearch;
@property(nonatomic) UITextField *probePlain;
@property(nonatomic) UIViewController *probeHost;
@property(nonatomic) TKWoWAddonManagerViewController *probeManager;
@property(nonatomic) NSUInteger launches, setups;
- (UIButton *)row:(NSString *)identifier;
@end
@implementation TKWoWFixtureDelegate
- (UIButton *)primary { return (id)Find(self.controller.view,@"wow.primary"); }
- (NSString *)status { return [(UILabel *)Find(self.controller.view,@"wow.status") text]; }
- (void)tap { [[self primary] sendActionsForControlEvents:UIControlEventTouchUpInside]; }
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    // The same log the app keeps. An assertion or a signal in this fixture used to
    // leave the console as the only record, and the console is a stream: whatever it
    // said was gone the moment the run ended. Now it is in Documents/wolkaraforever.log,
    // with the reason and the stack, and it can be read afterwards.
    WKLogStart();
    WKLog("test", @"fixture starting");
    method_setImplementation(class_getInstanceMethod(TKWoWClient.class,@selector(planForProduct:region:locale:error:)),(IMP)Plan);
    method_setImplementation(class_getInstanceMethod(TKWoWUpdater.class,@selector(updatePlan:root:progress:error:)),(IMP)Update);
    [NSUserDefaults.standardUserDefaults setObject:@"wow_classic_beta" forKey:@"WoWProduct"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WoWRepairRequested.wow_classic_beta"];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"WoWInstallRequested.wow_classic_beta"];
    // Device language must not change this fork's English launcher UI.
    [NSUserDefaults.standardUserDefaults setObject:@[@"es-ES"] forKey:@"AppleLanguages"];
    if (![NSProcessInfo.processInfo.arguments containsObject:@"--preview"]) dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        fprintf(stderr,"WoW UIKit TIMEOUT\n"); _Exit(1);
    });
    // Watching for the software keyboard tells a shim-level input block apart
    // from a manager that never focuses its search field.
    [NSNotificationCenter.defaultCenter addObserverForName:UIKeyboardDidShowNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; keyboardShown=YES; }];
    fixture=[TKFixtureLibrary new];
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.controller=[[TKWoWViewController alloc] initWithLibrary:(id)fixture];
    __weak TKWoWFixtureDelegate *weakSelf=self;
    self.controller.startApp=^(TKApp *app) { assert(app==(id)fixture.apps[0]); weakSelf.launches++; };
    self.controller.executionMode=TKExecutionModeDeveloperService;
    self.window.rootViewController=[[UINavigationController alloc] initWithRootViewController:self.controller];
    [self.window makeKeyAndVisible];
    [self performSelector:@selector(changeSelection) withObject:nil afterDelay:0.1];
}
- (void)changeSelection {
    [self.controller selectProduct:TKWoWProducts()[1]];
    [self performSelector:@selector(checkSelection) withObject:nil afterDelay:0.8];
}
- (void)checkSelection {
    assert([self primary].enabled);
    assert([[(UIButton *)Find(self.controller.view,@"wow.edition") configuration].title containsString:@"Classic Era"]);
    assert([[(UILabel *)Find(self.controller.view,@"wow.version") text] containsString:@"demo"]);
    [self.controller selectProduct:TKWoWProducts()[0]];
    [self performSelector:@selector(checkReady) withObject:nil afterDelay:0.3];
}
- (void)checkReady {
    // The add-on subsystem first: it needs no network and no launcher, and it was the one
    // part the audit listed as having no automated coverage at all.
    TestAddons();
    assert([self primary].enabled);
    assert([[self status] isEqual:@"Ready to play"] && self.controller.title.length==0);
    // The mark is the artwork when the asset catalog reaches the build, and the
    // wordmark when it does not. Either is a pass; neither is not.
    assert(Find(self.controller.view,@"wow.logo") || Find(self.controller.view,@"wow.title"));
    // The manager must construct its table header before a device user can
    // reach any add-on action; this caught a live iPad constraint crash.
    TKWoWAddonManagerViewController *manager=[[TKWoWAddonManagerViewController alloc] initWithAddOnsDirectory:NSTemporaryDirectory() edition:@"Forever · Beta"];
    [manager loadViewIfNeeded];
    [manager.view layoutIfNeeded];
    assert(manager.tableView.tableHeaderView.bounds.size.height==178);
    // The launcher opens the manager over itself as a popup now, so the path to
    // reproduce is a presentation. Loading the manager's view during it must not
    // raise, and its search field must be hit-testable and able to take first
    // responder (a device report said tapping it did nothing).
    UIWindow *probe=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)self.window.windowScene];
    probe.frame=self.window.bounds;
    UIViewController *probeHost=[UIViewController new];
    UINavigationController *probeNavigation=[[UINavigationController alloc] initWithRootViewController:probeHost];
    probe.rootViewController=probeNavigation;
    [probe makeKeyAndVisible];
    TKWoWAddonManagerViewController *pushed=[[TKWoWAddonManagerViewController alloc] initWithAddOnsDirectory:NSTemporaryDirectory() edition:@"Forever · Beta"];
    UINavigationController *probeFrame=[[UINavigationController alloc] initWithRootViewController:pushed];
    probeFrame.modalPresentationStyle=UIModalPresentationPageSheet;
    [probeHost presentViewController:probeFrame animated:NO completion:nil];
    assert(probeHost.presentedViewController==probeFrame);
    // A push loaded the page's view on the way in; a presentation loads it on the
    // transition instead, and the sheet only reaches its real size once the window
    // has laid out. Both are done here before anything is measured: a page measured
    // before it is on screen measures zero, which says nothing about the page.
    [pushed loadViewIfNeeded];
    [probeFrame.view layoutIfNeeded];
    [probe layoutIfNeeded];
    self.probeHost=probeHost;
    self.probeManager=pushed;
    self.probeWindow=probe;
    // Measured in the next turn, not here. A sheet is still being placed while it is
    // being presented, and hit-testing a view that UIKit is in the middle of moving
    // answers a question nobody has: measured too early, the search field hits the
    // transition view and looks broken when it is not.
    [self performSelector:@selector(checkAddonsSearch) withObject:nil afterDelay:0.6];
    return;
}
- (void)checkAddonsSearch {
    UIWindow *probe=self.probeWindow;
    [probe layoutIfNeeded];
    UISearchBar *search=(id)[self.probeManager valueForKey:@"search"];
    assert(search!=nil && search.frame.size.height>0);
    [search layoutIfNeeded];
    CGPoint centre=[search convertPoint:CGPointMake(CGRectGetMidX(search.bounds),CGRectGetMidY(search.bounds)) toView:probe];
    UIView *hit=[probe hitTest:centre withEvent:nil];
    NSLog(@"ADDONS_SEARCH bar=%@ centre=%@ hit=%@",
          NSStringFromCGRect(search.frame),NSStringFromCGPoint(centre),NSStringFromClass(hit.class));
    assert(hit!=nil && ([hit isDescendantOfView:search] || hit==search));
    // Control: a plain text field in the same window. If it raises no keyboard
    // either, the simulator itself has a hardware keyboard attached and only a
    // search bar that behaves differently points at our own layout.
    UITextField *plain=[[UITextField alloc] initWithFrame:CGRectMake(0,0,300,40)];
    [self.probeManager.view addSubview:plain];
    keyboardShown=NO;
    [probe makeKeyAndVisible];
    [plain becomeFirstResponder];
    self.probeSearch=search; self.probePlain=plain;
    [self performSelector:@selector(checkPlainKeyboard) withObject:nil afterDelay:0.6];
}
- (void)checkPlainKeyboard {
    NSLog(@"ADDONS_KEYBOARD_PLAIN shown=%d firstResponder=%d",keyboardShown?1:0,[self.probePlain isFirstResponder]?1:0);
    [self.probePlain resignFirstResponder];
    [self.probePlain removeFromSuperview];
    self.probePlain=nil;
    keyboardShown=NO;
    assert([self.probeSearch becomeFirstResponder]);
    [self performSelector:@selector(checkSearchKeyboard) withObject:nil afterDelay:0.6];
}
- (void)checkSearchKeyboard {
    NSLog(@"ADDONS_KEYBOARD shown=%d firstResponder=%d",keyboardShown?1:0,[self.probeSearch isFirstResponder]?1:0);
    [self.probeSearch resignFirstResponder];
    // One Done button, and it has to work on a presentation: these pages were
    // pushed once and are popups now, and a popup that cannot be closed is worse
    // than one in the wrong place.
    [self.probeManager done];
    [self performSelector:@selector(checkPopupClosed) withObject:nil afterDelay:0.6];
}
- (void)checkPopupClosed {
    assert(self.probeHost.presentedViewController==nil);
    self.probeWindow.hidden=YES; self.probeWindow.rootViewController=nil;
    self.probeWindow=nil; self.probeSearch=nil; self.probeManager=nil; self.probeHost=nil;
    // The same page on the real controller, because what matters next is what
    // closing it does to the launcher: nothing. The game files are read once per
    // launch, so opening a page over the home page and closing it must not send the
    // launcher back to the network - which is what it used to do, every time.
    requestsBeforePopup=atomic_load(&requests);
    [self.controller manageAddons];
    [self performSelector:@selector(checkAddonsPopupSettled) withObject:nil afterDelay:0.6];
}
- (void)checkAddonsPopupSettled {
    UINavigationController *frame=(id)self.controller.presentedViewController;
    assert(frame!=nil);
    // Drawn and closed only once it is actually up: dismissing a sheet that is still
    // arriving is a race, and the race is the test's fault, not the app's.
    [self.window layoutIfNeeded];
    [self capture:@"addons-popup.png"];
    [(TKWoWAddonManagerViewController *)frame.topViewController done];
    [self performSelector:@selector(checkVoiceSettingsPage) withObject:nil afterDelay:0.8];
}
// Both voice pages, opened the way the launcher opens them and drawn for the record.
// They were built out of system colours while everything around them was navy and
// gold; a screenshot is the only way to see that they are not any more.
//
// Each is opened, waited for, and only then drawn and closed. Asking a sheet to
// dismiss while it is still arriving is a race, and losing it looks exactly like a
// page that cannot be closed - which is how this fixture spent an hour lying about
// the voice page.
- (void)checkVoiceSettingsPage {
    assert(self.controller.presentedViewController==nil);
    [self.controller manageVoice];
    assert(self.controller.presentedViewController!=nil);
    [self performSelector:@selector(captureVoiceSettings) withObject:nil afterDelay:0.7];
}
- (void)captureVoiceSettings {
    UINavigationController *frame=(id)self.controller.presentedViewController;
    assert(frame!=nil && [frame.topViewController isKindOfClass:AKVoiceViewController.class]);
    [self.window layoutIfNeeded];
    [self capture:@"voice-settings.png"];
    [(AKVoiceViewController *)frame.topViewController done];
    [self performSelector:@selector(checkVoiceTestPage) withObject:nil afterDelay:0.9];
}
- (void)checkVoiceTestPage {
    assert(self.controller.presentedViewController==nil);
    [self.controller testVoice];
    assert(self.controller.presentedViewController!=nil);
    [self performSelector:@selector(captureVoiceTest) withObject:nil afterDelay:0.7];
}
- (void)captureVoiceTest {
    UINavigationController *frame=(id)self.controller.presentedViewController;
    assert(frame!=nil && [frame.topViewController isKindOfClass:AKVoiceTestViewController.class]);
    [self.window layoutIfNeeded];
    [self capture:@"voice-test.png"];
    [(AKVoiceTestViewController *)frame.topViewController done];
    [self performSelector:@selector(checkNoRecheck) withObject:nil afterDelay:0.9];
}
- (void)checkNoRecheck {
    assert(self.controller.presentedViewController==nil);
    assert(atomic_load(&requests)==requestsBeforePopup);
    // And appearing again cannot either. This is the rule itself, called directly
    // so that it does not depend on how UIKit treats a sheet: the check runs once.
    [self.controller viewDidAppear:NO];
    [self.controller viewDidAppear:NO];
    assert(atomic_load(&requests)==requestsBeforePopup);
    self.controller.executionMode=TKExecutionModeNone;
    assert(![self primary].enabled);
    self.controller.executionMode=TKExecutionModeDeveloperService;
    atomic_store(&revision,1); [self.controller refresh];
    [self performSelector:@selector(checkOutdated) withObject:nil afterDelay:0.3];
}
- (void)checkOutdated {
    assert([self primary].enabled && self.launches==0 && atomic_load(&updates)==1);
    assert(atomic_load(&repairs)==0);
    atomic_store(&interruptRepair,true);[self.controller repairInstallation];
    [self performSelector:@selector(checkRepairPaused) withObject:nil afterDelay:0.3];
}
- (void)checkRepairPaused {
    assert(atomic_load(&repairs)==1);
    assert([NSUserDefaults.standardUserDefaults boolForKey:@"WoWRepairRequested.wow_classic_beta"]);
    [self.controller refresh];
    [self performSelector:@selector(checkRepairComplete) withObject:nil afterDelay:0.3];
}
- (void)checkRepairComplete {
    assert(atomic_load(&repairs)==2 && [self primary].enabled && self.launches==0);
    assert(![NSUserDefaults.standardUserDefaults boolForKey:@"WoWRepairRequested.wow_classic_beta"]);
    atomic_store(&failure,true); [self.controller refresh];
    [self performSelector:@selector(checkOffline) withObject:nil afterDelay:0.3];
}
- (void)checkOffline {
    assert([self primary].enabled && self.launches==0);
    atomic_store(&failure,false); [self tap];
    [self performSelector:@selector(startThenBackground) withObject:nil afterDelay:0.3];
}
- (void)startThenBackground {
    assert([self primary].enabled);
    atomic_store(&slow,true); [self tap];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationWillResignActiveNotification object:nil];
    [self performSelector:@selector(checkCancellation) withObject:nil afterDelay:0.7];
}
- (void)checkCancellation {
    assert(self.launches==0); atomic_store(&slow,false); [self.controller refresh];
    [self performSelector:@selector(captureAndLaunch) withObject:nil afterDelay:0.3];
}
- (void)captureAndLaunch {
    assert([self primary].enabled);
    [self.window layoutIfNeeded];
    CGRect button=[[self primary] convertRect:[self primary].bounds toView:self.window];
    assert(CGRectContainsRect(self.window.bounds,button));
    UILabel *label=(id)Find(self.controller.view,@"wow.status");
    CGRect text=[label textRectForBounds:label.bounds limitedToNumberOfLines:label.numberOfLines];
    NSLog(@"DESCENDER_METRICS: frame=%@ text=%@ lineHeight=%g ascender=%g descender=%g",NSStringFromCGRect(label.frame),NSStringFromCGRect(text),label.font.lineHeight,label.font.ascender,label.font.descender);
    assert(label.bounds.size.height + 0.01 >= label.font.lineHeight);
    assert(text.origin.y >= 0 && CGRectGetMaxY(text) <= label.bounds.size.height + 0.5);
    self.controller.traitOverrides.preferredContentSizeCategory=UIContentSizeCategoryAccessibilityExtraExtraExtraLarge;
    [self performSelector:@selector(captureLargeText) withObject:nil afterDelay:0.3];
}
- (void)captureLargeText {
    [self.window layoutIfNeeded];
    UILabel *label=(id)Find(self.controller.view,@"wow.status");
    assert(label.bounds.size.height + 0.01 >= label.font.lineHeight);
    assert(CGRectGetMaxY([label textRectForBounds:label.bounds limitedToNumberOfLines:label.numberOfLines]) <= label.bounds.size.height + 0.5);
    UIScrollView *scroll=(id)Find(self.controller.view,@"wow.scroll");
    [scroll scrollRectToVisible:[label convertRect:label.bounds toView:scroll] animated:NO];
    [self capture:@"wow-home-large-text.png"];
    self.controller.traitOverrides.preferredContentSizeCategory=UIContentSizeCategoryLarge;
    [self performSelector:@selector(captureDefaultText) withObject:nil afterDelay:0.3];
}
- (void)captureDefaultText {
    [self.window layoutIfNeeded];
    UIScrollView *scroll=(id)Find(self.controller.view,@"wow.scroll");
    scroll.contentOffset=CGPointZero;
    [self capture:@"wow-home.png"];
    [self tap]; [self performSelector:@selector(checkLaunch) withObject:nil afterDelay:0.3];
}
- (void)capture:(NSString *)name {
    [self.window layoutIfNeeded];
    UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc] initWithBounds:self.window.bounds];
    UIImage *image=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        (void)context; [self.window drawViewHierarchyInRect:self.window.bounds afterScreenUpdates:YES];
    }];
    NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    assert([UIImagePNGRepresentation(image) writeToFile:[documents stringByAppendingPathComponent:name] atomically:YES]);
}
#pragma mark - The home page's contract, and the Forever UI rows

- (UIButton *)row:(NSString *)identifier { return (id)Find(self.controller.view, identifier); }
- (void)dismissPresented {
    UIViewController *presented = self.controller.presentedViewController;
    if (presented) [self.controller dismissViewControllerAnimated:NO completion:nil];
}
- (NSString *)configText {
    return [NSString stringWithContentsOfFile:[fixture.directory stringByAppendingPathComponent:@"WTF/Config.wtf"]
                                     encoding:NSUTF8StringEncoding error:NULL];
}
- (NSUInteger)gamepadAssignments:(NSString *)text enabled:(BOOL *)enabled {
    NSUInteger count = 0; BOOL on = NO;
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (![trimmed.uppercaseString hasPrefix:@"SET GAMEPADENABLE"]) continue;
        count++; on = [trimmed containsString:@"\"1\""];
    }
    if (enabled) *enabled = on;
    return count;
}
- (void)startPerformanceTests {
    // A synthetic Forever installation with a configuration that has every
    // category the reset must keep, and duplicate GamePadEnable assignments for
    // the gamepad row to normalise.
    NSString *wtf = [fixture.directory stringByAppendingPathComponent:@"WTF"];
    WriteFile([wtf stringByAppendingPathComponent:@"Config.wtf"],
        @"SET portal \"eu\"\n"
         "SET textLocale \"enUS\"\n"
         "SET audioLocale \"enUS\"\n"
         "SET accountName \"TESTACCOUNT\"\n"
         "SET gxResolution \"1920x1080\"\n"
         "SET graphicsQuality \"7\"\n"
         "SET Sound_OutputDriverIndex \"0\"\n"
         "SET GamePadEnable \"0\"\n"
         "SET GamePadEnable \"0\"\n"
         "SET GamePadConfig \"Addons\"\n"
         "SET uiScale \"1\"\n"
         "SET unknownSetting \"keep\"\n"
         "SET cameraDistance \"1.5\"\n");
    WriteFile([fixture.directory stringByAppendingPathComponent:@"Interface/AddOns/Fixture/Fixture.toc"],
              @"## Title: Fixture\n## Version: 1\n");

    // The touch layout store, seeded so the overlay row's read-modify-write can
    // be proven to keep every other value.
    [NSUserDefaults.standardUserDefaults setObject:@{@"opacity":@0.4, @"rearScale":@1.2,
        @"frontScale":@1.1, @"hapticsEnabled":@NO,
        @"positions":@{@"menu":@[@0.1, @0.2]}} forKey:@"WolkaraForeverTouchLayoutV1"];

    [self.controller render];
    [self.window layoutIfNeeded];

    // --- headings, in the order the page is read
    NSArray *headings = @[@[@"wow.heading.edition", @"GAME EDITION"],
                          @[@"wow.heading.addons", @"ADD-ON MANAGER"],
                          @[@"wow.heading.voice", @"VOICE MANAGER"],
                          @[@"wow.heading.performance", @"PERFORMANCE & UI MANAGER"]];
    for (NSArray *pair in headings) {
        UILabel *label = (id)Find(self.controller.view, pair[0]);
        assert(label != nil && [label.text isEqual:pair[1]]);
    }
    // --- the left column's exact order
    UIStackView *columns = (id)[self.controller valueForKey:@"_columns"];
    assert(columns != nil);
    UIStackView *left = columns.arrangedSubviews.firstObject;
    NSMutableArray *order = [NSMutableArray new];
    for (UIView *view in left.arrangedSubviews) [order addObject:view.accessibilityIdentifier ?: @""];
    NSString *mark = Find(self.controller.view, @"wow.logo") ? @"wow.logo" : @"wow.title";
    NSArray *expectedOrder = @[mark,
        @"wow.heading.edition", @"wow.edition", @"wow.preferences",
        @"wow.heading.addons", @"wow.addons.manage", @"wow.addons.macEver", @"wow.addons.directory",
        @"wow.heading.voice", @"wow.permissions", @"wow.voice", @"wow.voice.test",
        @"",
        @"wow.heading.performance", @"wow.performance.backup", @"wow.performance.reset",
        @"wow.performance.restore", @"wow.performance.gamepad", @"wow.performance.overlay",
        @"wow.performance.settingsFolder"];
    assert([order isEqualToArray:expectedOrder]);
    // --- labels, exactly
    assert([[(UIButton *)Find(self.controller.view, @"wow.addons.manage") configuration].title isEqual:@"Install Addons (Curse & Direct)"]);
    assert([[(UIButton *)Find(self.controller.view, @"wow.addons.directory") configuration].title isEqual:@"Open Add-on Directory"]);
    assert([[(UIButton *)Find(self.controller.view, @"wow.addons.macEver") configuration].title isEqual:@"Download Mac-Ever"]);
    assert([[(UIButton *)Find(self.controller.view, @"wow.permissions") configuration].title isEqual:@"Toggle Permissions (Mic & Speech)"]);
    assert([[(UIButton *)Find(self.controller.view, @"wow.voice") configuration].title isEqual:@"Key / Button Configuration"]);
    assert([[(UIButton *)Find(self.controller.view, @"wow.voice.test") configuration].title isEqual:@"Test Voice & Dictation"]);
    assert([[(UIButton *)Find(self.controller.view, @"wow.performance.backup") configuration].title isEqual:@"Backup WoW UI Configuration"]);
    assert([[(UIButton *)Find(self.controller.view, @"wow.performance.reset") configuration].title isEqual:@"Reset to Default Graphical Settings"]);
    assert([[(UIButton *)Find(self.controller.view, @"wow.performance.restore") configuration].title isEqual:@"Restore WoW UI Configuration"]);
    assert([[(UIButton *)Find(self.controller.view, @"wow.performance.gamepad") configuration].title isEqual:@"Enable Gamepad UI"]);
    assert([[(UIButton *)Find(self.controller.view, @"wow.performance.overlay") configuration].title isEqual:@"Enable Performance Overlay"]);
    assert([[(UIButton *)Find(self.controller.view, @"wow.performance.settingsFolder") configuration].title isEqual:@"Open Settings Folder"]);
    // --- enabled state on a ready, idle installation
    for (NSString *identifier in @[@"wow.performance.backup", @"wow.performance.reset",
                                   @"wow.performance.restore", @"wow.performance.gamepad",
                                   @"wow.performance.settingsFolder", @"wow.performance.overlay",
                                   @"wow.addons.manage", @"wow.voice", @"wow.voice.test",
                                   @"wow.permissions", @"wow.addons.macEver"])
        assert([self row:identifier].enabled);

    // --- Download Mac-Ever asks for exactly the CurseForge project page, and no browser opens
    __block NSURL *requested = nil;
    self.controller.openExternalURL = ^(NSURL *url) { requested = url; };
    [self row:@"wow.addons.macEver"].enabled = YES;
    [[self row:@"wow.addons.macEver"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    assert([requested.absoluteString isEqual:@"https://www.curseforge.com/wow/addons/mac-ever"]);
    self.controller.openExternalURL = nil;

    // --- the overlay row writes the shared store, keeping the layout's own values
    [[self row:@"wow.performance.overlay"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    NSDictionary *layout = [NSUserDefaults.standardUserDefaults objectForKey:@"WolkaraForeverTouchLayoutV1"];
    assert([layout[@"performanceOverlayEnabled"] boolValue]);
    assert([layout[@"opacity"] doubleValue] == 0.4 && [layout[@"rearScale"] doubleValue] == 1.2);
    NSArray *menuPoint = layout[@"positions"][@"menu"];
    assert(fabs([menuPoint[1] doubleValue] - 0.2) < 0.001);
    assert([[(UIButton *)Find(self.controller.view, @"wow.performance.overlay") configuration].title isEqual:@"Performance Overlay Enabled"]);
    [[self row:@"wow.performance.overlay"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    assert(![[NSUserDefaults.standardUserDefaults objectForKey:@"WolkaraForeverTouchLayoutV1"][@"performanceOverlayEnabled"] boolValue]);
    assert([[(UIButton *)Find(self.controller.view, @"wow.performance.overlay") configuration].title isEqual:@"Enable Performance Overlay"]);
    [[self row:@"wow.performance.overlay"] sendActionsForControlEvents:UIControlEventTouchUpInside];

    // --- Open Settings Folder opens Forever's WTF folder and changes nothing
    __block NSURL *folder = nil;
    self.controller.openSettingsFolderURL = ^(NSURL *url) { folder = url; };
    [[self row:@"wow.performance.settingsFolder"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    assert(folder != nil && [folder.lastPathComponent isEqual:@"WTF"]);
    assert([folder.path hasPrefix:fixture.directory]);
    self.controller.openSettingsFolderURL = nil;
    [self performSelector:@selector(checkFolderPicker) withObject:nil afterDelay:0.4];
}
- (void)checkFolderPicker {
    // --- nothing backed up yet: Restore says so instead of claiming success
    [[self row:@"wow.performance.restore"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    [self performSelector:@selector(checkNoBackupYet) withObject:nil afterDelay:0.5];
}
- (void)checkNoBackupYet {
    UIAlertController *alert = (id)self.controller.presentedViewController;
    assert([alert isKindOfClass:UIAlertController.class]);
    assert([alert.title isEqual:@"No backup to restore"]);
    assert([alert.message containsString:@"Backup"]);
    [self dismissPresented];
    assert(stubBackups == 0 && stubRestores == 0);
    [[self row:@"wow.performance.backup"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    [self performSelector:@selector(checkBackup) withObject:nil afterDelay:0.5];
}
static NSString *configBeforeReset;
- (void)checkBackup {
    UIAlertController *alert = (id)self.controller.presentedViewController;
    assert([alert isKindOfClass:UIAlertController.class]);
    assert([alert.title isEqual:@"Backup complete"]);
    assert([alert.message containsString:@"WTF/Backups"]);
    assert(stubBackups == 1);
    assert([NSFileManager.defaultManager fileExistsAtPath:
        [fixture.directory stringByAppendingPathComponent:[@"WTF/Backups" stringByAppendingPathComponent:stubNewest]]]);
    [self dismissPresented];
    configBeforeReset = [self configText];
    // --- the destructive row is confirmed first, and cancelling changes nothing
    [self performSelector:@selector(tapReset) withObject:nil afterDelay:0.4];
}
- (void)tapReset {
    [[self row:@"wow.performance.reset"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    [self performSelector:@selector(checkResetConfirmation) withObject:nil afterDelay:0.5];
}
- (void)checkResetConfirmation {
    UIAlertController *alert = (id)self.controller.presentedViewController;
    assert([alert isKindOfClass:UIAlertController.class]);
    assert([alert.title isEqual:@"Reset to default graphics settings?"]);
    assert([alert.message containsString:@"backup"]);
    [self dismissPresented];
    assert([[self configText] isEqual:configBeforeReset]);
    [self performSelector:@selector(performConfirmedReset) withObject:nil afterDelay:0.4];
}
- (void)performConfirmedReset {
    // The same path the confirmed action takes; the sheet above is the gate.
    [self.controller performGraphicsReset:fixture.directory];
    [self performSelector:@selector(checkReset) withObject:nil afterDelay:0.6];
}
- (void)checkReset {
    UIAlertController *alert = (id)self.controller.presentedViewController;
    assert([alert isKindOfClass:UIAlertController.class]);
    assert([alert.title isEqual:@"Graphics reset"]);
    assert([alert.message containsString:@"when Forever next launches"]);
    assert(stubBackups == 2);   // the reset made its own rollback point
    [self dismissPresented];
    NSString *config = [self configText];
    assert(![config containsString:@"SET gxResolution"]);
    assert(![config containsString:@"SET graphicsQuality"]);
    for (NSString *kept in @[@"SET portal \"eu\"", @"SET textLocale \"enUS\"", @"SET audioLocale \"enUS\"",
                             @"SET accountName \"TESTACCOUNT\"", @"SET Sound_OutputDriverIndex \"0\"",
                             @"SET GamePadEnable", @"SET GamePadConfig \"Addons\"", @"SET uiScale \"1\"",
                             @"SET unknownSetting \"keep\"", @"SET cameraDistance \"1.5\""])
        assert([config containsString:kept]);
    [self performSelector:@selector(tapGamepad) withObject:nil afterDelay:0.4];
}
- (void)tapGamepad {
    [[self row:@"wow.performance.gamepad"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    [self performSelector:@selector(checkGamepad) withObject:nil afterDelay:0.5];
}
- (void)checkGamepad {
    UIAlertController *alert = (id)self.controller.presentedViewController;
    assert([alert isKindOfClass:UIAlertController.class]);
    assert([alert.title isEqual:@"Gamepad UI enabled"]);
    [self dismissPresented];
    NSString *config = [self configText];
    BOOL enabled = NO;
    assert([self gamepadAssignments:config enabled:&enabled] == 1 && enabled);
    assert([config containsString:@"SET accountName \"TESTACCOUNT\""]);
    assert([[(UIButton *)Find(self.controller.view, @"wow.performance.gamepad") configuration].title isEqual:@"Gamepad UI Enabled"]);
    [self performSelector:@selector(tapRestore) withObject:nil afterDelay:0.4];
}
- (void)tapRestore {
    [[self row:@"wow.performance.restore"] sendActionsForControlEvents:UIControlEventTouchUpInside];
    [self performSelector:@selector(checkRestore) withObject:nil afterDelay:0.6];
}
- (void)checkRestore {
    UIAlertController *alert = (id)self.controller.presentedViewController;
    assert([alert isKindOfClass:UIAlertController.class]);
    assert([alert.title isEqual:@"Restore complete"]);
    assert([alert.message containsString:stubLastRestored]);
    assert(stubRestores == 1);
    assert(stubBackups == 3);   // restore snapshotted the current state first
    [self dismissPresented];
    puts("WoW UIKit PASS: automatic check/update, offline retry, edition race, background cancellation, verified launch, inline preparation/failure/session end, no duplicate launches and bundled licenses; home page headings, rows, order, identifiers, labels, enabled states and Mac-Ever URL; backup, confirmed reset, gamepad config, folder picker and restore flow.");
    fflush(stdout);
    if (![NSProcessInfo.processInfo.arguments containsObject:@"--preview"]) exit(0);
    // Leave a ready home for visual inspection; no real download or guest runs.
    [self.controller refresh];
}

- (void)checkLaunch {
    assert(self.launches==1); self.controller.sessionUsed=YES;
    [self.controller beginStartup];
    self.controller.startupStatusLabel.text=@"Preparing to run. This can take a few minutes. Keep this app open.";
    assert(![self primary].enabled && !self.controller.launchProgress.hidden);
    assert([[self status] isEqual:@"Starting…"]);
    // The Forever file rows are disabled while a start is in progress; every
    // handler rechecks the same guard.
    for (NSString *identifier in @[@"wow.performance.backup", @"wow.performance.reset",
                                   @"wow.performance.restore", @"wow.performance.gamepad",
                                   @"wow.performance.settingsFolder", @"wow.performance.overlay"])
        assert(![self row:identifier].enabled);
    assert(self.controller.navigationController.viewControllers.count==1);
    unsigned before=atomic_load(&requests);
    [self.controller refresh]; [self tap];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidBecomeActiveNotification object:nil];
    assert(atomic_load(&requests)==before && self.launches==1);
    [self capture:@"wow-starting.png"];
    [self.controller finishStartupWithMessage:@"Synthetic startup failure" failed:YES];
    assert([[self status] isEqual:@"Could not start"] && ![self primary].enabled);
    assert(self.controller.launchProgress.hidden && !self.controller.diagnosticsButton.hidden);
    [self capture:@"wow-startup-failed.png"];
    [self.controller finishStartupWithMessage:@"Session ended" failed:NO];
    assert(![self primary].enabled && self.controller.diagnosticsButton.hidden);
    // A recoverable preflight error must leave another attempt possible.
    self.controller.sessionUsed=NO;
    [self.controller beginStartup];
    [self.controller finishStartupWithMessage:@"Synthetic missing container" failed:YES];
    assert([self primary].enabled);
    [self.controller about];
    UITextView *credits=(id)self.controller.navigationController.topViewController.view;
    // Our own notice, which carries the licences of what the launcher's readers adapt.
    assert([credits.text containsString:@"Vasilii Kharitonov"]);
    assert([credits.text containsString:@"Permission is hereby granted"]);
    assert([credits.text containsString:@"Martin Benjamins"]);
    // Upstream's, which has to be there too: the app ships upstream's code.
    assert([credits.text containsString:@"Tolkara is original work released under the MIT License"]);
    // And the page says whose each one is, rather than concatenating whatever it found.
    assert([credits.text containsString:@"WolkaraForever — this app's licence"]);
    assert([credits.text containsString:@"Tolkara — the platform this app is built on"]);
    // A document the build forgot must be named on the page, not skipped: silence is how
    // this went unnoticed in the first place.
    assert(![credits.text containsString:@"missing from this build"]);
    [self.controller.navigationController popToRootViewControllerAnimated:NO];
    // Finally the home page's own contract, on a ready installation.
    [self performSelector:@selector(startPerformanceTests) withObject:nil afterDelay:0.3];
}

@end
@interface TKWoWFixtureApp : UIResponder <UIApplicationDelegate>
@end
@implementation TKWoWFixtureApp
- (UISceneConfiguration *)application:(UIApplication *)app configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)app; (void)options;
    UISceneConfiguration *config=[[UISceneConfiguration alloc] initWithName:@"WoW fixture" sessionRole:session.role];
    config.delegateClass=TKWoWFixtureDelegate.class; return config;
}
@end
int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(TKWoWFixtureApp.class)); }
}
