// Focused tests for the input, voice and configuration rules.
//
// The 2026-10-16 audit's required verification, in one place:
//
//   1. canonical element ids, mapping persistence and migration, cancellation,
//      controller disconnect, screenshot isolation, and every trigger pattern;
//   2. dictation: permission denial, unavailable on-device recognition, final-result
//      ordering, rapid toggles, exactly one delivery, and audio-session restoration;
//   3. a malformed configuration corpus: version, types, enums, trigger values,
//      oversized data, and a file that is not a file.
//
// It runs as a tiny app in the simulator because UIKit and GameController are what the
// code under test is made of. The recogniser and the audio session are the two things a
// test cannot run, and both are behind protocols in Dictation.h so they can be faked.
//
//   wolkara/tools/test_voice.sh

#import <UIKit/UIKit.h>

#import "../launcher/Input/InputElement.h"
#import "../launcher/Input/InputRouter.h"
#import "../launcher/Input/Trigger.h"
#import "../launcher/Voice/Dictation.h"
#import "../launcher/Voice/VoiceSettings.h"
#import "../launcher/Voice/VoiceViewController.h"
#import "../launcher/Voice/VoiceTestViewController.h"
#import "../launcher/Controller/ControllerInspector.h"
#import "../launcher/App/WolkaraConfig.h"

#import <AVFAudio/AVFAudio.h>
#import "../launcher/App/WolkaraLog.h"

static NSUInteger checks, failures;

static void Check(BOOL condition, NSString *what) {
    checks++;
    if (condition) return;
    failures++;
    fprintf(stderr, "FAIL: %s\n", what.UTF8String);
}
#define CHECK(condition, ...) Check((condition), [NSString stringWithFormat:__VA_ARGS__])

// Runs the main run loop, because a few of these paths are asynchronous on purpose.
static void Pump(NSTimeInterval seconds) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (until.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                                 beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
}

// A view by the identifier the page gives it, so the test asks for what a person taps
// rather than for an ivar.
static UIView *Find(UIView *view, NSString *identifier) {
    if ([view.accessibilityIdentifier isEqualToString:identifier]) return view;
    for (UIView *child in view.subviews) {
        UIView *match = Find(child, identifier);
        if (match) return match;
    }
    return nil;
}

#pragma mark - The two fakes

@interface FakeSpeech : NSObject <AKDictationSpeech>
@property (nonatomic) BOOL available;
@property (nonatomic) BOOL onDevice;
@property (nonatomic) BOOL authorized;
@property (nonatomic, copy) void (^handler)(NSString *, BOOL, NSError *);
@property (nonatomic) NSUInteger starts, finishes, cancels;
@property (nonatomic, copy) NSArray<NSString *> *words;
@end

@implementation FakeSpeech
- (instancetype)init { if ((self = [super init])) { _available = YES; _onDevice = YES; _authorized = YES; } return self; }
- (BOOL)isAvailable { return self.available; }
- (BOOL)supportsOnDeviceRecognition { return self.onDevice; }
- (void)requestAuthorization:(void (^)(BOOL))completion { completion(self.authorized); }
- (void)startOnDevice:(BOOL)onDevice words:(NSArray<NSString *> *)words handler:(void (^)(NSString *, BOOL, NSError *))handler {
    (void)onDevice;
    self.starts++;
    self.words = words;
    self.handler = handler;
}
- (void)finish { self.finishes++; }
- (void)cancel { self.cancels++; self.handler = nil; }
// What a recogniser would do next.
- (void)say:(NSString *)text final:(BOOL)isFinal {
    void (^handler)(NSString *, BOOL, NSError *) = self.handler;
    if (handler) handler(text, isFinal, nil);
}
@end

@interface FakeAudio : NSObject <AKDictationAudio>
@property (nonatomic) BOOL refuse;
@property (nonatomic) BOOL recording;
@property (nonatomic) NSUInteger begins, restores;
@end

@implementation FakeAudio
- (BOOL)beginRecording:(NSError **)error {
    self.begins++;
    if (self.refuse) {
        if (error) *error = [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey: @"the session said no"}];
        return NO;
    }
    self.recording = YES;
    return YES;
}
- (void)restore { self.restores++; self.recording = NO; }
@end

// The game's own text view, as far as dictation is concerned.
@interface FakeGameTextView : UIView
@property (nonatomic) NSUInteger inserts, returns;
@property (nonatomic, copy) NSString *lastText;
@end

@implementation FakeGameTextView
- (void)touchInsertText:(NSString *)text { self.inserts++; self.lastText = text; }
- (void)touchSpecialKey:(NSNumber *)code characters:(NSString *)characters {
    (void)code; (void)characters;
    self.returns++;
}
@end

#pragma mark - The tests

static void TestElements(void) {
    CHECK(([AKInputElementForControllerButton(@"Button Share") isEqualToString:@"controller.button.share"]),
          @"a pad's Share button should be controller.button.share, got %@", AKInputElementForControllerButton(@"Button Share"));
    CHECK(([AKInputElementForControllerButton(@"Button Left Shoulder") isEqualToString:@"controller.button.left.shoulder"]),
          @"a two-word button should be slugged, got %@", AKInputElementForControllerButton(@"Button Left Shoulder"));
    CHECK(([AKInputElementForKeyboardKey(36) isEqualToString:@"keyboard.key.36"]), @"a key code should be keyboard.key.36");
    CHECK(([AKInputElementForMouseButton(@"left") isEqualToString:@"mouse.button.left"]), @"a mouse button should be mouse.button.left");
    CHECK(([AKInputElementForTouchpad(@"Touchpad", @"down") isEqualToString:@"touchpad.touchpad.down"]), @"a touchpad phase should be touchpad.touchpad.down");

    // The two that used to change with every movement, which is why nothing learned
    // from one press ever matched the next one.
    NSString *up = AKInputElementForDirectionPad(@"Left Thumbstick", 0.1, -0.9);
    NSString *upAgain = AKInputElementForDirectionPad(@"Left Thumbstick", 0.3, -0.8);
    CHECK(([up isEqualToString:upAgain]), @"two presses of the same d-pad direction must be the same id (%@ vs %@)", up, upAgain);
    CHECK(([up isEqualToString:@"dpad.left.thumbstick.up.centre"]), @"got %@", up);
    CHECK(([AKInputElementForDirectionPad(@"Left Thumbstick", -0.9, -0.9) isEqualToString:@"dpad.left.thumbstick.up.left"]),
          @"a diagonal must be a name, not numbers");
    CHECK(([AKInputElementForDirectionPad(@"Left Thumbstick", 0, 0) isEqualToString:@"dpad.left.thumbstick.centre.centre"]),
          @"the middle must be centre");

    CHECK((AKInputElementIsCanonical(@"controller.button.share")), @"a controller id is canonical");
    CHECK((AKInputElementIsCanonical(@"system.screenshot")), @"a system id is canonical");
    CHECK((!AKInputElementIsCanonical(@"Button Share")), @"display text is not canonical");
    CHECK((!AKInputElementIsCanonical(@"dpad x=0.42 y=-1.00")), @"a value is not an id");

    CHECK(([AKInputElementCanonicalized(@"Button Share") isEqualToString:@"controller.button.share"]), @"legacy button name");
    CHECK(([AKInputElementCanonicalized(@"Share") isEqualToString:@"system.screenshot"]), @"the old screenshot spelling");
    CHECK(([AKInputElementCanonicalized(@"keycode 70") isEqualToString:@"keyboard.key.70"]), @"legacy key name");
    CHECK(([AKInputElementCanonicalized(@"mouse right") isEqualToString:@"mouse.button.right"]), @"legacy mouse name");
    CHECK(([AKInputElementCanonicalized(@"controller.button.a") isEqualToString:@"controller.button.a"]), @"an id is left alone");

    CHECK(([AKInputElementDisplay(@"controller.button.share") isEqualToString:@"Share"]), @"share reads as Share");
    CHECK(([AKInputElementDisplay(@"keyboard.key.36") isEqualToString:@"Key 36"]), @"a key reads as Key 36");
    CHECK(([AKInputElementDisplay(@"system.screenshot") containsString:@"Share"]), @"the screenshot signal reads as Share");
}

