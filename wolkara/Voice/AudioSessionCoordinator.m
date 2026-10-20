// Wolkara: the one owner of the audio session. See the header for why it exists.

#import "AudioSessionCoordinator.h"
#import "../App/WolkaraLog.h"

#import <AVFAudio/AVFAudio.h>
#include <dlfcn.h>

NSNotificationName const AKAudioPushToTalkLeaseDidChangeNotification =
    @"AKAudioSessionPushToTalkLeaseDidChange";

// A key that says "this thread is already inside a transition". It exists because the coordinator's own
// work calls the platform's session code, which asks the adapter for the output name, which asks the
// coordinator for the game's lease again - and dispatch_sync on a serial queue from inside that queue is
// a deadlock. That deadlock hung the app so that SIGTERM never landed, and the install timed out waiting
// for it to stop. Re-entry runs inline; everything else is serialised as before.
static char const AKAudioCoordinatorQueueKey;

@implementation AKAudioSessionCoordinator {
    // One transition at a time. The session's own API is asynchronous underneath, and two
    // transitions interleaving is exactly how a session ends up somewhere nobody asked for.
    dispatch_queue_t _transitions;
    AKAudioLease _lease;
    BOOL _pushToTalk;
    // Whether the game runtime wants playback. It can ask while push to talk holds the session, and
    // the answer then is "yes, when this is over" rather than "no" - which is the difference
    // between obeying the declared policy on release and guessing at it. The first version of this
    // logged the request and forgot it, so releasing put the session back to nothing.
    BOOL _gameWantsPlayback;
    NSString *_lastTransition;
    BOOL _observing;
}

+ (instancetype)shared {
    static AKAudioSessionCoordinator *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[AKAudioSessionCoordinator alloc] init]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _transitions = dispatch_queue_create("wolkara.audio.session", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_transitions, &AKAudioCoordinatorQueueKey, (void *)&AKAudioCoordinatorQueueKey, NULL);
        _lease = AKAudioLeaseNone;
        _lastTransition = @"none yet";
        // Reading the microphone permission needs no recording, so it can be answered at launch instead
        // of during a hold. It has to be read here because it is the one fact that cannot be told apart
        // from anywhere else in this class: when iOS has not granted it, the session still activates and
        // reports PlayAndRecord, the built-in microphone, input available, and the engine still runs -
        // the tap still fires with correctly shaped buffers - and every sample in them is exactly 0.0.
        // Nothing else in the audio chain looks wrong, because nothing else is.
        dispatch_async(dispatch_get_main_queue(), ^{ [self logMicrophonePermission]; });
    }
    return self;
}

- (void)logMicrophonePermission {
    NSString *mic = @"unknown";
    switch (AVAudioSession.sharedInstance.recordPermission) {
        case AVAudioSessionRecordPermissionUndetermined: mic = @"UNDETERMINED - never asked for"; break;
        case AVAudioSessionRecordPermissionDenied: mic = @"DENIED"; break;
        case AVAudioSessionRecordPermissionGranted: mic = @"granted"; break;
    }
    WKLog("audio", @"microphone permission: %@", mic);
}

// On the queue, or inline if this thread is already on it. See AKAudioCoordinatorQueueKey.
- (void)onTheQueue:(void (^)(void))work {
    if (dispatch_get_specific(&AKAudioCoordinatorQueueKey)) { work(); return; }
    dispatch_sync(_transitions, work);
}

- (AKAudioLease)lease { return _lease; }
- (BOOL)pushToTalkActive { return _pushToTalk; }
- (NSString *)lastTransition { return _lastTransition; }

#pragma mark - What the session is doing

// What the session is doing, for a log line or a screen. The review outcome's Phase 2 asks for the
// route, the sample rate, the channel count and whether input is available - the actual current
// route, not the preferred one, because Apple's API distinguishes them and a preference is not
// proof of anything.
- (NSString *)describeSession {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSString *route = session.currentRoute.inputs.firstObject.portType ?: @"no input";
    return [NSString stringWithFormat:@"%@/%@ %@ %.0fHz %luch in=%d",
            session.category, session.mode, route, session.sampleRate,
            (unsigned long)session.inputNumberOfChannels, (int)session.isInputAvailable];
}

