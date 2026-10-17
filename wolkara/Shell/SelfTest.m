// Wolkara: the self-tests the app runs on itself, on the device. See SelfTest.h for why.
//
// Two habits are kept everywhere below, because a self-test that lies is worse than none:
// every check says what it is checking, and the app reports which case it actually hit rather
// than the case that would be most flattering. The speech checks, for instance, say whether a
// microphone was opened at all.

#import "SelfTest.h"
#import "WolkaraLog.h"
#import "../Input/InputElement.h"
#import "../Input/InputRouter.h"
#import "../Input/Trigger.h"
#import "../Voice/Dictation.h"
#import "../Voice/VoiceSettings.h"
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

NSString *const AKSelfTestInput = @"input";
NSString *const AKSelfTestVoice = @"voice";

#pragma mark - Recording what happened

// One check at a time, logged as it runs, so the app's own log reads like a fixture's output
// and the first thing that was wrong is the thing the verdict names.
@interface AKSelfTestRecorder : NSObject
@property (nonatomic) NSUInteger passed;
@property (nonatomic) NSUInteger total;
@property (nonatomic, copy, nullable) NSString *firstFailure;
@property (nonatomic, copy) NSString *detail;
- (void)check:(BOOL)condition _:(NSString *)what;
@end

@implementation AKSelfTestRecorder
- (void)check:(BOOL)condition _:(NSString *)what {
    self.total++;
    if (condition) {
        self.passed++;
        WKLog("selftest", @"ok   %@", what);
        return;
    }
    if (!self.firstFailure) self.firstFailure = what;
    WKLog("selftest", @"FAIL %@", what);
}
@end

// Sleeps without blocking the main queue, because the main queue is where the app's own callbacks
// arrive. The first version of this pumped the run loop with `runMode:beforeDate:` instead, from
// inside a main-queue block, and that cannot work: libdispatch will not drain the main queue while
// a block from it is already running, so the speech framework's authorization callback - which the
// app deliberately dispatches to the main queue - was never delivered, and the test sat in
// Authorizing for ten seconds with the answer already waiting.
static void AKSelfTestSleep(NSTimeInterval seconds) {
    [NSThread sleepForTimeInterval:seconds];
}

// Runs a block on the main queue and waits for it, from wherever this is called. The input checks
// and the dictation calls have to be on the main queue - the router asserts it - and the voice
// checks must not be, so both exist here.
static void AKSelfTestOnMain(dispatch_block_t block) {
    if (NSThread.isMainThread) { block(); return; }
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{ block(); dispatch_semaphore_signal(done); });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
}

static BOOL AKSelfTestIsRecordingCategory(NSString *category) {
    return [category isEqualToString:AVAudioSessionCategoryRecord] ||
           [category isEqualToString:AVAudioSessionCategoryPlayAndRecord];
}

#pragma mark - Putting the user's settings back

// The self-test uses the real defaults store, because that is where the bug would be. It takes
// a copy of every key it can touch first, and puts the copy back at the end - including
// removing keys that were not there. A self-test that ate the user's mapping would be a worse
// fault than anything it looks for.
@interface AKSelfTestSettings : NSObject
- (instancetype)init;
- (void)restore;
// Every key this class saves and puts back: each stored mapping, plus the voice settings.
+ (NSArray<NSString *> *)keysToRestore;
// The keys to put back: those that were there when the snapshot was taken, plus any this test
// created afterwards. Restoring only the first set is how the first version of this left its own
// mapping behind - and the last check of the input test is what caught it, on the device.
+ (NSArray<NSString *> *)restoreKeysForSnapshot:(NSDictionary *)snapshot;
@property (nonatomic, readonly) NSDictionary *snapshot;
@end

@implementation AKSelfTestSettings {
    NSArray<NSString *> *_keys;
    NSDictionary *_snapshot;
    BOOL _enabled, _takeButtonFromGame;
    AKVoiceMode _mode;
}
+ (NSArray<NSString *> *)keysToRestore {
    NSMutableArray<NSString *> *keys = [NSMutableArray arrayWithObjects:
        @"AKVoiceEnabled", @"AKVoiceMode", @"AKVoiceAutoSubmit", @"AKVoiceTrailingSpace",
        @"AKVoiceCustomWords", @"AKVoiceTakeButtonFromGame", nil];
    for (NSString *key in NSUserDefaults.standardUserDefaults.dictionaryRepresentation.allKeys) {
        if ([key hasPrefix:@"AKInputTrigger."]) [keys addObject:key];
    }
    return keys;
}

