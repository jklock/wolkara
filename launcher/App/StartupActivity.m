#import "StartupActivity.h"
#import <QuartzCore/QuartzCore.h>
#include <limits.h>
#include <stdlib.h>

// Entries looked at per scan of the app's folder, at most.
static const unsigned ScanLimit = 4000;

// The newest regular file under folder changed after since, if any.
static NSURL *NewestWrite(NSURL *folder, NSDate *since, NSDate **modified, unsigned long long *bytes) {
    NSArray<NSURLResourceKey> *keys = @[NSURLIsRegularFileKey, NSURLContentModificationDateKey, NSURLFileSizeKey];
    NSDirectoryEnumerator<NSURL *> *entries = [[NSFileManager new] enumeratorAtURL:folder includingPropertiesForKeys:keys
        options:NSDirectoryEnumerationSkipsHiddenFiles | NSDirectoryEnumerationSkipsPackageDescendants errorHandler:nil];
    NSURL *newest = nil; unsigned seen = 0;
    for (NSURL *url in entries) {
        if (++seen > ScanLimit) break;
        NSDictionary<NSURLResourceKey, id> *values = [url resourceValuesForKeys:keys error:NULL];
        NSDate *date = values[NSURLContentModificationDateKey];
        if (![values[NSURLIsRegularFileKey] boolValue] || !date || [date compare:since] != NSOrderedDescending) continue;
        since = date; newest = url;
        *modified = date; *bytes = [values[NSURLFileSizeKey] unsignedLongLongValue];
    }
    return newest;
}

@implementation TKStartupActivityView {
    CATextLayer *_text;
    UIFont *_font;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    NSString *_shown;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hidden = YES;
    self.isAccessibilityElement = YES;
    self.accessibilityLabel = @"Startup activity";
    _font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
    _text = [CATextLayer layer];
    _text.font = (__bridge CFTypeRef)_font;
    _text.fontSize = _font.pointSize;
    _text.wrapped = YES;
    _text.truncationMode = kCATruncationEnd;
    [self.layer addSublayer:_text];
    _queue = dispatch_queue_create("tolkara.startup-activity", DISPATCH_QUEUE_SERIAL);
    [self registerForTraitChanges:@[UITraitUserInterfaceStyle.class, UITraitDisplayScale.class]
                       withAction:@selector(updateAppearance)];
    return self;
}
- (CGSize)intrinsicContentSize { return CGSizeMake(UIViewNoIntrinsicMetric, ceil(_font.lineHeight * 2) + 4); }
- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _text.frame = self.bounds;
    [CATransaction commit];
}
- (void)updateAppearance {
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    _text.foregroundColor = [UIColor.secondaryLabelColor resolvedColorWithTraitCollection:self.traitCollection].CGColor;
    _text.contentsScale = self.traitCollection.displayScale ?: 2;
    [CATransaction commit];
}
- (void)startInFolder:(NSString *)folder step:(NSString *(^)(NSTimeInterval *))step {
    [self stop];
    self.hidden = NO;
    [self updateAppearance];
    // Callers go on to hold the main thread, which would keep this hidden
    // until it returns: lay out and commit now.
    [self.superview layoutIfNeeded];
    [CATransaction flush];
    // Entries may come back under the real path (/private/var/…) or the given one (/var/…).
    char real[PATH_MAX];
    NSString *base = realpath(folder.fileSystemRepresentation, real) ? @(real) : folder;
    NSURL *root = [NSURL fileURLWithPath:base isDirectory:YES];
    NSMutableOrderedSet<NSString *> *prefixes = [NSMutableOrderedSet orderedSetWithObjects:
        [base stringByAppendingString:@"/"], [folder stringByAppendingString:@"/"], nil];
    if ([base hasPrefix:@"/private/"]) [prefixes addObject:[[base substringFromIndex:8] stringByAppendingString:@"/"]];
    NSDate *started = [NSDate date];
    CATextLayer *layer = _text;
    __weak TKStartupActivityView *weakSelf = self;
    __block NSString *file = nil; __block NSDate *written = nil; __block unsigned long long bytes = 0;
    __block unsigned wait = 0;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(_timer, ^{ @autoreleasepool {
        if (wait) wait--;
        else {
            CFTimeInterval begin = CACurrentMediaTime();
            NSDate *modified = nil; unsigned long long size = 0;
            NSURL *newest = NewestWrite(root, written ?: started, &modified, &size);
            if (newest) {
                file = newest.lastPathComponent;
                for (NSString *prefix in prefixes)
                    if ([newest.path hasPrefix:prefix]) { file = [newest.path substringFromIndex:prefix.length]; break; }
                written = modified; bytes = size;
            }
            // A large folder is looked at less often: scanning takes a tenth of the time at most.
            wait = (unsigned)MIN(30, (CACurrentMediaTime() - begin) * 10);
        }
        NSTimeInterval seconds = 0;
        NSString *now = step(&seconds);
        NSString *text = TKStartupActivityText(now, seconds, file, bytes, written ? -written.timeIntervalSinceNow : 0);
        // An explicit transaction commits from this queue while the main thread is busy.
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        layer.string = text;
        [CATransaction commit];
        TKStartupActivityView *view = weakSelf;
        if (view) @synchronized (view) { view->_shown = text; }
    }});
    dispatch_resume(_timer);
}
- (NSString *)accessibilityValue { @synchronized (self) { return _shown; } }
- (void)stop {
    if (_timer) dispatch_source_cancel(_timer);
    _timer = nil;
    self.hidden = YES;
}
- (void)dealloc { if (_timer) dispatch_source_cancel(_timer); }
@end