static void TestTriggers(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in defaults.dictionaryRepresentation.allKeys)
        if ([key hasPrefix:@"AKInputTrigger."]) [defaults removeObjectForKey:key];

    AKTrigger *trigger = [AKTrigger new];
    trigger.element = @"controller.button.share";
    trigger.pattern = AKTriggerPatternPress;
    CHECK(([trigger watchesElement:@"controller.button.share"]), @"an exact match");
    CHECK((![trigger watchesElement:@"controller.button.a"]), @"and nothing else");
    CHECK(([trigger watchesElement:@"controller.button.share"]), @"matching is by id, not by display text");

    AKTrigger *family = [AKTrigger new];
    family.element = @"controller.button.";
    CHECK(([family watchesElement:@"controller.button.a"]), @"a family covers every button");
    CHECK((![family watchesElement:@"keyboard.key.36"]), @"and not other kinds");

    AKTrigger *any = [AKTrigger new];
    any.element = AKTriggerAnyElement;
    CHECK(([any watchesElement:@"keyboard.key.36"]), @"any covers everything");

    // Storage round trip, then the corpus of things that must be refused.
    NSDictionary *stored = [trigger storedForm];
    AKTrigger *back = [AKTrigger triggerFromStored:stored];
    CHECK((back && [back.element isEqualToString:trigger.element] && back.pattern == trigger.pattern),
          @"a stored trigger comes back the same");
    CHECK(([AKTrigger triggerFromStored:nil] == nil), @"nothing is not a trigger");
    CHECK(([AKTrigger triggerFromStored:@{}] == nil), @"an empty dictionary is not a trigger");
    CHECK(([AKTrigger triggerFromStored:@{@"element": @42, @"pattern": @0}] == nil), @"a number is not an element");
    // A name an older build wrote is *migrated*, not refused: refusing it would throw
    // away the mapping a user made. What must be refused is a name we cannot read.
    AKTrigger *legacy = [AKTrigger triggerFromStored:@{@"element": @"Button Share", @"pattern": @0}];
    CHECK((legacy != nil && [legacy.element isEqualToString:@"controller.button.share"]),
          @"a legacy element name is migrated to its id, got %@", legacy.element);
    CHECK(([AKTrigger triggerFromStored:@{@"element": @"what is this", @"pattern": @0}] == nil),
          @"a name we cannot read is refused");
    CHECK(([AKTrigger triggerFromStored:@{@"element": @"controller.button.a", @"pattern": @9}] == nil), @"a pattern out of range");
    CHECK(([AKTrigger triggerFromStored:@{@"element": @"controller.button.a", @"pattern": @0, @"hold": @0.001}] == nil), @"a hold that is not a hold");
    CHECK(([AKTrigger triggerFromStored:@{@"element": @"controller.button.a", @"pattern": @0, @"hold": @99}] == nil), @"a hold that is forever");
    CHECK(([AKTrigger triggerFromStored:@{@"element": @"controller.button.a", @"pattern": @0, @"double": @0.001}] == nil), @"a double window of nothing");
    CHECK(([AKTrigger triggerFromStored:@{@"element": @"controller.button.a", @"pattern": @0, @"chord": @"Button X"}] == nil),
          @"a chord partner must be an id too");
    CHECK(([AKTrigger triggerFromStored:@{@"element": @"controller.button.a", @"pattern": @"press"}] == nil), @"a pattern must be a number");
    CHECK(([AKTrigger triggerFromStored:@{@"element": @"controller.button.a", @"pattern": @0, @"hold": @0.5}] != nil),
          @"a reasonable hold is fine");

    // Migration: what an older build wrote, and one entry that cannot be read at all.
    [defaults setObject:@{@"element": @"Button Share", @"pattern": @0} forKey:@"AKInputTrigger.vendor"];
    [defaults setObject:@{@"element": @"Button X", @"pattern": @9} forKey:@"AKInputTrigger.broken"];
    NSUInteger migrated = [AKTrigger migrateStoredTriggersInDefaults:defaults];
    CHECK((migrated == 2), @"both entries needed attention, got %lu", (unsigned long)migrated);
    CHECK(([[defaults dictionaryForKey:@"AKInputTrigger.vendor"][@"element"] isEqualToString:@"controller.button.share"]),
          @"a mapping made before this change keeps working");
    CHECK(([defaults dictionaryForKey:@"AKInputTrigger.broken"] == nil), @"an unreadable mapping is dropped");

    // Two controllers from one vendor are two controllers.
    CHECK((![[AKTrigger defaultsKeyForDevice:@"8bitdo.pro"] isEqualToString:[AKTrigger defaultsKeyForDevice:@"8bitdo.controller"]]),
          @"the key is the controller's identity, not its vendor");
    CHECK(([[AKTrigger legacyDefaultsKeyForVendor:@"8bitdo"] isEqualToString:@"AKInputTrigger.8bitdo"]), @"the old key is still readable");

    for (NSString *key in defaults.dictionaryRepresentation.allKeys)
        if ([key hasPrefix:@"AKInputTrigger."]) [defaults removeObjectForKey:key];
}

