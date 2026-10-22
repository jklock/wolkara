#import "AddonManager.h"
#import "AddonStore.h"
#import "AddonCredentialStore.h"
#import "CurseForgeClient.h"
#import "../App/WolkaraForeverTheme.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const TKForeverGameVersion=@"1.60.1";

@interface TKWoWAddon ()
@property(nonatomic, readwrite, copy) NSString *folder;
@property(nonatomic, readwrite, copy) NSString *title;
@property(nonatomic, readwrite, copy, nullable) NSString *version;
@property(nonatomic, readwrite) NSUInteger fileCount;
@end

@implementation TKWoWAddon
@end

// MARK: - CurseForge browser: columns, icons and cells

// The project list mirrors the CurseForge site's table: the project's artwork
// and name, then Downloads, Top, Latest, Category, Game Version and Author.
// "Action" is not a column: installing is the row's own selection.
typedef NS_OPTIONS(NSUInteger, TKAddonColumn) {
    TKAddonColumnDownloads = 1 << 0,
    TKAddonColumnTop       = 1 << 1,
    TKAddonColumnLatest    = 1 << 2,
    TKAddonColumnCategory  = 1 << 3,
    TKAddonColumnVersion   = 1 << 4,
    TKAddonColumnAuthor    = 1 << 5,
    TKAddonColumnAll       = 0x3f,
};
static NSString *const TKAddonColumnsKey = @"WolkaraForeverAddonColumnsV1";

static NSString *TKAddonColumnTitle(TKAddonColumn column) {
    switch (column) {
        case TKAddonColumnDownloads: return @"Downloads";
        case TKAddonColumnTop:       return @"Top";
        case TKAddonColumnLatest:    return @"Latest";
        case TKAddonColumnCategory:  return @"Category";
        case TKAddonColumnVersion:   return @"Game Version";
        case TKAddonColumnAuthor:    return @"Author";
        default: return @"";
    }
}
static CGFloat TKAddonColumnWidth(TKAddonColumn column) {
    switch (column) {
        case TKAddonColumnDownloads: return 74;
        case TKAddonColumnTop:       return 38;
        case TKAddonColumnLatest:    return 78;
        case TKAddonColumnCategory:  return 104;
        case TKAddonColumnVersion:   return 100;
        case TKAddonColumnAuthor:    return 86;
        default: return 0;
    }
}
static NSArray<NSNumber *> *TKAddonColumnOrder(void) {
    return @[@(TKAddonColumnDownloads), @(TKAddonColumnTop), @(TKAddonColumnLatest),
             @(TKAddonColumnCategory), @(TKAddonColumnVersion), @(TKAddonColumnAuthor)];
}
// The site shows `371.4M`; bytes would say `354.2 MB` and read as storage.
static NSString *TKAddonDownloadsText(NSNumber *value) {
    double n=value.doubleValue;
    if (n >= 1e9) return [NSString stringWithFormat:@"%.1fB", n/1e9];
    if (n >= 1e6) return [NSString stringWithFormat:@"%.1fM", n/1e6];
    if (n >= 1e3) return [NSString stringWithFormat:@"%.1fK", n/1e3];
    return [NSString stringWithFormat:@"%.0f", n];
}
static NSString *TKAddonDateText(NSString *iso) {
    if (![iso isKindOfClass:NSString.class] || iso.length < 10) return @"";
    // The site prints MM/dd/yyyy; the API sends ISO-8601.
    NSString *day=[iso substringToIndex:10];
    NSArray<NSString *> *parts=[day componentsSeparatedByString:@"-"];
    if (parts.count==3) return [NSString stringWithFormat:@"%@/%@/%@",parts[1],parts[2],parts[0]];
    return day;
}
static NSDictionary *TKAddonLatestFile(NSDictionary *project, NSString *gameVersion) {
    NSArray *files=[project[@"latestFiles"] isKindOfClass:NSArray.class]?project[@"latestFiles"]:@[];
    NSArray *available=[files filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(id item,NSDictionary *bindings){
        (void)bindings;
        return [item isKindOfClass:NSDictionary.class] && [item[@"isAvailable"] boolValue] &&
               [item[@"fileDate"] isKindOfClass:NSString.class];
    }]];
    NSArray *matching=gameVersion.length?[available filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,NSDictionary *bindings){
        (void)bindings;
        return [item[@"gameVersions"] isKindOfClass:NSArray.class] && [item[@"gameVersions"] containsObject:gameVersion];
    }]]:@[];
    NSArray *pool=matching.count?matching:available.count?available:files;
    return [pool sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){
        NSString *x=[a[@"fileDate"] isKindOfClass:NSString.class]?a[@"fileDate"]:@"";
        NSString *y=[b[@"fileDate"] isKindOfClass:NSString.class]?b[@"fileDate"]:@"";
        return [y compare:x];
    }].firstObject;
}
// The sheet's body used to run edge to edge: the edition panel touched the
// left rounding, the search field and the list touched both sides. Everything
// on this page is inset by this much now, rows and column titles included, so
// the gutters line up down the whole page.
static const CGFloat TKAddonPageMargin = 14;

static UIImage *TKAddonPlaceholderIcon(void) {
    UIImageSymbolConfiguration *configuration=[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIFontWeightRegular];
    return [UIImage systemImageNamed:@"puzzlepiece.extension" withConfiguration:configuration];
}

// Project artwork. The API's thumbnail URLs are on CurseForge's CDN; only that
// host is fetched, the data is capped, and decoding happens off the main thread.
@interface TKAddonIconLoader : NSObject
+ (instancetype)shared;
- (void)imageForURLString:(NSString *)string completion:(void (^)(UIImage *image))completion;
@end
@implementation TKAddonIconLoader {
    NSCache<NSString *, UIImage *> *_cache;
    NSURLSession *_session;
}
+ (instancetype)shared {
    static TKAddonIconLoader *loader;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ loader=[TKAddonIconLoader new]; });
    return loader;
}
- (instancetype)init {
    if ((self=[super init])) {
        _cache=[NSCache new]; _cache.countLimit=200;
        NSURLSessionConfiguration *configuration=NSURLSessionConfiguration.ephemeralSessionConfiguration;
        configuration.timeoutIntervalForRequest=20;
        _session=[NSURLSession sessionWithConfiguration:configuration];
    }
    return self;
}
- (void)imageForURLString:(NSString *)string completion:(void (^)(UIImage *))completion {
    if (!string.length || !completion) return;
    UIImage *cached=[_cache objectForKey:string];
    if (cached) { completion(cached); return; }
    NSURL *url=[NSURL URLWithString:string];
    NSString *host=url.host.lowercaseString;
    if (![url.scheme.lowercaseString isEqual:@"https"] ||
        !([host isEqual:@"forgecdn.net"] || [host hasSuffix:@".forgecdn.net"])) { completion(nil); return; }
    [[_session dataTaskWithURL:url completionHandler:^(NSData *data,NSURLResponse *response,NSError *failure) {
        (void)failure;
        NSHTTPURLResponse *http=(id)response;
        if (!data.length || data.length>2*1024*1024 || (http && (http.statusCode<200 || http.statusCode>=300))) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
            return;
        }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
            UIImage *image=[UIImage imageWithData:data];
            if (image) [self->_cache setObject:image forKey:string];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(image); });
        });
    }] resume];
}
@end

