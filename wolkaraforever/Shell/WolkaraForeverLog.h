// WolkaraForever: one log, on disk, from the first line of the process.
//
// stderr is not enough, and that is the whole reason this file exists. The host's
// own lines only went to stderr, which is kept only when the app is launched with a
// console attached, and the platform only redirects stderr into
// Documents/native-guest.log once a guest is actually started. So everything the
// launcher said while it was opening - and everything it said while it was dying -
// was already gone by the time anyone looked at it.
//
// On 2026-10-16 the launcher aborted the moment its page loaded. The client's own
// Errors/ folder was empty (that folder is the guest's), the guest log had nothing
// from that launch, and the only record that existed was a system crash report
// nobody had asked for. An hour went into finding an Auto Layout exception that
// three lines of log would have handed over immediately.
//
// So: Documents/wolkaraforever.log, appended, capped at a megabyte with one rotation, and
// readable from a Mac with `wolkaraforever/tools/pilot.sh log`. Uncaught exceptions and
// fatal signals are written into the same file, so a crash explains itself next to
// the story that led to it.

#import <Foundation/Foundation.h>

/// Opens the log and installs the exception and signal handlers. Call it from the
/// first line of `main`. Safe to call more than once.
void WKLogStart(void);

/// One line. `tag` is short and greppable: `host`, `ui`, `wow`, `voice`.
void WKLogLine(const char *tag, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
#define WKLog(tag, ...) WKLogLine(tag, __VA_ARGS__)

/// Where the log is, and whether it is open. For the diagnostics screen and tools.
NSString *WKLogPath(void);
NSString *WKLogRotationPath(void);

/// Writes a line without going through the file's own bookkeeping. Used by the
/// crash handlers, which run when it is too late to be careful.
void WKLogFatal(const char *tag, NSString *message);

/// The documents a build of this app has to carry, as pairs of a heading and the file
/// name in the bundle: this app's own licence and notice, and upstream Tolkara's, which
/// have to stay because the app ships upstream's code too. One list, so the launch-time
/// log line and the About page cannot come to different conclusions about what should be
/// there - and so a build that is missing one says so, in the log and on the page, rather
/// than quietly showing nothing. See development/NOTES.md for how that happened.
NSArray<NSArray<NSString *> *> *WKBundledDocuments(void);
