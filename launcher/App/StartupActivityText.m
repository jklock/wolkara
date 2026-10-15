#import "StartupActivityText.h"

static NSString *Elapsed(NSTimeInterval seconds) {
    unsigned whole = (unsigned)MAX(0, seconds);
    if (whole < 60) return [NSString stringWithFormat:@"%u s", whole];
    return [NSString stringWithFormat:@"%u min %u s", whole / 60, whole % 60];
}
// "0 bytes", not "Zero KB", for a file just created.
static NSString *FileSize(unsigned long long bytes) {
    NSByteCountFormatter *formatter = [NSByteCountFormatter new];
    formatter.countStyle = NSByteCountFormatterCountStyleFile;
    formatter.allowsNonnumericFormatting = NO;
    return [formatter stringFromByteCount:(long long)bytes];
}
// Long paths keep their start and their file name.
static NSString *Shortened(NSString *path) {
    const NSUInteger limit = 72;
    if (path.length <= limit) return path;
    return [NSString stringWithFormat:@"%@…%@", [path substringToIndex:limit / 2 - 1],
            [path substringFromIndex:path.length - limit / 2]];
}

NSString *TKStartupStepText(const char *step, unsigned long long done, unsigned long long total) {
    if (!step) return nil;
    if (!total) return @(step);
    return [NSString localizedStringWithFormat:@"%s (%llu of %llu)", step, done, total];
}

NSString *TKStartupActivityText(NSString *step, NSTimeInterval seconds, NSString *file, unsigned long long bytes, NSTimeInterval age) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (step) [lines addObject:[NSString stringWithFormat:@"Now: %@ · %@", step, Elapsed(seconds)]];
    if (file) [lines addObject:[NSString stringWithFormat:@"Last file written: %@ · %@ · %@ ago", Shortened(file),
        FileSize(bytes), Elapsed(age)]];
    return [lines componentsJoinedByString:@"\n"];
}
