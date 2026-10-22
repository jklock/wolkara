// WolkaraForever: the self-tests the app runs on itself, on the device. See SelfTest.h for why.
//
// Two habits are kept everywhere below, because a self-test that lies is worse than none:
// every check says what it is checking, and the app reports which case it actually hit rather
// than the case that would be most flattering. The speech checks, for instance, say whether a
// microphone was opened at all.

#import "SelfTest.h"
#import "WolkaraForeverLog.h"
#import "../WoW/ForeverUI.h"
#import "../Input/InputElement.h"
#import "../Input/InputRouter.h"
#import "../Input/Trigger.h"
#import "../Voice/Dictation.h"
#import "../Voice/AudioSessionCoordinator.h"
#import "../Voice/VoiceSettings.h"
#import <AVFoundation/AVFoundation.h>
#import <Speech/Speech.h>

NSString *const AKSelfTestInput = @"input";
NSString *const AKSelfTestVoice = @"voice";
NSString *const AKSelfTestMic = @"mic";
NSString *const AKSelfTestDictationTarget = @"dictation-target";
NSString *const AKSelfTestForeverUI = @"forever-ui";
NSString *const AKSelfTestForeverUIClean = @"forever-ui-clean";

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
            // Hold it long enough for audio to actually arrive, and say what arrived. The check above
            // only proves the session looks right; it passed for months over a microphone that was
            // delivering nothing. A live microphone in a quiet room still has a noise floor, so exactly
            // zero across a second and a half is not a quiet room - it is a microphone that is not
            // reaching us, and it is the difference between a recogniser that fails and a session that
            // was never wrong.
            AKSelfTestSleep(1.5);
            [recorder check:AKSelfTestIsRecordingCategory(session.category) _:@"and it is still recording, not taken away mid-hold"];
            NSString *categoryWhileHolding = session.category;
            // The capture is stopped before the peak is read. The audio goes to a file and the number is
            // read back from it, so it describes what the microphone delivered rather than what a
            // consumer of the stream saw. Cancel measures as well as finish, because a diagnostic that
            // only works on the happy path cannot diagnose the unhappy one.
            AKSelfTestOnMain(^{ [dictation cancel]; });
            AKSelfTestSleep(0.6);
            double decibels = AKVoiceLoudestDecibels();
            WKLog("selftest", @"selftest: held the microphone for 1.5 seconds; peak %.1f dBFS while the session was %@",
                  decibels, categoryWhileHolding);
            // -120 dBFS is what a silent input meters at, and it is 0.000001 linear - so a check for
            // "greater than zero" passes on silence, which is what this test did before. A room measures
            // -50 to -70 dBFS, so below -70 is the microphone not reaching the app.
            [recorder check:(decibels > -70.0) _:[NSString stringWithFormat:
                @"the microphone delivers more than digital silence (peak %.1f dBFS)", decibels]];
            [recorder check:(dictation.state == AKDictationStateIdle) _:@"cancelling ends the session"];
            [recorder check:(!dictation.listening) _:@"and closes the microphone"];
            [recorder check:[session.category isEqualToString:categoryBefore] _:@"and puts the audio session back as it was"];
            detail = [NSString stringWithFormat:@"speech=authorized on-device=1, session=record-then-restored, peak=%.1f dBFS", decibels];
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

#pragma mark - A bare recorder

// A bare recorder, with none of this app's audio code in the path.
//
// The coordinator has been in the path of every measurement made during this fault, so a test that
// asks the coordinator for the session cannot tell whether the coordinator is why the microphone
// arrives silent. This takes the session by hand, the way the documentation does it, and records with
// nothing between the microphone and AVFoundation. It runs only under --selftest=mic and cannot be
// reached from the UI; check_layers.sh names it as its single exemption for that reason.
// One capture with nothing but AVFoundation in the path, returning its peak in dBFS.
static float AKSelfTestRecordOnce(NSDictionary *settings, NSString *label, AVAudioSession *session) {
    NSError *error = nil;
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:
        [NSString stringWithFormat:@"wolkaraforever-mic-%@.wav", label]]];
    [[NSFileManager defaultManager] removeItemAtURL:url error:NULL];
    AVAudioRecorder *bare = [[AVAudioRecorder alloc] initWithURL:url settings:settings error:&error];
    if (!bare) {
        WKLog("selftest", @"mic: %@ could not be created: %@", label, error.localizedDescription);
        return -160.0f;
    }
    bare.meteringEnabled = YES;
    if (![bare record]) {
        WKLog("selftest", @"mic: %@ would not start", label);
        return -160.0f;
    }
    AKSelfTestSleep(1.2);
    [bare updateMeters];
    float decibels = [bare peakPowerForChannel:0];
    NSTimeInterval seconds = bare.currentTime;
    [bare stop];
    WKLog("selftest", @"mic: %@ captured %.2fs, peak %.1f dBFS (session %@)",
          label, seconds, decibels, session.category);
    return decibels;
}

