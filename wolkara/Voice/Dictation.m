// Wolkara: dictation, in full.

#import "Dictation.h"
#import "AudioSessionCoordinator.h"
#import "../App/WolkaraLog.h"
#import "VoiceSettings.h"

#import <AVFAudio/AVFAudio.h>
#import <Speech/Speech.h>
#import <UIKit/UIKit.h>
#include <math.h>

// kVK_Return, and the character the game expects for it. Taken from the accessory row,
// which sends its Return exactly this way.
static unsigned short const AKReturnKeyCode = 36;

// How long the recogniser gets to produce its last words after the audio ends.
//
// The capture records a file now and the recogniser reads the whole of it, so this is a whole-file pass
// rather than a streaming one, and it only starts once the audio has ended. This is the safety net for a
// stuck recogniser, not the expected wait - but a file request reports no partials, so a timeout that
// fired early would deliver nothing at all, which is the exact symptom that took days to separate from a
// silent microphone. Generous on purpose.
static NSTimeInterval const AKDefaultFinalizeTimeout = 8.0;

// Per capture, not per process: the loudest sample this capture has heard. Reset when a capture starts,
// so a second hold never reports the first hold's number.
static double AKLoudestSoFar;

// The same peak as a level in dBFS, because the linear value cannot show the difference that matters:
// a silent input meters at -120 dBFS, which is 0.000001 linear and looks like "not zero" to any check
// written as `> 0`. A room is -50 to -70 dBFS. Kept in decibels so the check can be a threshold that
// silence cannot satisfy.
static double AKLoudestDecibels = -160.0;

double AKVoiceLoudestDecibels(void) { return AKLoudestDecibels; }

double AKVoiceLoudestSample(void) { return AKLoudestSoFar; }

// The loudest sample a recording holds, as a level in dBFS, read from the recorder's own meter.
//
// The first version of this read the recorded file back with AVAudioFile and reported 0.00000 - which
// was the read failing with error -50, not the microphone being silent. A measurement that can fail and
// still look like the fault it is meant to detect is worse than no measurement, so the level comes from
// the recorder's meter, where silence is -160 dB and cannot be confused with a parse error.

#pragma mark - The real recogniser

// Owns the audio engine, the request and the task, because those three are one thing:
// the engine's tap is what feeds the request, and the request is what the task reads.
@interface AKSpeechSession : NSObject <AKDictationSpeech>
@end

@implementation AKSpeechSession {
    AVAudioRecorder *_recorder;
    NSURL *_recording;
    BOOL _onDevice;
    NSArray<NSString *> *_words;
    SFSpeechRecognizer *_recognizer;
    SFSpeechURLRecognitionRequest *_request;
    SFSpeechRecognitionTask *_task;
    void (^_handler)(NSString *, BOOL, NSError *);
    BOOL _finished;
}

- (instancetype)init {
    if ((self = [super init])) {
        _recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    }
    return self;
}

- (BOOL)isAvailable { return _recognizer.isAvailable; }
- (BOOL)supportsOnDeviceRecognition { return _recognizer.supportsOnDeviceRecognition; }

- (void)requestAuthorization:(void (^)(BOOL granted))completion {
    // A push-to-talk hold starts on the first syllable. Re-requesting permission
    // after it was already granted needlessly dispatches the real audio start to
    // a later turn of the main queue, so a quick “hello” is captured as only its
    // tail. Start immediately once iPadOS has already authorised this app.
    if (SFSpeechRecognizer.authorizationStatus == SFSpeechRecognizerAuthorizationStatusAuthorized) {
        completion(YES);
        return;
    }
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(status == SFSpeechRecognizerAuthorizationStatusAuthorized);
        });
    }];
}