static void TestSettings(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in defaults.dictionaryRepresentation.allKeys)
        if ([key hasPrefix:@"AKInputTrigger."] || [key hasPrefix:@"AKVoice"]) [defaults removeObjectForKey:key];
    AKVoiceSettings *settings = AKVoiceSettings.shared;
    settings.enabled = NO;
    settings.mode = AKVoiceModeHold;

    CHECK((!settings.enabled), @"voice is off until it is asked for");
    CHECK(([settings triggerForDevice:@"pad"] == nil), @"with nothing mapped there is no trigger at all");
    CHECK(([[settings mappingSummaryForDevice:@"pad"] isEqualToString:@"Not set"]), @"and the screen says so");

    // Enabled but unmapped is still nothing: no fallback, which is the audit's first
    // release blocker.
    settings.enabled = YES;
    CHECK(([settings triggerForDevice:@"pad"] == nil), @"switching it on does not invent a trigger");

    [settings setLearnedElement:@"controller.button.share" forDevice:@"pad"];
    AKTrigger *mapped = [settings triggerForDevice:@"pad"];
    CHECK((mapped && [mapped.element isEqualToString:@"controller.button.share"]), @"the learned element is stored as an id");
    CHECK((mapped.pattern == AKTriggerPatternPushToTalk), @"hold to talk is the pattern in hold mode");
    CHECK(([[settings mappingSummaryForDevice:@"pad"] containsString:@"Share"]), @"and it reads as Share");

    settings.mode = AKVoiceModeToggle;
    CHECK(([settings triggerForDevice:@"pad"].pattern == AKTriggerPatternPress),
          @"the mode owns the pattern, so changing it changes the mapping's behaviour");

    settings.enabled = NO;
    CHECK(([settings triggerForDevice:@"pad"] == nil), @"switching it off stops it firing, whatever is stored");
    CHECK(([[settings mappingSummaryForDevice:@"pad"] containsString:@"Share"]), @"but the screen still shows what is set");
    settings.enabled = YES;

    [settings clearMappingForDevice:@"pad"];
    CHECK(([settings triggerForDevice:@"pad"] == nil), @"clearing the mapping leaves nothing");

    // A mapping from an older build, keyed by the vendor name alone.
    [defaults setObject:@{@"element": @"Button X", @"pattern": @0} forKey:@"AKInputTrigger.8bitdo"];
    CHECK(([settings adoptLegacyMappingForDevice:@"8bitdo.pro" vendor:@"8bitdo"]), @"the old mapping is adopted");
    CHECK(([settings triggerForDevice:@"8bitdo.pro"] != nil), @"onto the controller's identity");
    CHECK(([defaults dictionaryForKey:@"AKInputTrigger.8bitdo"] == nil), @"and the old key is gone");
    CHECK((![settings adoptLegacyMappingForDevice:@"8bitdo.pro" vendor:@"8bitdo"]), @"adopting twice does nothing");

    // The dictionary is biased into the recogniser, so it is bounded and cleaned.
    settings.customWords = @[@"Thunderfury", @"Thunderfury", @"", @"  ", [@"" stringByPaddingToLength:200 withString:@"x" startingAtIndex:0], @42, @"Ragnaros"];
    CHECK((settings.customWords.count == 2), @"duplicates, blanks and overlong words are dropped, got %lu", (unsigned long)settings.customWords.count);
    CHECK(([settings.customWords containsObject:@"Thunderfury"] && [settings.customWords containsObject:@"Ragnaros"]), @"the real words stay");

    for (NSString *key in defaults.dictionaryRepresentation.allKeys)
        if ([key hasPrefix:@"AKInputTrigger."] || [key hasPrefix:@"AKVoice"]) [defaults removeObjectForKey:key];
}

static void TestLearning(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in defaults.dictionaryRepresentation.allKeys)
        if ([key hasPrefix:@"AKInputTrigger."]) [defaults removeObjectForKey:key];
    AKVoiceSettings *settings = AKVoiceSettings.shared;
    settings.enabled = YES;
    settings.mode = AKVoiceModeToggle;

    AKInputRouter *router = AKInputRouter.shared;
    router.learningTimeout = 20.0;
    __block NSString *learnedElement = nil;
    router.onLearned = ^(AKTrigger *trigger, NSString *device) {
        (void)device;
        learnedElement = trigger.element;
        [AKVoiceSettings.shared setLearnedElement:trigger.element forDevice:device];
    };

    [router beginLearning];
    CHECK((router.learning), @"arming a mapping listens");
    [router reportElement:@"controller.button.y" value:1 pressed:YES device:@"pad" source:AKInputSourceController];
    CHECK((!router.learning), @"the first press ends the listening");
    CHECK(([learnedElement isEqualToString:@"controller.button.y"]), @"and it is the press that was adopted, got %@", learnedElement);
    CHECK(([settings triggerForDevice:@"pad"] != nil), @"which is now the mapping");

    // The timeout disarms, and a press afterwards must not become the mapping. This is
    // the audit's "post-timeout event cannot modify persistence".
    NSString *before = [[settings triggerForDevice:@"pad"] element];
    __block BOOL expired = NO;
    id token = [NSNotificationCenter.defaultCenter addObserverForName:AKInputRouterLearningDidExpireNotification
                                                              object:nil queue:NSOperationQueue.mainQueue
                                                          usingBlock:^(NSNotification *note) { (void)note; expired = YES; }];
    router.learningTimeout = 0.15;
    [router beginLearning];
    Pump(0.5);
    CHECK((expired), @"an armed mapping that hears nothing says so");
    CHECK((!router.learning), @"and disarms itself");
    [router reportElement:@"controller.button.b" value:1 pressed:YES device:@"pad" source:AKInputSourceController];
    CHECK(([[[settings triggerForDevice:@"pad"] element] isEqualToString:before]),
          @"a press after the timeout must not rewrite the mapping");
    [NSNotificationCenter.defaultCenter removeObserver:token];

    // Backgrounding clears it too.
    router.learningTimeout = 20.0;
    [router beginLearning];
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationDidEnterBackgroundNotification object:nil];
    CHECK((!router.learning), @"going to the background disarms the mapper");

    // And so does the pad going away: the element being learned no longer exists.
    [router beginLearning];
    [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidDisconnectNotification object:nil];
    CHECK((!router.learning), @"a controller leaving disarms the mapper");

    // But a pad arriving must not. It connects a moment after launch on real hardware,
    // and cancelling then would make mapping impossible - measured in this fixture.
    [router beginLearning];
    [NSNotificationCenter.defaultCenter postNotificationName:GCControllerDidConnectNotification object:nil];
    CHECK((router.learning), @"a controller arriving leaves the mapper armed");
    [router cancelLearning];

    router.onLearned = nil;
    for (NSString *key in defaults.dictionaryRepresentation.allKeys)
        if ([key hasPrefix:@"AKInputTrigger."]) [defaults removeObjectForKey:key];
}

