#import "WolkaraLog.h"

#include <fcntl.h>
#include <os/lock.h>
#include <signal.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

// The file stays open for the life of the process. Every line is one write(2) on an
// O_APPEND descriptor, which the kernel makes atomic, so lines from several threads
// cannot interleave and no lock is needed to write one. The lock exists only for
// rotation, and the crash handlers write without taking it.
static int WKLogDescriptor = -1;
static os_unfair_lock WKLogLock = OS_UNFAIR_LOCK_INIT;
// A plain integer, not `_Atomic`: the __atomic_* builtins below are what make the
// reads and writes safe, and they want an ordinary pointer to work on.
static unsigned long long WKLogBytes = 0;
static NSString *WKLogFilePath = nil;
static NSString *WKLogRotatedPath = nil;

// A megabyte is about a day of launcher use, and two files of that is nothing to
// fetch over a cable.
static const unsigned long long WKLogLimit = 1 << 20;

NSString *WKLogPath(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *directory = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents"];
        NSFileManager *files = NSFileManager.defaultManager;
        if (![files fileExistsAtPath:directory])
            [files createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
        WKLogFilePath = [directory stringByAppendingPathComponent:@"wolkara.log"];
        WKLogRotatedPath = [directory stringByAppendingPathComponent:@"wolkara.log.1"];
    });
    return WKLogFilePath;
}

NSString *WKLogRotationPath(void) {
    (void)WKLogPath();
    return WKLogRotatedPath;
}

// Rotation, not truncation: the launch before the one that went wrong is often the
// one worth reading.
static void WKLogRotate(void) {
    if (!os_unfair_lock_trylock(&WKLogLock)) return;
    NSFileManager *files = NSFileManager.defaultManager;
    if (WKLogDescriptor >= 0) close(WKLogDescriptor);
    [files removeItemAtPath:WKLogRotationPath() error:NULL];
    [files moveItemAtPath:WKLogPath() toPath:WKLogRotationPath() error:NULL];
    WKLogDescriptor = open(WKLogPath().fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    __atomic_store_n(&WKLogBytes, 0, __ATOMIC_RELAXED);
    os_unfair_lock_unlock(&WKLogLock);
}

static void WKLogWriteBytes(const char *bytes, size_t length) {
    if (WKLogDescriptor < 0 || length == 0) return;
    ssize_t written = write(WKLogDescriptor, bytes, length);
    if (written < 0) return;
    unsigned long long total = __atomic_add_fetch(&WKLogBytes, (unsigned long long)length, __ATOMIC_RELAXED);
    if (total > WKLogLimit) WKLogRotate();
}

static NSString *WKLogStamp(void) {
    // A formatter per call would be wasteful at any rate, and this is not a hot
    // path, but a cached one is neither, so cache it on the log's own queue
    // semantics: NSDateFormatter is safe to use from one thread at a time, and the
    // stamp is built under the same lock the rotation uses.
    static NSDateFormatter *formatter = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.dateFormat = @"HH:mm:ss.SSS";
    });
    os_unfair_lock_lock(&WKLogLock);
    NSString *stamp = [formatter stringFromDate:NSDate.date];
    os_unfair_lock_unlock(&WKLogLock);
    return stamp;
}

static void WKLogEmit(const char *tag, NSString *message) {
    NSString *line = [NSString stringWithFormat:@"%@ [%s] %@\n", WKLogStamp(), tag, message];
    // stderr as well, so a console run reads exactly as it always did and the
    // platform's own channel keeps its behaviour.
    fputs(line.UTF8String, stderr);
    WKLogWriteBytes(line.UTF8String, strlen(line.UTF8String));
}

void WKLogLine(const char *tag, NSString *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
    va_end(arguments);
    WKLogEmit(tag, message);
}

void WKLogFatal(const char *tag, NSString *message) {
    NSString *line = [NSString stringWithFormat:@"%@ [%s] %@\n", WKLogStamp(), tag, message];
    fputs(line.UTF8String, stderr);
    WKLogWriteBytes(line.UTF8String, strlen(line.UTF8String));
}