+ (NSArray<NSString *> *)restoreKeysForSnapshot:(NSDictionary *)snapshot {
    NSMutableArray<NSString *> *keys = [[self keysToRestore] mutableCopy];
    for (NSString *key in snapshot.allKeys) if (![keys containsObject:key]) [keys addObject:key];
    return keys;
}

- (instancetype)init {
    if ((self = [super init])) {
        _keys = [AKSelfTestSettings keysToRestore];
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        NSMutableDictionary *saved = [NSMutableDictionary dictionary];
        for (NSString *key in _keys) {
            id value = [defaults objectForKey:key];
            if (value) saved[key] = value;
        }
        _snapshot = saved;
        // The three settings the app caches are put back through their setters, so the
        // in-memory copy and the store agree and the adapter is told the answer again.
        _enabled = AKVoiceSettings.shared.enabled;
        _takeButtonFromGame = AKVoiceSettings.shared.takeButtonFromGame;
        _mode = AKVoiceSettings.shared.mode;
    }
    return self;
}
- (NSDictionary *)snapshot { return _snapshot; }

- (void)restore {
    AKVoiceSettings *settings = AKVoiceSettings.shared;
    // The cached settings first: going through their setters is what tells the adapter and the
    // router that something changed.
    settings.enabled = _enabled;
    settings.takeButtonFromGame = _takeButtonFromGame;
    settings.mode = _mode;
    // The exact bytes last, because setting the mode rewrites every stored mapping - including
    // dropping fields that no longer mean anything - and the promise here is that the user's
    // store is left exactly as it was found. Writing the snapshot afterwards wins.
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in [AKSelfTestSettings restoreKeysForSnapshot:_snapshot]) {
        if (_snapshot[key]) [defaults setObject:_snapshot[key] forKey:key];
        else [defaults removeObjectForKey:key];
    }
    [AKInputRouter.shared applyMappings];
}
@end

#pragma mark - Input

// The device id the input checks use. Not a real one, so that nothing the user has mapped can
// be adopted by accident, and so that everything these checks write is removed again - which
// the last two checks are about.
static NSString *const AKSelfTestDevice = @"selftest.pad";