// Every pattern the router can match. The launcher offers press and push-to-talk; the
// others are reachable by a stored mapping, and "all trigger patterns" is on the audit's
// verification list, so they are driven here rather than assumed.
static void TestTriggerPatterns(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in defaults.dictionaryRepresentation.allKeys)
        if ([key hasPrefix:@"AKInputTrigger."]) [defaults removeObjectForKey:key];
    AKVoiceSettings *settings = AKVoiceSettings.shared;
    settings.enabled = YES;

    AKInputRouter *router = AKInputRouter.shared;
    __block NSUInteger fired = 0;
    router.onTrigger = ^(AKTrigger *trigger, AKInputEvent *event) {
        (void)trigger; (void)event;
        fired++;
    };
    router.onTriggerBegan = nil;
    router.onTriggerEnded = nil;

    AKTrigger *doubleTap = [AKTrigger new];
    doubleTap.element = @"controller.button.a";
    doubleTap.pattern = AKTriggerPatternDouble;
    doubleTap.doubleInterval = 0.35;
    [settings setTrigger:doubleTap forDevice:@"patterns"];

    // One press is not a double, and two inside the window are.
    [router reportElement:@"controller.button.a" value:1 pressed:YES device:@"patterns" source:AKInputSourceController];
    [router reportElement:@"controller.button.a" value:0 pressed:NO device:@"patterns" source:AKInputSourceController];
    CHECK((fired == 0), @"one press must not fire a double, got %lu", (unsigned long)fired);
    [router reportElement:@"controller.button.a" value:1 pressed:YES device:@"patterns" source:AKInputSourceController];
    [router reportElement:@"controller.button.a" value:0 pressed:NO device:@"patterns" source:AKInputSourceController];
    CHECK((fired == 1), @"two presses in the window must fire once, got %lu", (unsigned long)fired);

    // Long: a tap the game owns is untouched, a held press is not.
    fired = 0;
    AKTrigger *longPress = [AKTrigger new];
    longPress.element = @"controller.button.b";
    longPress.pattern = AKTriggerPatternLong;
    longPress.holdInterval = 0.15;
    [settings setTrigger:longPress forDevice:@"patterns"];
    [router reportElement:@"controller.button.b" value:1 pressed:YES device:@"patterns" source:AKInputSourceController];
    [router reportElement:@"controller.button.b" value:0 pressed:NO device:@"patterns" source:AKInputSourceController];
    Pump(0.4);
    CHECK((fired == 0), @"a quick tap must not fire a long press, got %lu", (unsigned long)fired);
    [router reportElement:@"controller.button.b" value:1 pressed:YES device:@"patterns" source:AKInputSourceController];
    Pump(0.4);
    CHECK((fired == 1), @"a held press must fire once, got %lu", (unsigned long)fired);
    [router reportElement:@"controller.button.b" value:0 pressed:NO device:@"patterns" source:AKInputSourceController];

    // Chord: the partner has to be down first.
    fired = 0;
    AKTrigger *chord = [AKTrigger new];
    chord.element = @"controller.button.x";
    chord.chordElement = @"controller.button.y";
    chord.pattern = AKTriggerPatternChord;
    [settings setTrigger:chord forDevice:@"patterns"];
    [router reportElement:@"controller.button.x" value:1 pressed:YES device:@"patterns" source:AKInputSourceController];
    CHECK((fired == 0), @"one half of a chord must not fire");
    [router reportElement:@"controller.button.x" value:0 pressed:NO device:@"patterns" source:AKInputSourceController];
    [router reportElement:@"controller.button.y" value:1 pressed:YES device:@"patterns" source:AKInputSourceController];
    [router reportElement:@"controller.button.x" value:1 pressed:YES device:@"patterns" source:AKInputSourceController];
    CHECK((fired == 1), @"both halves together must fire once, got %lu", (unsigned long)fired);

    router.onTrigger = nil;
    for (NSString *key in defaults.dictionaryRepresentation.allKeys)
        if ([key hasPrefix:@"AKInputTrigger."]) [defaults removeObjectForKey:key];
}

// The audio session, through the real bridge rather than a fake. The remediation review
// accepted a documented policy in place of exact restoration, and a policy still has to be
// the one that happens: the category and mode it found are what is there afterwards.
static void TestAudioSessionPolicy(void) {
    AKDictation *dictation = AKDictation.shared;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeMoviePlayback
                      options:0 error:&error]) {
        CHECK(0, @"the test could not set a starting category: %@", error.localizedDescription);
        return;
    }
    [session setActive:YES error:NULL];

    FakeSpeech *speech = [FakeSpeech new];
    dictation.speech = speech;
    dictation.audio = nil;      // the real bridge
    dictation.transcriptHandler = nil;
    [AKDictation setGameTextTarget:[FakeGameTextView new]];

    [dictation begin];
    CHECK((dictation.state == AKDictationStateListening), @"the real bridge starts a session");
    CHECK(([session.category isEqualToString:AVAudioSessionCategoryRecord]),
          @"and takes the session for recording, got %@", session.category);

    [dictation end];
    [speech say:@"done" final:YES];
    CHECK(([session.category isEqualToString:AVAudioSessionCategoryPlayback]),
          @"and puts the category it found back, got %@", session.category);
    CHECK(([session.mode isEqualToString:AVAudioSessionModeMoviePlayback]),
          @"and the mode, got %@", session.mode);

    [AKDictation setGameTextTarget:nil];
    [dictation cancel];
}

// A screenshot is not attributable to a controller, so it is not a voice trigger and cannot
// be stored as one. The remediation review's point: offering it for the user to map only
// moves the guess to them, because nothing in the notification says whether a pad or a
// thumb on the screen produced it.
static void TestScreenshotIsolation(void) {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    for (NSString *key in defaults.dictionaryRepresentation.allKeys)
        if ([key hasPrefix:@"AKInputTrigger."]) [defaults removeObjectForKey:key];

    AKDictation *dictation = AKDictation.shared;
    FakeSpeech *speech = [FakeSpeech new];
    FakeAudio *audio = [FakeAudio new];
    dictation.speech = speech;
    dictation.audio = audio;
    AKVoiceSettings *settings = AKVoiceSettings.shared;

    // Wire it the way Shell/main.m does, so what is tested is the real wiring.
    AKInputRouter.shared.onTrigger = ^(AKTrigger *trigger, AKInputEvent *event) {
        (void)trigger; (void)event;
        [AKDictation.shared toggle];
    };
    AKInputRouter.shared.onTriggerBegan = ^(AKTrigger *trigger, AKInputEvent *event) {
        (void)trigger; (void)event;
        [AKDictation.shared begin];
    };
    AKInputRouter.shared.onTriggerEnded = ^(AKTrigger *trigger, AKInputEvent *event) {
        (void)trigger; (void)event;
        [AKDictation.shared end];
    };

    settings.enabled = NO;
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationUserDidTakeScreenshotNotification object:nil];
    Pump(0.1);
    CHECK((speech.starts == 0), @"a screenshot must not start dictation while the feature is off");

    settings.enabled = YES;
    [NSNotificationCenter.defaultCenter postNotificationName:UIApplicationUserDidTakeScreenshotNotification object:nil];
    Pump(0.1);
    CHECK((speech.starts == 0), @"nor with it on and a controller mapped, because it is not an input at all");

    [NSNotificationCenter.defaultCenter postNotificationName:UIScreenCapturedDidChangeNotification object:nil];
    Pump(0.1);
    CHECK((speech.starts == 0), @"and neither must a screen capture");

    // It cannot be stored as a mapping either.
    CHECK(([AKTrigger triggerFromStored:@{@"element": @"system.screenshot", @"pattern": @0}] == nil),
          @"a system signal must not be storable as a voice trigger");

    // And a mapping left by an earlier build is dropped rather than resurrected. A user who
    // pressed a button to map it did choose something, but what they chose cannot be told
    // apart from a thumb on the screen, so it goes - loudly, so the log explains it.
    [defaults setObject:@{@"element": @"Share", @"pattern": @0} forKey:@"AKInputTrigger.pad"];
    NSUInteger dropped = [AKTrigger migrateStoredTriggersInDefaults:defaults];
    CHECK((dropped == 1), @"a stored system mapping is removed, got %lu", (unsigned long)dropped);
    CHECK(([defaults dictionaryForKey:@"AKInputTrigger.pad"] == nil), @"and is gone from the database");
    CHECK(([settings triggerForDevice:@"pad"] == nil), @"so nothing is left to fire");

    settings.enabled = NO;
    dictation.transcriptHandler = nil;
}

