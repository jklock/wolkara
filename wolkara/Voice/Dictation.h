// Wolkara: dictation into the game.
//
// Tap the pad's Share button once and this listens. Tap it again and it stops,
// types what you said into the game where your cursor is, and sends it.
//
// Nothing of ours appears on screen: no panel, no keyboard, no field. The game's
// own chat box is the only visible part of it.
//
// The recognition is Apple's on-device model, asked for explicitly, so no audio
// leaves the iPad.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface AKDictation : NSObject

+ (instancetype)shared;

// Start listening, or — if already listening — stop, transcribe, type and send.
- (void)toggle;
// Push to talk: the first call starts, the second finishes. Used when the mode
// is hold, so the microphone is open exactly while the button is down.
- (void)begin;
- (void)end;

// Whether the microphone is currently ours.
@property (nonatomic, readonly) BOOL listening;

// Where a transcript goes instead of the game, and how a screen follows the
// microphone. The launcher's test screen sets both so the words land in its own
// box; the game path leaves them unset and behaves exactly as it always has.
// While the handler is set, the game is not typed into at all.
@property (nonatomic, copy, nullable) void (^transcriptHandler)(NSString *text);
@property (nonatomic, copy, nullable) void (^listeningChanged)(BOOL listening);

@end

NS_ASSUME_NONNULL_END
