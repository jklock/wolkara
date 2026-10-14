#import "AddonManager.h"
#import "AddonStore.h"
#import "AddonCredentialStore.h"
#import "CurseForgeClient.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

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

@interface TKWoWAddonManagerViewController () <UIDocumentPickerDelegate>
@property(nonatomic, copy) NSString *addOnsDirectory;
@property(nonatomic, copy) NSString *edition;
@property(nonatomic, copy) NSArray<TKWoWAddon *> *addons;
@property(nonatomic) UISegmentedControl *mode;
@property(nonatomic) TKAddonStore *store;
@property(nonatomic) TKAddonCredentialStore *credentials;
@property(nonatomic) UISearchBar *search;
@property(nonatomic) NSArray<NSDictionary *> *results;
@property(nonatomic) NSInteger sortField;
@property(nonatomic,copy) NSString *browseStatus;
@end

@implementation TKWoWAddonManagerViewController
- (instancetype)initWithAddOnsDirectory:(NSString *)directory edition:(NSString *)edition {
    if (!(self=[super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _addOnsDirectory=directory.copy; _edition=edition.copy; _addons=@[]; self.title=@"ADD-ON MANAGER";
    _store=[[TKAddonStore alloc] initWithAddOnsDirectory:directory product:@"wow_classic_beta" gameVersion:@"1.60.1"]; _results=@[]; _sortField=1;
    _credentials=[TKAddonCredentialStore new];
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    self.view.backgroundColor=[UIColor colorWithRed:0.015 green:0.025 blue:0.045 alpha:1];
    self.tableView.backgroundColor=UIColor.clearColor;
    self.tableView.separatorStyle=UITableViewCellSeparatorStyleNone;
    self.navigationItem.largeTitleDisplayMode=UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"Done" style:UIBarButtonItemStyleDone target:self action:@selector(done)];
    self.navigationItem.leftBarButtonItem.tintColor=[UIColor colorWithRed:0.9 green:0.72 blue:0.35 alpha:1];
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
    UIColor *gold=[UIColor colorWithRed:0.9 green:0.72 blue:0.35 alpha:1];
    CGFloat width=MAX(CGRectGetWidth(self.tableView.bounds),320);
    UIView *header=[[UIView alloc] initWithFrame:CGRectMake(0,0,width,178)];
    UILabel *edition=[UILabel new]; edition.text=[NSString stringWithFormat:@"Edition: %@  ▾",_edition];
    edition.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody]; edition.textColor=gold;
    edition.backgroundColor=[UIColor colorWithWhite:1 alpha:0.08]; edition.layer.cornerRadius=14; edition.layer.masksToBounds=YES;
    edition.frame=CGRectMake(0,14,width,42); edition.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    [header addSubview:edition];
    _mode=[[UISegmentedControl alloc] initWithItems:@[[NSString stringWithFormat:@"Installed (%lu)",(unsigned long)_addons.count],@"Search CurseForge"]];
    _mode.selectedSegmentIndex=0; _mode.selectedSegmentTintColor=gold;
    [_mode setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.blackColor} forState:UIControlStateSelected];
    [_mode setTitleTextAttributes:@{NSForegroundColorAttributeName:[UIColor colorWithWhite:0.72 alpha:1]} forState:UIControlStateNormal];
    [_mode addTarget:self action:@selector(changeMode:) forControlEvents:UIControlEventValueChanged];
    _mode.frame=CGRectMake(0,72,width,36); _mode.autoresizingMask=UIViewAutoresizingFlexibleWidth;
    [header addSubview:_mode];
    _search=[UISearchBar new]; _search.placeholder=@"Search World of Warcraft add-ons"; _search.frame=CGRectMake(0,116,width,44); _search.autoresizingMask=UIViewAutoresizingFlexibleWidth; _search.searchBarStyle=UISearchBarStyleMinimal; _search.delegate=(id)self; [header addSubview:_search];
    return header;
}
- (void)done { [self.navigationController popViewControllerAnimated:YES]; }
- (void)changeMode:(UISegmentedControl *)sender { if(sender.selectedSegmentIndex==1)[self browse]; [self.tableView reloadData]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [searchBar resignFirstResponder]; [self browse]; }
- (void)browse { NSString *key=[_credentials curseForgeKey:NULL]; if(!key.length){_browseStatus=@"Enter an approved CurseForge Core API key to browse.";_results=@[];[self.tableView reloadData];return;} _browseStatus=@"Loading CurseForge…";[self.tableView reloadData]; TKCurseForgeClient *client=[[TKCurseForgeClient alloc]initWithAPIKey:key];[client browseModsWithQuery:_search.text?:@"" sortField:_sortField sortOrder:@"desc" categoryID:nil index:0 completion:^(id value,NSError *error){dispatch_async(dispatch_get_main_queue(),^{self.results=[value[@"data"] isKindOfClass:NSArray.class]?value[@"data"]:@[]; NSDictionary *page=[value[@"pagination"] isKindOfClass:NSDictionary.class]?value[@"pagination"]:@{}; self.browseStatus=error.localizedDescription?:[NSString stringWithFormat:@"%@ projects found · %@",page[@"totalCount"]?:@0,@"Forever compatibility is verified at install"];[self.tableView reloadData];});}]; }
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
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return _mode.selectedSegmentIndex==0?2:1; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; return _mode.selectedSegmentIndex==0?(section==0?1:_store.records.count):_results.count+1; }
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section { (void)tableView; return _mode.selectedSegmentIndex==0 && section==1?@"Installed":nil; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView; return _mode.selectedSegmentIndex==0 && section==1?@"Existing add-ons are preserved. Wolkara only removes package folders it installed and recorded.":nil;
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"addon"];
    if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"addon"];
    if (_mode.selectedSegmentIndex==1 && indexPath.row==0) {
        BOOL hasKey=[_credentials curseForgeKey:NULL].length>0;
        cell.textLabel.text=hasKey?@"Browse CurseForge":@"Set up CurseForge access";
        cell.detailTextLabel.text=_browseStatus?:@"Sort: Featured · tap a result to install; compatibility is verified from the downloaded TOC.";
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
    } else if (_mode.selectedSegmentIndex==1) {
        NSDictionary *entry=_results[indexPath.row-1]; cell.textLabel.text=entry[@"name"]?:entry[@"displayName"]?:@"Untitled add-on";
        cell.detailTextLabel.text=[NSString stringWithFormat:@"%@ · %@ downloads · Install",entry[@"summary"]?:@"No description",entry[@"downloadCount"]?:@0];
        cell.selectionStyle=UITableViewCellSelectionStyleNone;
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
    if (_mode.selectedSegmentIndex==1 && indexPath.row==0) { [self setupKey]; return; }
    if (_mode.selectedSegmentIndex==1) { NSDictionary *entry=_results[indexPath.row-1]; [self installMod:entry]; return; }
    if (indexPath.section==0) return;
    TKAddonRecord *record=_store.records[indexPath.row]; if(!record.managed)return;
    UIAlertController *sheet=[UIAlertController alertControllerWithTitle:record.name message:record.disabled?@"This package is stored privately and is not visible to World of Warcraft.":@"Only this managed package can be changed. Existing folders are left alone." preferredStyle:UIAlertControllerStyleActionSheet];
    [sheet addAction:[UIAlertAction actionWithTitle:record.disabled?@"Restore":@"Disable" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){(void)a;[self mutate:^BOOL(NSError **e){return [self.store setDisabled:!record.disabled record:record error:e];}];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:record.pinned?@"Unpin updates":@"Pin this version" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){(void)a;[self mutate:^BOOL(NSError **e){return [self.store setPinned:!record.pinned record:record error:e];}];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Remove managed package" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a){(void)a;[self mutate:^BOOL(NSError **e){return [self.store removeRecord:record error:e];}];}]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    sheet.popoverPresentationController.sourceView=self.view; sheet.popoverPresentationController.sourceRect=[tableView rectForRowAtIndexPath:indexPath]; [self presentViewController:sheet animated:YES completion:nil];
}
- (void)installAuctionator {
    NSError *credentialError=nil; NSString *key=[_credentials curseForgeKey:&credentialError];
    if(!key.length){[self setupKey];return;}
    TKCurseForgeClient *client=[[TKCurseForgeClient alloc] initWithAPIKey:key];
    [client latestFileForModID:@6124 gameVersion:@"1.60.1" completion:^(NSDictionary *file,NSError *error){if(error){[self showProviderError:error];return;}[client downloadURLForModID:@6124 fileID:file[@"id"] completion:^(NSString *url,NSError *downloadError){if(downloadError){[self showProviderError:downloadError];return;} NSError *requestError=nil;NSURLRequest *request=[client assetRequestForURL:url error:&requestError];if(!request){[self showProviderError:requestError];return;} NSURLSessionDownloadTask *task=[[NSURLSession sharedSession] downloadTaskWithRequest:request completionHandler:^(NSURL *location,NSURLResponse *response,NSError *failure){(void)response;if(failure||!location){[self showProviderError:failure?:[NSError errorWithDomain:@"Wolkara.CurseForge" code:1 userInfo:@{NSLocalizedDescriptionKey:@"CurseForge did not return an archive."}]];return;}NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".zip"]];NSError *move=nil;[[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:path] error:&move];if(move||![self.store importZIPAtURL:[NSURL fileURLWithPath:path] error:&move]){[self showProviderError:move];return;}dispatch_async(dispatch_get_main_queue(),^{[self reloadAddons];});}];[task resume];}];}];
}
- (void)showProviderError:(NSError *)error { dispatch_async(dispatch_get_main_queue(),^{UIAlertController *a=[UIAlertController alertControllerWithTitle:@"CurseForge request failed" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil];}); }
- (void)mutate:(BOOL (^)(NSError **))operation { NSError *error=nil; if(!operation(&error)){UIAlertController *a=[UIAlertController alertControllerWithTitle:@"Could not change add-on" message:error.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:a animated:YES completion:nil];} [self reloadAddons]; }
- (void)setupKey { UIAlertController *a=[UIAlertController alertControllerWithTitle:@"CurseForge API key" message:@"Enter a current approved key. It stays only in this device’s Keychain and is sent only to CurseForge metadata APIs." preferredStyle:UIAlertControllerStyleAlert];[a addTextFieldWithConfigurationHandler:^(UITextField *f){f.secureTextEntry=YES;f.autocorrectionType=UITextAutocorrectionTypeNo;f.autocapitalizationType=UITextAutocapitalizationTypeNone;f.placeholder=@"API key";}];[a addAction:[UIAlertAction actionWithTitle:@"Save" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x){(void)x;NSError *e=nil;if(![self.credentials storeCurseForgeKey:a.textFields.firstObject.text error:&e]){UIAlertController *failure=[UIAlertController alertControllerWithTitle:@"Could not save key" message:e.localizedDescription preferredStyle:UIAlertControllerStyleAlert];[failure addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:failure animated:YES completion:nil];}else [self.tableView reloadData];}]];[a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:a animated:YES completion:nil]; }
@end