static void TestDictation(void) {
    AKDictation *dictation = AKDictation.shared;
    FakeSpeech *speech = [FakeSpeech new];
    FakeAudio *audio = [FakeAudio new];
    dictation.speech = speech;
    dictation.audio = audio;
    dictation.finalizeTimeout = 0.2;
    __block NSMutableArray<NSString *> *heard = [NSMutableArray array];
    dictation.transcriptHandler = ^(NSString *text) { [heard addObject:text]; };
    __block NSString *problem = nil;
    dictation.problemHandler = ^(NSString *message) { problem = message; };
    AKVoiceSettings.shared.enabled = YES;
    AKVoiceSettings.shared.autoSubmit = NO;
    AKVoiceSettings.shared.trailingSpace = NO;

    // A refused permission: nothing opens, and the user is told.
    speech.authorized = NO;
    [dictation begin];
    CHECK((dictation.state == AKDictationStateIdle), @"a refused permission leaves it idle");
    CHECK((audio.begins == 0), @"and the audio session is never taken");
    CHECK((problem.length > 0), @"and the user is told why");
    speech.authorized = YES;

    // A device that cannot recognise speech on its own is refused, not sent away.
    speech.onDevice = NO;
    [dictation begin];
    CHECK((dictation.state == AKDictationStateIdle && speech.starts == 0), @"no on-device recognition means no session");
    speech.onDevice = YES;

    // The audio session refusing is reported and nothing is left open.
    audio.refuse = YES;
    [dictation begin];
    CHECK((dictation.state == AKDictationStateIdle && speech.starts == 0), @"an audio session that will not start stops it");
    audio.refuse = NO;

    // The final result is what is delivered, not the last partial. This is the audit's
    // "the last words can arrive after the text has gone".
    [heard removeAllObjects];
    [dictation begin];
    CHECK((dictation.state == AKDictationStateListening), @"the microphone is open");
    [speech say:@"hello" final:NO];
    [dictation end];
    CHECK((dictation.state == AKDictationStateFinalizing), @"ending the audio waits for the last words");
    CHECK((heard.count == 0), @"and nothing is delivered while it waits");
    [speech say:@"hello world" final:YES];
    CHECK((heard.count == 1 && [heard.firstObject isEqualToString:@"hello world"]),
          @"the final result is what is delivered, got %@", heard);
    CHECK((dictation.state == AKDictationStateIdle), @"and the session is over");
    CHECK((audio.restores > 0 && !audio.recording), @"the audio session was given back");

    // A late final result after delivery must not deliver again.
    [speech say:@"hello world again" final:YES];
    CHECK((heard.count == 1), @"exactly once, even if the recogniser says so twice");

    // If the last words never come, nothing is delivered and the user is told. What is in
    // hand is a partial result; the product promises a final transcript, and half a sentence
    // in the game's chat box - sent, if auto-submit is on - is worse than none.
    [heard removeAllObjects];
    problem = nil;
    NSUInteger restoresBefore = audio.restores;
    [dictation begin];
    [speech say:@"half a sentence" final:NO];
    [dictation end];
    Pump(0.6);
    CHECK((heard.count == 0), @"a recogniser that never finishes must not have a partial delivered, got %@", heard);
    CHECK((problem.length > 0), @"and the user is told why nothing happened");
    CHECK((dictation.state == AKDictationStateIdle), @"and the session ends");
    CHECK((audio.restores > restoresBefore), @"with the audio session given back");

    // Something else taking the audio ends the session rather than leaving the microphone
    // open behind a session we no longer own.
    [heard removeAllObjects];
    [dictation begin];
    [speech say:@"interrupted" final:NO];
    [NSNotificationCenter.defaultCenter postNotificationName:AVAudioSessionInterruptionNotification
                                                      object:nil
                                                    userInfo:@{AVAudioSessionInterruptionTypeKey: @(AVAudioSessionInterruptionTypeBegan)}];
    CHECK((dictation.state == AKDictationStateIdle), @"an interruption ends the session");
    CHECK((heard.count == 0), @"and delivers nothing");

    // Repeated triggers while it is already listening are the same press.
    [heard removeAllObjects];
    NSUInteger startsBefore = speech.starts;
    [dictation begin];
    [dictation begin];
    [dictation begin];
    CHECK((speech.starts == startsBefore + 1), @"three presses while it is open are one session");
    [dictation cancel];

    // Rapid toggles: each utterance is delivered once and they do not run together.
    [heard removeAllObjects];
    [dictation toggle];
    [speech say:@"one" final:NO];
    [dictation toggle];
    [speech say:@"one" final:YES];
    [dictation toggle];
    [speech say:@"two" final:NO];
    [dictation toggle];
    [speech say:@"two" final:YES];
    CHECK((heard.count == 2 && [heard[0] isEqualToString:@"one"] && [heard[1] isEqualToString:@"two"]),
          @"two utterances, two deliveries, in order: got %@", heard);

    // Cancel delivers nothing at all.
    [heard removeAllObjects];
    [dictation begin];
    [speech say:@"never mind" final:NO];
    [dictation cancel];
    [speech say:@"never mind" final:YES];
    CHECK((heard.count == 0), @"a cancelled session delivers nothing");
    CHECK((dictation.state == AKDictationStateIdle), @"and ends");

    dictation.transcriptHandler = nil;
    dictation.problemHandler = nil;
}

