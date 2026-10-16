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

// Import the file into the defaults database, once, before anything reads a
// setting. Safe to call more than once.
- (void)load;
// Write the defaults database back out. Every change calls this, so the file is
// never behind the running app.
- (void)save;

// Where the file is, for the diagnostics screen and for logs.
@property (nonatomic, readonly) NSString *path;

@end

NS_ASSUME_NONNULL_END