static void AKSelfTestRunInput(AKSelfTestRecorder *recorder) {
    // --- The matching rule, which the router fires on and ownership is decided by ---
    [recorder check:([AKTrigger element:@"controller.button.a" covers:@"controller.button.a"]) _:@"an exact element id is covered"];
    [recorder check:(![AKTrigger element:@"controller.button.a" covers:@"controller.button.b"]) _:@"and a different one is not"];
    [recorder check:([AKTrigger element:@"controller.button." covers:@"controller.button.b"]) _:@"a family covers every element in it"];
    [recorder check:(![AKTrigger element:@"controller.button." covers:@"keyboard.key.4"]) _:@"and not another kind"];
    [recorder check:([AKTrigger element:AKTriggerAnyElement covers:@"keyboard.key.4"]) _:@"any covers everything, as the learning screen means it"];

    // --- What may be stored. A mapping is the user's choice; these are the values that are
    // not a choice, and each one would be a mapping nobody made. ---
    [recorder check:([AKTrigger validatedStoredForm:@{ @"element": @"keyboard.key.70", @"pattern": @0 }] != nil) _:@"a plain mapping is stored"];
    [recorder check:([AKTrigger validatedStoredForm:@{ @"element": @"system.screenshot", @"pattern": @0 }] == nil) _:@"a system signal is never stored"];
    [recorder check:([AKTrigger validatedStoredForm:@{ @"element": AKTriggerAnyElement, @"pattern": @0 }] == nil) _:@"and neither is any"];
    [recorder check:([AKTrigger validatedStoredForm:@{ @"element": @"keyboard.key.70", @"pattern": @1 }] == nil) _:@"a retired pattern is refused"];
    [recorder check:([AKTrigger validatedStoredForm:@{ @"element": @"keyboard.key.70", @"pattern": @0.5 }] == nil) _:@"and so is a fractional one"];
    [recorder check:([AKTrigger validatedStoredForm:@{ @"element": [@"keyboard.key." stringByAppendingString:[@"" stringByPaddingToLength:200 withString:@"7" startingAtIndex:0]], @"pattern": @0 }] == nil) _:@"and an over-long element"];

    // --- Element ids are stable across the values the inspector reports, which is what makes a
    // stored mapping still mean the same button the next time. ---
    NSString *key70 = AKInputElementForKeyboardKey(70);
    [recorder check:([key70 isEqualToString:AKInputElementCanonicalized(key70)]) _:@"a key id is already canonical"];
    [recorder check:([AKInputElementCanonicalized(@"Button Share") isEqualToString:@"controller.button.share"]) _:@"a legacy name is migrated to its id"];

    // --- The router's own learning path, on a device id of its own ---
    // This id belongs to the test and to nothing else, and an earlier build of the test left
    // its key behind. Cleared first: the snapshot below would faithfully put such a leftover
    // back, and a self-test should not inherit its own litter. What the last checks are about is
    // what *this* run writes and puts back.
    [AKTrigger forgetTriggerForDevice:AKSelfTestDevice defaults:NSUserDefaults.standardUserDefaults];
    AKSelfTestSettings *settings = [[AKSelfTestSettings alloc] init];
    AKInputRouter *router = AKInputRouter.shared;
    // The shell installs these to drive dictation (main.m). They are put back at the end,
    // because a self-test that left the app unable to start dictation would be a fault rather
    // than a test. They are replaced rather than chained on purpose: chaining would have this
    // test start a real dictation session every time it feeds a press.
    void (^previousLearned)(AKTrigger *, NSString *) = router.onLearned;
    void (^previousFired)(AKTrigger *, AKInputEvent *) = router.onTrigger;
    void (^previousBegan)(AKTrigger *, AKInputEvent *) = router.onTriggerBegan;
    void (^previousEnded)(AKTrigger *, AKInputEvent *) = router.onTriggerEnded;
    [router cancelLearning];
    NSMutableArray<AKTrigger *> *adopted = [NSMutableArray array];
    router.onLearned = ^(AKTrigger *trigger, NSString *device) { [adopted addObject:trigger]; };
    [router beginLearning];
    [recorder check:router.learning _:@"the mapper arms"];
    // Reported the way the inspector reports a controller: an element, a value, a press, and
    // the device it came from. This is our own code feeding our own router - nothing is pressed
    // in any application, and no game is running while a self-test runs.
    [router reportElement:@"controller.button.a" value:1 pressed:YES device:AKSelfTestDevice source:AKInputSourceController];
    [recorder check:(adopted.count == 1) _:@"the first press that arrives is adopted"];
    [recorder check:(!router.learning) _:@"and arming ends with it"];
    [recorder check:(adopted.firstObject != nil && [adopted.firstObject.element isEqualToString:@"controller.button.a"]) _:@"as the canonical element id"];
    [router reportElement:@"controller.button.a" value:0 pressed:NO device:AKSelfTestDevice source:AKInputSourceController];

    // The router writes nothing itself - there is one owner of what is remembered - so the
    // store call below is the one the voice page makes when that callback fires. What this
    // proves is the router firing from a mapping the settings stored; that the *page* wires the
    // two together is what the simulator fixture proves.
    AKVoiceSettings *voice = AKVoiceSettings.shared;
    [voice setLearnedElement:@"controller.button.a" forDevice:AKSelfTestDevice];
    voice.enabled = YES;
    __block NSUInteger began = 0, ended = 0, fired = 0;
    router.onTriggerBegan = ^(AKTrigger *trigger, AKInputEvent *event) { began++; };
    router.onTriggerEnded = ^(AKTrigger *trigger, AKInputEvent *event) { ended++; };
    router.onTrigger = ^(AKTrigger *trigger, AKInputEvent *event) { fired++; };
    [recorder check:(voice.mode == AKVoiceModeHold) _:@"hold to talk is the mode until the user chooses otherwise"];
    [router reportElement:@"controller.button.a" value:1 pressed:YES device:AKSelfTestDevice source:AKInputSourceController];
    [router reportElement:@"controller.button.a" value:1 pressed:YES device:AKSelfTestDevice source:AKInputSourceController];
    [router reportElement:@"controller.button.a" value:0 pressed:NO device:AKSelfTestDevice source:AKInputSourceController];
    [router reportElement:@"controller.button.a" value:0 pressed:NO device:AKSelfTestDevice source:AKInputSourceController];
    [recorder check:(began == 1 && ended == 1) _:@"a held button starts dictation once and ends it once, repeat samples and all"];

    // The same mapping in the other mode fires on the press alone, which is what the mode means.
    voice.mode = AKVoiceModeToggle;
    [router reportElement:@"controller.button.a" value:1 pressed:YES device:AKSelfTestDevice source:AKInputSourceController];
    [router reportElement:@"controller.button.a" value:0 pressed:NO device:AKSelfTestDevice source:AKInputSourceController];
    [recorder check:(fired == 1) _:@"and in the other mode it fires once, on the press"];

    // --- What the adapter is told, for the switch the user can turn on ---
    // The user may already have keys of their own taken, so the comparison is against the set
    // that is published *with the switch on* before this test adds anything - not against an
    // empty set, which was wrong the first time and on a device that had keys of its own it
    // failed for the right reason.
    voice.takeButtonFromGame = YES;
    NSSet<NSNumber *> *theirs = voice.ownedKeyUsages;
    [voice setLearnedElement:@"keyboard.key.70" forDevice:AKSelfTestDevice];
    NSMutableSet<NSNumber *> *expected = [theirs mutableCopy];
    [expected addObject:@70];
    [recorder check:[voice.ownedKeyUsages isEqualToSet:expected] _:@"the key this test mapped joins exactly the keys the user had already taken"];
    [recorder check:[voice ownsElement:@"keyboard.key.70"] _:@"and the ownership decision agrees"];
    [recorder check:(![voice ownsElement:@"keyboard.key.71"]) _:@"a key the user has not taken is untouched"];
    voice.takeButtonFromGame = NO;
    [recorder check:(voice.ownedKeyUsages.count == 0) _:@"with the switch off nothing is published at all"];

    // --- The user's own settings, exactly as they were ---
    [settings restore];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *different = nil;
    for (NSString *key in [AKSelfTestSettings restoreKeysForSnapshot:settings.snapshot]) {
        id before = settings.snapshot[key];
        id after = [defaults objectForKey:key];
        if (before != after && ![before isEqual:after]) { different = key; break; }
    }
    [recorder check:(different == nil) _:[NSString stringWithFormat:@"every setting this test touched is exactly as it was%@",
        different ? [NSString stringWithFormat:@" (%@ differs)", different] : @""]];
    NSString *mappedKey = [AKTrigger defaultsKeyForDevice:AKSelfTestDevice];
    id leftBehind = [defaults objectForKey:mappedKey];
    NSMutableArray<NSString *> *remaining = [NSMutableArray array];
    for (NSString *key in defaults.dictionaryRepresentation.allKeys) {
        if ([key hasPrefix:@"AKInputTrigger."]) [remaining addObject:key];
    }
    [recorder check:(leftBehind == nil) _:[NSString stringWithFormat:@"including the mapping this test made, which is gone (key %@ = %@; stored mappings left: %@)",
        mappedKey, leftBehind ?: @"nothing", remaining.count ? [remaining componentsJoinedByString:@", "] : @"none"]];
    // With the switch off, nothing is published at all, so what "back to what it was" means
    // depends on the switch the user had - which is restored, and checked, above.
    NSSet<NSNumber *> *expectedAfterRestore = voice.takeButtonFromGame ? theirs : [NSSet set];
    [recorder check:[voice.ownedKeyUsages isEqualToSet:expectedAfterRestore] _:@"and the set published to the adapter is back to what the user's own switch allows"];
    // And the router no longer fires from it: the mapping is not merely absent from the store.
    NSUInteger quiet = fired;
    [router reportElement:@"controller.button.a" value:1 pressed:YES device:AKSelfTestDevice source:AKInputSourceController];
    [router reportElement:@"controller.button.a" value:0 pressed:NO device:AKSelfTestDevice source:AKInputSourceController];
    [recorder check:(fired == quiet) _:@"so pressing that button now does nothing at all"];
    // And the app is put back as it was found here too: the handlers the shell installed.
    router.onLearned = previousLearned;
    router.onTrigger = previousFired;
    router.onTriggerBegan = previousBegan;
    router.onTriggerEnded = previousEnded;

    recorder.detail = @"matching, the forms that may be stored, the mapper, both modes, the published key set";
}

