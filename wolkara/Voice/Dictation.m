// Wolkara: dictation, in full.

#import "Dictation.h"
#import "../App/WolkaraLog.h"
#import "VoiceSettings.h"

#import <AVFAudio/AVFAudio.h>
#import <Speech/Speech.h>

// kVK_Return, and the character the game expects for it. Taken from the accessory row,
// which sends its Return exactly this way.
static unsigned short const AKReturnKeyCode = 36;

// How long the recogniser gets to produce its last words after the audio ends. Long
// enough for a slow final pass on-device, short enough that a stuck session does not
// hold the microphone open.
static NSTimeInterval const AKDefaultFinalizeTimeout = 3.0;

#pragma mark - The real recogniser

// Owns the audio engine, the request and the task, because those three are one thing:
// the engine's tap is what feeds the request, and the request is what the task reads.
@interface AKSpeechSession : NSObject <AKDictationSpeech>
@end

@implementation AKSpeechSession {
    AVAudioEngine *_engine;
    SFSpeechRecognizer *_recognizer;
    SFSpeechAudioBufferRecognitionRequest *_request;
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

    _request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    // The product promises this; the caller has already refused to start when the
    // recogniser cannot do it.
    _request.requiresOnDeviceRecognition = onDevice;
    _request.shouldReportPartialResults = YES;
    if (words.count) _request.contextualStrings = words;

    _engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = _engine.inputNode;
    AVAudioFormat *format = [input outputFormatForBus:0];
    [input installTapOnBus:0 bufferSize:1024 format:format
                     block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        (void)when;
        [self->_request appendAudioPCMBuffer:buffer];
    }];

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

    NSError *error = nil;
    [_engine prepare];
    if (![_engine startAndReturnError:&error]) {
        [self cancel];
        if (_handler) _handler(@"", NO, error);
    }
}

- (void)finish {
    // Ending the audio is what makes the recogniser produce its final result; the
    // task is not cancelled, so that result still arrives.
    [_request endAudio];
}

- (void)cancel {
    _finished = YES;
    _handler = nil;
    if (_engine) {
        [_engine.inputNode removeTapOnBus:0];
        [_engine stop];
        _engine = nil;
    }
    [_task cancel];
    _task = nil;
    _request = nil;
}

@end

#pragma mark - The real audio session

// Takes the session and gives it back the way it was found. The old code set record
// mode and always left the app at playback, which is a change the game can hear.
@interface AKAudioSessionBridge : NSObject <AKDictationAudio>
@end

@implementation AKAudioSessionBridge {
    AVAudioSessionCategory _category;
    AVAudioSessionMode _mode;
    AVAudioSessionCategoryOptions _options;
    BOOL _saved;
}

- (BOOL)beginRecording:(NSError **)error {
    AVAudioSession *session = AVAudioSession.sharedInstance;
    _category = session.category;
    _mode = session.mode;
    _options = session.categoryOptions;
    _saved = YES;
    // Record only, and without asking the system to duck or interrupt anything: the
    // game's audio is not ours to take away.
    return [session setCategory:AVAudioSessionCategoryRecord mode:AVAudioSessionModeDefault
                        options:0 error:error] &&
           [session setActive:YES error:error];
}

- (void)restore {
    if (!_saved) return;
    _saved = NO;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    // Category first, then active. Reactivating is deliberate: we activated the
    // session for recording, so leaving it inactive would be the change, and the game
    // would come back silent.
    if (![session setCategory:_category mode:_mode options:_options error:&error])
        WKLog("voice", @"audio: could not restore the category: %@", error.localizedDescription);
    if (![session setActive:YES error:&error])
        WKLog("voice", @"audio: could not restore the session: %@", error.localizedDescription);
    WKLog("voice", @"audio: restored %@/%@ (options %lu)", _category, _mode, (unsigned long)_options);
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
    }
    return self;
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
        WKLog("voice", @"dictation: no final result within %.1fs; using what was heard", self2.finalizeTimeout);
        [self2 finishWithTranscript:nil];
    });
}

- (void)cancel {
    _abandoned = YES;
    _delivered = YES;   // nothing may be delivered after a cancel
    _session++;
    [self.speech cancel];
    [self.audio restore];
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
    [self.audio restore];
    [self.speech cancel];
    [self setState:AKDictationStateIdle];
    [self deliver];
}

- (void)fail:(NSString *)message {
    WKLog("voice", @"dictation: %@", message);
    [self.audio restore];
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