#pragma mark - Crashes

// An uncaught exception is the case that cost an hour: the reason and the stack are
// both right here, and are the same ones the system crash report will show - except
// this one is written next to the lines that led to it, before the process goes.
static void WKLogUncaughtException(NSException *exception) {
    NSMutableString *report = [NSMutableString stringWithFormat:@"uncaught %@: %@", exception.name, exception.reason];
    // The user info of a constraint failure names the views, which is the part
    // that actually says what is wrong.
    if (exception.userInfo.count) [report appendFormat:@"\n    user info: %@", exception.userInfo];
    NSArray<NSString *> *stack = NSThread.callStackSymbols;
    for (NSUInteger index = 0; index < stack.count && index < 40; index++)
        [report appendFormat:@"\n    %@", stack[index]];
    WKLogFatal("fatal", report);
}

// Signal handlers may only call things that are safe inside a signal. write(2) is;
// strlen over a literal and string formatting are not, so the text and its length
// are both literals here, and the rich report is left to the exception handler.
static const char WKLogAbortText[] = "[fatal] SIGABRT - the process aborted: an uncaught exception, a failed assert, or abort()\n";
static const char WKLogSegvText[]  = "[fatal] SIGSEGV - the process touched memory it does not own\n";
static const char WKLogBusText[]   = "[fatal] SIGBUS - the process touched misaligned or unmapped memory\n";
static const char WKLogIllText[]   = "[fatal] SIGILL - the process ran an illegal instruction\n";
static const char WKLogFpeText[]   = "[fatal] SIGFPE - the process faulted on arithmetic\n";
static const char WKLogTrapText[]  = "[fatal] SIGTRAP - the process hit a trap instruction\n";
static const char WKLogOtherText[] = "[fatal] the process was killed by a signal with no entry here\n";

#define WK_TEXT(text) { text, sizeof(text) - 1 }

static const struct { const char *text; size_t length; } WKLogSignals[] = {
    WK_TEXT(WKLogAbortText), WK_TEXT(WKLogSegvText), WK_TEXT(WKLogBusText),
    WK_TEXT(WKLogIllText), WK_TEXT(WKLogFpeText), WK_TEXT(WKLogTrapText),
};

static void WKLogSignal(int number) {
    const char *text = WKLogOtherText;
    size_t length = sizeof(WKLogOtherText) - 1;
    static const int numbers[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP };
    for (size_t index = 0; index < sizeof(numbers) / sizeof(numbers[0]); index++) {
        if (numbers[index] != number) continue;
        text = WKLogSignals[index].text;
        length = WKLogSignals[index].length;
        break;
    }
    if (WKLogDescriptor >= 0) {
        ssize_t ignored = write(WKLogDescriptor, text, length);
        (void)ignored;
    }
    // Hand the signal back to the system, so the crash report is still written and
    // the behaviour of the process is unchanged: this only adds a line.
    signal(number, SIG_DFL);
    raise(number);
}

void WKLogStart(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        WKLogDescriptor = open(WKLogPath().fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
        struct stat information = {0};
        if (WKLogDescriptor >= 0 && fstat(WKLogDescriptor, &information) == 0)
            __atomic_store_n(&WKLogBytes, (unsigned long long)information.st_size, __ATOMIC_RELAXED);

        NSSetUncaughtExceptionHandler(&WKLogUncaughtException);
        static const int numbers[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP };
        for (size_t index = 0; index < sizeof(numbers) / sizeof(numbers[0]); index++)
            signal(numbers[index], WKLogSignal);

        NSDictionary *info = NSBundle.mainBundle.infoDictionary;
        WKLog("host", @"--- %@ %@ (%@) pid %d launched ---",
              info[@"CFBundleName"] ?: @"Wolkara",
              info[@"CFBundleShortVersionString"] ?: @"?",
              info[@"CFBundleVersion"] ?: @"?",
              getpid());
        WKLog("host", @"arguments: %@", [NSProcessInfo.processInfo.arguments componentsJoinedByString:@" "]);
        WKLog("host", @"log file: %@", WKLogPath());
    });
}