static void AKSelfTestRunMic(AKSelfTestRecorder *recorder) {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;

    WKLog("selftest", @"mic: permission=%ld input_available=%d other_audio=%d category=%@",
          (long)session.recordPermission, (int)session.isInputAvailable,
          (int)session.isOtherAudioPlaying, session.category);
    [recorder check:(session.recordPermission == AVAudioSessionRecordPermissionGranted)
                  _:@"the microphone permission is granted"];

    [recorder check:[session setCategory:AVAudioSessionCategoryRecord
                                    mode:AVAudioSessionModeDefault
                                 options:0 error:&error]
                  _:[NSString stringWithFormat:@"the record category is taken: %@", error.localizedDescription]];
    error = nil;
    [recorder check:[session setActive:YES error:&error]
                  _:[NSString stringWithFormat:@"and the session activates: %@", error.localizedDescription]];
    [recorder check:(session.isInputAvailable) _:@"input is available after activation"];

    // 16-bit integer LPCM: the same settings the dictation path uses, and for the same reason - 32-bit
    // float gives a recorder that starts, reports success, and writes a file with no audio in it.
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(48000.0),
        AVNumberOfChannelsKey: @(1),
        AVLinearPCMBitDepthKey: @(16),
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
    };

    // Three captures in one process, differing only in whether the session was ever released:
    //   1. straight after activation             - the state every dictation is in since 2026-10-17 13:34
    //   2. again, with the session never released - the state the working build left behind
    //   3. after a release and a fresh activation - to show it is the release and not the first use
    float cold = AKSelfTestRecordOnce(settings, @"after-activation", session);
    float warm = AKSelfTestRecordOnce(settings, @"session-never-released", session);
    [session setActive:NO error:NULL];
    AKSelfTestSleep(0.4);
    [session setCategory:AVAudioSessionCategoryRecord mode:AVAudioSessionModeDefault options:0 error:NULL];
    [session setActive:YES error:NULL];
    AKSelfTestSleep(0.4);
    float reopened = AKSelfTestRecordOnce(settings, @"after-release", session);

    WKLog("selftest", @"mic: cold %.1f dBFS, warm %.1f dBFS, reopened %.1f dBFS", cold, warm, reopened);
    [recorder check:(cold > -70.0 || warm > -70.0 || reopened > -70.0) _:[NSString stringWithFormat:
        @"a bare recorder hears the microphone (cold %.1f, warm %.1f, reopened %.1f dBFS)",
        cold, warm, reopened]];

    error = nil;
    [session setActive:NO error:&error];
}

#pragma mark - Entry

// The check the crash of 2026-10-21 needed, and the one part of that path a self-test can
// check without a person speaking: the object registered as the game's text input must
// answer the two selectors dictation sends it. It was registered as AKKeyboardTextView, the
// draft editor, which answers neither, so the first transcript into the game aborted the app
// with "-[AKKeyboardTextView touchInsertText:]: unrecognized selector".
//
// Nothing is typed and nothing in the game is touched: the registered object is asked what
// it is, and answers. Run it with `--local-game-startup`, because the target exists only
// once the guest's host view has been created.
static void AKSelfTestRunDictationTarget(AKSelfTestRecorder *recorder) {
    __block UIView *target = nil;
    for (NSUInteger slice = 0; slice < 300 && !target; slice++) {
        AKSelfTestOnMain(^{ target = AKDictation.gameTextTarget; });
        if (!target) AKSelfTestSleep(0.1);
    }
    if (!target) {
        recorder.detail = @"no guest, so no text target";
        WKLog("selftest", @"no text target was registered in 30s; this check needs --local-game-startup");
        [recorder check:NO _:@"<a running guest registered a text target for dictation>"];
        return;
    }
    WKLog("selftest", @"the registered text target is %@", NSStringFromClass(target.class));
    recorder.detail = [NSString stringWithFormat:@"%@ answers both selectors", NSStringFromClass(target.class)];
    [recorder check:[target respondsToSelector:NSSelectorFromString(@"touchInsertText:")]
                 _:@"<the registered text target takes typed words (touchInsertText:)> "];
    [recorder check:[target respondsToSelector:NSSelectorFromString(@"touchSpecialKey:characters:")]
                 _:@"<and keys (touchSpecialKey:characters:) for Return>"];
}

#pragma mark - The Forever UI rows, on the installation actually on the device