@interface TKAddonProjectCell : UITableViewCell
@property (nonatomic, copy) NSString *iconURLString;
- (void)configureWithProject:(NSDictionary *)project file:(NSDictionary *)file
                        rank:(NSString *)rank columns:(NSUInteger)columns
                 gameVersion:(NSString *)gameVersion compact:(BOOL)compact;
@end
@implementation TKAddonProjectCell {
    UIImageView *_iconView;
    UILabel *_titleLabel, *_fileLabel;
    NSMutableDictionary<NSNumber *, UILabel *> *_valueLabels;
    NSMutableDictionary<NSNumber *, NSLayoutConstraint *> *_widthConstraints;
}
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)identifier {
    if ((self=[super initWithStyle:style reuseIdentifier:identifier])) {
        self.backgroundColor=[UIColor colorWithRed:0.07 green:0.09 blue:0.13 alpha:1];
        self.selectionStyle=UITableViewCellSelectionStyleDefault;
        _iconView=[[UIImageView alloc] init];
        _iconView.translatesAutoresizingMaskIntoConstraints=NO;
        _iconView.contentMode=UIViewContentModeScaleAspectFill;
        _iconView.clipsToBounds=YES;
        _iconView.layer.cornerRadius=10;
        _iconView.backgroundColor=[UIColor colorWithWhite:1 alpha:0.06];
        _iconView.image=TKAddonPlaceholderIcon();
        _iconView.tintColor=[UIColor colorWithWhite:0.55 alpha:1];
        _iconView.accessibilityIdentifier=@"wow.addons.logo";
        [NSLayoutConstraint activateConstraints:@[
            [_iconView.widthAnchor constraintEqualToConstant:46],
            [_iconView.heightAnchor constraintEqualToConstant:46],
        ]];
        _titleLabel=[UILabel new];
        _titleLabel.font=[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _titleLabel.textColor=[UIColor colorWithWhite:0.96 alpha:1];
        _titleLabel.numberOfLines=1;
        _titleLabel.lineBreakMode=NSLineBreakByTruncatingTail;
        _titleLabel.accessibilityIdentifier=@"wow.addons.name";
        _fileLabel=[UILabel new];
        _fileLabel.font=[UIFont systemFontOfSize:11.5 weight:UIFontWeightRegular];
        _fileLabel.textColor=[UIColor colorWithWhite:0.62 alpha:1];
        _fileLabel.numberOfLines=1;
        _fileLabel.lineBreakMode=NSLineBreakByTruncatingMiddle;
        _fileLabel.accessibilityIdentifier=@"wow.addons.file";
        UIStackView *text=[ [UIStackView alloc] initWithArrangedSubviews:@[_titleLabel,_fileLabel] ];
        text.axis=UILayoutConstraintAxisVertical; text.spacing=2; text.alignment=UIStackViewAlignmentLeading;
        UIStackView *name=[ [UIStackView alloc] initWithArrangedSubviews:@[_iconView,text] ];
        name.axis=UILayoutConstraintAxisHorizontal; name.spacing=10; name.alignment=UIStackViewAlignmentCenter;
        [name setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [name setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        _valueLabels=[NSMutableDictionary new]; _widthConstraints=[NSMutableDictionary new];
        NSMutableArray *arranged=[@[name] mutableCopy];
        for (NSNumber *number in TKAddonColumnOrder()) {
            TKAddonColumn column=(TKAddonColumn)number.unsignedIntegerValue;
            UILabel *label=[UILabel new];
            label.font=[UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
            label.textColor=[UIColor colorWithWhite:0.82 alpha:1];
            label.numberOfLines=1;
            label.lineBreakMode=NSLineBreakByTruncatingTail;
            label.accessibilityIdentifier=[@"wow.addons.value." stringByAppendingString:TKAddonColumnTitle(column).lowercaseString];
            NSLayoutConstraint *width=[label.widthAnchor constraintEqualToConstant:TKAddonColumnWidth(column)];
            width.active=YES;
            _valueLabels[number]=label; _widthConstraints[number]=width;
            [arranged addObject:label];
        }
        UIStackView *row=[ [UIStackView alloc] initWithArrangedSubviews:arranged ];
        row.axis=UILayoutConstraintAxisHorizontal; row.spacing=10; row.alignment=UIStackViewAlignmentCenter;
        row.translatesAutoresizingMaskIntoConstraints=NO;
        [self.contentView addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:TKAddonPageMargin],
            [row.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-TKAddonPageMargin],
            [row.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:9],
            [row.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-9],
        ]];
    }
    return self;
}
- (void)prepareForReuse {
    [super prepareForReuse];
    _iconURLString=nil;
    _iconView.image=TKAddonPlaceholderIcon();
}
- (void)configureWithProject:(NSDictionary *)project file:(NSDictionary *)file rank:(NSString *)rank
                     columns:(NSUInteger)columns gameVersion:(NSString *)gameVersion compact:(BOOL)compact {
    _titleLabel.text=[project[@"name"] isKindOfClass:NSString.class]?project[@"name"]:@"Untitled add-on";
    NSString *fileText=[file[@"displayName"] isKindOfClass:NSString.class]?file[@"displayName"]:@"";
    _fileLabel.text=fileText.length?fileText:([project[@"summary"] isKindOfClass:NSString.class]?project[@"summary"]:@"");
    NSArray *categories=[project[@"categories"] isKindOfClass:NSArray.class]?project[@"categories"]:@[];
    NSDictionary *firstCategory=[categories.firstObject isKindOfClass:NSDictionary.class]?categories.firstObject:nil;
    NSArray *authors=[project[@"authors"] isKindOfClass:NSArray.class]?project[@"authors"]:@[];
    NSDictionary *firstAuthor=[authors.firstObject isKindOfClass:NSDictionary.class]?authors.firstObject:nil;
    NSArray *versions=[file[@"gameVersions"] isKindOfClass:NSArray.class]?file[@"gameVersions"]:@[];
    NSString *version=gameVersion.length?gameVersion:(versions.lastObject?:@"");
    NSDictionary<NSNumber *, NSString *> *texts=@{
        @(TKAddonColumnDownloads): TKAddonDownloadsText(project[@"downloadCount"]),
        @(TKAddonColumnTop): rank?:@"—",
        @(TKAddonColumnLatest): TKAddonDateText(file[@"fileDate"]),
        @(TKAddonColumnCategory): [firstCategory[@"name"] isKindOfClass:NSString.class]?firstCategory[@"name"]:@"",
        @(TKAddonColumnVersion): version,
        @(TKAddonColumnAuthor): [firstAuthor[@"name"] isKindOfClass:NSString.class]?firstAuthor[@"name"]:@"",
    };
    for (NSNumber *number in TKAddonColumnOrder()) {
        TKAddonColumn column=(TKAddonColumn)number.unsignedIntegerValue;
        BOOL visible=(columns & column) && !(compact && column!=TKAddonColumnDownloads && column!=TKAddonColumnVersion);
        UILabel *label=_valueLabels[number];
        label.hidden=!visible;
        label.text=texts[number]?:@"";
    }
    NSString *icon=project[@"logo"][@"thumbnailUrl"];
    if (![icon isKindOfClass:NSString.class] || !icon.length) icon=project[@"logo"][@"url"];
    if (![icon isKindOfClass:NSString.class]) icon=nil;
    _iconURLString=icon;
    if (icon.length) {
        __weak TKAddonProjectCell *weakSelf=self;
        NSString *wanted=icon;
        [[TKAddonIconLoader shared] imageForURLString:icon completion:^(UIImage *image) {
            TKAddonProjectCell *self=weakSelf; if (!self || ![self->_iconURLString isEqual:wanted]) return;
            if (image) { self->_iconView.image=image; self->_iconView.tintColor=nil; }
        }];
    }
}
@end

@interface TKAddonColumnsHeaderView : UIView
- (void)configureWithColumns:(NSUInteger)columns compact:(BOOL)compact;
@end
@implementation TKAddonColumnsHeaderView {
    NSMutableDictionary<NSNumber *, UILabel *> *_labels;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self=[super initWithFrame:frame])) {
        self.backgroundColor=WKInk();
        UILabel *name=[UILabel new];
        name.text=@"NAME";
        name.font=[UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        name.textColor=[UIColor colorWithWhite:0.55 alpha:1];
        UIStackView *row=[ [UIStackView alloc] initWithArrangedSubviews:@[name] ];
        _labels=[NSMutableDictionary new];
        for (NSNumber *number in TKAddonColumnOrder()) {
            TKAddonColumn column=(TKAddonColumn)number.unsignedIntegerValue;
            UILabel *label=[UILabel new];
            label.text=TKAddonColumnTitle(column).uppercaseString;
            label.font=[UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
            label.textColor=[UIColor colorWithWhite:0.55 alpha:1];
            [label.widthAnchor constraintEqualToConstant:TKAddonColumnWidth(column)].active=YES;
            _labels[number]=label;
            [row addArrangedSubview:label];
        }
        row.axis=UILayoutConstraintAxisHorizontal; row.spacing=10; row.alignment=UIStackViewAlignmentCenter;
        row.translatesAutoresizingMaskIntoConstraints=NO;
        [self addSubview:row];
        [NSLayoutConstraint activateConstraints:@[
            [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:TKAddonPageMargin],
            [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-TKAddonPageMargin],
            [row.topAnchor constraintEqualToAnchor:self.topAnchor],
            [row.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        ]];
    }
    return self;
}
- (void)configureWithColumns:(NSUInteger)columns compact:(BOOL)compact {
    for (NSNumber *number in TKAddonColumnOrder()) {
        TKAddonColumn column=(TKAddonColumn)number.unsignedIntegerValue;
        _labels[number].hidden=!(columns & column) || (compact && column!=TKAddonColumnDownloads && column!=TKAddonColumnVersion);
    }
}
@end

static NSString *TOCValue(NSString *text, NSString *key) {
    NSString *prefix=[@"## " stringByAppendingString:key];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (![line hasPrefix:prefix]) continue;
        NSString *value=[[line substringFromIndex:prefix.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (value.length && value.length<=512) return value;
    }
    return nil;
}

static NSString *ReadTOC(NSString *directory, NSString *folder) {
    NSArray<NSString *> *names=[[NSFileManager.defaultManager contentsOfDirectoryAtPath:directory error:NULL] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    NSString *preferred=[folder stringByAppendingPathExtension:@"toc"];
    for (NSString *name in names) {
        if (![name.pathExtension.lowercaseString isEqual:@"toc"]) continue;
        if (![name isEqual:preferred] && [names containsObject:preferred]) continue;
        NSData *data=[NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:name] options:0 error:NULL];
        if (!data.length || data.length>256*1024) continue;
        NSString *text=[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!text) text=[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
        if (text) return text;
    }
    return nil;
}

NSArray<TKWoWAddon *> *TKWoWAddonsAtDirectory(NSString *directory) {
    NSFileManager *manager=NSFileManager.defaultManager;
    NSArray<NSString *> *names=[[manager contentsOfDirectoryAtPath:directory error:NULL] sortedArrayUsingSelector:@selector(localizedStandardCompare:)];
    NSMutableArray<TKWoWAddon *> *addons=[NSMutableArray new];
    for (NSString *name in names) {
        if (!name.length || [name hasPrefix:@"."]) continue;
        NSString *path=[directory stringByAppendingPathComponent:name];
        NSURL *url=[NSURL fileURLWithPath:path]; NSNumber *directoryValue=nil;
        if (![url getResourceValue:&directoryValue forKey:NSURLIsDirectoryKey error:NULL] || !directoryValue.boolValue) continue;
        NSString *toc=ReadTOC(path,name);
        if (!toc) continue;
        NSDirectoryEnumerator *files=[manager enumeratorAtURL:[NSURL fileURLWithPath:path] includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles|NSDirectoryEnumerationSkipsPackageDescendants errorHandler:nil];
        NSUInteger count=0; while ([files nextObject]) count++;
        TKWoWAddon *addon=[TKWoWAddon new]; addon.folder=name;
        addon.title=TOCValue(toc,@"Title:")?:name;
        addon.version=TOCValue(toc,@"Version:"); addon.fileCount=count;
        [addons addObject:addon];
    }
    return addons;
}

@interface TKWoWAddonManagerViewController () <UIDocumentPickerDelegate, UISearchBarDelegate>
@property(nonatomic, copy) NSString *addOnsDirectory;
@property(nonatomic, copy) NSString *edition;
@property(nonatomic, copy) NSArray<TKWoWAddon *> *addons;
@property(nonatomic) UISegmentedControl *mode;
@property(nonatomic) TKAddonStore *store;
@property(nonatomic) TKAddonCredentialStore *credentials;
@property(nonatomic) UISearchBar *search;
@property(nonatomic) NSArray<NSDictionary *> *results;
@property(nonatomic) NSInteger sortField;
@property(nonatomic, copy) NSString *sortOrder;
@property(nonatomic) NSNumber *categoryID;
@property(nonatomic, copy) NSString *categoryLabel;
@property(nonatomic) NSUInteger totalCount;
@property(nonatomic) BOOL loadingMore;
@property(nonatomic) BOOL startInBrowse;
@property(nonatomic) NSArray<NSDictionary *> *categories;
@property(nonatomic,copy) NSString *browseStatus;
// The site's list controls: a game-version filter, the seven sort fields and
// the columns that can be shown. The filter and columns are remembered.
@property(nonatomic,copy) NSString *gameVersion;
@property(nonatomic) NSUInteger columns;
@property(nonatomic) UILabel *countLabel;
@property(nonatomic) UIButton *sortButton, *filterButton, *columnsButton;
@end

@implementation TKWoWAddonManagerViewController
- (instancetype)initWithAddOnsDirectory:(NSString *)directory edition:(NSString *)edition {
    return [self initWithAddOnsDirectory:directory edition:edition browse:NO];
}
- (instancetype)initWithAddOnsDirectory:(NSString *)directory edition:(NSString *)edition browse:(BOOL)browse {
    if (!(self=[super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _startInBrowse=browse;
    _addOnsDirectory=directory.copy; _edition=edition.copy; _addons=@[]; self.title=@"ADD-ON MANAGER";
    _store=[[TKAddonStore alloc] initWithAddOnsDirectory:directory product:@"wow_classic_beta" gameVersion:TKForeverGameVersion]; _results=@[]; _sortField=1; _sortOrder=@"desc";
    _credentials=[TKAddonCredentialStore new];
    _gameVersion=TKForeverGameVersion;
    NSNumber *savedColumns=[NSUserDefaults.standardUserDefaults objectForKey:TKAddonColumnsKey];
    _columns=savedColumns?savedColumns.unsignedIntegerValue:TKAddonColumnAll;
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    // The launcher's own colours, from WolkaraForeverTheme, so this screen and the voice
    // screens cannot drift apart again.
    self.view.backgroundColor=WKInk();
    // Navy, not clear. A transparent table shows whatever is behind it, and behind a
    // sheet is the presentation container, which is white: as a popup this page had a
    // white body under a navy navigation bar. Measured in the fixture on 2026-10-16.
    self.tableView.backgroundColor=WKInk();
    self.tableView.separatorStyle=UITableViewCellSeparatorStyleNone;
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.leftBarButtonItem.tintColor=WKGold();
    self.navigationItem.rightBarButtonItems=@[
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(importAddon)],
        [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(reloadAddons)]
    ];
    self.navigationItem.rightBarButtonItems[0].accessibilityIdentifier=@"wow.addons.import";
    self.navigationItem.rightBarButtonItems[1].accessibilityIdentifier=@"wow.addons.refresh";
    self.tableView.accessibilityIdentifier=@"wow.addons";
    self.tableView.tableHeaderView=[self header];
    [self reloadAddons];
    [self updateToolbar];
    if (_startInBrowse) {
        _mode.selectedSegmentIndex=1;
        [self updateToolbar];
        if ([self hasKey]) [self beginBrowse];
    }
}
- (UIView *)header {
    UIColor *gold=WKGold();
    CGFloat width=MAX(CGRectGetWidth(self.tableView.bounds),320);
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,width,212)];
    header.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    CGFloat body=width-2*TKAddonPageMargin;
    UIView *editionPanel=[[UIView alloc] initWithFrame:CGRectMake(TKAddonPageMargin,14,body,42)];
    editionPanel.backgroundColor=WKPanel(); editionPanel.layer.cornerRadius=14; editionPanel.layer.masksToBounds=YES;
    editionPanel.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    UILabel *edition=[UILabel new]; edition.text=[NSString stringWithFormat:@"Edition: %@  ▾",_edition];
    edition.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody]; edition.textColor=gold;
    edition.backgroundColor=UIColor.clearColor;
    edition.frame=CGRectMake(14,0,body-28,42); edition.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    [editionPanel addSubview:edition];
    [header addSubview:editionPanel];
    _mode=[[UISegmentedControl alloc] initWithItems:@[[NSString stringWithFormat:@"Installed (%lu)",(unsigned long)_addons.count],@"Browse CurseForge"]];
    _mode.selectedSegmentIndex=0; _mode.selectedSegmentTintColor=gold;
    [_mode setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.blackColor} forState:UIControlStateSelected];
    [_mode setTitleTextAttributes:@{NSForegroundColorAttributeName:[UIColor colorWithWhite:0.72 alpha:1]} forState:UIControlStateNormal];
    [_mode addTarget:self action:@selector(changeMode:) forControlEvents:UIControlEventValueChanged];
    _mode.frame=CGRectMake(TKAddonPageMargin,72,body,36); _mode.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    [header addSubview:_mode];
    _search=[UISearchBar new]; _search.placeholder=@"Search World of Warcraft add-ons"; _search.frame=CGRectMake(TKAddonPageMargin,116,body,44); _search.autoresizingMask=UIViewAutoresizingFlexibleWidth; _search.searchBarStyle=UISearchBarStyleMinimal; _search.delegate=self; [header addSubview:_search];

    // The list toolbar, where the site puts its count, sort, filters and column
    // picker. Auto Layout inside the header's frame keeps the buttons right.
    _countLabel=[UILabel new];
    _countLabel.font=[UIFont systemFontOfSize:12 weight:UIFontWeightRegular];
    _countLabel.textColor=[UIColor colorWithWhite:0.62 alpha:1];
    _countLabel.accessibilityIdentifier=@"wow.addons.count";
    [_countLabel setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    _sortButton=[self toolbarButton:@"wow.addons.sort" title:@"Sort"];
    _filterButton=[self toolbarButton:@"wow.addons.filters" title:@"Filters"];
    _columnsButton=[self toolbarButton:@"wow.addons.columns" title:@"Columns"];
    UIStackView *toolbar=[[UIStackView alloc] initWithArrangedSubviews:@[_countLabel,_sortButton,_filterButton,_columnsButton]];
    toolbar.axis=UILayoutConstraintAxisHorizontal; toolbar.spacing=10; toolbar.alignment=UIStackViewAlignmentCenter;
    toolbar.translatesAutoresizingMaskIntoConstraints=NO;
    [header addSubview:toolbar];
    [NSLayoutConstraint activateConstraints:@[
        [toolbar.leadingAnchor constraintEqualToAnchor:header.leadingAnchor constant:TKAddonPageMargin],
        [toolbar.trailingAnchor constraintEqualToAnchor:header.trailingAnchor constant:-TKAddonPageMargin],
        [toolbar.topAnchor constraintEqualToAnchor:header.topAnchor constant:168],
        [toolbar.heightAnchor constraintEqualToConstant:34],
        [_sortButton.widthAnchor constraintEqualToConstant:118],
        [_filterButton.widthAnchor constraintEqualToConstant:92],
        [_columnsButton.widthAnchor constraintEqualToConstant:104],
    ]];
    return header;
}
- (UIButton *)toolbarButton:(NSString *)identifier title:(NSString *)title {
    UIButton *button=[UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    button.tintColor=WKGold();
    button.contentHorizontalAlignment=UIControlContentHorizontalAlignmentRight;
    button.showsMenuAsPrimaryAction=YES;
    button.accessibilityIdentifier=identifier;
    return button;
}
- (void)updateToolbar {
    BOOL browse=_mode.selectedSegmentIndex==1;
    _countLabel.hidden=!browse; _sortButton.hidden=!browse; _filterButton.hidden=!browse; _columnsButton.hidden=!browse;
    if (!browse) return;
    if (_totalCount) {
        NSNumberFormatter *formatter=[NSNumberFormatter new];
        formatter.numberStyle=NSNumberFormatterDecimalStyle;
        _countLabel.text=[NSString stringWithFormat:@"%@ projects found",[formatter stringFromNumber:@(_totalCount)]];
    } else _countLabel.text=[self hasKey]?@"Searching…":@"Enter a CurseForge key";
    [_sortButton setTitle:[NSString stringWithFormat:@"Sort: %@",BrowseSortLabel(_sortField)] forState:UIControlStateNormal];
    [_filterButton setTitle:(_categoryID||_gameVersion.length)?[NSString stringWithFormat:@"Filters · %@",_categoryLabel?:_gameVersion]:@"Filters" forState:UIControlStateNormal];
    _sortButton.menu=[self sortMenu];
    _filterButton.menu=[self filterMenu];
    _columnsButton.menu=[self columnsMenu];
    _sortButton.enabled=[self hasKey]; _filterButton.enabled=[self hasKey]; _columnsButton.enabled=[self hasKey];
}
- (UIMenu *)sortMenu {
    __weak TKWoWAddonManagerViewController *weakSelf=self;
    NSMutableArray<UIMenuElement *> *fields=[NSMutableArray new];
    for (NSArray *option in BrowseSorts()) {
        NSInteger field=[option[0] integerValue];
        UIAction *action=[UIAction actionWithTitle:option[1] image:nil identifier:nil handler:^(UIAction *a) {
            (void)a; TKWoWAddonManagerViewController *self=weakSelf; if(!self)return;
            if (self.sortField==field) self.sortOrder=[self.sortOrder isEqual:@"asc"]?@"desc":@"asc";
            else { self.sortField=field; self.sortOrder=(field==4||field==5)?@"asc":@"desc"; }
            [self updateToolbar]; [self beginBrowse];
        }];
        action.state=field==_sortField?UIMenuElementStateOn:UIMenuElementStateOff;
        [fields addObject:action];
    }
    UIAction *ascending=[UIAction actionWithTitle:@"Ascending" image:nil identifier:nil handler:^(UIAction *a) {
        (void)a; TKWoWAddonManagerViewController *self=weakSelf; if(!self)return;
        self.sortOrder=@"asc"; [self updateToolbar]; [self beginBrowse];
    }];
    ascending.state=[_sortOrder isEqual:@"asc"]?UIMenuElementStateOn:UIMenuElementStateOff;
    UIAction *descending=[UIAction actionWithTitle:@"Descending" image:nil identifier:nil handler:^(UIAction *a) {
        (void)a; TKWoWAddonManagerViewController *self=weakSelf; if(!self)return;
        self.sortOrder=@"desc"; [self updateToolbar]; [self beginBrowse];
    }];
    descending.state=[_sortOrder isEqual:@"desc"]?UIMenuElementStateOn:UIMenuElementStateOff;
    return [UIMenu menuWithTitle:@"Sort projects" children:@[
        [UIMenu menuWithTitle:@"Field" children:fields],
        [UIMenu menuWithTitle:@"Direction" children:@[ascending,descending]],
    ]];
}
- (UIMenu *)filterMenu {
    __weak TKWoWAddonManagerViewController *weakSelf=self;
    UIAction *allVersions=[UIAction actionWithTitle:@"All game versions" image:nil identifier:nil handler:^(UIAction *a) {
        (void)a; TKWoWAddonManagerViewController *self=weakSelf; if(!self)return;
        self.gameVersion=nil; [self updateToolbar]; [self beginBrowse];
    }];
    allVersions.state=_gameVersion.length?UIMenuElementStateOff:UIMenuElementStateOn;
    UIAction *forever=[UIAction actionWithTitle:@"1.60.1 (Forever)" image:nil identifier:nil handler:^(UIAction *a) {
        (void)a; TKWoWAddonManagerViewController *self=weakSelf; if(!self)return;
        self.gameVersion=TKForeverGameVersion; [self updateToolbar]; [self beginBrowse];
    }];
    forever.state=[_gameVersion isEqual:TKForeverGameVersion]?UIMenuElementStateOn:UIMenuElementStateOff;
    UIAction *allCategories=[UIAction actionWithTitle:@"All categories" image:nil identifier:nil handler:^(UIAction *a) {
        (void)a; TKWoWAddonManagerViewController *self=weakSelf; if(!self)return;
        self.categoryID=nil; self.categoryLabel=nil; [self updateToolbar]; [self beginBrowse];
    }];
    allCategories.state=_categoryID?UIMenuElementStateOff:UIMenuElementStateOn;
    UIAction *choose=[UIAction actionWithTitle:_categoryLabel?[NSString stringWithFormat:@"Category: %@",_categoryLabel]:@"Choose category…" image:nil identifier:nil handler:^(UIAction *a) {
        (void)a; [weakSelf chooseCategoryFrom:nil];
    }];
    UIAction *clear=[UIAction actionWithTitle:@"Clear filters" image:nil identifier:nil handler:^(UIAction *a) {
        (void)a; TKWoWAddonManagerViewController *self=weakSelf; if(!self)return;
        self.gameVersion=TKForeverGameVersion; self.categoryID=nil; self.categoryLabel=nil;
        [self updateToolbar]; [self beginBrowse];
    }];
    return [UIMenu menuWithTitle:@"Filters" children:@[
        [UIMenu menuWithTitle:@"Game version" children:@[allVersions,forever]],
        [UIMenu menuWithTitle:@"Category" children:@[allCategories,choose]],
        clear,
    ]];
}
- (UIMenu *)columnsMenu {
    __weak TKWoWAddonManagerViewController *weakSelf=self;
    NSMutableArray<UIMenuElement *> *actions=[NSMutableArray new];
    for (NSNumber *number in TKAddonColumnOrder()) {
        TKAddonColumn column=(TKAddonColumn)number.unsignedIntegerValue;
        UIAction *action=[UIAction actionWithTitle:TKAddonColumnTitle(column) image:nil identifier:nil handler:^(UIAction *a) {
            (void)a; TKWoWAddonManagerViewController *self=weakSelf; if(!self)return;
            self.columns = (self.columns & column) ? (self.columns & ~column) : (self.columns | column);
            [NSUserDefaults.standardUserDefaults setObject:@(self.columns) forKey:TKAddonColumnsKey];
            [self updateToolbar]; [self.tableView reloadData];
        }];
        action.state=(_columns & column)?UIMenuElementStateOn:UIMenuElementStateOff;
        [actions addObject:action];
    }
    return [UIMenu menuWithTitle:@"Columns" children:actions];
}
- (void)done { WKDismissPage(self); }
- (void)changeMode:(UISegmentedControl *)sender {
    if (sender.selectedSegmentIndex==1) { if ([self hasKey]) [self beginBrowse]; else _browseStatus=@"Enter an approved CurseForge Core API key to search and install World of Warcraft add-ons."; }
    [self updateToolbar];
    [self.tableView reloadData];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; [self beginBrowse]; }
- (BOOL)hasKey { return [_credentials curseForgeKey:NULL].length>0; }
- (BOOL)canLoadMore { return _results.count>0 && _results.count<_totalCount; }
- (void)beginBrowse { [self fetchPageAtIndex:0 append:NO]; }
- (void)loadMore { if (_loadingMore) return; [self fetchPageAtIndex:_results.count append:YES]; }
- (void)fetchPageAtIndex:(NSUInteger)index append:(BOOL)append {
    NSString *key=[_credentials curseForgeKey:NULL];
    if (!key.length) { _browseStatus=@"Enter an approved CurseForge Core API key to search and install World of Warcraft add-ons."; _results=@[]; _totalCount=0; [self.tableView reloadData]; return; }
    if (append) _browseStatus=@"Loading more projects…";
    else { _results=@[]; _totalCount=0; _browseStatus=@"Loading CurseForge…"; }
    _loadingMore=YES; [self.tableView reloadData];
    TKCurseForgeClient *client=[[TKCurseForgeClient alloc] initWithAPIKey:key];
    [client browseModsWithQuery:_search.text?:@"" sortField:_sortField sortOrder:_sortOrder categoryID:_categoryID
                   gameVersion:_gameVersion classID:nil index:index completion:^(id value,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{
            self.loadingMore=NO;
            if (error) { self.browseStatus=error.localizedDescription; }
            else {
                NSArray *page=[value[@"data"] isKindOfClass:NSArray.class]?value[@"data"]:@[];
                self.results=append?[self.results arrayByAddingObjectsFromArray:page]:page;
                NSDictionary *pagination=[value[@"pagination"] isKindOfClass:NSDictionary.class]?value[@"pagination"]:@{};
                NSNumber *total=[pagination[@"totalCount"] isKindOfClass:NSNumber.class]?pagination[@"totalCount"]:nil;
                self.totalCount=total?total.unsignedIntegerValue:MAX(self.results.count,page.count);
                self.browseStatus=[NSString stringWithFormat:@"%lu of %lu projects · Forever compatibility is verified at install",(unsigned long)self.results.count,(unsigned long)MAX(self.totalCount,self.results.count)];
            }
            [self updateToolbar];
            [self.tableView reloadData];
        });
    }];
}
static NSArray *BrowseSorts(void) { return @[ @[@(1),@"Featured"], @[@(2),@"Popularity"], @[@(3),@"Last Updated"], @[@(4),@"Name"], @[@(5),@"Author"], @[@(6),@"Total Downloads"], @[@(11),@"Release Date"] ]; }
static NSString *BrowseSortLabel(NSInteger field) { for (NSArray *option in BrowseSorts()) if ([option[0] integerValue]==field) return option[1]; return @"Featured"; }
- (void)presentSheet:(UIAlertController *)sheet from:(NSIndexPath *)indexPath {
    sheet.popoverPresentationController.sourceView=self.view;
    sheet.popoverPresentationController.sourceRect=indexPath?[self.tableView rectForRowAtIndexPath:indexPath]:CGRectMake(CGRectGetMidX(self.view.bounds),CGRectGetMaxY(self.view.bounds),1,1);
    [self presentViewController:sheet animated:YES completion:nil];
}
- (void)presentSortMenuFrom:(NSIndexPath *)indexPath {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"Sort projects" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    for (NSArray *option in BrowseSorts()) {
        NSInteger field=[option[0] integerValue];
        [sheet addAction:[UIAlertAction actionWithTitle:field==_sortField?[@"✓ " stringByAppendingString:option[1]]:option[1] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;
            if (self.sortField==field) self.sortOrder=[self.sortOrder isEqual:@"asc"]?@"desc":@"asc";
            else { self.sortField=field; self.sortOrder=(field==4||field==5)?@"asc":@"desc"; }
            [self beginBrowse];
        }]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Direction: %@",[_sortOrder isEqual:@"asc"]?@"Ascending":@"Descending"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action; self.sortOrder=[self.sortOrder isEqual:@"asc"]?@"desc":@"asc"; [self beginBrowse];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet from:indexPath];
}
- (void)chooseCategoryFrom:(NSIndexPath *)indexPath {
    if (_categories.count) { [self presentCategoryMenuFrom:indexPath]; return; }
    NSString *key=[_credentials curseForgeKey:NULL]; if (!key.length) { [self setupKey]; return; }
    _browseStatus=@"Loading CurseForge categories…"; [self.tableView reloadData];
    TKCurseForgeClient *client=[[TKCurseForgeClient alloc] initWithAPIKey:key];
    [client categoriesForGameID:1 completion:^(id value,NSError *error){
        dispatch_async(dispatch_get_main_queue(),^{
            if (error) { self.browseStatus=error.localizedDescription; [self.tableView reloadData]; return; }
            NSArray *all=[value isKindOfClass:NSArray.class]?value:@[];
            NSNumber *addOnClass=nil;
            for (NSDictionary *entry in all) if ([entry isKindOfClass:NSDictionary.class] && [entry[@"isClass"] boolValue] && [entry[@"name"] isKindOfClass:NSString.class] && [entry[@"name"] rangeOfString:@"addon" options:NSCaseInsensitiveSearch].location!=NSNotFound && [entry[@"id"] isKindOfClass:NSNumber.class]) { addOnClass=entry[@"id"]; break; }
            NSMutableArray *matched=[NSMutableArray new],*top=[NSMutableArray new];
            for (NSDictionary *entry in all) {
                if (![entry isKindOfClass:NSDictionary.class] || [entry[@"isClass"] boolValue]) continue;
                if (![entry[@"id"] isKindOfClass:NSNumber.class] || ![entry[@"name"] isKindOfClass:NSString.class]) continue;
                if (addOnClass && ![entry[@"classId"] isEqual:addOnClass]) continue;
                NSDictionary *category=@{ @"id":entry[@"id"],@"name":entry[@"name"] };
                [matched addObject:category];
                NSNumber *parent=[entry[@"parentCategoryId"] isKindOfClass:NSNumber.class]?entry[@"parentCategoryId"]:@0;
                if (parent.integerValue==0) [top addObject:category];
            }
            NSArray *categories=top.count?top:(matched.count?matched:nil);
            if (!categories.count) { self.browseStatus=@"CurseForge returned no add-on categories."; [self.tableView reloadData]; return; }
            self.categories=[categories sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){return [a[@"name"] localizedCaseInsensitiveCompare:b[@"name"]];}];
            [self presentCategoryMenuFrom:indexPath];
        });
    }];
}
- (void)presentCategoryMenuFrom:(NSIndexPath *)indexPath {
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:@"Filter by category" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:_categoryID?@"All categories":@"✓ All categories" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action; self.categoryID=nil; self.categoryLabel=nil; [self beginBrowse];}]];
    for (NSDictionary *category in _categories) {
        [sheet addAction:[UIAlertAction actionWithTitle:[category[@"id"] isEqual:_categoryID]?[@"✓ " stringByAppendingString:category[@"name"]]:category[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action; self.categoryID=category[@"id"]; self.categoryLabel=category[@"name"]; [self updateToolbar]; [self beginBrowse];}]];
    }
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet from:indexPath];
}
- (void)presentProject:(NSDictionary *)entry {
    NSString *name=[entry[@"name"] isKindOfClass:NSString.class]?entry[@"name"]:@"Untitled add-on";
    NSMutableArray<NSString *> *details=[NSMutableArray new];
    if ([entry[@"summary"] isKindOfClass:NSString.class] && [entry[@"summary"] length]) [details addObject:entry[@"summary"]];
    NSMutableArray<NSString *> *authors=[NSMutableArray new];
    if ([entry[@"authors"] isKindOfClass:NSArray.class]) for (NSDictionary *author in entry[@"authors"]) if ([author isKindOfClass:NSDictionary.class] && [author[@"name"] isKindOfClass:NSString.class]) [authors addObject:author[@"name"]];
    if (authors.count) [details addObject:[@"By " stringByAppendingString:[authors componentsJoinedByString:@", "]]];
    if ([entry[@"downloadCount"] isKindOfClass:NSNumber.class]) [details addObject:[NSString stringWithFormat:@"%@ downloads on CurseForge",entry[@"downloadCount"]]];
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:name message:[details componentsJoinedByString:@"\n"] preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Install latest compatible file" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action;[self installMod:entry];}]];
    NSString *website=nil;
    if ([entry[@"links"] isKindOfClass:NSDictionary.class] && [entry[@"links"][@"websiteUrl"] isKindOfClass:NSString.class]) website=entry[@"links"][@"websiteUrl"];
    if (!website.length && [entry[@"slug"] isKindOfClass:NSString.class]) website=[@"https://www.curseforge.com/wow/addons/" stringByAppendingString:entry[@"slug"]];
    if (website.length) [sheet addAction:[UIAlertAction actionWithTitle:@"Open project page" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action; NSURL *url=[NSURL URLWithString:website]; if (url) [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet from:nil];
}
- (void)showError:(NSString *)title message:(NSString *)message {
    dispatch_async(dispatch_get_main_queue(),^{
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}
- (void)providerFailed:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(),^{
        self.browseStatus=error.localizedDescription;
        [self.tableView reloadData];
        [self showProviderError:error];
    });
}
- (void)installMod:(NSDictionary *)entry {
    NSNumber *modID=[entry[@"id"] isKindOfClass:NSNumber.class]?entry[@"id"]:nil;
    if (!modID) return;
    NSString *name=[entry[@"name"] isKindOfClass:NSString.class]?entry[@"name"]:@"This add-on";
    NSString *key=[_credentials curseForgeKey:NULL];
    if (!key.length) { [self setupKey]; return; }
    _browseStatus=[NSString stringWithFormat:@"Downloading %@…",name]; [self.tableView reloadData];
    TKCurseForgeClient *client=[[TKCurseForgeClient alloc] initWithAPIKey:key];
    [client latestFileForModID:modID gameVersion:TKForeverGameVersion completion:^(NSDictionary *file,NSError *error){
        if (error) { [self providerFailed:error]; return; }
        NSNumber *fileID=[file[@"id"] isKindOfClass:NSNumber.class]?file[@"id"]:nil;
        if (!fileID) { [self providerFailed:[NSError errorWithDomain:@"WolkaraForever.CurseForge" code:1 userInfo:@{NSLocalizedDescriptionKey:@"CurseForge returned an incomplete file record."}]]; return; }
        [client downloadURLForModID:modID fileID:fileID completion:^(NSString *url,NSError *downloadError){
            if (downloadError) { [self providerFailed:downloadError]; return; }
            NSError *requestError=nil;
            NSURLRequest *request=[client assetRequestForURL:url error:&requestError];
            if (!request) { [self providerFailed:requestError]; return; }
            NSURLSessionDownloadTask *task=[[NSURLSession sharedSession] downloadTaskWithRequest:request completionHandler:^(NSURL *location,NSURLResponse *response,NSError *failure){
                (void)response;
                if (failure||!location) { [self providerFailed:failure?:[NSError errorWithDomain:@"WolkaraForever.CurseForge" code:1 userInfo:@{NSLocalizedDescriptionKey:@"CurseForge did not return an archive."}]]; return; }
                NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".zip"]];
                NSError *moveError=nil; [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:path] error:&moveError];
                NSError *importError=nil;
                BOOL imported=!moveError && [self.store importZIPAtURL:[NSURL fileURLWithPath:path] error:&importError];
                [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
                dispatch_async(dispatch_get_main_queue(),^{
                    if (!imported) { NSError *cause=moveError?:importError; [self showError:@"Could not install add-on" message:cause.localizedDescription?:@"The downloaded archive could not be imported."]; return; }
                    self.browseStatus=[NSString stringWithFormat:@"Installed %@. Forever compatibility was verified from its TOC.",name];
                    [self reloadAddons];
                });
            }];
            [task resume];
        }];
    }];
}
- (void)reloadAddons {
    [NSFileManager.defaultManager createDirectoryAtPath:_addOnsDirectory withIntermediateDirectories:YES attributes:nil error:NULL];
    [_store reload]; _addons=TKWoWAddonsAtDirectory(_addOnsDirectory); [self.tableView reloadData];
    [_mode setTitle:[NSString stringWithFormat:@"Installed (%lu)",(unsigned long)_store.records.count] forSegmentAtIndex:0];
}
- (void)importAddon {
    UIDocumentPickerViewController *picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeZIP] asCopy:YES];
    picker.allowsMultipleSelection=NO; picker.delegate=self;
    [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    (void)controller;
    NSError *failure=nil; NSURL *url=urls.firstObject; BOOL accessed=[url startAccessingSecurityScopedResource];
    if (!url || ![_store importZIPAtURL:url error:&failure]) { }
    if (accessed) [url stopAccessingSecurityScopedResource];
    [self reloadAddons];
    if (failure) {
        // The document picker is still dismissing on this callback. Queue the
        // alert so an import failure is never hidden behind that transition.
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Could not import add-on" message:failure.localizedDescription preferredStyle:UIAlertControllerStyleAlert];
            [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:alert animated:YES completion:nil];
        });
    }
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; if (_mode.selectedSegmentIndex==1) return section==0?0:_results.count+([self canLoadMore]?1:0); return section==0?1:_store.records.count; }
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (_mode.selectedSegmentIndex==1 && section==1 && _results.count) {
        TKAddonColumnsHeaderView *header=[[TKAddonColumnsHeaderView alloc] initWithFrame:CGRectMake(0,0,tableView.bounds.size.width,22)];
        [header configureWithColumns:_columns compact:self.traitCollection.horizontalSizeClass==UIUserInterfaceSizeClassCompact];
        return header;
    }
    return nil;
}
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    (void)tableView;
    if (_mode.selectedSegmentIndex==1 && section==1 && _results.count) return 22;
    return UITableViewAutomaticDimension;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return _mode.selectedSegmentIndex==0 && section==1?@"Installed":nil; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (_mode.selectedSegmentIndex==1) return section==1?_browseStatus:nil;
    return section==1?@"Existing add-ons are preserved. WolkaraForever only removes package folders it installed and recorded.":nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"addon"];
    if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"addon"];
    cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    if (_mode.selectedSegmentIndex==1 && indexPath.section==0) {
        if (![self hasKey]) { cell.textLabel.text=@"Set up CurseForge access"; cell.detailTextLabel.text=@"Enter an approved Core API key to search and install from CurseForge."; }
        else if (indexPath.row==0) { cell.textLabel.text=[NSString stringWithFormat:@"Sort: %@",BrowseSortLabel(_sortField)]; cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · tap to change",[_sortOrder isEqual:@"asc"]?@"Ascending":@"Descending"]; }
        else { cell.textLabel.text=[NSString stringWithFormat:@"Category: %@",_categoryLabel?:@"All"]; cell.detailTextLabel.text=@"Tap to filter by category"; }
    } else if (_mode.selectedSegmentIndex==1) {
        if (indexPath.row==(NSInteger)_results.count) {
            cell.textLabel.text=@"Load more…";
            cell.detailTextLabel.text=[NSString stringWithFormat:@"%lu of %lu projects shown",(unsigned long)_results.count,(unsigned long)_totalCount];
        } else {
            TKAddonProjectCell *project=[tableView dequeueReusableCellWithIdentifier:@"project"];
            if (!project) project=[[TKAddonProjectCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"project"];
            NSDictionary *entry=_results[indexPath.row];
            NSDictionary *file=TKAddonLatestFile(entry,_gameVersion);
            NSNumber *modID=[entry[@"id"] isKindOfClass:NSNumber.class]?entry[@"id"]:nil;
            project.accessibilityIdentifier=modID?[NSString stringWithFormat:@"wow.addons.project.%@",modID]:@"wow.addons.project";
            NSString *rank=[entry[@"gamePopularityRank"] isKindOfClass:NSNumber.class]?
                [NSString stringWithFormat:@"%@",entry[@"gamePopularityRank"]]:nil;
            [project configureWithProject:entry file:file rank:rank columns:_columns gameVersion:_gameVersion
                                   compact:self.traitCollection.horizontalSizeClass==UIUserInterfaceSizeClassCompact];
            return project;
        }
    } else if (indexPath.section==0) {
        cell.textLabel.text=_addons.count?[NSString stringWithFormat:@"%lu add-on%@ installed",(unsigned long)_addons.count,_addons.count==1?@"":@"s"]:@"No add-ons installed";
        cell.detailTextLabel.text=nil; cell.selectionStyle=UITableViewCellSelectionStyleNone;
    }
    else {
    TKAddonRecord *addon=_store.records[indexPath.row]; cell.textLabel.text=addon.name;
    NSString *state=addon.disabled?@"Disabled":(addon.managed?@"Compatible · managed":@"Unverified · existing");
    cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@ · %@%@",addon.version,addon.source,state,addon.pinned?@" · pinned":@""];
    cell.selectionStyle=UITableViewCellSelectionStyleNone;
    }
    cell.backgroundColor=[UIColor colorWithRed:0.07 green:0.09 blue:0.13 alpha:1]; cell.textLabel.textColor=[UIColor colorWithRed:0.9 green:0.72 blue:0.35 alpha:1]; cell.detailTextLabel.textColor=[UIColor colorWithWhite:0.75 alpha:1]; cell.textLabel.numberOfLines=0; cell.detailTextLabel.numberOfLines=0;
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_mode.selectedSegmentIndex==1) {
        if (indexPath.section==0) return;
        if (indexPath.row==(NSInteger)_results.count) { [self loadMore]; return; }
        [self presentProject:_results[indexPath.row]]; return;
    }
    if (indexPath.section==0) return;
    TKAddonRecord *record=_store.records[indexPath.row]; if(!record.managed)return;
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:record.name message:record.disabled?@"This package is stored privately and is not visible to World of Warcraft.":@"Only this managed package can be changed. Existing folders are left alone." preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:record.disabled?@"Restore":@"Disable" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){(void)a;[self mutate:^BOOL(NSError **e){return [self.store setDisabled:!record.disabled record:record error:e];}];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:record.pinned?@"Unpin updates":@"Pin this version" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){(void)a;[self mutate:^BOOL(NSError **e){return [self.store setPinned:!record.pinned record:record error:e];}];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Remove managed package" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){(void)a;[self mutate:^BOOL(NSError **e){return [self.store removeRecord:record error:e];}];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [self presentSheet:sheet from:indexPath];
}
- (void)showProviderError:(NSError *)error { dispatch_async(dispatch_get_main_queue(),^{UIAlertController *a=[UIAlertController alertControllerWithTitle:@"CurseForge request failed" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil];}); }
- (void)mutate:(BOOL (^)(NSError **))operation { NSError *error=nil; if(!operation(&error)){UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Could not change add-on" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil];} [self reloadAddons]; }
- (void)setupKey { UIAlertController *a=[UIAlertController alertControllerWithTitle:@"CurseForge API key" message:@"Enter a current approved key. It stays only in this device’s Keychain and is sent only to CurseForge metadata APIs." preferredStyle:UIAlertControllerStyleAlert];[a addTextFieldWithConfigurationHandler:^(UITextField *f){f.secureTextEntry=YES;f.autocorrectionType=UITextAutocorrectionTypeNo;f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.placeholder=@"API key";}];[a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){(void)x;NSError *e=nil;if(![self.credentials storeCurseForgeKey:a.textFields.firstObject.text error:&e]){UIAlertController *failure=[UIAlertController alertControllerWithTitle:@"Could not save key" message:e.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[failure addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:failure animated:YES completion:nil];}else { [self.tableView reloadData]; if (self.mode.selectedSegmentIndex==1) [self beginBrowse]; }}]];[a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil]; }
@end
