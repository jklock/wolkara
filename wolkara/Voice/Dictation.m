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
    float _inputLevel;
    NSUInteger _buffersReceived;
    NSUInteger _unreadableBuffers;
    void (^_levelHandler)(float);
}

// The loudest sample in a buffer, 0 to 1. The tap is installed with the input's own float format,
// so anything else is treated as silence rather than guessed at.
static float AKSpeechPeak(AVAudioPCMBuffer *buffer, BOOL *readable) {
    if (readable) *readable = (buffer.floatChannelData != NULL && buffer.frameLength > 0);
    if (!readable || !*readable) return 0;
    float peak = 0;
    for (AVAudioChannelCount channel = 0; channel < buffer.format.channelCount; channel++) {
        const float *samples = buffer.floatChannelData[channel];
        for (AVAudioFrameCount frame = 0; frame < buffer.frameLength; frame++) {
            float value = samples[frame] < 0 ? -samples[frame] : samples[frame];
            if (value > peak) peak = value;
        }
    }
    return peak;
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
    // The input route is not ready the instant the session is made active, and a tap installed
    // against a format read too early delivers nothing at all: the session looks healthy, the
    // recogniser is handed a stream with nothing in it, and it reports that it heard no speech.
    // That is what the user saw on an iPad on 2026-10-17 - zero buffers, with the microphone
    // permission granted. Waited out, briefly, rather than guessed at, and the format is logged so
    // the next run shows what it was.
    AVAudioFormat *format = [input outputFormatForBus:0];
    for (NSUInteger attempt = 0; attempt < 20 && (format.sampleRate <= 0 || format.channelCount == 0); attempt++) {
        [NSThread sleepForTimeInterval:0.025];
        format = [input outputFormatForBus:0];
    }
    WKLog("voice", @"dictation: input format %.0fHz %u channel(s) after waiting",
          format.sampleRate, (unsigned)format.channelCount);
    _inputLevel = 0;
    _buffersReceived = 0;
    _unreadableBuffers = 0;
    [input installTapOnBus:0 bufferSize:1024 format:format
                     block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        (void)when;
        [self->_request appendAudioPCMBuffer:buffer];
        // What it is hearing, for the screen and for the log. Published on the main queue because
        // a screen draws it; the peak is kept rather than the last sample so that a bar built from
        // this does not flicker to zero between words. Counting buffers as well as measuring them
        // is what tells a silent room apart from a microphone that is not delivering anything.
        BOOL readable = NO;
        float level = AKSpeechPeak(buffer, &readable);
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_buffersReceived++;
            if (!readable) self->_unreadableBuffers++;
            if (level > self->_inputLevel) self->_inputLevel = level;
            if (self->_levelHandler) self->_levelHandler(self->_inputLevel);
        });
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
    _levelHandler = nil;
    // The tap's own account, where its counters are in scope: how many buffers it delivered, how
    // many of those could not be read as samples at all, and the loudest sample seen. A buffer
    // that cannot be read is the difference between a meter that is blind and a microphone that is
    // hearing nothing, and only this line tells them apart.
    WKLog("voice", @"dictation: tap delivered %lu buffer(s), %lu unreadable, loudest %.3f",
          (unsigned long)_buffersReceived, (unsigned long)_unreadableBuffers, _inputLevel);
    if (_engine) {
        [_engine.inputNode removeTapOnBus:0];
        [_engine stop];
        _engine = nil;
    }
    [_task cancel];
    _task = nil;
    _request = nil;
}

- (float)inputLevel { return _inputLevel; }
- (NSUInteger)buffersReceived { return _buffersReceived; }
- (void (^)(float))levelHandler { return _levelHandler; }
- (void)setLevelHandler:(void (^)(float))handler { _levelHandler = [handler copy]; }

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

