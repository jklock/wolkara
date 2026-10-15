#import "DiagnosticsViewController.h"
#import "Diagnostics.h"

@interface TKDiagnostic ()
- (void)runWithReport:(TKDiagnosticReport)report;
@end
@interface TKDiagnosticSection ()
@property(nonatomic, copy) NSString *title, *footer;
@property(nonatomic, copy) NSArray<TKDiagnostic *> *items;
@end

@implementation TKDiagnostic {
    void (^_run)(TKDiagnosticReport);
}
+ (instancetype)diagnosticWithTitle:(NSString *)title detail:(NSString *)detail run:(void (^)(TKDiagnosticReport))run {
    TKDiagnostic *diagnostic=[TKDiagnostic new];
    diagnostic->_title=title.copy; diagnostic->_detail=detail.copy; diagnostic->_run=[run copy];
    return diagnostic;
}
- (void)runWithReport:(TKDiagnosticReport)report { _run(report); }
@end

@implementation TKDiagnosticSection
+ (instancetype)sectionWithTitle:(NSString *)title footer:(NSString *)footer items:(NSArray<TKDiagnostic *> *)items {
    TKDiagnosticSection *section=[TKDiagnosticSection new];
    section.title=title; section.footer=footer; section.items=items;
    return section;
}
@end

@implementation TKReportViewController {
    NSString *_file;
    UITextView *_textView;
}
- (instancetype)initWithTitle:(NSString *)title file:(NSString *)file {
    if (!(self=[super initWithNibName:nil bundle:nil])) return nil;
    self.title=title; _file=file.copy; _text=@"";
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor=UIColor.systemBackgroundColor;
    _textView=[[UITextView alloc] initWithFrame:self.view.bounds];
    _textView.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _textView.editable=NO;
    _textView.font=[UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _textView.textContainerInset=UIEdgeInsetsMake(16,12,16,12);
    [self.view addSubview:_textView];
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction target:self action:@selector(share:)];
    if (_file) {
        // Runtime logs can be large; the end is what matters when reading here.
        NSFileHandle *handle=[NSFileHandle fileHandleForReadingAtPath:_file];
        unsigned long long size=[handle seekToEndOfFile], limit=1024*1024;
        [handle seekToFileOffset:size>limit ? size-limit : 0];
        NSData *data=[handle readDataToEndOfFile];
        [handle closeFile];
        NSString *text=[[NSString alloc] initWithData:data?:NSData.data encoding:NSUTF8StringEncoding]?:
            [[NSString alloc] initWithData:data?:NSData.data encoding:NSISOLatin1StringEncoding];
        _text=size>limit ? [@"… (showing the last 1 MiB; share the file for all of it)\n" stringByAppendingString:text?:@""] : text?:@"";
    }
    _textView.text=_text;
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_file && _textView.text.length) [_textView scrollRangeToVisible:NSMakeRange(_textView.text.length-1,1)];
}
- (void)setText:(NSString *)text { _text=text.copy; _textView.text=_text; }
- (void)share:(UIBarButtonItem *)sender {
    id item=_file ? [NSURL fileURLWithPath:_file] : _text;
    UIActivityViewController *activity=[[UIActivityViewController alloc] initWithActivityItems:@[item] applicationActivities:nil];
    activity.popoverPresentationController.barButtonItem=sender;
    [self presentViewController:activity animated:YES completion:nil];
}
@end

@implementation TKDiagnosticsViewController {
    NSArray<TKDiagnosticSection *> *_sections;
    NSArray<NSString *> *_logs;
    BOOL _running;
}
- (instancetype)initWithSections:(NSArray<TKDiagnosticSection *> *)sections {
    if (!(self=[super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _sections=sections.copy; _logs=@[];
    self.title=@"Diagnostics";
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"cell"];
}
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadLogs];
}
// Reports and runtime logs the launcher and checks leave in Documents.
- (void)reloadLogs {
    NSString *documents=TKDocumentsPath(@"");
    NSMutableArray *logs=[NSMutableArray new];
    for (NSString *name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:documents error:NULL])
        if ([@[@"log",@"txt"] containsObject:name.pathExtension.lowercaseString]) [logs addObject:[documents stringByAppendingPathComponent:name]];
    [logs sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSDate *first=[NSFileManager.defaultManager attributesOfItemAtPath:a error:NULL].fileModificationDate?:NSDate.distantPast;
        NSDate *second=[NSFileManager.defaultManager attributesOfItemAtPath:b error:NULL].fileModificationDate?:NSDate.distantPast;
        return [second compare:first];
    }];
    _logs=logs;
    [self.tableView reloadData];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return (NSInteger)_sections.count+1; }
