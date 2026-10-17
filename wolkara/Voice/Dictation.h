// Wolkara: what the button says, turned into text in the game.
//
// The shape of it: a mapped button starts the microphone, the same button (or its
// release) stops it, and what was said is typed into the game.
//
// Three things here come straight out of the 2026-10-16 audit:
//
//   * **Exactly one delivery.** The old code copied the transcript and tore the audio
//     down immediately, so the recogniser's last words could arrive after the text -
//     and after Return - had already gone to the game. There is now an explicit
//     `finalizing` state: the audio ends, the recogniser is asked for its final result,
//     and the text is delivered once, when that result arrives or when the wait times
//     out.
//   * **The audio session is given back as it was found.** It used to set record mode
//     and then always leave the app at playback, which changes how the game sounds.
//   * **On-device or nothing.** The product says recognition happens on the iPad, so a
//     device that cannot do it is refused rather than quietly sent to a server.
//
// The recogniser and the audio session are behind two small protocols because they are
// the two things that cannot run in a test, and the delivery rules are exactly what a
// test has to be able to exercise.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AKDictationState) {
    AKDictationStateIdle = 0,
    // Asking for microphone and speech permission.
    AKDictationStateAuthorizing,
    // The microphone is open.
    AKDictationStateListening,
    // The audio has ended and the recogniser's last result is being waited for.
    AKDictationStateFinalizing,
};

#pragma mark - The two seams

@protocol AKDictationSpeech <NSObject>
- (BOOL)isAvailable;
/// Whether recognition can happen without sending audio anywhere.
- (BOOL)supportsOnDeviceRecognition;
/// Asks once per session. The answer is what matters; the call may be asynchronous.
- (void)requestAuthorization:(void (^)(BOOL granted))completion;
/// Starts feeding audio to the recogniser. `handler` is called with the running
/// transcript, once with `isFinal`, and with an `error` if the session failed.
- (void)startOnDevice:(BOOL)onDevice
                words:(NSArray<NSString *> *)words
              handler:(void (^)(NSString *transcript, BOOL isFinal, NSError *error))handler;
/// Stop feeding audio and ask for the last result. Either `isFinal` or the deadline
/// in AKDictation follows.
- (void)finish;
/// Abandon the session. No further handler calls.
- (void)cancel;
/// How much sound has arrived this session: the loudest sample seen, 0 to 1, and how many buffers
/// the tap delivered. A recogniser that reports no speech and a level of zero are the same
/// finding - the difference between an app that is not listening and a room that is quiet - and
/// the buffer count is what proves audio is reaching the app when the room is silent.
///
/// Written as methods rather than as properties on purpose: a property declared in a protocol
/// cannot be synthesised by an implementer that writes its own accessors, and this build treats
/// that warning as an error.
- (float)inputLevel;
- (NSUInteger)buffersReceived;
- (void (^)(float))levelHandler;
- (void)setLevelHandler:(void (^)(float))handler;
@end

@protocol AKDictationAudio <NSObject>
/// Take the session for recording, remembering how to put it back.
- (BOOL)beginRecording:(NSError **)error;
/// Put back the category, mode, options and active state that were there before. Returns NO
/// when it could not be done, and fills in why. Leaving the session on a recording category
/// holds the microphone, which the user can see on the iPad, so the caller retries rather than
/// assuming this worked.
- (BOOL)restore:(NSError **)error;
@end

#pragma mark - Dictation

@interface AKDictation : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly) AKDictationState state;
/// The microphone is open. True while listening *and* while waiting for the last
/// words, because the indicator above the iPad must not blink off in between.
@property (nonatomic, readonly) BOOL listening;
/// What the microphone has heard this session, and called while it changes so a screen can show
/// that it is being heard as it happens. Nil when nothing is running.
@property (nonatomic, readonly) float inputLevel;
@property (nonatomic, readonly) NSUInteger buffersReceived;
@property (nonatomic, copy, nullable) void (^levelHandler)(float level);

- (void)toggle;
- (void)begin;
- (void)end;
/// Abandon whatever is happening and deliver nothing.
- (void)cancel;

/// A screen that wants the words instead of the game: the test screen. While one is
/// set, the game is never typed into.
@property (nonatomic, copy, nullable) void (^transcriptHandler)(NSString *text);
@property (nonatomic, copy, nullable) void (^listeningChanged)(BOOL listening);
/// For a screen that wants to show what is happening; used by the test screen.
@property (nonatomic, copy, nullable) void (^stateChanged)(AKDictationState state);
/// Something the user should be told: a refused permission, no on-device
/// recognition, no microphone. Logged as well, always.
@property (nonatomic, copy, nullable) void (^problemHandler)(NSString *message);

/// The game's own text view, registered by the layer's touch controls when they
/// create it. Words go there and nowhere else: the old code walked every window in
/// every scene looking for something that answers the private selector, which is not
/// a thing to do while a game is running.
+ (void)setGameTextTarget:(nullable UIView *)view;
+ (nullable UIView *)gameTextTarget;

/// Test seams. Left nil in the app, where the real recogniser and the real audio
/// session are used.
@property (nonatomic, strong, nullable) id<AKDictationSpeech> speech;
@property (nonatomic, strong, nullable) id<AKDictationAudio> audio;
/// How long to wait for the recogniser's last words after the audio ends. If they do not
/// arrive in that time, nothing is typed and the user is told: what would otherwise be
/// delivered is a partial result, and half a sentence in the game's chat box is worse than
/// an empty one.
@property (nonatomic) NSTimeInterval finalizeTimeout;

@end

NS_ASSUME_NONNULL_END