- (void)startOnDevice:(BOOL)onDevice
                words:(NSArray<NSString *> *)words
              handler:(void (^)(NSString *, BOOL, NSError *))handler {
    _handler = [handler copy];
    _finished = NO;

    _onDevice = onDevice;
    _words = [words copy];
    AKLoudestSoFar = 0;

    // Record to a file instead of tapping an AVAudioEngine.
    //
    // Measured on the device across four session configurations, the engine's tap fired at the right
    // rate with well-formed standard float32 buffers and every sample was exactly 0.0, while the
    // session was correct each time: permission granted, input available, routed to the built-in
    // microphone, and the category read during the capture was a recording one. An AVAudioRecorder is
    // a different implementation of the same session, which is the one thing that tells an engine
    // receiving nothing apart from a microphone delivering nothing - and it leaves the audio on disk,
    // so the peak reported at the end describes what the microphone delivered, not what a consumer of
    // the stream did with it.
    _recording = [NSURL fileURLWithPath:
                  [NSTemporaryDirectory() stringByAppendingPathComponent:@"wolkara-dictation.wav"]];
    [[NSFileManager defaultManager] removeItemAtURL:_recording error:NULL];
    // 16-bit integer LPCM, not 32-bit float.
    //
    // The float settings were mine, and they are the reason every recording this app has made is 4 KB:
    // a header and no audio frames. `record` returns success and `currentTime` advances, so nothing
    // looked wrong, but AVAudioRecorder does not reliably write float LPCM to a file on iOS. 16-bit
    // integer is what every documented example uses, and a recorder that cannot write looks exactly
    // like a microphone that cannot hear.
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVSampleRateKey: @(48000.0),
        AVNumberOfChannelsKey: @(1),
        AVLinearPCMBitDepthKey: @(16),
        AVLinearPCMIsFloatKey: @NO,
        AVLinearPCMIsBigEndianKey: @NO,
    };
    NSError *error = nil;

    // Warm the capture before the real one starts.
    //
    // The one time dictation produced words, the microphone was still open from the press before, so the
    // capture began against a session that had already been running. Every attempt since has started
    // cold and delivered nothing at all - not quiet audio, but no audio: the recording left on the device
    // held zero audio bytes while this code reported "recorded 1.53s". So the microphone is opened and
    // closed once, for a fraction of a second, and only then is the capture the user is speaking into
    // started. That reproduces the only state this app has ever worked in.
    NSURL *warmup = [NSURL fileURLWithPath:
                     [NSTemporaryDirectory() stringByAppendingPathComponent:@"wolkara-warmup.wav"]];
    [[NSFileManager defaultManager] removeItemAtURL:warmup error:NULL];
    AVAudioRecorder *warmer = [[AVAudioRecorder alloc] initWithURL:warmup settings:settings error:NULL];
    if ([warmer record]) {
        [NSThread sleepForTimeInterval:0.15];
        [warmer stop];
        WKLog("voice", @"dictation: warmed the capture for 150ms before starting the real one");
    } else {
        WKLog("voice", @"dictation: the warm-up capture would not start");
    }
    warmer = nil;
    [[NSFileManager defaultManager] removeItemAtURL:warmup error:NULL];

    _recorder = [[AVAudioRecorder alloc] initWithURL:_recording settings:settings error:&error];
    if (!_recorder) {
        [self cancel];
        if (_handler) _handler(@"", NO, error);
        return;
    }
    // So that the peak of the whole capture can be read from the recorder itself when it stops, rather
    // than reconstructed from the file afterwards.
    _recorder.meteringEnabled = YES;
    if (![_recorder record]) {
        NSError *refused = [NSError errorWithDomain:@"wolkara.dictation" code:1 userInfo:@{
            NSLocalizedDescriptionKey: @"The microphone did not start recording."}];
        [self cancel];
        if (_handler) _handler(@"", NO, refused);
        return;
    }
    WKLog("voice", @"dictation: recorder started, %.0fHz %lu channel(s), %@; the session is %@; app %@",
          _recorder.format.sampleRate, (unsigned long)_recorder.format.channelCount,
          _recorder.format.isStandard ? @"standard float32" : @"NOT standard",
          AVAudioSession.sharedInstance.category,
          UIApplication.sharedApplication.applicationState == UIApplicationStateActive ? @"active"
              : (UIApplication.sharedApplication.applicationState == UIApplicationStateInactive ? @"inactive" : @"background"));
}

