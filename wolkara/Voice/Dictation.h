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

// Whether the microphone is currently ours.
@property (nonatomic, readonly) BOOL listening;

@end

NS_ASSUME_NONNULL_END
