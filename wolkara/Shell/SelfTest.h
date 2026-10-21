// Wolkara: the checks the app can run on the device by itself.
//
// The device matrix can install the app, launch it, read its log and stop it, but it cannot
// press a button on a pad or speak into the microphone - so those paths were written off as
// "needs a person". This is the alternative: the app drives its own code, the same way the
// simulator fixtures stand in for a controller and a recogniser, and reports what happened in
// its own log, which is where the matrix reads it.
//
// What it exercises is Wolkara's own code - the input router, the settings, the dictation state
// machine and the real audio session. It never touches a running application, never presses
// anything in the game, and cannot be reached from the UI: it runs only when the app is
// launched with `--selftest=<name>`. Every stored setting it changes it puts back, including
// the user's own mappings, and it says so in the log when it is done.
//
// This is the product's own answer to "are we running every test we can". A build shipped
// without it would have to ask a person to press a pad button to prove the mapper works; with
// it, the same claim is a line in the device matrix.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The names `--selftest=` accepts. An unknown name fails, so a typo in the matrix cannot look
// like a pass.
extern NSString *const AKSelfTestInput;
extern NSString *const AKSelfTestVoice;
/// A bare recorder, opened the way Apple documents it, with none of the app's audio code in the path.
extern NSString *const AKSelfTestMic;

// Runs one self-test and logs the verdict the matrix greps:
//   selftest: <name> PASS <passed>/<total> checks (<what was exercised>)
//   selftest: <name> FAIL <passed>/<total> checks: <the first thing that was wrong>
// The speech test finishes off the main thread - see SelfTest.m for why that is not optional -
// so the verdict is the return value only for the checks that finish synchronously. Read the
// line, not the return.
void AKRunSelfTest(NSString *name);

// The name asked for on the command line, or nil. `--selftest=input` and `--selftest input`
// are both accepted.
NSString *_Nullable AKSelfTestRequestedFromArguments(NSArray<NSString *> *arguments);

NS_ASSUME_NONNULL_END