- (void)finish {
    // Ending the capture is what produces the file the recogniser reads.
    [self stopRecordingAndMeasure];
    if (!_finished) [self recogniseRecording];
}

- (void)cancel {
    // The measurement is taken even when the capture is abandoned. A diagnostic that only works on the
    // happy path cannot diagnose the unhappy one, and "cancel" is what a failed press does.
    [self stopRecordingAndMeasure];
    _finished = YES;
    _handler = nil;
    [_task cancel];
    _task = nil;
    _request = nil;
    if (_recording) [[NSFileManager defaultManager] removeItemAtURL:_recording error:NULL];
    _recording = nil;
}

// Stop the recorder and say what it captured. Called by both finish and cancel, so the number exists
// however the press ended.
//
// `updateMeters` refreshes the peak since the previous call, so one call at the end reports the loudest
// moment of the whole recording. Silence is -160 dBFS and is reported as such; anything above it is a
// real level, converted back to a linear peak so the rest of the app still has one number to look at.
- (void)stopRecordingAndMeasure {
    if (!_recorder) return;
    [_recorder updateMeters];
    float decibels = [_recorder peakPowerForChannel:0];
    NSTimeInterval seconds = _recorder.currentTime;
    [_recorder stop];
    _recorder = nil;
    AKLoudestDecibels = (double)decibels;
    AKLoudestSoFar = (decibels <= -160.0f) ? 0.0 : pow(10.0, (double)decibels / 20.0);
    WKLog("voice", @"dictation: recorded %.2fs, peak %.1f dBFS (%.5f linear), session %@, other audio playing %d, app %@",
          seconds, decibels, AKLoudestSoFar, AVAudioSession.sharedInstance.category,
          (int)AVAudioSession.sharedInstance.isOtherAudioPlaying,
          UIApplication.sharedApplication.applicationState == UIApplicationStateActive ? @"active"
              : (UIApplication.sharedApplication.applicationState == UIApplicationStateInactive ? @"inactive" : @"background"));
}

- (void)recogniseRecording {
    if (!_recording) return;
    _request = [[SFSpeechURLRecognitionRequest alloc] initWithURL:_recording];
    // The product promises this; the caller has already refused to start when the recogniser cannot.
    _request.requiresOnDeviceRecognition = _onDevice;
    _request.shouldReportPartialResults = NO;
    if (_words.count) _request.contextualStrings = _words;

    __weak AKSpeechSession *weakSelf = self;
    _task = [_recognizer recognitionTaskWithRequest:_request
                                      resultHandler:^(SFSpeechRecognitionResult *result, NSError *error) {
        AKSpeechSession *session = weakSelf;
        if (!session || session->_finished) return;
        NSString *text = result.bestTranscription.formattedString ?: @"";
        // `isFinal` is the recogniser saying it has nothing more for this session.
        // That, or an error, is the moment the caller has been waiting for.
        if (result.isFinal || error) session->_finished = YES;
        if (session->_handler) session->_handler(text, result.isFinal, error);
    }];
}

@end

#pragma mark - The real audio session

// Takes the session and gives it back the way it was found. The old code set record
// mode and always left the app at playback, which is a change the game can hear.
@interface AKAudioSessionBridge : NSObject <AKDictationAudio>
@end

@implementation AKAudioSessionBridge

// The session is not this object's to take or to put back. The coordinator owns it, and this asks
// for a push-to-talk lease and hands it back. The answer is whether the session is in the state the
// policy says it should be in - not whether a call returned success, which is a different thing and
// is the one the old code reported while the microphone stayed held.
- (BOOL)beginRecording:(NSError **)error {
    return [[AKAudioSessionCoordinator shared] beginPushToTalk:error];
}

- (BOOL)restore:(NSError **)error {
    return [[AKAudioSessionCoordinator shared] endPushToTalk:error];
}

@end

#pragma mark - Dictation

@implementation AKDictation {
    AKSpeechSession *_realSpeech;
    AKAudioSessionBridge *_realAudio;
    NSMutableString *_transcript;
    BOOL _delivered;
    BOOL _abandoned;
    NSUInteger _session;
}