// What "restore" means here, exactly.
//
// The category, mode and options that were there before are put back, and the session is
// left **active**. AVAudioSession has no public way to ask whether it was active before we
// arrived, so the previous activation state cannot be observed and is not claimed: this is
// an audio policy, not a snapshot of everything. The policy is right for this app - a
// foreground game host whose session is expected to be active - and it is what the header
// and docs/VOICE.md say, rather than "the session is restored exactly".
- (BOOL)restore:(NSError **)error {
    if (!_saved) return YES;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *failure = nil;
    BOOL category = [session setCategory:_category mode:_mode options:_options error:&failure];
    BOOL active = category && [session setActive:YES error:&failure];
    if (category && active) {
        _saved = NO;
        // Said only when it happened. The version before this printed the line even when both
        // calls had failed, so the app's own log claimed the session had been given back while
        // it sat on Record holding the microphone - measured on an iPad on 2026-10-17, a minute
        // after dictation ended. `_saved` stays set on failure so the retry can try again.
        WKLog("voice", @"audio: put back %@/%@ (options %lu) and left the session active",
              _category, _mode, (unsigned long)_options);
        return YES;
    }
    if (error) *error = failure;
    return NO;
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
    NSUInteger _audioRestoreAttempt;
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
        // A call, Siri, or another app taking the session ends dictation rather than
        // leaving the microphone open behind a session we no longer own.
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(sessionWasInterrupted:)
                                                   name:AVAudioSessionInterruptionNotification object:nil];
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

- (void)sessionWasInterrupted:(NSNotification *)note {
    NSNumber *type = note.userInfo[AVAudioSessionInterruptionTypeKey];
    if (![type isKindOfClass:NSNumber.class] || type.unsignedIntegerValue != AVAudioSessionInterruptionTypeBegan) return;
    if (_state == AKDictationStateIdle) return;
    WKLog("voice", @"dictation: the audio session was taken away; nothing will be typed");
    [self cancel];
    void (^problem)(NSString *) = self.problemHandler;
    if (problem) problem(@"Something else took the audio, so nothing was typed.");
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
    _audioRestoreAttempt = 0;
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
    // What it is hearing, every half second, while it runs: the buffer count, the loudest sample,
    // and the category the session is on. The category is in there because the audio session is
    // shared with the app's own keep-alive and with whatever the game does, and a category that
    // changes under a running dictation would stop the audio with no other sign of it - which is
    // exactly the kind of fault that reads as "it heard nothing".

    // Whether the app may use the microphone at all, asked before anything is opened. On
    // 2026-10-17 a reinstall left this app without the microphone grant, and dictation then said
    // "Nothing was heard" - the recogniser listening to a silent stream, which is what iOS feeds
    // an app it has not allowed to listen. That message sent the user looking for a fault that was
    // not there; this is the fault, and it has a different answer.
    AVAudioApplicationRecordPermission permission = [AVAudioApplication sharedInstance].recordPermission;
    WKLog("voice", @"dictation: microphone permission=%ld", (long)permission);
    if (permission == AVAudioApplicationRecordPermissionDenied) {
        [self fail:@"Wolkara is not allowed to use the microphone. Turn it on in Settings, under Privacy & Security, Microphone, then try again."];
        return;
    }
    if (permission == AVAudioApplicationRecordPermissionUndetermined) {
        __weak AKDictation *weakSelf = self;
        [AVAudioApplication requestRecordPermissionWithCompletionHandler:^(BOOL granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                AKDictation *self2 = weakSelf;
                if (!self2 || self2->_session != session) return;
                if (!granted) {
                    [self2 fail:@"Wolkara is not allowed to use the microphone. Turn it on in Settings, under Privacy & Security, Microphone, then try again."];
                    return;
                }
                [self2 startAudioForSession:session];
            });
        }];
        return;
    }
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
    // The person holding the iPad is who this is listening to, so the built-in microphone is asked
    // for by name. A controller that reconnects can otherwise become the input, and a controller
    // has no microphone in it: the session is then healthy - Record, the right sample rate, buffers
    // arriving at the right rate - and every sample in them is zero, which reads as the app hearing
    // nothing. That is what happened here: the first dictation worked, a controller reconnected,
    // and after that every one of them was silence with nothing wrong to see.
    AVAudioSession *audioSession = AVAudioSession.sharedInstance;
    for (AVAudioSessionPortDescription *port in audioSession.availableInputs) {
        if ([port.portType isEqualToString:AVAudioSessionPortBuiltInMic]) {
            NSError *preference = nil;
            if (![audioSession setPreferredInput:port error:&preference])
                WKLog("voice", @"dictation: could not ask for the built-in microphone: %@", preference.localizedDescription);
            else
                WKLog("voice", @"dictation: asked for the built-in microphone, from %lu available input(s)", (unsigned long)audioSession.availableInputs.count);
            break;
        }
    }
    // Measured here, where it means something. The first version of this logged the category at the
    // top of this method, before the session was taken, so it read the app's ordinary category and
    // said nothing at all about the session - and a finding was drawn from it. This is the moment
    // the session has been taken; anything other than Record here is the fault.
    WKLog("voice", @"dictation: category=%@ after taking the session", AVAudioSession.sharedInstance.category);
    // Which input the session was actually given. The samples are read back as float and counted,
    // so a stream of zeros can be told from a stream that never arrived - but neither says whether
    // iOS routed the microphone at all, and a route that is a headset with nothing in it, or no
    // input at all, looks exactly like silence from the inside.
    AVAudioSessionRouteDescription *route = AVAudioSession.sharedInstance.currentRoute;
    NSMutableString *inputs = [NSMutableString string];
    for (AVAudioSessionPortDescription *port in route.inputs)
        [inputs appendFormat:@"%@(%@) ", port.portName, port.portType];
    WKLog("voice", @"dictation: input route is %@ - %lu input(s), session %.0fHz",
          inputs.length ? inputs : @"NOTHING", (unsigned long)route.inputs.count,
          AVAudioSession.sharedInstance.sampleRate);
    [self logWhatIsBeingHeard];
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

