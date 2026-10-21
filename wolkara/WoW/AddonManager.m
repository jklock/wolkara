#import "AddonManager.h"
#import "AddonStore.h"
#import "AddonCredentialStore.h"
#import "CurseForgeClient.h"
#import "../App/WolkaraTheme.h"
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
@property(nonatomic) NSArray<NSDictionary *> *categories;
@property(nonatomic,copy) NSString *browseStatus;
@end

@implementation TKWoWAddonManagerViewController
- (instancetype)initWithAddOnsDirectory:(NSString *)directory edition:(NSString *)edition {
    if (!(self=[super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _addOnsDirectory=directory.copy; _edition=edition.copy; _addons=@[]; self.title=@"ADD-ON MANAGER";
    _store=[[TKAddonStore alloc] initWithAddOnsDirectory:directory product:@"wow_classic_beta" gameVersion:TKForeverGameVersion]; _results=@[]; _sortField=1; _sortOrder=@"desc";
    _credentials=[TKAddonCredentialStore new];
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    // The launcher's own colours, from WolkaraTheme, so this screen and the voice
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
}
- (UIView *)header {
    UIColor *gold=WKGold();
    CGFloat width=MAX(CGRectGetWidth(self.tableView.bounds),320);
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,width,178)];
    UILabel *edition=[UILabel new]; edition.text=[NSString stringWithFormat:@"Edition: %@  ▾",_edition];
    edition.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody]; edition.textColor=gold;
    edition.backgroundColor=WKPanel(); edition.layer.cornerRadius=14; edition.layer.masksToBounds=YES;
    edition.frame=CGRectMake(0,14,width,42); edition.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    [header addSubview:edition];
    _mode=[[UISegmentedControl alloc] initWithItems:@[[NSString stringWithFormat:@"Installed (%lu)",(unsigned long)_addons.count],@"Browse CurseForge"]];
    _mode.selectedSegmentIndex=0; _mode.selectedSegmentTintColor=gold;
    [_mode setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.blackColor} forState:UIControlStateSelected];
    [_mode setTitleTextAttributes:@{NSForegroundColorAttributeName:[UIColor colorWithWhite:0.72 alpha:1]} forState:UIControlStateNormal];
    [_mode addTarget:self action:@selector(changeMode:) forControlEvents:UIControlEventValueChanged];
    _mode.frame=CGRectMake(0,72,width,36); _mode.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    [header addSubview:_mode];
    _search=[UISearchBar new]; _search.placeholder=@"Search World of Warcraft add-ons"; _search.frame=CGRectMake(0,116,width,44); _search.autoresizingMask=UIViewAutoresizingFlexibleWidth; _search.searchBarStyle=UISearchBarStyleMinimal; _search.delegate=self; [header addSubview:_search];
    return header;
}
- (void)done { WKDismissPage(self); }
- (void)changeMode:(UISegmentedControl *)sender {
    if (sender.selectedSegmentIndex==1) { if ([self hasKey]) [self beginBrowse]; else _browseStatus=@"Enter an approved CurseForge Core API key to search and install World of Warcraft add-ons."; }
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
    [client browseModsWithQuery:_search.text?:@"" sortField:_sortField sortOrder:_sortOrder categoryID:_categoryID index:index completion:^(id value,NSError *error){
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
        [sheet addAction:[UIAlertAction actionWithTitle:[category[@"id"] isEqual:_categoryID]?[@"✓ " stringByAppendingString:category[@"name"]]:category[@"name"] style:UIAlertActionStyleDefault handler:^(UIAlertAction *action){(void)action; self.categoryID=category[@"id"]; self.categoryLabel=category[@"name"]; [self beginBrowse];}]];
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
        if (!fileID) { [self providerFailed:[NSError errorWithDomain:@"Wolkara.CurseForge" code:1 userInfo:@{NSLocalizedDescriptionKey:@"CurseForge returned an incomplete file record."}]]; return; }
        [client downloadURLForModID:modID fileID:fileID completion:^(NSString *url,NSError *downloadError){
            if (downloadError) { [self providerFailed:downloadError]; return; }
            NSError *requestError=nil;
            NSURLRequest *request=[client assetRequestForURL:url error:&requestError];
            if (!request) { [self providerFailed:requestError]; return; }
            NSURLSessionDownloadTask *task=[[NSURLSession sharedSession] downloadTaskWithRequest:request completionHandler:^(NSURL *location,NSURLResponse *response,NSError *failure){
                (void)response;
                if (failure||!location) { [self providerFailed:failure?:[NSError errorWithDomain:@"Wolkara.CurseForge" code:1 userInfo:@{NSLocalizedDescriptionKey:@"CurseForge did not return an archive."}]]; return; }
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
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; if (_mode.selectedSegmentIndex==1) return section==0?([self hasKey]?2:1):_results.count+([self canLoadMore]?1:0); return section==0?1:_store.records.count; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return _mode.selectedSegmentIndex==0 && section==1?@"Installed":nil; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (_mode.selectedSegmentIndex==1) return section==1?_browseStatus:nil;
    return section==1?@"Existing add-ons are preserved. Wolkara only removes package folders it installed and recorded.":nil;
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
            NSDictionary *entry=_results[indexPath.row]; cell.textLabel.text=entry[@"name"]?:entry[@"displayName"]?:@"Untitled add-on";
            cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@ downloads · tap for details",entry[@"summary"]?:@"No description",entry[@"downloadCount"]?:@0];
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
        if (indexPath.section==0) { if (![self hasKey]) { [self setupKey]; return; } if (indexPath.row==0) { [self presentSortMenuFrom:indexPath]; return; } [self chooseCategoryFrom:indexPath]; return; }
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
