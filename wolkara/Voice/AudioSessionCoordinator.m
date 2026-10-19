// Wolkara: the one owner of the audio session. See the header for why it exists.

#import "AudioSessionCoordinator.h"
#import "../App/WolkaraLog.h"

#import <AVFAudio/AVFAudio.h>

NSNotificationName const AKAudioPushToTalkLeaseDidChangeNotification =
    @"AKAudioSessionPushToTalkLeaseDidChange";

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
        _lease = AKAudioLeaseNone;
        _lastTransition = @"none yet";
    }
    return self;
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
    dispatch_sync(_transitions, ^{
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
    });
    return ok;
}

- (void)releaseGamePlayback {
    dispatch_sync(_transitions, ^{
        _gameWantsPlayback = NO;
        if (_lease != AKAudioLeaseGame) return;
        NSString *from = [self nameForLease:_lease];
        _lease = AKAudioLeaseNone;
        NSError *error = nil;
        BOOL ok = [self releaseSession:&error];
        [self logTransitionFrom:from to:@"idle" result:ok error:error];
    });
}

- (BOOL)beginPushToTalk:(NSError **)error {
    __block BOOL ok = NO;
    __block NSError *failure = nil;
    dispatch_sync(_transitions, ^{
        NSString *from = [self nameForLease:_lease];
        AVAudioSession *session = AVAudioSession.sharedInstance;
        // PlayAndRecord, not Record: the game's audio has to stay audible while the user talks, and
        // Record silences everything else. This is the review outcome's declared policy.
        if (![session setCategory:AVAudioSessionCategoryPlayAndRecord
                             mode:AVAudioSessionModeDefault
                          options:AVAudioSessionCategoryOptionDefaultToSpeaker |
                                  AVAudioSessionCategoryOptionAllowBluetooth
                            error:&failure]) {
            [self logTransitionFrom:from to:@"push-to-talk" result:NO error:failure];
            return;
        }
        // The built-in microphone, asked for as a preference and never treated as proof: the route
        // is read back afterwards, and what it says is what is logged.
        for (AVAudioSessionPortDescription *port in session.availableInputs) {
            if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
                [session setPreferredInput:port error:NULL];
                break;
            }
        }
        if (![session setActive:YES error:&failure]) {
            [self logTransitionFrom:from to:@"push-to-talk" result:NO error:failure];
            return;
        }
        _lease = AKAudioLeasePushToTalk;
        _pushToTalk = YES;
        [self startObserving];
        ok = YES;
        [self logTransitionFrom:from to:@"push-to-talk" result:YES error:nil];
    });
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
    dispatch_sync(_transitions, ^{
        if (!_pushToTalk) { ok = YES; return; }   // nothing to hand back, and no state claimed
        NSString *from = @"push-to-talk";
        _pushToTalk = NO;
        AVAudioSession *session = AVAudioSession.sharedInstance;
        // The preference goes with the lease: it was asked for by push to talk, and leaving it
        // behind would silently change where the game's own audio comes from.
        [session setPreferredInput:nil error:NULL];
        if (_gameWantsPlayback) {
            _lease = AKAudioLeaseGame;
            ok = [self applyPlaybackForGame];
            [self logTransitionFrom:from to:@"game" result:ok error:failure];
        } else {
            _lease = AKAudioLeaseNone;
            ok = [self releaseSession:&failure];
            [self logTransitionFrom:from to:@"idle" result:ok error:failure];
        }
    });
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
    // ended by the time the caller looks, and the serial queue is only ever entered from outside it.
    dispatch_sync(_transitions, ^{
        if (!self->_pushToTalk) return;
        self->_pushToTalk = NO;
        self->_lease = AKAudioLeaseNone;
        [self logTransitionFrom:@"push-to-talk" to:@"idle" result:NO error:nil];
        WKLog("audio", @"session: push to talk was ended by %@", why);
        void (^taken)(NSString *) = self.pushToTalkWasTaken;
        if (taken) dispatch_async(dispatch_get_main_queue(), ^{ taken(why); });
    });
    [NSNotificationCenter.defaultCenter
        postNotificationName:AKAudioPushToTalkLeaseDidChangeNotification
                      object:self userInfo:@{@"active": @NO}];
}

// An interruption ending is when the session can be taken again. The game's policy is restored only
// if a game lease is held; nothing is forced while push to talk is recording.
- (void)theInterruptionEnded {
    dispatch_sync(_transitions, ^{
        if (self->_pushToTalk) return;
        if (self->_gameWantsPlayback) {
            BOOL ok = [self applyPlaybackForGame];
            [self logTransitionFrom:@"game" to:@"game" result:ok error:nil];
        }
    });
}

@end