+ (instancetype)shared {
    static AKDictation *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [AKDictation new]; });
    return shared;
}

- (instancetype)init {
    if ((self = [super init])) {
        _transcript = [NSMutableString string];
        _finalizeTimeout = AKDefaultFinalizeTimeout;
        // The audio session is the coordinator's, and it says when push to talk was ended by an
        // interruption, a media reset or the route going. Dictation used to observe
        // AVAudioSessionInterruptionNotification itself, which is two owners of one session with two
        // ideas about it - what the review outcome's Phase 1 exists to remove.
        __weak AKDictation *weakSelf = self;
        [AKAudioSessionCoordinator shared].pushToTalkWasTaken = ^(NSString *why) {
            AKDictation *self2 = weakSelf;
            if (!self2) return;
            [self2 cancel];
            void (^problem)(NSString *) = self2.problemHandler;
            if (problem) problem([NSString stringWithFormat:@"Something else took the audio (%@), so nothing was typed.", why]);
        };
        // And leaving the app does too. This matters here more than in most apps: the
        // target declares `UIBackgroundModes: [audio]` so a running game keeps its sound,
        // which means iOS does NOT take the session away when the user goes to the Home
        // screen. Without this, a session left listening would hold the microphone and
        // Apple's recogniser open in the background - the user would see the orange
        // indicator with the game behind it, and nothing would ever type the words.
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(appLeftTheForeground:)
                                                   name:UIApplicationDidEnterBackgroundNotification object:nil];
    }
    return self;
}

- (void)appLeftTheForeground:(NSNotification *)note {
    (void)note;
    // Said before the state is changed, because the state is what a reader wants to know.
    WKLog("voice", @"dictation: the app went to the background (state=%ld, listening=%d)",
          (long)_state, (int)self.listening);
    if (_state == AKDictationStateIdle) return;
    [self cancel];
    void (^problem)(NSString *) = self.problemHandler;
    if (problem) problem(@"The app went to the background, so nothing was typed.");
}

- (BOOL)listening { return _state == AKDictationStateListening || _state == AKDictationStateFinalizing; }

#pragma mark - The registered target

static __weak UIView *AKGameTextTarget = nil;

+ (void)setGameTextTarget:(nullable UIView *)view { AKGameTextTarget = view; }
+ (nullable UIView *)gameTextTarget { return AKGameTextTarget; }

#pragma mark - Seams

- (id<AKDictationSpeech>)speech {
    if (_speech) return _speech;
    if (!_realSpeech) _realSpeech = [AKSpeechSession new];
    return _realSpeech;
}

- (id<AKDictationAudio>)audio {
    if (_audio) return _audio;
    if (!_realAudio) _realAudio = [AKAudioSessionBridge new];
    return _realAudio;
}

#pragma mark - The one entry point

- (void)toggle {
    if (self.listening) [self end];
    else [self begin];
}

- (void)begin {
    switch (_state) {
    case AKDictationStateIdle: break;
    // Already busy: a second press while the microphone is opening is the same press.
    case AKDictationStateAuthorizing:
    case AKDictationStateListening:
    case AKDictationStateFinalizing: return;
    }
    _abandoned = NO;
    _delivered = NO;
    [_transcript setString:@""];
    NSUInteger session = ++_session;
    [self setState:AKDictationStateAuthorizing];

    id<AKDictationSpeech> speech = self.speech;
    if (!speech.supportsOnDeviceRecognition) {
        [self fail:@"This iPad cannot recognise speech without sending it away, so the microphone stays off."];
        return;
    }
    __weak AKDictation *weakSelf = self;
    [speech requestAuthorization:^(BOOL granted) {
        AKDictation *self2 = weakSelf;
        if (!self2 || self2->_session != session) return;   // a later press replaced this
        if (!granted) { [self2 fail:@"Speech recognition permission was refused."]; return; }
        [self2 startAudioForSession:session];
    }];
}