#pragma mark - Voice

static void AKSelfTestRunVoice(AKSelfTestRecorder *recorder) {
    AKDictation *dictation = AKDictation.shared;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSString *categoryBefore = session.category;
    AKSelfTestOnMain(^{ [dictation cancel]; });
    AKSelfTestSleep(0.4);
    [recorder check:(dictation.state == AKDictationStateIdle) _:@"dictation starts idle"];
    [recorder check:(!dictation.listening) _:@"and not listening"];

    SFSpeechRecognizerAuthorizationStatus status = SFSpeechRecognizer.authorizationStatus;
    SFSpeechRecognizer *recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    BOOL onDevice = recognizer.supportsOnDeviceRecognition;
    // The app's own handler still receives every message: this wraps it rather than replacing it.
    void (^previous)(NSString *) = dictation.problemHandler;
    __block NSString *problem = nil;
    dictation.problemHandler = ^(NSString *message) { problem = message; if (previous) previous(message); };
    NSString *detail = @"";

    if (status == SFSpeechRecognizerAuthorizationStatusAuthorized && onDevice) {
        // The real path: the real recogniser, on-device recognition only, and the audio session
        // the feature actually takes. A real voice is the one thing missing here, not the code
        // path. The permission callback and the engine start are both asynchronous, so this
        // waits on the app's own state rather than for a fixed time.
        AKSelfTestOnMain(^{ [dictation begin]; });
        for (NSUInteger slice = 0; slice < 100 && dictation.state == AKDictationStateAuthorizing; slice++) {
            AKSelfTestSleep(0.1);
        }
        if (dictation.listening) {
            // `listening` is the app's own record that it got as far as opening the microphone,
            // and this is the operating system's corroboration of it.
            [recorder check:AKSelfTestIsRecordingCategory(session.category) _:@"the microphone is opened for a session started for real"];
            // The one that matters to somebody who is speaking: audio is arriving. A silent stream is
            // what iOS hands an app it has not allowed to listen, and it looks exactly like a working
            // session until the recogniser reports that it heard nothing.
            [recorder check:(dictation.buffersReceived > 0) _:[NSString stringWithFormat:@"and the microphone is delivering audio (%lu buffer(s), loudest %.3f)",
                (unsigned long)dictation.buffersReceived, dictation.inputLevel]];
            AKSelfTestOnMain(^{ [dictation cancel]; });
            AKSelfTestSleep(0.6);
            [recorder check:(dictation.state == AKDictationStateIdle) _:@"cancelling ends the session"];
            [recorder check:(!dictation.listening) _:@"and closes the microphone"];
            [recorder check:[session.category isEqualToString:categoryBefore] _:@"and puts the audio session back as it was"];
            detail = [NSString stringWithFormat:@"speech=authorized on-device=1, permission=%ld, buffers=%lu, session=record-then-restored",
                  (long)[AVAudioApplication sharedInstance].recordPermission, (unsigned long)dictation.buffersReceived];
        } else {
            // It did not open. On a device where it does not, the app must either say why or be
            // visibly still waiting on the permission callback - doing neither, silently, is the
            // fault this checks for. What would be worse, a session left open, is what the check
            // at the end of this method covers. Reporting a device that cannot open a session as
            // a failure would be blaming the wrong layer, which is why the verdict says which
            // state it reached.
            [recorder check:(problem.length > 0 || dictation.state == AKDictationStateAuthorizing)
                        _:[NSString stringWithFormat:@"a session that does not open is explained, or visibly still waiting on permission (state=%ld, problem=%@)",
                           (long)dictation.state, problem ?: @"none"]];
            [recorder check:[session.category isEqualToString:categoryBefore] _:@"and nothing was taken from the audio session"];
            detail = [NSString stringWithFormat:@"speech=authorized on-device=%d, session did not open: state=%ld, %@",
                      (int)onDevice, (long)dictation.state, problem ?: @"no reason given"];
        }
    } else if (status == SFSpeechRecognizerAuthorizationStatusNotDetermined) {
        // Permission has never been asked for. Asking now would raise a prompt with nobody in
        // front of the iPad, so the checks are the ones that hold without any session at all.
        [recorder check:(dictation.state == AKDictationStateIdle) _:@"with permission never asked for, nothing starts"];
        [recorder check:(!dictation.listening) _:@"and no microphone is taken"];
        [recorder check:[session.category isEqualToString:categoryBefore] _:@"and the audio session is untouched"];
        detail = @"speech=not-asked, nothing opened: a real voice is still the one thing missing";
    } else {
        // Refused or restricted. The app must say so and open nothing.
        AKSelfTestOnMain(^{ [dictation begin]; });
        AKSelfTestSleep(0.8);
        [recorder check:(dictation.state == AKDictationStateIdle) _:@"a refused permission leaves dictation idle"];
        [recorder check:(!dictation.listening) _:@"with the microphone closed"];
        [recorder check:[session.category isEqualToString:categoryBefore] _:@"and the audio session untouched"];
        [recorder check:(problem.length > 0) _:@"and the user is told why, rather than nothing happening"];
        detail = @"speech=refused, refused before anything was opened";
    }
    // Whatever happened above, this is the invariant the whole feature exists to keep.
    [recorder check:(!AKSelfTestIsRecordingCategory(session.category)) _:@"it is not left recording"];
    if (!onDevice) WKLog("selftest", @"note: this device reports no on-device recognition");
    recorder.detail = detail;
    dictation.problemHandler = previous;
}

