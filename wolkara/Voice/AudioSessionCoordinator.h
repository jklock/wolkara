// Wolkara: the one owner of the audio session.
//
// Why this exists: the session was being mutated from three places - dictation taking it for
// recording, the CoreAudio adapter forcing playback whenever it felt the session had gone, and the
// shell reading it - and they could not see each other. A dictation that was interrupted by the
// adapter, a session left recording after a put-back that failed, a route that changed under a
// running recording: all of those came from having no single owner. The review outcome's Phase 1
// asks for one, with declared states rather than saved-and-replayed session state, and this is it.
//
// Nothing else in the app may call -setCategory:mode:options:error:, -setActive:options:error: or
// -setPreferredInput:error:. A test enforces that.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// What the coordinator believes it is doing. These are the declared states of the review outcome's
/// table, not a snapshot of the session: the session cannot be asked what it was, so it is not
/// guessed at and not replayed.
typedef NS_ENUM(NSInteger, AKAudioLease) {
    /// The launcher, idle. No recording; the session is released so that other apps can play.
    AKAudioLeaseNone = 0,
    /// A guest is running and the game runtime needs the session active for playback. This is the
    /// lease the CoreAudio adapter holds, and it is what keeps a running game alive in the
    /// background.
    AKAudioLeaseGame,
    /// Push to talk is recording. Exactly one of these at a time, and it is above the game's lease
    /// while it lasts.
    AKAudioLeasePushToTalk,
};

/// Posted when the push-to-talk lease is taken or released, carrying a NSNumber BOOL. The CoreAudio
/// adapter observes this by name - it lives in translation/ and cannot include this header, the same
/// arrangement as the touch adapter's notification - and must not force playback while it is set.
extern NSNotificationName const AKAudioPushToTalkLeaseDidChangeNotification;

/// The state of the session, one transition at a time. Every method returns whether the session is
/// in the state the policy says it should be in, which is not the same as whether a call succeeded:
/// a call can succeed and leave the session somewhere the policy did not ask for.
@interface AKAudioSessionCoordinator : NSObject

+ (instancetype)shared;

/// What the coordinator is doing now.
@property (nonatomic, readonly) AKAudioLease lease;
/// Whether push to talk currently holds the session.
@property (nonatomic, readonly) BOOL pushToTalkActive;
/// The last transition, as one line: old state, requested state, category, mode, route, whether
/// activation succeeded, and any error. Also logged.
@property (nonatomic, readonly, copy) NSString *lastTransition;
/// Called when push to talk must stop because the session was taken away - an interruption, a media
/// services reset, or the route going. The owner of dictation cancels; the coordinator has already
/// released the lease by then.
@property (nonatomic, copy, nullable) void (^pushToTalkWasTaken)(NSString *why);

/// The game runtime declares that it needs active playback. Idempotent.
- (BOOL)requestGamePlayback:(NSString *)why;
/// The game runtime is gone; the lease is dropped.
- (void)releaseGamePlayback;
/// Dictation asks to record. YES only when the session is recording afterwards.
- (BOOL)beginPushToTalk:(NSError **)error;
/// Dictation is done. The session goes back to the declared policy: the game's playback if a game
/// lease is held, otherwise released with NotifyOthersOnDeactivation so that other apps resume.
- (BOOL)endPushToTalk:(NSError **)error;
/// What the session is doing, for a log line or a screen: category, mode, route, input.
- (NSString *)describeSession;

@end

NS_ASSUME_NONNULL_END