// One line per transition, always the same shape, so that a session's whole history can be read
// back from the log without guessing which call did what.
- (void)logTransitionFrom:(NSString *)from to:(NSString *)to result:(BOOL)ok error:(NSError *)error {
    _lastTransition = [NSString stringWithFormat:@"%@ -> %@ (%@) %@%@",
                       from, to, [self describeSession], ok ? @"ok" : @"FAILED",
                       error ? [NSString stringWithFormat:@": %@", error.localizedDescription] : @""];
    WKLog("audio", @"session: %@", _lastTransition);
}

#pragma mark - The states

// Playback, active: the game's lease. The adapter asks for this, and only when it is not already
// the case, because setting the category is what interrupts other apps.
- (BOOL)requestGamePlayback:(NSString *)why {
    __block BOOL ok = NO;
    [self onTheQueue:^{
        NSString *from = [self nameForLease:_lease];
        if (_lease == AKAudioLeasePushToTalk) {
            // Push to talk owns the session right now. The wish is recorded and honoured when the
            // lease ends - forcing playback here is what used to kill a running dictation - and the
            // answer is yes, because the request has been accepted rather than refused. The session
            // is in the state the policy says it should be in: push to talk.
            _gameWantsPlayback = YES;
            WKLog("audio", @"session: playback wanted (%@) while push to talk holds the session", why);
            ok = YES;
            return;
        }
        _gameWantsPlayback = YES;
        _lease = AKAudioLeaseGame;
        ok = [self applyPlaybackForGame];
        [self logTransitionFrom:from to:@"game" result:ok error:nil];
    }];
    return ok;
}

- (void)releaseGamePlayback {
    [self onTheQueue:^{
        _gameWantsPlayback = NO;
        if (_lease != AKAudioLeaseGame) return;
        NSString *from = [self nameForLease:_lease];
        _lease = AKAudioLeaseNone;
        NSError *error = nil;
        BOOL ok = [self releaseSession:&error];
        [self logTransitionFrom:from to:@"idle" result:ok error:error];
    }];
}

- (BOOL)beginPushToTalk:(NSError **)error {
    __block BOOL ok = NO;
    __block NSError *failure = nil;
    [self onTheQueue:^{
        NSString *from = [self nameForLease:_lease];
        AVAudioSession *session = AVAudioSession.sharedInstance;
        // Record, which is what this feature shipped with and what worked. It was changed to
        // PlayAndRecord with DefaultToSpeaker and AllowBluetooth so that the game stayed audible while
        // the user talked. That change is the only capture-side difference between the version that
        // transcribed speech and the one where every sample is exactly 0.0 - the speakerphone path puts
        // capture behind echo cancellation, and this is an input-only engine, not a call. A microphone
        // that delivers digital silence is worth far more than game audio for the two seconds a
        // dictation lasts, and the game's playback is restored the moment the hold ends.
        //
        // Measured before this change, with everything else correct: permission granted,
        // PlayAndRecord/Default on the built-in microphone at 48000Hz, the engine running, the tap
        // firing with well-formed float32 buffers, and the loudest sample 0.00000 for the whole hold.
        if (![session setCategory:AVAudioSessionCategoryRecord
                             mode:AVAudioSessionModeDefault
                          options:0
                            error:&failure]) {
            [self logTransitionFrom:from to:@"push-to-talk" result:NO error:failure];
            return;
        }
        // No preferred input. The version that transcribed speech never set one, and setting it is the
        // last capture-side difference left between that version and this one: it chooses a microphone
        // port by name, where the system's own choice is what fed the working build. Measured with a
        // preferred input set, on Record and on PlayAndRecord alike: every sample was exactly 0.0 while
        // the route still reported the built-in microphone. If the input is silent for that reason, this
        // is what removes it; the route is read back in the log either way, so nothing is assumed.
        if (![session setActive:YES error:&failure]) {
            [self logTransitionFrom:from to:@"push-to-talk" result:NO error:failure];
            return;
        }
        _lease = AKAudioLeasePushToTalk;
        _pushToTalk = YES;
        [self startObserving];
        ok = YES;
        [self logTransitionFrom:from to:@"push-to-talk" result:YES error:nil];
    }];
    if (!ok && error) *error = failure;
    if (ok) {
        [NSNotificationCenter.defaultCenter
            postNotificationName:AKAudioPushToTalkLeaseDidChangeNotification
                          object:self userInfo:@{@"active": @YES}];
    }
    return ok;
}

