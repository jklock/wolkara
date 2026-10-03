#import "WoWViewController.h"
#import "Client.h"

@implementation TKWoWViewController {
    TKAppLibrary *_library;
    TKWoWClient *_client;
    NSDictionary *_product, *_version, *_plan;
    NSString *_region, *_locale, *_status;
    NSUInteger _generation;
    BOOL _busy;
}
- (instancetype)initWithLibrary:(TKAppLibrary *)library {
    if (!(self=[super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
    _library=library; self.title=@"World of Warcraft";
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    _product=TKWoWProducts()[0];
    for (NSDictionary *p in TKWoWProducts()) if ([p[@"id"] isEqual:[defaults stringForKey:@"WoWProduct"]]) _product=p;
    _region=[defaults stringForKey:@"WoWRegion"]?:@"eu";
    if (![@[@"eu",@"us",@"kr",@"tw"] containsObject:_region]) _region=@"eu";
    _locale=[defaults stringForKey:@"WoWLocale"]?:@"enUS";
    if (![@[@"enUS",@"esES"] containsObject:_locale]) _locale=@"enUS";
    _status=@"Checking the selected channel…";
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(foreground:)
        name:UIApplicationDidBecomeActiveNotification object:nil];
}
- (void)viewDidAppear:(BOOL)animated { [super viewDidAppear:animated]; if (!_busy) [self check]; }
- (void)viewDidDisappear:(BOOL)animated { [super viewDidDisappear:animated]; [self cancel]; }
- (void)foreground:(NSNotification *)note { (void)note; if (self.view.window && !_busy) [self check]; }
- (void)cancel { [_client cancel]; _client=nil; _busy=NO; _generation++; [self.tableView reloadData]; }
- (TKWoWClient *)begin:(NSString *)message {
    [_client cancel]; _client=[TKWoWClient new]; _generation++; _busy=YES; _status=message;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel target:self action:@selector(cancelOperation)];
    [self.tableView reloadData]; return _client;
}
- (void)cancelOperation { [self cancel]; _status=@"Cancelled. Your installed game has not changed."; [self finish]; }
- (void)finish { _busy=NO; self.navigationItem.rightBarButtonItem=nil; [self.tableView reloadData]; }
- (void)check {
    _plan=nil; _version=nil;
    TKWoWClient *client=[self begin:@"Checking for updates…"];
    NSUInteger generation=_generation; NSDictionary *product=_product; NSString *region=_region;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSError *error=nil; NSDictionary *version=[client versionForProduct:product[@"id"] region:region error:&error];
        dispatch_async(dispatch_get_main_queue(),^{
            if (generation!=self->_generation) return;
            self->_version=version;
            self->_status=version ? [NSString stringWithFormat:@"Latest version: %@\nCheck the download to inspect the macOS files.",version[@"VersionsName"]] : error.localizedDescription;
            [self finish];
        });
    });
}
- (void)inspect:(BOOL)launch {
    TKWoWClient *client=[self begin:launch?@"Checking the latest build and your imported executable…":@"Downloading and verifying the installation manifest…"];
    NSUInteger generation=_generation; NSDictionary *product=_product; NSString *region=_region, *locale=_locale;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        NSError *error=nil; NSDictionary *plan=[client planForProduct:product[@"id"] region:region locale:locale error:&error];
        TKApp *app=nil;
        if (plan && launch) app=[self importedAppForPlan:plan product:product error:&error];
        dispatch_async(dispatch_get_main_queue(),^{
            if (generation!=self->_generation) return;
            self->_plan=plan;
            if (plan) self->_version=plan[@"version"];
            self->_status=error ? error.localizedDescription : [NSString stringWithFormat:
                @"%@\n%lu macOS installation files (%@). This excludes the large game data download.\n\nThe full installer is still under development.",
                plan[@"version"][@"VersionsName"],(unsigned long)[plan[@"files"] count],
                [NSByteCountFormatter stringFromByteCount:[plan[@"installFileBytes"] longLongValue] countStyle:NSByteCountFormatterCountStyleFile]];
            [self finish];
            if (app && self.startApp) self.startApp(app);
        });
    });
}
- (TKApp *)importedAppForPlan:(NSDictionary *)plan product:(NSDictionary *)product error:(NSError **)error {
    for (TKApp *app in _library.apps) {
        if (app.source!=TKAppSourceDocuments || ![app.workingDirectory.lastPathComponent isEqual:product[@"folder"]]) continue;
        NSString *directory=[_library workingDirectoryForApp:app error:error];
        NSString *path=[_library executablePathForApp:app error:error];
        if (!directory || !path) return nil;
        NSString *info=[directory.stringByDeletingLastPathComponent stringByAppendingPathComponent:@".build.info"];
        NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:info error:nil];
        if (!attributes || [attributes[NSFileSize] unsignedLongLongValue]>2*1024*1024) break;
        NSData *data=[NSData dataWithContentsOfFile:info];
        NSArray *rows=data?TKWoWTable(data,error):nil;
        if (!rows || !TKWoWBuildCurrent(rows,product[@"id"],plan[@"version"])) {
            *error=TKWoWError(@"The imported copy does not match the latest build. Update it before playing. Automatic installation is not available in this prototype."); return nil;
        }
        NSString *prefix=[directory stringByAppendingString:@"/"];
        if (![path hasPrefix:prefix]) break;
        NSString *relative=[path substringFromIndex:prefix.length];
        for (NSDictionary *file in plan[@"files"]) if ([file[@"path"] isEqual:relative]) {
            attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:error];
            uint64_t size=[attributes[NSFileSize] unsignedLongLongValue];
            if (!attributes || size>256*1024*1024 || size!=[file[@"size"] unsignedLongLongValue]) break;
            NSData *original=[NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:error];
            if (original && [TKWoWMD5(original) isEqual:file[@"contentKey"]]) return app;
            *error=TKWoWError(@"The imported executable does not match this build. Recopy the original file before playing."); return nil;
        }
        break;
    }
    *error=TKWoWError(@"No matching imported installation with build metadata was found. This prototype cannot install a complete game yet.");
    return nil;
}
- (NSDictionary *)executableFile {
    for (NSDictionary *file in _plan[@"files"]) {
        NSString *path=file[@"path"];
        if ([path hasPrefix:@"World of Warcraft"] && [path hasSuffix:@".app/Contents/MacOS/World of Warcraft"]) return file;
    }
    return nil;
}
- (void)downloadExecutable {
    NSDictionary *file=[self executableFile], *plan=_plan;
    if (!file) return;
    TKWoWClient *client=[self begin:@"Downloading the original client file and its verification metadata. This can take several minutes. Keep Tolkara open.\n\nThe installed game will not change."];
    NSUInteger generation=_generation;
    NSString *base=NSSearchPathForDirectoriesInDomains(NSCachesDirectory,NSUserDomainMask,YES).firstObject;
    NSString *directory=[base stringByAppendingPathComponent:@"WoWStaging"];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{
        NSError *error=nil; NSString *path=[client stageFile:file plan:plan directory:directory error:&error];
        dispatch_async(dispatch_get_main_queue(),^{
            if (generation!=self->_generation) return;
            self->_status=path?@"Original client file downloaded and verified in temporary storage. It has not been installed. The remaining game-data installer is not implemented yet.":error.localizedDescription;
            [self finish];
        });
    });
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 3; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    (void)tableView; return section==0 ? (NSInteger)TKWoWProducts().count : section==1 ? 2 : 5;
}
- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    (void)tableView; return @[@"Edition",@"Download preferences",@"Experimental launcher"][section];
}
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    if (section==0) return @"Availability and execution support vary by edition. Retail has not been tested. Forever currently uses the Classic Beta channel.";
    if (section==1) return @"This selects download metadata. It does not change the game's login settings.";
    return @"Play checks the latest build and original executable again. A failed check blocks launch here. Existing Tolkara library entries remain available. Developer service still prepares execution memory on each launch; Local signing is unchanged.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell=[tableView dequeueReusableCellWithIdentifier:@"wow"];
    if (!cell) cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"wow"];
    cell.textLabel.numberOfLines=0; cell.detailTextLabel.text=nil; cell.accessoryType=UITableViewCellAccessoryNone;
    cell.textLabel.textColor=UIColor.labelColor; cell.selectionStyle=UITableViewCellSelectionStyleDefault;
    if (indexPath.section==0) {
        NSDictionary *p=TKWoWProducts()[(NSUInteger)indexPath.row]; cell.textLabel.text=p[@"name"];
        if ([p isEqual:_product]) cell.accessoryType=UITableViewCellAccessoryCheckmark;
    } else if (indexPath.section==1) {
        cell.textLabel.text=indexPath.row==0 ? [@"Region: " stringByAppendingString:_region.uppercaseString] : [@"Language: " stringByAppendingString:_locale];
        cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    } else {
        cell.textLabel.text=@[_status?:@"",@"Check for updates",@"Inspect download",@"Download original client to temporary storage",@"Play imported copy"][(NSUInteger)indexPath.row];
        BOOL enabled=!_busy && indexPath.row>0 && (indexPath.row!=3 || [self executableFile]);
        cell.textLabel.textColor=enabled?UIColor.systemBlueColor:UIColor.secondaryLabelColor;
        cell.selectionStyle=enabled?UITableViewCellSelectionStyleDefault:UITableViewCellSelectionStyleNone;
    }
    return cell;
}
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section==0) {
        _product=TKWoWProducts()[(NSUInteger)indexPath.row];
        [NSUserDefaults.standardUserDefaults setObject:_product[@"id"] forKey:@"WoWProduct"]; [self check];
    } else if (indexPath.section==1) {
        UIAlertController *chooser=[UIAlertController alertControllerWithTitle:indexPath.row==0?@"Region":@"Language" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
        for (NSString *value in (indexPath.row==0?@[@"eu",@"us",@"kr",@"tw"]:@[@"enUS",@"esES"])) {
            [chooser addAction:[UIAlertAction actionWithTitle:value style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
                (void)action;
                if (indexPath.row==0) self->_region=value; else self->_locale=value;
                [NSUserDefaults.standardUserDefaults setObject:value forKey:indexPath.row==0?@"WoWRegion":@"WoWLocale"]; [self check];
            }]];
        }
        [chooser addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        chooser.popoverPresentationController.sourceView=[tableView cellForRowAtIndexPath:indexPath];
        [self presentViewController:chooser animated:YES completion:nil];
    } else if (!_busy) {
        if (indexPath.row==1) [self check];
        else if (indexPath.row==2) [self inspect:NO];
        else if (indexPath.row==3) [self downloadExecutable];
        else if (indexPath.row==4) [self inspect:YES];
    }
}
@end