static void TestTypingIntoTheGame(void) {
    AKDictation *dictation = AKDictation.shared;
    FakeSpeech *speech = [FakeSpeech new];
    FakeAudio *audio = [FakeAudio new];
    dictation.speech = speech;
    dictation.audio = audio;
    dictation.transcriptHandler = nil;   // the game's path, not a screen's
    AKVoiceSettings.shared.enabled = YES;
    AKVoiceSettings.shared.trailingSpace = NO;
    AKVoiceSettings.shared.autoSubmit = NO;

    // Nothing registered: nothing is typed anywhere. The old code searched every window
    // in every scene for the private selector, which is what this replaces.
    [AKDictation setGameTextTarget:nil];
    [dictation begin];
    [speech say:@"into the void" final:NO];
    [dictation end];
    [speech say:@"into the void" final:YES];
    CHECK((dictation.state == AKDictationStateIdle), @"it still ends cleanly with no target");

    FakeGameTextView *target = [FakeGameTextView new];
    [AKDictation setGameTextTarget:target];
    [dictation begin];
    [speech say:@"for the horde" final:NO];
    [dictation end];
    [speech say:@"for the horde" final:YES];
    CHECK((target.inserts == 1 && [target.lastText isEqualToString:@"for the horde"]),
          @"the words go into the game's own view, got %@", target.lastText);
    CHECK((target.returns == 0), @"and Return only when it was asked for");

    AKVoiceSettings.shared.autoSubmit = YES;
    AKVoiceSettings.shared.trailingSpace = YES;
    [dictation begin];
    [speech say:@"again" final:NO];
    [dictation end];
    [speech say:@"again" final:YES];
    CHECK(([target.lastText isEqualToString:@"again "]), @"the trailing space is theirs, got '%@'", target.lastText);
    CHECK((target.returns == 1), @"and auto-submit sends Return once");
    AKVoiceSettings.shared.autoSubmit = NO;
    AKVoiceSettings.shared.trailingSpace = NO;
    [AKDictation setGameTextTarget:nil];
}

static void TestConfigCorpus(void) {
    NSString *problem = nil;
    NSDictionary *file = @{@"version": @1, @"settings": @{@"WoWRegion": @"eu", @"AKVoiceMode": @1}};
    NSDictionary *accepted = [TKWolkaraConfig validatedSettingsFromFile:file problem:&problem];
    CHECK((accepted.count == 2 && problem == nil), @"a good file is accepted whole");

    // The shape of the file.
    CHECK(([TKWolkaraConfig validatedSettingsFromFile:nil problem:&problem].count == 0 && problem.length), @"nil is not a file");
    CHECK(([TKWolkaraConfig validatedSettingsFromFile:(id)@[@1] problem:&problem].count == 0 && problem.length), @"an array is not a file");
    CHECK(([TKWolkaraConfig validatedSettingsFromFile:@{@"settings": @{}} problem:&problem].count == 0 && problem.length),
          @"a file with no version is refused");
    CHECK(([TKWolkaraConfig validatedSettingsFromFile:@{@"version": @99, @"settings": @{}} problem:&problem].count == 0 && problem.length),
          @"a file from a newer version is refused");
    CHECK(([TKWolkaraConfig validatedSettingsFromFile:@{@"version": @1} problem:&problem].count == 0 && problem.length),
          @"a file with no settings is refused");

    // Values that must not get through.
    NSDictionary *bad = @{@"version": @1, @"settings": @{
        @"WoWRegion": @"mars",
        @"WoWProduct": @"not a name!",
        @"WoWLocale": @7,
        @"AKVoiceMode": @9,
        @"AKVoiceEnabled": @"yes",
        @"AKVoiceAutoSubmit": @2,
        @"AKVoiceTrailingSpace": @[@1],
        @"AKVoiceCustomWords": @[@"ok", @42],
        @"AKNotOurs": @"whatever",
        @"AKInputTrigger.pad": @{@"element": @"not a thing we know", @"pattern": @0},
        @"AKInputTrigger.bad": @{@"element": @"controller.button.a", @"pattern": @99},
    }};
    accepted = [TKWolkaraConfig validatedSettingsFromFile:bad problem:&problem];
    CHECK((accepted.count == 0), @"every value in that file is unusable, got %lu", (unsigned long)accepted.count);
    CHECK((problem.length > 0), @"and the refusal is described");

    // A file with one good value and one bad one keeps the good one.
    NSDictionary *mixed = @{@"version": @1, @"settings": @{@"WoWRegion": @"us", @"AKVoiceMode": @5}};
    accepted = [TKWolkaraConfig validatedSettingsFromFile:mixed problem:&problem];
    CHECK((accepted.count == 1 && [accepted[@"WoWRegion"] isEqualToString:@"us"]),
          @"a valid value beside an invalid one still stands");
    CHECK((problem.length > 0), @"and the invalid one is reported");

    // A trigger that is valid, to prove the schema does not simply refuse everything.
    NSDictionary *mapping = @{@"version": @1, @"settings": @{
        @"AKInputTrigger.pad": @{@"element": @"controller.button.share", @"pattern": @0, @"hold": @0.6}}};
    accepted = [TKWolkaraConfig validatedSettingsFromFile:mapping problem:&problem];
    CHECK((accepted.count == 1), @"a valid mapping is accepted");

    // And the file the app writes is a file the app would accept.
    [TKWolkaraConfig.shared save];
    NSData *data = [NSData dataWithContentsOfFile:TKWolkaraConfig.shared.path];
    CHECK((data.length > 0), @"the app writes a config file");
    id written = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    CHECK(([written isKindOfClass:NSDictionary.class]), @"and it is JSON");
    CHECK(([written[@"version"] integerValue] == 1), @"with the version it claims");
    NSString *roundTrip = nil;
    [TKWolkaraConfig validatedSettingsFromFile:written problem:&roundTrip];
    CHECK((roundTrip == nil), @"and nothing in it is refused, got %@", roundTrip);
}