- (BOOL)endPushToTalk:(NSError **)error {
    __block BOOL ok = NO;
    __block NSError *failure = nil;
    [self onTheQueue:^{
        if (!_pushToTalk) { ok = YES; return; }   // nothing to hand back, and no state claimed
        NSString *from = @"push-to-talk";
        _pushToTalk = NO;
        AVAudioSession *session = AVAudioSession.sharedInstance;
        // The preference goes with the lease: it was asked for by push to talk, and leaving it
        // behind would silently change where the game's own audio comes from. Push to talk no longer
        // sets one (see beginPushToTalk), and this still clears anything an earlier build left behind.
        [session setPreferredInput:nil error:NULL];
        if (_gameWantsPlayback) {
            _lease = AKAudioLeaseGame;
            ok = [self applyPlaybackForGame];
            [self logTransitionFrom:from to:@"game" result:ok error:failure];
        } else {
            _lease = AKAudioLeaseNone;
            ok = [self applyLauncherPolicy:&failure];
            [self logTransitionFrom:from to:@"idle" result:ok error:failure];
        }
    }];
    if (!ok && error) *error = failure;
    if (!_pushToTalk) {
        [NSNotificationCenter.defaultCenter
            postNotificationName:AKAudioPushToTalkLeaseDidChangeNotification
                          object:self userInfo:@{@"active": @NO}];
    }
    return ok;
}

#pragma mark - Applying a policy

- (BOOL)applyPlaybackForGame {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback
                         mode:AVAudioSessionModeDefault
                      options:0 error:&error]) return NO;
    return [session setActive:YES error:&error];
}

// The launcher's policy: what the session is when nothing is running.
//
// Declared here rather than remembered from whatever was there before push to talk - the review outcome
// is explicit that these are leases, not a replay of arbitrary session state. SoloAmbient is what the
// app is on at launch, and it is what dictation must leave behind. Releasing the session while leaving
// the category on PlayAndRecord is a session that is inactive but still categorised as recording, which
// the device self-test correctly refuses to accept as "put back as it was" - and the test is the
// acceptance criterion, so the code was the thing that was wrong.
- (BOOL)applyLauncherPolicy:(NSError **)error {
    NSError *failure = nil;
    // The session is released before the category is changed. Dictation now records, and releasing the
    // input before asking for an output-only category is the order that cannot leave a microphone open;
    // the other order asks for the switch while the input is still running. This is ordering chosen for
    // safety, not a measured fix - the failed transitions in the voice suite are the pre-existing
    // "the session was taken from us" line, which reports the loss on purpose and is present before and
    // after this change.
    if (![self releaseSession:&failure]) {
        if (error) *error = failure;
        return NO;
    }
    if (![AVAudioSession.sharedInstance setCategory:AVAudioSessionCategorySoloAmbient
                                               mode:AVAudioSessionModeDefault
                                            options:0 error:&failure]) {
        if (error) *error = failure;
        return NO;
    }
    return YES;
}

// Releasing rather than forcing: with NotifyOthersOnDeactivation the system tells whatever was
// interrupted that it may resume, which is what a user expects after dictation ends. Blindly
// activating - what the old code did after every dictation - takes the session away from the game
// and from every other app for no reason.
- (BOOL)releaseSession:(NSError **)error {
    return [AVAudioSession.sharedInstance
            setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
            error:error];
}

- (NSString *)nameForLease:(AKAudioLease)lease {
    switch (lease) {
    case AKAudioLeaseNone: return @"idle";
    case AKAudioLeaseGame: return @"game";
    case AKAudioLeasePushToTalk: return @"push-to-talk";
    }
    return @"unknown";
}

#pragma mark - When the system takes the session away

// Interruption, media services reset, route change, available input change: all of them are the
// coordinator's business, because all of them end a recording. The lease is released here and the
// owner of dictation is told, rather than each of them having its own idea of the session.
- (void)startObserving {
    if (_observing) return;
    _observing = YES;
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    __weak AKAudioSessionCoordinator *weakSelf = self;
    [center addObserverForName:AVAudioSessionInterruptionNotification object:nil
                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
        if (type.unsignedIntegerValue == AVAudioSessionInterruptionTypeBegan)
            [weakSelf theSessionWasTaken:@"an interruption"];
        else
            [weakSelf theInterruptionEnded];
    }];
    [center addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil
                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note;
        [weakSelf theSessionWasTaken:@"the media services were reset"];
    }];
    [center addObserverForName:AVAudioSessionRouteChangeNotification object:nil
                         queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        NSNumber *reason = note.userInfo[AVAudioSessionRouteChangeReasonKey];
        // Only a route that went away matters: a new device arriving does not stop a recording, but
        // the input it was using disappearing does.
        if (reason.unsignedIntegerValue == AVAudioSessionRouteChangeReasonOldDeviceUnavailable)
            [weakSelf theSessionWasTaken:@"the route changed"];
    }];
}