- (void)startAudioForSession:(NSUInteger)session {
    if (_session != session || _abandoned) return;
    // Refused before anything is opened, rather than started and failed: the audio
    // session is not ours to take if there is nothing to feed it to.
    if (!self.speech.isAvailable) {
        [self fail:@"Speech recognition is not available right now."];
        return;
    }

    NSError *error = nil;
    if (![self.audio beginRecording:&error]) {
        [self fail:[NSString stringWithFormat:@"The audio session would not start: %@", error.localizedDescription]];
        return;
    }
    __weak AKDictation *weakSelf = self;
    [self.speech startOnDevice:YES words:AKVoiceSettings.shared.customWords
                       handler:^(NSString *transcript, BOOL isFinal, NSError *error2) {
        [weakSelf speechReported:transcript isFinal:isFinal error:error2 session:session];
    }];
    [self setState:AKDictationStateListening];
    WKLog("voice", @"dictation: listening (on-device=1)");
}

// Read once, so a recogniser that is unavailable right now is refused rather than
// started and failed.
- (void)end {
    switch (_state) {
    case AKDictationStateIdle:
    case AKDictationStateFinalizing: return;
    case AKDictationStateAuthorizing:
        // Nothing was started. Abandon it, in case the permission answer arrives late.
        _abandoned = YES;
        _session++;
        [self setState:AKDictationStateIdle];
        return;
    case AKDictationStateListening:
        break;
    }
    [self setState:AKDictationStateFinalizing];
    NSUInteger session = _session;
    [self.speech finish];
    // The recogniser is asked for its last words and given a bounded wait. Whichever
    // happens first, delivery happens once.
    __weak AKDictation *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.finalizeTimeout * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AKDictation *self2 = weakSelf;
        if (!self2 || self2->_state != AKDictationStateFinalizing || self2->_session != session) return;
        [self2 abandonForTimeout];
    });
}

// The deadline passed. Nothing is delivered.
//
// What is in hand is a *partial* result, and the product's promise is a final transcript:
// putting half a sentence into the game's chat box - and, with auto-submit on, sending it
// - is worse than putting nothing there. The remediation review caught the first version
// doing exactly that and calling it a timeout. The user is told instead, and because a
// timeout is usually the recogniser being unavailable or the microphone being silent,
// saying so is more useful than a guess at what they said.
- (void)abandonForTimeout {
    if (_state != AKDictationStateFinalizing) return;
    WKLog("voice", @"dictation: no final result within %.1fs; nothing will be typed", self.finalizeTimeout);
    [self.speech cancel];
    [self giveTheSessionBack];
    _abandoned = YES;
    _delivered = YES;   // nothing may be delivered for this session
    _session++;
    [self setState:AKDictationStateIdle];
    void (^problem)(NSString *) = self.problemHandler;
    if (problem) problem(@"The recogniser did not finish in time, so nothing was typed.");
}

- (void)cancel {
    _abandoned = YES;
    _delivered = YES;   // nothing may be delivered after a cancel
    _session++;
    [self.speech cancel];
    [self giveTheSessionBack];
    [_transcript setString:@""];
    [self setState:AKDictationStateIdle];
}

#pragma mark - What the recogniser says

- (void)speechReported:(NSString *)transcript isFinal:(BOOL)isFinal error:(NSError *)error session:(NSUInteger)session {
    if (_session != session || _abandoned) return;
    if (transcript.length) [_transcript setString:transcript];
    if (error) {
        if (_state == AKDictationStateFinalizing) {
            WKLog("voice", @"dictation: the recogniser failed while finishing: %@", error.localizedDescription);
            [self finishWithTranscript:transcript];
        } else {
            [self fail:[NSString stringWithFormat:@"Recognition stopped: %@", error.localizedDescription]];
        }
        return;
    }
    // A final result is the only thing that ends a session early. Anything else is a
    // partial result, and partial results are not delivered at all.
    if (isFinal && _state == AKDictationStateFinalizing) [self finishWithTranscript:transcript];
}