// The two pages, and what they do to dictation when they come and go.
//
// The audit's finding here: the test screen replaces AKDictation's handlers globally, so
// every path that takes the screen away has to put them back - and a transcript that
// arrives after it is gone must not land in the game's chat box.
static void TestVoiceScreens(UIWindow *window) {
    UIViewController *host = [UIViewController new];
    UINavigationController *navigation = [[UINavigationController alloc] initWithRootViewController:host];
    window.rootViewController = navigation;
    [window makeKeyAndVisible];
    [window layoutIfNeeded];

    AKDictation *dictation = AKDictation.shared;
    FakeSpeech *speech = [FakeSpeech new];
    FakeAudio *audio = [FakeAudio new];
    dictation.speech = speech;
    dictation.audio = audio;
    AKVoiceSettings.shared.enabled = NO;
    AKVoiceSettings.shared.mode = AKVoiceModeHold;

    // --- the settings page
    AKVoiceViewController *settings = [AKVoiceViewController new];
    [navigation pushViewController:settings animated:NO];
    Pump(0.2);
    UISwitch *enabled = (id)Find(settings.view, @"voice.enabled");
    CHECK((enabled != nil), @"the settings page has the switch that turns voice on");
    CHECK((enabled.on == AKVoiceSettings.shared.enabled), @"and it shows the setting");
    UILabel *mapping = (id)Find(settings.view, @"voice.mapping");
    CHECK((mapping.text.length > 0), @"and it says what is mapped, got nothing");
    CHECK((Find(settings.view, @"voice.map") != nil), @"and it has the Map button");
    // The audit's finding: the router observes input and the game observes it too, so a
    // mapped button keeps doing its game action. The product is limited to explicitly
    // mapped inputs and says so where the mapping is made; if that sentence ever goes
    // away, the limit is no longer stated anywhere the user will see it.
    UILabel *collision = (id)Find(settings.view, @"voice.mapping.collision");
    CHECK((collision != nil), @"and it says the mapped button still reaches the game");
    CHECK(([collision.text containsString:@"still reaches the game"]), @"in those words, got: %@", collision.text);
    // And it does not offer patterns it cannot honour: two modes, not four patterns.
    UISegmentedControl *mode = (id)Find(settings.view, @"voice.mode");
    CHECK((mode.numberOfSegments == 2), @"and offers two modes, not the model's four patterns");
    // Leaving the page must not leave the mapper armed.
    [AKInputRouter.shared beginLearning];
    [navigation popViewControllerAnimated:NO];
    Pump(0.2);
    CHECK((!AKInputRouter.shared.learning), @"leaving the settings page disarms the mapper");

    // --- the test screen
    AKVoiceTestViewController *page = [AKVoiceTestViewController new];
    [navigation pushViewController:page animated:NO];
    Pump(0.2);
    CHECK((dictation.transcriptHandler != nil), @"the test screen claims the words while it is up");
    CHECK((dictation.listeningChanged != nil && dictation.stateChanged != nil && dictation.problemHandler != nil),
          @"and the state, the microphone changes and the problems");

    // A result that arrives after the screen has gone must not be typed into the game.
    // This is the hazard the audit named: the recogniser can call back once more after
    // the screen has taken its handlers away, and the words would land in the game's
    // chat box on the way out.
    FakeGameTextView *target = [FakeGameTextView new];
    [AKDictation setGameTextTarget:target];
    [dictation begin];
    Pump(0.1);
    CHECK((dictation.state == AKDictationStateListening), @"the test screen can start a session");
    void (^inFlight)(NSString *, BOOL, NSError *) = speech.handler;
    CHECK((inFlight != nil), @"and the recogniser has somewhere to report");
    [navigation popViewControllerAnimated:NO];
    Pump(0.2);
    CHECK((dictation.transcriptHandler == nil && dictation.listeningChanged == nil &&
           dictation.stateChanged == nil && dictation.problemHandler == nil),
          @"and lets go of every handler when it goes away");
    CHECK((dictation.state == AKDictationStateIdle), @"and stops the microphone on the way out");
    if (inFlight) inFlight(@"too late", YES, nil);
    CHECK((target.inserts == 0), @"so a result in flight when the screen left is dropped");
    CHECK((dictation.state == AKDictationStateIdle), @"and the session stays over");

    // With voice off, the screen says so rather than looking ready.
    AKVoiceSettings.shared.enabled = NO;
    [navigation pushViewController:page animated:NO];
    Pump(0.2);
    UILabel *button = (id)Find(page.view, @"voice.test.button");
    CHECK(([button.text containsString:@"switched off"]), @"the test screen says when voice is off, got %@", button.text);
    [navigation popViewControllerAnimated:NO];
    Pump(0.2);

    [AKDictation setGameTextTarget:nil];
    dictation.transcriptHandler = nil;
    dictation.listeningChanged = nil;
    dictation.stateChanged = nil;
    dictation.problemHandler = nil;
}