#pragma mark - Entry

static void AKSelfTestLogVerdict(AKSelfTestRecorder *recorder, NSString *name) {
    if (recorder.firstFailure) {
        WKLog("selftest", @"selftest: %@ FAIL %lu/%lu checks: %@",
              name, (unsigned long)recorder.passed, (unsigned long)recorder.total, recorder.firstFailure);
        return;
    }
    WKLog("selftest", @"selftest: %@ PASS %lu/%lu checks (%@)", name,
          (unsigned long)recorder.passed, (unsigned long)recorder.total, recorder.detail);
}

void AKRunSelfTest(NSString *name) {
    AKSelfTestRecorder *recorder = [AKSelfTestRecorder new];
    recorder.detail = @"";
    WKLog("selftest", @"selftest: %@ starting", name);
    if ([name isEqualToString:AKSelfTestInput]) {
        // On the main queue: the router asserts it, and these checks are synchronous, so there
        // is nothing to wait for and nothing is held up while they run.
        AKSelfTestOnMain(^{ AKSelfTestRunInput(recorder); });
        AKSelfTestLogVerdict(recorder, name);
        return;
    }
    if ([name isEqualToString:AKSelfTestVoice]) {
        // Off the main queue, necessarily: the app's speech callbacks are delivered *to* the main
        // queue, so a test that occupied it could never receive them.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            AKSelfTestRunVoice(recorder);
            AKSelfTestLogVerdict(recorder, name);
        });
        return;
    }
    [recorder check:NO _:[NSString stringWithFormat:@"%@ is a self-test this build knows", name]];
    AKSelfTestLogVerdict(recorder, name);
}

NSString *AKSelfTestRequestedFromArguments(NSArray<NSString *> *arguments) {
    for (NSUInteger index = 0; index < arguments.count; index++) {
        NSString *argument = arguments[index];
        if ([argument hasPrefix:@"--selftest="]) return [argument substringFromIndex:@"--selftest=".length];
        if ([argument isEqualToString:@"--selftest"] && index + 1 < arguments.count) return arguments[index + 1];
    }
    return nil;
}
