#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSErrorDomain const TKForeverUIErrorDomain;
// The Forever edition these rows are about. They never touch another edition's
// files: every path is resolved from that installation's working directory and
// checked to stay inside it.
FOUNDATION_EXPORT NSString *const TKForeverUIEdition;

// WoW Forever file operations for the home page's Performance & UI Manager.
//
// The configuration half is here, in Objective-C, because it is small, byte
// exact and testable without a simulator. The archive half is a Swift class
// (ForeverUIArchive.swift) that uses the project's pinned ZIPFoundation; it is
// reached by name so this module does not depend on Swift at link time.
@interface TKForeverUI : NSObject

// WTF/Config.wtf, with every GamePadEnable assignment normalised to exactly one
// `SET GamePadEnable "1"`. Other lines keep their bytes. Reads the file back and
// fails unless exactly one assignment with value 1 is present.
+ (BOOL)enableGamepadInWorkingDirectory:(NSString *)directory error:(NSError **)error;

// YES when Config.wtf exists and carries exactly one GamePadEnable assignment,
// with value 1. A missing or unreadable config reads as NO.
+ (BOOL)gamepadEnabledInWorkingDirectory:(NSString *)directory;

// Removes only the graphics/display CVars in the measured Forever allowlist and
// rewrites the file atomically. Account, locale, audio, UI, input, gamepad,
// cache and unknown settings are preserved byte for byte.
+ (BOOL)resetGraphicsInWorkingDirectory:(NSString *)directory error:(NSError **)error;

// The Forever installation's WTF directory. Creates it only when asked, and
// only inside the working directory. Nil when the path cannot be resolved.
+ (nullable NSString *)wtfDirectoryInWorkingDirectory:(NSString *)directory
                                               create:(BOOL)create
                                                error:(NSError **)error;

// Archive bridge. Each returns nil/NO with an error when the archive class is
// not in the build, so a caller can explain that rather than claim success.
+ (nullable NSString *)createUIBackupInWorkingDirectory:(NSString *)directory
                                               edition:(NSString *)edition
                                                 error:(NSError **)error;
+ (nullable NSString *)newestUIBackupInWorkingDirectory:(NSString *)directory
                                                  error:(NSError **)error;
+ (BOOL)restoreUIBackupNamed:(NSString *)name
          inWorkingDirectory:(NSString *)directory
                     edition:(NSString *)edition
                       error:(NSError **)error;
+ (BOOL)recoverInterruptedRestoreInWorkingDirectory:(NSString *)directory
                                             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