// The parts of the file's life that only happen when something is wrong: a file that was
// cut off halfway, a write that cannot happen, and the previous good copy.
static void TestConfigRecovery(void) {
    TKWolkaraConfig *config = TKWolkaraConfig.shared;
    NSFileManager *files = NSFileManager.defaultManager;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *directory = config.path.stringByDeletingLastPathComponent;

    // A good file, copied aside, then cut off halfway: the previous copy is used and the
    // refused file is kept rather than overwritten by the next save.
    [defaults setObject:@"us" forKey:@"WoWRegion"];
    [config save];
    [files removeItemAtPath:config.backupPath error:NULL];
    [files copyItemAtPath:config.path toPath:config.backupPath error:NULL];
    [defaults removeObjectForKey:@"WoWRegion"];
    [@"{\"version\": 1, \"settings\": {\"WoWRegion\": \"e" writeToFile:config.path
                                                            atomically:YES
                                                              encoding:NSUTF8StringEncoding
                                                                 error:NULL];
    [config reloadFromFile];
    CHECK(([files fileExistsAtPath:config.rejectedPath]), @"a file that cannot be read is kept, not lost");
    CHECK(([[defaults stringForKey:@"WoWRegion"] isEqualToString:@"us"]),
          @"and the previous good copy is used, got %@", [defaults stringForKey:@"WoWRegion"]);

    // A partial file with no copy to fall back on: nothing is applied and nothing is lost.
    [files removeItemAtPath:config.backupPath error:NULL];
    [defaults setObject:@"eu" forKey:@"WoWRegion"];
    [@"{\"version\": 1" writeToFile:config.path atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [config reloadFromFile];
    CHECK(([[defaults stringForKey:@"WoWRegion"] isEqualToString:@"eu"]),
          @"a file that cannot be read changes nothing");
    CHECK((config.lastImportProblem.length > 0), @"and it says what was wrong with it");

    // A file with one bad value and one good one keeps the good one and reports the bad.
    [config save];
    [files removeItemAtPath:config.backupPath error:NULL];
    NSDictionary *mixed = @{@"version": @1, @"settings": @{@"WoWRegion": @"kr", @"AKVoiceMode": @77}};
    [[NSJSONSerialization dataWithJSONObject:mixed options:0 error:NULL] writeToFile:config.path atomically:YES];
    [config reloadFromFile];
    CHECK(([[defaults stringForKey:@"WoWRegion"] isEqualToString:@"kr"]), @"a valid value beside an invalid one is applied");
    CHECK((config.lastImportProblem.length > 0), @"and the invalid one is reported");

    // A write that cannot happen leaves the file it could not replace intact.
    [config save];
    NSData *before = [NSData dataWithContentsOfFile:config.path];
    [files setAttributes:@{NSFilePosixPermissions: @(0500)} ofItemAtPath:directory error:NULL];
    [defaults setObject:@"tw" forKey:@"WoWRegion"];
    [config save];
    NSData *after = [NSData dataWithContentsOfFile:config.path];
    [files setAttributes:@{NSFilePosixPermissions: @(0755)} ofItemAtPath:directory error:NULL];
    CHECK((before.length > 0 && [before isEqualToData:after]),
          @"a write that fails must leave the previous file whole");

    // And the file is healthy again once it can be written.
    [config save];
    CHECK(([NSData dataWithContentsOfFile:config.path].length > 0), @"and it writes again when it can");
    [config reloadFromFile];
    CHECK((config.lastImportProblem == nil), @"with nothing left to complain about, got %@", config.lastImportProblem);
    [defaults removeObjectForKey:@"WoWRegion"];
}

// A malformed file beside an unusable copy, which is the case the remediation review
// named: both are reachable from the user-editable Documents boundary, and the first
// version copied the copy over the file and read it again - round and round until the stack
// ran out. Reaching the end of this function without a crash is most of the test.
// A file far larger than a config file can be. It is read at launch from a directory the
// user can write to, so it is refused before it is parsed.
static void TestConfigOversized(void) {
    TKWolkaraConfig *config = TKWolkaraConfig.shared;
    NSFileManager *files = NSFileManager.defaultManager;
    NSMutableData *huge = [NSMutableData dataWithLength:3 * 1024 * 1024];
    [huge replaceBytesInRange:NSMakeRange(0, 4) withBytes:"[1,2"];
    [files removeItemAtPath:config.backupPath error:NULL];
    [huge writeToFile:config.path atomically:YES];
    [config reloadFromFile];
    CHECK((config.lastImportProblem.length > 0), @"a file too large to be a config file is refused");
    CHECK(([files fileExistsAtPath:config.rejectedPath]), @"and kept rather than read");
}

static void TestConfigRecursion(void) {
    TKWolkaraConfig *config = TKWolkaraConfig.shared;
    NSFileManager *files = NSFileManager.defaultManager;
    NSDictionary *good = @{@"version": @1, @"settings": @{@"WoWRegion": @"eu"}};

    // A primary that is cut off halfway, and a copy that is cut off the same way.
    [@"{\"version\": 1, \"settings\": {\"WoWRegion\": \"e" writeToFile:config.path
                                                             atomically:YES
                                                               encoding:NSUTF8StringEncoding
                                                                  error:NULL];
    [files removeItemAtPath:config.backupPath error:NULL];
    [@"{\"version\": 1, \"settings\": {\"WoWRegion\": \"e" writeToFile:config.backupPath
                                                             atomically:YES
                                                               encoding:NSUTF8StringEncoding
                                                                  error:NULL];
    [config reloadFromFile];
    CHECK((config.lastImportProblem.length > 0), @"a bad file beside a bad copy is reported");
    CHECK(([NSData dataWithContentsOfFile:config.path].length > 0), @"and it leaves a file on disk");

    // A copy that is valid JSON and still not a config file.
    [files removeItemAtPath:config.backupPath error:NULL];
    [@"[1, 2, 3]" writeToFile:config.backupPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    [config reloadFromFile];
    CHECK((config.lastImportProblem.length > 0), @"a copy that is JSON but not our JSON is refused too");

    // And the file the app writes is still one it can read.
    [files removeItemAtPath:config.backupPath error:NULL];
    [config save];
    CHECK(([NSData dataWithContentsOfFile:config.path].length > 0), @"the app writes its own file again");
    [config reloadFromFile];
    CHECK((config.lastImportProblem == nil), @"and reading it is clean, got %@", config.lastImportProblem);
    (void)good;
}

// A write that cannot happen, which the audit's list asks for by name: what does the app
// do when the file cannot be written, and does the user lose the file that is already
// there?
//
// The obstruction is a directory where the temporary file goes. That fails the write
// without touching the permissions of Documents, which is where the log this test then
// reads also lives - a chmod there would take the evidence away along with the failure it
// was meant to demonstrate.
static void TestConfigWriteFailure(void) {
    TKWolkaraConfig *config = TKWolkaraConfig.shared;
    NSFileManager *files = NSFileManager.defaultManager;
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSString *obstruction = [config.path stringByAppendingPathExtension:@"writing"];

    // A file to protect: the write below must not be able to take it away.
    [files removeItemAtPath:obstruction error:NULL];
    [files removeItemAtPath:config.path error:NULL];
    [defaults setObject:@"eu" forKey:@"WoWRegion"];
    [config save];
    NSData *before = [NSData dataWithContentsOfFile:config.path];
    CHECK((before.length > 0), @"a config file to protect before the failing write");

    CHECK(([files createDirectoryAtPath:obstruction withIntermediateDirectories:NO attributes:nil error:NULL]),
          @"the write can be obstructed for the test");

    [defaults setObject:@"us" forKey:@"WoWRegion"];
    WKLog("test", @"a write failure is being provoked now");
    [config save];

    NSData *after = [NSData dataWithContentsOfFile:config.path];
    CHECK([after isEqualToData:before], @"a write that fails leaves the file that was there alone");
    CHECK(([files fileExistsAtPath:obstruction]), @"and does not remove what was in the way, which was not its to remove");

    // And it says so, in the log the user can read, rather than only failing quietly.
    NSString *log = [NSString stringWithContentsOfFile:WKLogPath() encoding:NSUTF8StringEncoding error:NULL] ?: @"";
    CHECK(([log containsString:@"could not write wolkara-config.json.writing"]), @"and the log names what could not be written");
    CHECK(([log containsString:@"a write failure is being provoked now"]), @"(the log is the app's own, being read back)");

    // Nothing is broken for good: once the way is clear, the next write lands.
    [files removeItemAtPath:obstruction error:NULL];
    [config save];
    NSData *recovered = [NSData dataWithContentsOfFile:config.path];
    CHECK((recovered.length > 0), @"and the next write works once the obstruction is gone");
    [config reloadFromFile];
    CHECK((config.lastImportProblem == nil), @"and what it wrote reads back cleanly, got %@", config.lastImportProblem);
    CHECK(([defaults stringForKey:@"WoWRegion"] != nil), @"with the settings still where they were");
    [defaults removeObjectForKey:@"WoWRegion"];
}

#pragma mark - Running them

@interface TestDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic) UIWindow *window;
@end

@implementation TestDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session; (void)options;
    WKLogStart();
    WKLog("test", @"voice suite starting");
    // A fixture that can hang is not a test: it is a build that never finishes. This one is
    // bounded by the runner too, but the watchdog means a hang says so in the log rather
    // than leaving an empty screen and a mystery.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        fprintf(stderr, "VOICE TIMEOUT\n");
        _Exit(1);
    });
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [UIViewController new];
    [self.window makeKeyAndVisible];

    // The router and the inspector are what the real app starts; starting them here
    // means the screenshot path is exercised end to end rather than in pieces.
    [AKInputRouter.shared begin];

    TestElements();
    TestTriggers();
    TestSettings();
    TestLearning();
    TestTriggerPatterns();
    TestAudioSessionPolicy();
    TestScreenshotIsolation();
    TestDictation();
    TestTypingIntoTheGame();
    TestVoiceScreens(self.window);
    TestConfigCorpus();
    TestConfigRecovery();
    TestConfigOversized();
    TestConfigRecursion();
    TestConfigWriteFailure();

    if (failures == 0) {
        printf("VOICE PASS: %lu checks\n", (unsigned long)checks);
        fflush(stdout);
        exit(0);
    }
    printf("VOICE FAIL: %lu of %lu checks failed\n", (unsigned long)failures, (unsigned long)checks);
    fflush(stdout);
    exit(1);
}
@end

// A scene-based app needs to say which object is the scene's delegate; without this
// the scene never connects and the suite silently does nothing.
@interface TestApp : UIResponder <UIApplicationDelegate>
@end

@implementation TestApp
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session
                                   options:(UISceneConnectionOptions *)options {
    (void)application; (void)options;
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Voice tests"
                                                                        sessionRole:session.role];
    configuration.delegateClass = TestDelegate.class;
    return configuration;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(TestApp.class));
    }
}