- (BOOL)isLogSection:(NSInteger)section { return section==(NSInteger)_sections.count; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView;
    if ([self isLogSection:section]) return MAX((NSInteger)_logs.count,1);
    return (NSInteger)_sections[(NSUInteger)section].items.count;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView;
    return [self isLogSection:section] ? @"Logs and reports" : _sections[(NSUInteger)section].title;
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    return [self isLogSection:section] ? @"Files in Tolkara's Documents folder, newest first." : _sections[(NSUInteger)section].footer;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    UIListContentConfiguration *content=UIListContentConfiguration.subtitleCellConfiguration;
    content.secondaryTextProperties.color=UIColor.secondaryLabelColor;
    cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    if ([self isLogSection:indexPath.section]) {
        if (!_logs.count) {
            content.text=@"No logs yet";
            content.textProperties.color=UIColor.secondaryLabelColor;
            cell.accessoryType=UITableViewCellAccessoryNone;
            cell.selectionStyle=UITableViewCellSelectionStyleNone;
        } else {
            NSString *path=_logs[(NSUInteger)indexPath.row];
            NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
            content.text=path.lastPathComponent;
            content.secondaryText=[NSString stringWithFormat:@"%@ · %@",
                [NSByteCountFormatter stringFromByteCount:(long long)attributes.fileSize countStyle:NSByteCountFormatterCountStyleFile],
                [NSDateFormatter localizedStringFromDate:attributes.fileModificationDate?:NSDate.date dateStyle:NSDateFormatterShortStyle timeStyle:NSDateFormatterShortStyle]];
            content.image=[UIImage systemImageNamed:@"doc.text"];
        }
    } else {
        TKDiagnostic *diagnostic=_sections[(NSUInteger)indexPath.section].items[(NSUInteger)indexPath.row];
        content.text=diagnostic.title;
        content.secondaryText=diagnostic.detail;
        content.image=[UIImage systemImageNamed:diagnostic.endsSession ? @"exclamationmark.triangle" : @"stethoscope"];
    }
    cell.contentConfiguration=content;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self isLogSection:indexPath.section]) {
        if (!_logs.count) return;
        NSString *path=_logs[(NSUInteger)indexPath.row];
        [self.navigationController pushViewController:[[TKReportViewController alloc] initWithTitle:path.lastPathComponent file:path] animated:YES];
        return;
    }
    [self runDiagnostic:_sections[(NSUInteger)indexPath.section].items[(NSUInteger)indexPath.row]];
}

- (void)runDiagnostic:(TKDiagnostic *)diagnostic {
    if (_running) {
        [self alert:@"A check is still running" message:@"Wait for it to finish before starting another."];
        return;
    }
    if (!diagnostic.endsSession) { [self startDiagnostic:diagnostic]; return; }
    UIAlertController *confirm=[UIAlertController alertControllerWithTitle:diagnostic.title
        message:@"This test runs host code or loads compatibility libraries, and the system may close Tolkara. Afterwards, close and reopen Tolkara before starting an app."
        preferredStyle:UIAlertControllerStyleAlert];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [confirm addAction:[UIAlertAction actionWithTitle:@"Run" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        if (self.sessionEnding) self.sessionEnding();
        [self startDiagnostic:diagnostic];
    }]];
    [self presentViewController:confirm animated:YES completion:nil];
}
- (void)startDiagnostic:(TKDiagnostic *)diagnostic {
    _running=YES;
    TKReportViewController *report=[[TKReportViewController alloc] initWithTitle:diagnostic.title file:nil];
    report.text=@"Running…";
    [self.navigationController pushViewController:report animated:YES];
    __weak TKDiagnosticsViewController *weakSelf=self;
    [diagnostic runWithReport:^(NSString *text, BOOL finished) {
        dispatch_block_t update=^{
            report.text=text;
            if (!finished) return;
            TKDiagnosticsViewController *strongSelf=weakSelf;
            if (strongSelf) { strongSelf->_running=NO; [strongSelf reloadLogs]; }
        };
        if (NSThread.isMainThread) update(); else dispatch_async(dispatch_get_main_queue(),update);
    }];
}
- (void)alert:(NSString *)title message:(NSString *)message {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
@end