- (void)theSessionWasTaken:(NSString *)why {
    // Synchronous, from the main queue where the notification arrives: a lease that ends must have
    // ended by the time the caller looks. Inline if this is already the coordinator's own queue.
    [self onTheQueue:^{
        if (!self->_pushToTalk) return;
        self->_pushToTalk = NO;
        self->_lease = AKAudioLeaseNone;
        [self logTransitionFrom:@"push-to-talk" to:@"idle" result:NO error:nil];
        WKLog("audio", @"session: push to talk was ended by %@", why);
        void (^taken)(NSString *) = self.pushToTalkWasTaken;
        if (taken) dispatch_async(dispatch_get_main_queue(), ^{ taken(why); });
    }];
    [NSNotificationCenter.defaultCenter
        postNotificationName:AKAudioPushToTalkLeaseDidChangeNotification
                      object:self userInfo:@{@"active": @NO}];
}

// An interruption ending is when the session can be taken again. The game's policy is restored only
// if a game lease is held; nothing is forced while push to talk is recording.
- (void)theInterruptionEnded {
    [self onTheQueue:^{
        if (self->_pushToTalk) return;
        if (self->_gameWantsPlayback) {
            BOOL ok = [self applyPlaybackForGame];
            [self logTransitionFrom:@"game" to:@"game" result:ok error:nil];
        }
    }];
}

@end

// The platform's CoreAudio adapter asks for the game's playback lease through this symbol.
//
// It cannot include this class's header - it lives in translation/ and is compiled into the same image
// - so a C symbol is the boundary that works without either side knowing the other's layout. It is
// called synchronously from whatever thread the adapter is on, and the coordinator decides: the adapter
// never touches the session itself, so there is no flag for it to read, no notification to race, and no
// window in which it can take the session from a running dictation. That window is what this replaced.
// Exported and retained on purpose, and both words are load-bearing.
//
// CoreAudio finds this with dlsym(RTLD_DEFAULT, ...), and dlsym sees nothing the linker has stripped.
// The first version of this hook was dead-stripped out of the shipped app: every test passed, because
// they call the function directly, which keeps it alive in the test binary and nowhere else - and the
// adapter's lookup returned NULL at runtime, so the game never got its lease. `used` stops the linker
// removing it, the default visibility keeps it findable, and a build-artifact test in the gate asserts
// the symbol is in the app rather than in a test.
__attribute__((used, visibility("default")))
BOOL TKWolkaraRequestGamePlayback(void) {
    return [[AKAudioSessionCoordinator shared] requestGamePlayback:@"the CoreAudio adapter asked"];
}

// A reference the linker cannot argue with, and a line in the log that says whether the adapter will be
// able to find the hook at all.
//
// `used` stops the compiler removing the function; nothing stops the linker removing a global that
// nothing references, and dlsym needs it in the image. Taking its address here is a real reference, so
// the symbol is kept and exported - and the log line means the launch says out loud whether the name
// resolves, rather than a missing feature being discovered weeks later. The version before this was dead
// stripped out of the shipped app while every test passed, because the tests call the function directly.
__attribute__((constructor))
static void AKPublishTheHostPlaybackHook(void) {
    // A real reference the linker cannot argue with: nothing else in the app calls this, and a global
    // nothing references is exactly what gets stripped.
    void *hook = (void *)&TKWolkaraRequestGamePlayback;
    // Logged a moment later, not here: constructors run before main, which is where the log file is set
    // up, so a line written now goes nowhere. One second in is after logging works and before anyone can
    // press a button, and it is the same dlsym call the adapter makes.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        void *found = dlsym(RTLD_DEFAULT, "TKWolkaraRequestGamePlayback");
        WKLog("audio", @"the playback hook is at %p and %@ by name", hook,
              found ? @"reachable" : @"NOT reachable - the adapter cannot ask for playback");
    });
}
