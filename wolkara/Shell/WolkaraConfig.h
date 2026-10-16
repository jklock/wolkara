// Wolkara: the user's choices, in a file as well as in the defaults database.
//
// NSUserDefaults lives in the app's container and does survive an update, but it
// is one opaque plist that nobody can read, back up, or carry anywhere. The
// choices that cost the user real time - the edition, the download language, the
// button they mapped, the words they taught the recogniser - are therefore also
// written to a file under Documents, where they can be seen, copied off, and come
// back after a reinstall.
//
// The CurseForge key is deliberately not here. Secrets belong in the keychain,
// which is where AddonCredentialStore already keeps it, and which already
// survives a reinstall; copying it into a readable file would be a step backwards
// for no gain.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TKWolkaraConfig : NSObject

+ (instancetype)shared;

// Import the file into the defaults database, once, before anything reads a setting.
// Every value is checked against a schema first; a file that cannot be trusted is kept
// as `.rejected` and the last good copy is used instead. Safe to call more than once.
- (void)load;
// Write the defaults database back out. Called for every change, coalesced into one
// write, on a queue of its own.
- (void)save;
// Read the file again from the top, as a fresh launch would. For tests, and for anything
// that wants to re-read after the file has been changed by hand.
- (void)reloadFromFile;

// Where the file is, for the diagnostics screen and for logs.
@property (nonatomic, readonly) NSString *path;
// The previous good copy, which a refused file falls back to.
@property (nonatomic, readonly) NSString *backupPath;
// A refused file is copied here rather than overwritten, so nothing the user wrote is
// destroyed by the next save.
@property (nonatomic, readonly) NSString *rejectedPath;
// What went wrong with the file, if anything, in words a person can act on. Nil when
// the last import was clean.
@property (nonatomic, readonly, nullable) NSString *lastImportProblem;

// The rules, on their own, so a corpus of malformed files can be run through them
// without going near the singleton or the disk. Returns the settings that may be
// applied - never nil, and never a value that failed a check - and fills `problem` with
// a description of what was refused.
+ (NSDictionary<NSString *, id> *)validatedSettingsFromFile:(nullable NSDictionary *)file
                                                    problem:(NSString *_Nullable *_Nullable)problem;

@end

NS_ASSUME_NONNULL_END