static NSString *AKSelfTestDocuments(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

// The Forever edition's working directory, where the launcher's rows would resolve it. Only the
// installed folder is needed here: this exercises the file operations themselves.
static NSString *AKSelfTestForeverDirectory(void) {
    NSString *documents = AKSelfTestDocuments();
    for (NSString *candidate in @[@"World of Warcraft/_classic_beta_", @"_classic_beta_"]) {
        NSString *path = [documents stringByAppendingPathComponent:candidate];
        BOOL directory = NO;
        if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && directory)
            return path;
    }
    return nil;
}

static NSString *AKSelfTestConfigPath(NSString *directory) {
    return [directory stringByAppendingPathComponent:@"WTF/Config.wtf"];
}

static NSString *AKSelfTestReadText(NSString *path) {
    return [NSString stringWithContentsOfFile:path encoding:NSISOLatin1StringEncoding error:NULL];
}

// Deliberately a second, smaller parser: a test that reuses the code under test cannot catch a
// mistake in it.
static NSString *AKSelfTestCVarName(NSString *line) {
    NSMutableArray<NSString *> *tokens = [NSMutableArray new];
    for (NSString *token in [line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet])
        if (token.length) [tokens addObject:token];
    if (tokens.count < 2 || ![tokens[0].uppercaseString isEqualToString:@"SET"]) return nil;
    return tokens[1];
}

static BOOL AKSelfTestGraphicsLine(NSString *line) {
    NSString *name = AKSelfTestCVarName(line).lowercaseString;
    return [name hasPrefix:@"gx"] || [name hasPrefix:@"graphics"];
}

static NSArray<NSString *> *AKSelfTestLines(NSString *text) {
    NSMutableArray<NSString *> *lines = [[text componentsSeparatedByString:@"\n"] mutableCopy];
    if (lines.count && [lines.lastObject length] == 0) [lines removeLastObject];
    return lines;
}

