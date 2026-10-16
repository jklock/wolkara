// Wolkara: dictation into the game, in full.
//
// The shape of it: Share tap -> listen -> Share tap -> stop, type, send.
//
// Typing and sending go through the same call the layer's own text entry uses,
// so the game receives ordinary keystrokes and cannot tell the difference. That
// path is the one already proven in the game: the accessory row's Replace and
// Return use it.

#import "Dictation.h"

#if __has_include("AKSupport.h")
#import "AKSupport.h"
#define AKDLog(...) AKLog(__VA_ARGS__)
#else
#define AKDLog(...) NSLog(@"[ak] %@", [NSString stringWithFormat:__VA_ARGS__])
#endif

#import <AVFAudio/AVFAudio.h>
#import <Speech/Speech.h>
#import <UIKit/UIKit.h>

#import "VoiceSettings.h"

// kVK_Return, and the character the game expects for it. Taken from the
// accessory row, which sends its Return exactly this way.
static unsigned short const AKReturnKeyCode = 36;

@implementation AKDictation {
    AVAudioEngine *_engine;
    SFSpeechRecognizer *_recognizer;
    SFSpeechAudioBufferRecognitionRequest *_request;
    SFSpeechRecognitionTask *_task;
    NSMutableString *_transcript;
    // The last state a screen was told about, so a screen hears about changes
    // rather than about every path that happens to reach the teardown.
    BOOL _notifiedListening;
}

+ (instancetype)shared {
    static AKDictation *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [AKDictation new]; });
    return shared;
}

- (BOOL)listening { return _engine != nil; }

#pragma mark - The one entry point

- (void)toggle {
    if (self.listening) [self stopAndSend];
    else [self startListening];
}

- (void)begin { [self startListening]; }
- (void)end { [self stopAndSend]; }

#pragma mark - Listening

- (void)startListening {
    // Both permissions are asked for on first use and then never again. If the
    // user says no, we say so and stop: there is nothing else to try.
    [SFSpeechRecognizer requestAuthorization:^(SFSpeechRecognizerAuthorizationStatus status) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (status != SFSpeechRecognizerAuthorizationStatusAuthorized) {
                AKDLog(@"dictation: speech permission refused (%ld)", (long)status);
                return;
            }
            AVAudioSession *session = AVAudioSession.sharedInstance;
            [session requestRecordPermission:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!granted) { AKDLog(@"dictation: microphone permission refused"); return; }
                    [self beginAudio];
                });
            }];
        });
    }];
}

- (void)beginAudio {
    if (self.listening) return;

    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    // Record only. The game's own audio is not our concern here; the user's
    // chosen output device is restored when we stop.
    if (![session setCategory:AVAudioSessionCategoryRecord error:&error] ||
        ![session setActive:YES error:&error]) {
        AKDLog(@"dictation: audio session refused: %@", error.localizedDescription);
        return;
    }

    _recognizer = [[SFSpeechRecognizer alloc] initWithLocale:[NSLocale localeWithLocaleIdentifier:@"en-US"]];
    if (!_recognizer.isAvailable) {
        AKDLog(@"dictation: recognizer unavailable right now");
        [self tearDownAudio];
        return;
    }

    _request = [[SFSpeechAudioBufferRecognitionRequest alloc] init];
    // On-device, always: nothing said in a game should travel to a server.
    _request.requiresOnDeviceRecognition = _recognizer.supportsOnDeviceRecognition;
    _request.shouldReportPartialResults = YES;
    // Handy's dictionary: words the recogniser should expect, so names and game
    // terms come out spelled the way the user means them.
    if (AKVoiceSettings.shared.customWords.count) _request.contextualStrings = AKVoiceSettings.shared.customWords;
    _transcript = [NSMutableString string];

    _engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = _engine.inputNode;
    AVAudioFormat *format = [input outputFormatForBus:0];
    [input installTapOnBus:0 bufferSize:1024 format:format
                     block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        (void)when;
        [self->_request appendAudioPCMBuffer:buffer];
    }];
    [_engine prepare];
    if (![_engine startAndReturnError:&error]) {
        AKDLog(@"dictation: engine would not start: %@", error.localizedDescription);
        [self tearDownAudio];
        return;
    }

    __weak AKDictation *weakSelf = self;
    _task = [_recognizer recognitionTaskWithRequest:_request
                                      resultHandler:^(SFSpeechRecognitionResult *result, NSError *taskError) {
        AKDictation *self2 = weakSelf;
        if (!self2) return;
        if (result) {
            NSString *best = result.bestTranscription.formattedString;
            if (best.length) { self2->_transcript.string = best; }
        }
        if (taskError) AKDLog(@"dictation: recogniser said: %@", taskError.localizedDescription);
    }];

    AKDLog(@"dictation: listening (on-device=%d)", _request.requiresOnDeviceRecognition);
    [self noteListening];
}