// The one place a session ends well. Everything is put back *before* the words go
// anywhere, so the game's audio is already returning while its input is being typed.
- (void)finishWithTranscript:(nullable NSString *)transcript {
    if (_delivered || _abandoned) return;
    _delivered = YES;
    if (transcript.length) [_transcript setString:transcript];
    [self giveTheSessionBack];
    [self.speech cancel];
    [self setState:AKDictationStateIdle];
    [self deliver];
}

// Handing the session back, once, and saying so when it did not work.
//
// No retries. The review outcome is explicit that a failed put-back leaves an explicit recoverable
// state and a user-visible message rather than an unbounded retry loop, and the retry this replaces
// is the clearest example of why: a retry from a failed put-back could fire after the next dictation
// had begun and take the session away from it, which the user saw as the microphone being broken.
- (void)giveTheSessionBack {
    NSError *error = nil;
    if ([self.audio restore:&error]) return;
    WKLog("voice", @"audio: the session could not be handed back: %@", error.localizedDescription ?: @"no reason given");
    if (self.problemHandler)
        self.problemHandler(@"The microphone could not be handed back. If the microphone indicator is still on, close Wolkara and open it again.");
}

- (void)fail:(NSString *)message {
    WKLog("voice", @"dictation: %@", message);
    [self giveTheSessionBack];
    [self.speech cancel];
    _abandoned = YES;
    _session++;
    [self setState:AKDictationStateIdle];
    void (^problem)(NSString *) = self.problemHandler;
    if (problem) problem(message);
}

#pragma mark - The words

- (void)deliver {
    NSString *text = [_transcript stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    void (^handler)(NSString *) = _transcriptHandler;
    if (handler) {
        // A test screen is up: the words are its business, not the game's. It is told
        // even when nothing was heard, so it can say so.
        WKLog("voice", @"dictation: heard %lu characters, for the test screen", (unsigned long)text.length);
        handler(text);
        return;
    }
    if (!text.length) { WKLog("voice", @"dictation: stopped, heard nothing"); return; }
    WKLog("voice", @"dictation: heard %lu characters", (unsigned long)text.length);
    if (AKVoiceSettings.shared.trailingSpace) text = [text stringByAppendingString:@" "];
    if ([self typeIntoGame:text]) {
        // Separately, and deliberately: the text goes in first, then Return - and only
        // when it was asked for, which is Handy's auto-submit.
        if (AKVoiceSettings.shared.autoSubmit) [self sendReturn];
    }
}

- (BOOL)typeIntoGame:(NSString *)text {
    UIView *target = AKDictation.gameTextTarget;
    if (!target) {
        WKLog("voice", @"dictation: the game has not registered a text target; nothing typed");
        return NO;
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [target performSelector:NSSelectorFromString(@"touchInsertText:") withObject:text];
#pragma clang diagnostic pop
    return YES;
}

- (void)sendReturn {
    UIView *target = AKDictation.gameTextTarget;
    if (!target) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [target performSelector:NSSelectorFromString(@"touchSpecialKey:characters:")
                 withObject:@(AKReturnKeyCode)
                 withObject:@"\r"];
#pragma clang diagnostic pop
    WKLog("voice", @"dictation: sent Return");
}

#pragma mark - Telling whoever is watching

- (void)setState:(AKDictationState)state {
    AKDictationState previous = _state;
    _state = state;
    if (previous == state) return;
    WKLog("voice", @"dictation: %@ -> %@", [self nameForState:previous], [self nameForState:state]);
    void (^changed)(BOOL) = _listeningChanged;
    BOOL listening = self.listening;
    BOOL wasListening = previous == AKDictationStateListening || previous == AKDictationStateFinalizing;
    if (changed && listening != wasListening) changed(listening);
    void (^stateHandler)(AKDictationState) = _stateChanged;
    if (stateHandler) stateHandler(state);
}

- (NSString *)nameForState:(AKDictationState)state {
    switch (state) {
    case AKDictationStateIdle: return @"idle";
    case AKDictationStateAuthorizing: return @"authorizing";
    case AKDictationStateListening: return @"listening";
    case AKDictationStateFinalizing: return @"finalizing";
    }
    return @"?";
}

@end