static void AKSelfTestRunForeverUI(AKSelfTestRecorder *recorder) {
    NSString *directory = AKSelfTestForeverDirectory();
    [recorder check:directory != nil _:@"a Forever installation is present on this device"];
    if (!directory) return;
    NSString *configPath = AKSelfTestConfigPath(directory);
    NSString *before = AKSelfTestReadText(configPath);
    [recorder check:before.length > 0 _:@"its Config.wtf is readable"];
    if (!before.length) return;

    // --- backup
    NSError *error = nil;
    NSString *backup = [TKForeverUI createUIBackupInWorkingDirectory:directory edition:TKForeverUIEdition error:&error];
    [recorder check:backup.length > 0 _:[NSString stringWithFormat:@"backup created (%@)", error.localizedDescription ?: @"no name"]];
    if (!backup.length) return;
    [recorder check:[NSFileManager.defaultManager fileExistsAtPath:
        [directory stringByAppendingPathComponent:[@"WTF/Backups" stringByAppendingPathComponent:backup]]]
                 _:@"the backup is a file in WTF/Backups"];
    [recorder check:[[TKForeverUI newestUIBackupInWorkingDirectory:directory error:NULL] isEqual:backup]
                 _:@"it is the newest valid backup"];

    // --- reset removes graphics and keeps everything else
    error = nil;
    BOOL reset = [TKForeverUI resetGraphicsInWorkingDirectory:directory error:&error];
    [recorder check:reset _:[NSString stringWithFormat:@"reset ran (%@)", error.localizedDescription ?: @"ok"]];
    NSString *afterReset = AKSelfTestReadText(configPath);
    [recorder check:afterReset != nil && ![AKSelfTestLines(afterReset) containsObjectPassing:^BOOL(NSString *line) {
        return AKSelfTestGraphicsLine(line);
    }] _:@"no graphics CVar is left in Config.wtf"];
    NSMutableArray *expectedKept = [NSMutableArray new];
    for (NSString *line in AKSelfTestLines(before)) if (!AKSelfTestGraphicsLine(line)) [expectedKept addObject:line];
    [recorder check:[AKSelfTestLines(afterReset) isEqualToArray:expectedKept]
                 _:@"account, locale, audio, UI, input, gamepad, bindings and unknown settings are byte-identical"];

    // --- restore brings the whole UI back, which is also what leaves the device as it was
    error = nil;
    BOOL restored = [TKForeverUI restoreUIBackupNamed:backup inWorkingDirectory:directory
                                              edition:TKForeverUIEdition error:&error];
    [recorder check:restored _:[NSString stringWithFormat:@"restore ran (%@)", error.localizedDescription ?: @"ok"]];
    [recorder check:[AKSelfTestReadText(configPath) isEqual:before]
                 _:@"the restored Config.wtf is byte-identical to the original"];

    // --- the gamepad write adds exactly one answer and changes nothing else
    error = nil;
    BOOL gamepad = [TKForeverUI enableGamepadInWorkingDirectory:directory error:&error];
    [recorder check:gamepad _:[NSString stringWithFormat:@"gamepad write ran (%@)", error.localizedDescription ?: @"ok"]];
    NSString *afterGamepad = AKSelfTestReadText(configPath);
    NSUInteger assignments = 0;
    BOOL enabled = NO;
    NSMutableArray *expectedGamepad = [NSMutableArray new];
    for (NSString *line in AKSelfTestLines(afterGamepad)) {
        NSString *name = AKSelfTestCVarName(line);
        if ([name caseInsensitiveCompare:@"GamePadEnable"] == NSOrderedSame) {
            assignments++;
            enabled = [line containsString:@"\"1\""];
        } else {
            [expectedGamepad addObject:line];
        }
    }
    [recorder check:assignments == 1 && enabled _:@"exactly one GamePadEnable assignment, value 1"];
    NSMutableArray *originalNonGamepad = [NSMutableArray new];
    for (NSString *line in AKSelfTestLines(before))
        if ([AKSelfTestCVarName(line) caseInsensitiveCompare:@"GamePadEnable"] != NSOrderedSame)
            [originalNonGamepad addObject:line];
    [recorder check:[expectedGamepad isEqualToArray:originalNonGamepad]
                 _:@"no other Config.wtf line changed"];

    // Undo the gamepad write the same way, so the user's configuration is untouched.
    error = nil;
    [recorder check:[TKForeverUI restoreUIBackupNamed:backup inWorkingDirectory:directory
                                              edition:TKForeverUIEdition error:&error]
                 _:@"the final restore leaves the user's UI as it was"];

    // --- leave the overlay on and expanded so the in-game HUD can be seen on this device
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id stored = [defaults objectForKey:@"WolkaraForeverTouchLayoutV1"];
    NSMutableDictionary *layout = [stored isKindOfClass:NSDictionary.class] ? [stored mutableCopy]
                                                                           : [NSMutableDictionary new];
    layout[@"performanceOverlayEnabled"] = @YES;
    [defaults setObject:layout forKey:@"WolkaraForeverTouchLayoutV1"];
    [defaults setBool:YES forKey:@"WolkaraForeverPerformanceOverlayExpanded"];
    [defaults setObject:@[@0.55, @0.35] forKey:@"WolkaraForeverPerformanceOverlayPosition"];
    NSDictionary *saved = [defaults objectForKey:@"WolkaraForeverTouchLayoutV1"];
    [recorder check:[saved[@"performanceOverlayEnabled"] boolValue]
                 _:@"the overlay preference is on in the shared layout store"];

    recorder.detail = [NSString stringWithFormat:@"backup, reset, restore and gamepad on the real installation; overlay left on for the HUD check (backup %@)", backup];
}

static void AKSelfTestRunForeverUIClean(AKSelfTestRecorder *recorder) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id stored = [defaults objectForKey:@"WolkaraForeverTouchLayoutV1"];
    if ([stored isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *layout = [stored mutableCopy];
        layout[@"performanceOverlayEnabled"] = @NO;
        [defaults setObject:layout forKey:@"WolkaraForeverTouchLayoutV1"];
    }
    [defaults removeObjectForKey:@"WolkaraForeverPerformanceOverlayExpanded"];
    [defaults removeObjectForKey:@"WolkaraForeverPerformanceOverlayPosition"];
    NSDictionary *saved = [defaults objectForKey:@"WolkaraForeverTouchLayoutV1"];
    [recorder check:![saved[@"performanceOverlayEnabled"] boolValue]
                 _:@"the overlay preference is off again"];
    [recorder check:[defaults objectForKey:@"WolkaraForeverPerformanceOverlayPosition"] == nil]
                 _:@"the HUD position is cleared, so it starts at its default corner"];
    recorder.detail = @"overlay preference returned to its default off state";
}

static void AKSelfTestLogVerdict(AKSelfTestRecorder *recorder, NSString *name) {    if (recorder.firstFailure) {
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
    if ([name isEqualToString:AKSelfTestMic]) {
        // Off the main queue: it sleeps for a second and a half and must not block the app.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            AKSelfTestRunMic(recorder);
            AKSelfTestLogVerdict(recorder, name);
        });
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
    if ([name isEqualToString:AKSelfTestDictationTarget]) {
        // Off the main queue too: it waits for the guest to start, which happens on the main queue.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            AKSelfTestRunDictationTarget(recorder);
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