#pragma mark - Stop, type, send

- (void)stopAndSend {
    NSString *text = [_transcript copy] ?: @"";
    [_request endAudio];
    [_task finish];
    [self tearDownAudio];

    text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    void (^handler)(NSString *) = _transcriptHandler;
    if (handler) {
        // A test screen is up: the words are its business, not the game's. It is
        // told even when nothing was heard, so it can say so.
        AKDLog(@"dictation: heard %lu characters, for the test screen", (unsigned long)text.length);
        handler(text);
        return;
    }
    if (!text.length) { AKDLog(@"dictation: stopped, heard nothing"); return; }

    AKDLog(@"dictation: heard %lu characters", (unsigned long)text.length);
    if (AKVoiceSettings.shared.trailingSpace) text = [text stringByAppendingString:@" "];
    if ([self typeIntoGame:text]) {
        // Separately, and deliberately: the text goes in first, then Return —
        // and only when it was asked for, which is Handy's auto-submit.
        if (AKVoiceSettings.shared.autoSubmit) [self sendReturn];
    }
}

- (void)tearDownAudio {
    if (_engine) {
        [_engine.inputNode removeTapOnBus:0];
        [_engine stop];
        _engine = nil;
    }
    _request = nil;
    _task = nil;
    NSError *error = nil;
    // Hand the session back so the game's audio returns to normal.
    [AVAudioSession.sharedInstance setActive:NO withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation error:&error];
    [AVAudioSession.sharedInstance setCategory:AVAudioSessionCategoryPlayback error:NULL];
    [self noteListening];
}

// Tell whoever is watching the moment the microphone changes hands, once.
- (void)noteListening {
    if (_notifiedListening == self.listening) return;
    _notifiedListening = self.listening;
    void (^changed)(BOOL) = _listeningChanged;
    if (changed) changed(self.listening);
}

#pragma mark - The game's own input path

// The guest's view is the one that answers touchInsertText: — the same call the
// layer's text entry makes. Find it rather than assume where it sits.
- (nullable UIView *)guestTextTargetInView:(UIView *)view {
    if ([view respondsToSelector:NSSelectorFromString(@"touchInsertText:")]) return view;
    for (UIView *child in view.subviews) {
        UIView *found = [self guestTextTargetInView:child];
        if (found) return found;
    }
    return nil;
}

- (nullable UIView *)guestTextTarget {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIView *found = [self guestTextTargetInView:window];
            if (found) return found;
        }
    }
    return nil;
}

- (BOOL)typeIntoGame:(NSString *)text {
    UIView *target = [self guestTextTarget];
    if (!target) { AKDLog(@"dictation: no game text target found; nothing typed"); return NO; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [target performSelector:NSSelectorFromString(@"touchInsertText:") withObject:text];
#pragma clang diagnostic pop
    return YES;
}

- (void)sendReturn {
    UIView *target = [self guestTextTarget];
    if (!target) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    [target performSelector:NSSelectorFromString(@"touchSpecialKey:characters:")
                 withObject:@(AKReturnKeyCode)
                 withObject:@"\r"];
#pragma clang diagnostic pop
    AKDLog(@"dictation: sent Return");
}

@end