// Giving the session back, with the retry the audio session needs.
//
// The put-back can fail transiently: a dictation session on an iPad on 2026-10-17 met
// InsufficientPriority ('!pri', OSStatus 561017449) once, and once was enough for the app to
// leave its session on Record - the microphone stays held and the indicator stays on, which is
// exactly what the user sees and cannot account for. So it is tried again a few times, nothing
// is claimed until it works, and if it never works the user is told rather than left with a
// microphone that is still on.
// Every half second while a session is running, what it is hearing. Half a second because that is
// long enough to see a change and short enough to see it happen while the user is still speaking.
- (void)logWhatIsBeingHeard {
    // Started when the session starts, which is while it is still authorizing: the first buffers
    // arrive before the state changes to listening, and waiting for that state is how the first
    // version of this logged nothing at all.
    if (_state == AKDictationStateIdle) return;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    WKLog("voice", @"dictation: heard %lu buffer(s), loudest %.3f, category=%@, activeInput=%d",
          (unsigned long)self.buffersReceived, self.inputLevel, session.category,
          (int)[session isInputAvailable]);
    __weak AKDictation *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [weakSelf logWhatIsBeingHeard]; });
}

- (void)giveTheSessionBack {
    // What this session heard, once, on every path that ends one however short it was: the buffer
    // count, the loudest sample, and how many buffers could not be read as samples at all. A press
    // can be a third of a second, which is too short for the half-second line, and this is the line
    // that says whether the microphone picked anything up.
    WKLog("voice", @"dictation: this session heard %lu buffer(s), loudest %.3f",
          (unsigned long)self.buffersReceived, self.inputLevel);
    NSError *error = nil;
    if ([self.audio restore:&error]) { _audioRestoreAttempt = 0; return; }
    WKLog("voice", @"audio: could not put the session back yet: %@", error.localizedDescription ?: @"no reason given");
    if (_audioRestoreAttempt >= 4) {
        WKLog("voice", @"audio: STILL not given back after 4 attempts; the microphone may be held");
        if (self.problemHandler)
            self.problemHandler(@"The microphone could not be handed back to the game. If the microphone indicator is still on, close Wolkara and open it again.");
        return;
    }
    _audioRestoreAttempt++;
    // The retry belongs to the session whose put-back failed, and to no other. A retry that fires
    // after a newer session has started puts the audio session back underneath it: on 2026-10-17
    // the category went to SoloAmbient microseconds into a new session, the tap delivered no
    // buffers, and the recogniser reported that it heard nothing - which is what the user saw as
    // the microphone being busted, and it was this.
    NSUInteger generation = _session;
    __weak AKDictation *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AKDictation *self2 = weakSelf;
        if (!self2 || self2->_session != generation || self2->_state != AKDictationStateIdle) return;
        [self2 giveTheSessionBack];
    });
}

// What the microphone is hearing, straight from the session that owns the tap. A screen draws it
// and the log records it, so whether audio is arriving is answered by a number rather than by the
// absence of an error message.
- (float)inputLevel { return self.speech.inputLevel; }
- (NSUInteger)buffersReceived { return self.speech.buffersReceived; }
- (void (^)(float))levelHandler { return self.speech.levelHandler; }
- (void)setLevelHandler:(void (^)(float))handler { self.speech.levelHandler = handler; }

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
