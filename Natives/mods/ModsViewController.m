#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "ModBrowseViewController.h"
#import "ModDetailViewController.h"
#import "ModJarMetadata.h"
#import "ModVersionSelector.h"
#import "ModsViewController.h"
#import "PLProfiles.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

NS_ASSUME_NONNULL_BEGIN

static const CGFloat kDisabledRowAlpha = 0.45;
static NSString *const kModCellID = @"ModCell";

static NSString *GameRoot(void) {
    const char *gameDir = getenv("GAME_DIR");
    return gameDir ? @(gameDir) : @"";
}

/* `value` when it is a non-empty string. */
static NSString * _Nullable StringOrNil(id _Nullable value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

#pragma mark - Rows

/* One jar as shown in the list. Built on the work queue, read-only once published to the main queue
   (except `jar`, which only the work queue touches). */
@interface ModsRow : NSObject
@property(nonatomic) ModJar *jar;
@property(nonatomic, copy) NSString *fileName;
@property(nonatomic) BOOL enabled;
@property(nonatomic, copy, nullable) NSDictionary *entry; // the record entry, nil when not identified
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy, nullable) NSString *subtitle;
@property(nonatomic, nullable) NSURL *iconURL;
@end

@implementation ModsRow
@end

#pragma mark - Background work (work queue only)

static NSDictionary * _Nullable VersionForHash(NSDictionary *versions, NSString *sha1) {
    id version = versions[sha1];
    if (!version) {
        for (NSString *key in versions) {
            if ([key isKindOfClass:NSString.class] && [key caseInsensitiveCompare:sha1] == NSOrderedSame) {
                version = versions[key];
                break;
            }
        }
    }
    return [version isKindOfClass:NSDictionary.class] ? version : nil;
}

/* The file of `version` whose sha1 is `sha1`, or nil. */
static NSDictionary * _Nullable FileWithSha1(NSDictionary *version, NSString *sha1) {
    id files = version[@"files"];
    if (![files isKindOfClass:NSArray.class]) return nil;
    for (id file in (NSArray *)files) {
        if (![file isKindOfClass:NSDictionary.class]) continue;
        id hashes = file[@"hashes"];
        if (![hashes isKindOfClass:NSDictionary.class]) continue;
        NSString *fileSha1 = StringOrNil(hashes[@"sha1"]);
        if (fileSha1 && [fileSha1 caseInsensitiveCompare:sha1] == NSOrderedSame) return file;
    }
    return nil;
}

/* Per-file cache of the sha1 and jar metadata, dropped when the file's size or date changes. Renaming to
   and from ".disabled" keeps both, so switching a mod does not re-read it. */
static NSMutableDictionary *CacheEntryForJar(ModJar *jar, NSMutableDictionary *cache) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:jar.path error:nil];
    NSString *stamp = [NSString stringWithFormat:@"%f-%llu",
        attributes.fileModificationDate.timeIntervalSince1970, attributes.fileSize];
    NSMutableDictionary *entry = cache[jar.fileName];
    if (![entry[@"stamp"] isEqualToString:stamp]) {
        entry = [NSMutableDictionary dictionaryWithObject:stamp forKey:@"stamp"];
        cache[jar.fileName] = entry;
    }
    return entry;
}

static NSString * _Nullable CachedSha1(ModJar *jar, NSMutableDictionary *cache) {
    NSMutableDictionary *entry = CacheEntryForJar(jar, cache);
    if (!entry[@"sha1"]) {
        NSString *sha1 = [ModFolder sha1OfFileAtPath:jar.path];
        if (!sha1) return nil;
        entry[@"sha1"] = sha1;
    }
    return entry[@"sha1"];
}

static NSDictionary * _Nullable CachedMetadata(ModJar *jar, NSMutableDictionary *cache) {
    NSMutableDictionary *entry = CacheEntryForJar(jar, cache);
    if (!entry[@"metadata"]) {
        entry[@"metadata"] = [ModJarMetadata metadataForJarAtPath:jar.path] ?: NSNull.null;
    }
    id metadata = entry[@"metadata"];
    return [metadata isKindOfClass:NSDictionary.class] ? metadata : nil;
}

/* Looks up jars that are not in the record on Modrinth (one hash request, one projects request).
   Matches are added to the record, misses go to unknownHashes. Returns YES if the record changed.
   Any failed request (offline) leaves the record alone so the jars are tried again next time. */
static BOOL IdentifyJars(NSArray<ModJar *> *jars, ModIndex *modIndex, ModrinthModsAPI *api, NSMutableDictionary *cache) {
    // Several jars can share a hash (copies of one file): each of them gets the result.
    NSMutableDictionary<NSString *, NSMutableArray<ModJar *> *> *jarsByHash = [NSMutableDictionary new];
    for (ModJar *jar in jars) {
        if (modIndex.entries[jar.fileName]) continue;
        NSString *sha1 = CachedSha1(jar, cache);
        if (!sha1 || [modIndex.unknownHashes containsObject:sha1]) continue;
        NSMutableArray<ModJar *> *sameHash = jarsByHash[sha1];
        if (!sameHash) {
            sameHash = [NSMutableArray new];
            jarsByHash[sha1] = sameHash;
        }
        [sameHash addObject:jar];
    }
    if (jarsByHash.count == 0) return NO;

    NSDictionary<NSString *, NSDictionary *> *versions = [api versionsForHashes:jarsByHash.allKeys];
    if (!versions) return NO;

    NSMutableArray<NSString *> *projectIds = [NSMutableArray new];
    for (NSString *sha1 in jarsByHash) {
        NSString *projectId = StringOrNil(VersionForHash(versions, sha1)[@"project_id"]);
        if (projectId) [projectIds addObject:projectId];
    }
    NSDictionary<NSString *, NSDictionary *> *projects = [api projectsWithIds:projectIds];
    if (!projects) return NO;

    for (NSString *sha1 in jarsByHash) {
        NSDictionary *version = VersionForHash(versions, sha1);
        if (!version) {
            [modIndex.unknownHashes addObject:sha1];
            continue;
        }
        NSDictionary *file = FileWithSha1(version, sha1) ?: [ModVersionSelector primaryFileOfVersion:version];
        NSString *projectId = StringOrNil(version[@"project_id"]);
        NSDictionary *project = projectId ? projects[projectId] : nil;
        for (ModJar *jar in jarsByHash[sha1]) {
            modIndex.entries[jar.fileName] = [ModIndex entryForVersion:version file:file ?: @{} project:project];
        }
    }
    return YES;
}

/* Scans the folder, prunes and fills in the record, and builds the rows sorted by title. */
static NSArray<ModsRow *> *LoadRows(ModFolder *folder, ModIndex *modIndex, ModrinthModsAPI *api, NSMutableDictionary *cache) {
    NSArray<ModJar *> *jars = [folder scanJars];

    NSMutableSet<NSString *> *fileNames = [NSMutableSet new];
    for (ModJar *jar in jars) {
        [fileNames addObject:jar.fileName];
    }
    NSUInteger countBeforePrune = modIndex.entries.count;
    [modIndex pruneEntriesNotIn:fileNames];
    BOOL changed = modIndex.entries.count != countBeforePrune;
    if (IdentifyJars(jars, modIndex, api, cache)) {
        changed = YES;
    }
    if (changed) {
        [modIndex save:nil];
    }

    // Forget files that are gone.
    NSMutableSet *staleKeys = [NSMutableSet setWithArray:cache.allKeys];
    [staleKeys minusSet:fileNames];
    [cache removeObjectsForKeys:staleKeys.allObjects];

    NSString *manualLabel = localize(@"mods.row.manual", nil);
    NSMutableArray<ModsRow *> *rows = [NSMutableArray new];
    for (ModJar *jar in jars) {
        NSDictionary *entry = [modIndex.entries[jar.fileName] copy];
        NSString *title = StringOrNil(entry[@"title"]);
        NSString *version = StringOrNil(entry[@"versionNumber"]);
        if (!title || !version) {
            NSDictionary *metadata = CachedMetadata(jar, cache);
            title = title ?: StringOrNil(metadata[@"name"]);
            version = version ?: StringOrNil(metadata[@"version"]);
        }

        ModsRow *row = [ModsRow new];
        row.jar = jar;
        row.fileName = jar.fileName;
        row.enabled = jar.enabled;
        row.entry = entry;
        row.title = title ?: jar.fileName;
        if (entry) {
            row.subtitle = version;
            NSString *iconUrl = StringOrNil(entry[@"iconUrl"]);
            row.iconURL = iconUrl ? [NSURL URLWithString:iconUrl] : nil;
        } else {
            row.subtitle = version ? [NSString stringWithFormat:@"%@ · %@", version, manualLabel] : manualLabel;
        }
        [rows addObject:row];
    }
    [rows sortUsingComparator:^NSComparisonResult(ModsRow *a, ModsRow *b) {
        NSComparisonResult result = [a.title localizedStandardCompare:b.title];
        return result != NSOrderedSame ? result : [a.fileName localizedStandardCompare:b.fileName];
    }];
    return rows;
}

#pragma mark - ModsViewController

@interface ModsViewController () <UIDocumentPickerDelegate, UISearchResultsUpdating>
@property(nonatomic, readwrite) BOOL busy;
@property(nonatomic, readonly) BOOL isWorking; // operationRunning || reloading
@property(nonatomic) BOOL operationRunning;
@property(nonatomic) BOOL reloading;
@property(nonatomic) BOOL reloadPending;
@property(nonatomic) BOOL loadedOnce;
@property(nonatomic) BOOL showFolderNotice;
@property(nonatomic) dispatch_queue_t workQueue;
@property(nonatomic) NSMutableDictionary *jarCache; // work queue only

@property(nonatomic) NSArray<ModsRow *> *rows;
@property(nonatomic) NSArray<ModsRow *> *visibleRows;
@property(nonatomic) NSDictionary<NSString *, ModsRow *> *rowsByFileName;

@property(nonatomic, nullable) UISearchController *searchController;
@property(nonatomic, nullable) UIBarButtonItem *addItem;
@property(nonatomic, nullable) UIBarButtonItem *importItem;
@property(nonatomic, nullable) UIActivityIndicatorView *spinner;
@end

@implementation ModsViewController

- (instancetype)initWithProfileName:(NSString *)profileName {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    _profileName = [profileName copy];
    _api = [ModrinthModsAPI new];
    _workQueue = dispatch_queue_create("net.kdt.pojavlaunch.mods", DISPATCH_QUEUE_SERIAL);
    _jarCache = [NSMutableDictionary new];
    _rows = @[];
    _visibleRows = @[];
    _rowsByFileName = @{};

    NSString *versionId = PLProfiles.current.profiles[profileName][@"lastVersionId"];
    NSString *versionsDir = [GameRoot() stringByAppendingPathComponent:@"versions"];
    _info = [ModProfileInfo infoForVersionId:versionId ?: @"" versionsDir:versionsDir];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"mods.title", nil);
    self.definesPresentationContext = YES;

    NSString *unavailableMessage = [self prepareFolder];
    if (unavailableMessage) {
        [self showMessage:unavailableMessage];
        return;
    }

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.navigationItem.searchController = self.searchController;

    self.importItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"folder.badge.plus"]
        style:UIBarButtonItemStylePlain target:self action:@selector(actionImport)];
    self.importItem.accessibilityLabel = localize(@"mods.action.import", nil);
    self.addItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAdd
        target:self action:@selector(actionAdd)];
    self.addItem.accessibilityLabel = localize(@"mods.action.add", nil);
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.navigationItem.rightBarButtonItems = @[
        self.addItem,
        self.importItem,
        [[UIBarButtonItem alloc] initWithCustomView:self.spinner]
    ];
    [self updateBusyState];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // Also picks up files changed in the Files app while another screen was shown.
    [self reloadFromDisk];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.showFolderNotice) {
        self.showFolderNotice = NO;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"mods.title", nil)
            message:localize(@"mods.alert.own_folder", nil) preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

/* Sets up `folder` and `index`, first giving a modded profile on the shared game folder its own folder.
   Returns the message to show instead of the list when the profile cannot have mods. */
- (nullable NSString *)prepareFolder {
    if (!self.info.isModded) {
        return localize(@"mods.empty.vanilla", nil);
    }
    if (self.info.minecraftVersion.length == 0) {
        return localize(@"mods.empty.unknown_version", nil);
    }

    NSMutableDictionary *profile = PLProfiles.current.profiles[self.profileName];
    if (!profile) {
        return localize(@"mods.empty.vanilla", nil);
    }
    NSString *baseDir = GameRoot();
    NSString *gameDir = profile[@"gameDir"];
    if ([ModFolder isSharedGameDir:gameDir baseDir:baseDir]) {
        NSError *error;
        NSString *newGameDir = [ModFolder migrateProfileNamed:self.profileName baseDir:baseDir error:&error];
        if (!newGameDir) {
            return [NSString stringWithFormat:localize(@"mods.error.own_folder", nil), error.localizedDescription];
        }
        profile[@"gameDir"] = newGameDir;
        if (![profile[@"modsFolderNotice"] isEqual:@"1"]) {
            profile[@"modsFolderNotice"] = @"1";
            self.showFolderNotice = YES;
        }
        [PLProfiles.current save];
        gameDir = newGameDir;
        if (self.gameDirChanged) {
            self.gameDirChanged(newGameDir);
        }
    }

    NSString *modsDir = [[ModFolder gameDirPathForGameDir:gameDir baseDir:baseDir] stringByAppendingPathComponent:@"mods"];
    _folder = [[ModFolder alloc] initWithModsDir:modsDir];
    _index = [[ModIndex alloc] initWithModsDir:modsDir];
    return nil;
}

- (void)showMessage:(nullable NSString *)message {
    if (!message) {
        self.tableView.backgroundView = nil;
        return;
    }
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = message;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.secondaryLabelColor;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;

    UIView *container = [UIView new];
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.trailingAnchor constant:-16]
    ]];
    self.tableView.backgroundView = container;
}

#pragma mark Busy state and operations

- (void)updateBusyState {
    BOOL busy = self.isWorking;
    if (self.busy != busy) {
        self.busy = busy;
    }
    self.addItem.enabled = !busy;
    self.importItem.enabled = !busy;
    if (busy) {
        [self.spinner startAnimating];
        // Close any open swipe actions.
        [self.tableView setEditing:NO animated:YES];
    } else {
        [self.spinner stopAnimating];
    }
    for (UITableViewCell *cell in self.tableView.visibleCells) {
        if ([cell.accessoryView isKindOfClass:UISwitch.class]) {
            ((UISwitch *)cell.accessoryView).enabled = !busy;
        }
    }
}

/* The state machine runs on the raw flags; `busy` is only their published copy (recomputed by
   updateBusyState at every transition). */
- (BOOL)isWorking {
    return self.operationRunning || self.reloading;
}

- (void)runOperation:(void (^)(void (^done)(NSError * _Nullable error)))operation {
    if (self.isWorking || !self.folder) {
        return;
    }
    self.operationRunning = YES;
    [self updateBusyState];

    __block BOOL finished = NO; // only read and written on the main queue
    void (^done)(NSError * _Nullable) = ^(NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (finished) return;
            finished = YES;
            self.operationRunning = NO;
            if (error) {
                showDialog(localize(@"Error", nil), error.localizedDescription);
            }
            // Starts the reload (which also covers any reload asked for during the operation) and keeps
            // `busy` YES until it ends; if no reload can start, this drops `busy` here.
            [self reloadFromDisk];
            [self updateBusyState];
        });
    };
    operation(done);
}

- (void)reloadFromDisk {
    if (!self.folder || !self.index) {
        return;
    }
    if (self.isWorking) {
        // Runs once the current operation or reload ends.
        self.reloadPending = YES;
        return;
    }
    self.reloadPending = NO;
    self.reloading = YES;
    [self updateBusyState];

    ModFolder *folder = self.folder;
    ModIndex *modIndex = self.index;
    ModrinthModsAPI *api = self.api;
    NSMutableDictionary *cache = self.jarCache;
    dispatch_async(self.workQueue, ^{
        NSArray<ModsRow *> *rows = LoadRows(folder, modIndex, api, cache);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.reloading = NO;
            self.loadedOnce = YES;
            if (self.reloadPending) {
                // Asked for again while this one ran: start it right away, staying busy throughout.
                [self reloadFromDisk];
                [self publishRows:rows];
                return;
            }
            [self updateBusyState];
            [self publishRows:rows];
        });
    });
}

- (void)publishRows:(NSArray<ModsRow *> *)rows {
    self.rows = rows;
    NSMutableDictionary *byFileName = [NSMutableDictionary new];
    for (ModsRow *row in rows) {
        byFileName[row.fileName] = row;
    }
    self.rowsByFileName = byFileName;
    [self applyFilter];
    [self showMessage:rows.count == 0 ? localize(@"mods.empty.none", nil) : nil];
    [self.tableView reloadData];
}

#pragma mark Search

- (void)applyFilter {
    NSString *text = [self.searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (text.length == 0) {
        self.visibleRows = self.rows;
        return;
    }
    self.visibleRows = [self.rows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:
        ^BOOL(ModsRow *row, NSDictionary *bindings) {
            return [row.title localizedCaseInsensitiveContainsString:text];
        }]];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self applyFilter];
    [self.tableView reloadData];
}

#pragma mark Enable, disable, delete

/* Titles of the enabled mods whose record says they require `row`'s project. */
- (NSArray<NSString *> *)enabledDependentTitlesOfRow:(ModsRow *)row {
    NSString *projectId = StringOrNil(row.entry[@"projectId"]);
    // The record is only read here while nothing else is using it.
    if (!projectId || !self.index || self.isWorking) {
        return @[];
    }
    NSMutableArray<NSString *> *titles = [NSMutableArray new];
    for (NSString *fileName in [self.index fileNamesRequiringProject:projectId]) {
        ModsRow *dependent = self.rowsByFileName[fileName];
        if (dependent.enabled && ![fileName isEqualToString:row.fileName]) {
            [titles addObject:dependent.title];
        }
    }
    return titles;
}

/* Runs `confirmed` at once, or after asking when enabled mods need `row`. */
- (void)confirmRemovingRow:(ModsRow *)row actionTitle:(NSString *)actionTitle
                 confirmed:(void (^)(void))confirmed cancelled:(nullable void (^)(void))cancelled {
    NSArray<NSString *> *titles = [self enabledDependentTitlesOfRow:row];
    if (titles.count == 0) {
        confirmed();
        return;
    }
    NSString *message = [NSString stringWithFormat:localize(@"mods.alert.needed_by", nil),
        row.title, [titles componentsJoinedByString:@", "]];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:row.title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *action) {
            if (cancelled) cancelled();
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:actionTitle style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            confirmed();
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (nullable ModsRow *)rowForView:(UIView *)view {
    CGPoint point = [view convertPoint:CGPointMake(CGRectGetMidX(view.bounds), CGRectGetMidY(view.bounds)) toView:self.tableView];
    NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
    if (!indexPath || indexPath.row >= self.visibleRows.count) {
        return nil;
    }
    return self.visibleRows[indexPath.row];
}

- (void)switchChanged:(UISwitch *)sender {
    ModsRow *row = [self rowForView:sender];
    if (!row) {
        [self.tableView reloadData];
        return;
    }
    BOOL enable = sender.isOn;
    if (self.busy || enable == row.enabled) {
        [sender setOn:row.enabled animated:YES];
        return;
    }

    __weak ModsViewController *weakSelf = self;
    void (^apply)(void) = ^{
        [weakSelf setRow:row enabled:enable];
    };
    if (enable) {
        apply();
        return;
    }
    [self confirmRemovingRow:row actionTitle:localize(@"mods.action.disable", nil) confirmed:apply cancelled:^{
        [sender setOn:YES animated:YES];
    }];
}

- (void)setRow:(ModsRow *)row enabled:(BOOL)enabled {
    if (self.busy || !self.folder) {
        // Something else started meanwhile: show the real state again.
        [self.tableView reloadData];
        return;
    }
    ModFolder *folder = self.folder;
    ModJar *jar = row.jar;
    dispatch_queue_t queue = self.workQueue;
    [self runOperation:^(void (^done)(NSError * _Nullable)) {
        dispatch_async(queue, ^{
            NSError *error;
            BOOL ok = [folder setJar:jar enabled:enabled error:&error];
            done(ok ? nil : error);
        });
    }];
}

- (void)deleteRow:(ModsRow *)row {
    if (self.busy || !self.folder || !self.index) {
        return;
    }
    ModFolder *folder = self.folder;
    ModIndex *modIndex = self.index;
    ModJar *jar = row.jar;
    NSString *fileName = row.fileName;
    dispatch_queue_t queue = self.workQueue;
    [self runOperation:^(void (^done)(NSError * _Nullable)) {
        dispatch_async(queue, ^{
            NSError *error;
            BOOL ok = [folder deleteJar:jar error:&error];
            if (ok && modIndex.entries[fileName]) {
                [modIndex.entries removeObjectForKey:fileName];
                [modIndex save:nil];
            }
            done(ok ? nil : error);
        });
    }];
}

#pragma mark Browse and detail

- (void)actionAdd {
    if (self.busy || !self.folder) {
        return;
    }
    ModBrowseViewController *browse = [[ModBrowseViewController alloc] initWithModsController:self];
    UINavigationController *navigationController = [[UINavigationController alloc] initWithRootViewController:browse];
    [self presentViewController:navigationController animated:YES completion:nil];
}

/* The Modrinth project a row's jar came from, or nil for mods added by hand. */
- (nullable NSString *)projectIdOfRow:(ModsRow *)row {
    return StringOrNil(row.entry[@"projectId"]);
}

/* The mod's detail page, which marks the installed version and can switch to another one. */
- (void)showDetailOfRow:(ModsRow *)row {
    NSString *projectId = [self projectIdOfRow:row];
    if (!projectId || !self.folder) {
        return;
    }
    ModDetailViewController *detail = [[ModDetailViewController alloc] initWithModsController:self projectId:projectId hit:nil];
    [self.navigationController pushViewController:detail animated:YES];
}

#pragma mark Import

- (void)actionImport {
    if (self.busy || !self.folder) {
        return;
    }
    NSMutableArray<UTType *> *types = [NSMutableArray new];
    for (NSString *identifier in @[@"public.java-archive", @"com.sun.java-archive"]) {
        UTType *type = [UTType typeWithIdentifier:identifier];
        if (type) [types addObject:type];
    }
    if (types.count == 0) {
        [types addObject:UTTypeData];
    }
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    picker.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (url) {
        [self importJarAtURL:url];
    }
}

- (void)importJarAtURL:(NSURL *)url {
    if (self.busy || !self.folder) {
        return;
    }
    NSString *fileName = url.lastPathComponent;
    if (![fileName.pathExtension.lowercaseString isEqualToString:@"jar"]) {
        showDialog(localize(@"Error", nil), localize(@"mods.import.not_jar", nil));
        return;
    }
    // The folder only lists lowercase ".jar" files.
    if (![fileName.pathExtension isEqualToString:@"jar"]) {
        fileName = [fileName.stringByDeletingPathExtension stringByAppendingPathExtension:@"jar"];
    }

    NSString *path = [self.folder.modsDir stringByAppendingPathComponent:fileName];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL clash = [fm fileExistsAtPath:path] || [fm fileExistsAtPath:[path stringByAppendingString:@".disabled"]];
    if (!clash) {
        [self importURL:url asFileName:fileName replace:NO keepBoth:NO];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:fileName
        message:localize(@"mods.import.exists", nil) preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"mods.import.replace", nil) style:UIAlertActionStyleDestructive
        handler:^(UIAlertAction *action) {
            [self importURL:url asFileName:fileName replace:YES keepBoth:NO];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"mods.import.keep_both", nil) style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            [self importURL:url asFileName:fileName replace:NO keepBoth:YES];
        }]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)importURL:(NSURL *)url asFileName:(NSString *)fileName replace:(BOOL)replace keepBoth:(BOOL)keepBoth {
    if (self.busy || !self.folder || !self.index) {
        return;
    }
    ModFolder *folder = self.folder;
    ModIndex *modIndex = self.index;
    dispatch_queue_t queue = self.workQueue;
    [self runOperation:^(void (^done)(NSError * _Nullable)) {
        dispatch_async(queue, ^{
            // "Keep both" saves it as "X (2).jar" (or the next free number).
            NSString *targetName = keepBoth ? [folder uniqueFileNameFor:fileName] : fileName;
            NSError *error;
            NSString *written = [folder importJarFromURL:url asFileName:targetName replaceExisting:replace error:&error];
            if (written && modIndex.entries[written]) {
                // The replaced file's record no longer applies; the new file is identified on reload.
                [modIndex.entries removeObjectForKey:written];
                [modIndex save:nil];
            }
            done(written ? nil : error);
        });
    }];
}

#pragma mark UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.folder ? 1 : 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.visibleRows.count;
}

- (nullable NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!self.loadedOnce) {
        return nil;
    }
    return [self headerText];
}

/* "6 mods · Fabric 0.16.5 · 1.21.1" (no loader version when it is unknown). */
- (NSString *)headerText {
    NSUInteger count = self.rows.count;
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    [parts addObject:count == 1 ? localize(@"mods.header.count.one", nil)
        : [NSString stringWithFormat:localize(@"mods.header.count.other", nil), (int)count]];

    NSDictionary<NSString *, NSString *> *loaderNames = @{
        @"fabric": @"Fabric", @"quilt": @"Quilt", @"forge": @"Forge", @"neoforge": @"NeoForge"
    };
    NSString *loader = self.info.loader;
    NSString *loaderName = loader ? (loaderNames[loader] ?: loader) : nil;
    if (loaderName) {
        NSString *loaderVersion = self.info.loaderVersion;
        [parts addObject:loaderVersion.length > 0 ? [NSString stringWithFormat:@"%@ %@", loaderName, loaderVersion] : loaderName];
    }
    if (self.info.minecraftVersion.length > 0) {
        [parts addObject:self.info.minecraftVersion];
    }
    return [parts componentsJoinedByString:@" · "];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kModCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kModCellID];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.imageView.frame = CGRectMake(0, 0, 40, 40);
        cell.imageView.isSizeFixed = YES;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        UISwitch *toggle = [UISwitch new];
        [toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }

    ModsRow *row = self.visibleRows[indexPath.row];
    cell.textLabel.text = row.title;
    cell.detailTextLabel.text = row.subtitle;
    // Mods from Modrinth open their detail page.
    cell.selectionStyle = [self projectIdOfRow:row] ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    UIImage *placeholder = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(40, 40)];
    if (row.iconURL) {
        [cell.imageView setImageWithURL:row.iconURL placeholderImage:placeholder];
    } else {
        // A reused cell may still be loading another mod's icon.
        [cell.imageView cancelImageDownloadTask];
        cell.imageView.image = placeholder;
    }

    UISwitch *toggle = (UISwitch *)cell.accessoryView;
    [toggle setOn:row.enabled animated:NO];
    toggle.enabled = !self.busy;
    cell.contentView.alpha = row.enabled ? 1 : kDisabledRowAlpha;
    return cell;
}

#pragma mark UITableViewDelegate

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return indexPath.row < (NSInteger)self.visibleRows.count && [self projectIdOfRow:self.visibleRows[indexPath.row]] != nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row < (NSInteger)self.visibleRows.count) {
        [self showDetailOfRow:self.visibleRows[indexPath.row]];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return !self.busy;
}

- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (self.busy || indexPath.row >= self.visibleRows.count) {
        return [UISwipeActionsConfiguration configurationWithActions:@[]];
    }
    ModsRow *row = self.visibleRows[indexPath.row];
    __weak ModsViewController *weakSelf = self;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:localize(@"mods.action.delete", nil)
        handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
            // The row goes away when the list reloads after the delete.
            completionHandler(NO);
            ModsViewController *strongSelf = weakSelf;
            if (!strongSelf || strongSelf.busy) return;
            [strongSelf confirmRemovingRow:row actionTitle:localize(@"mods.action.delete", nil) confirmed:^{
                [weakSelf deleteRow:row];
            } cancelled:nil];
        }];
    NSMutableArray<UIContextualAction *> *actions = [NSMutableArray arrayWithObject:delete];
    if ([self projectIdOfRow:row]) {
        UIContextualAction *changeVersion = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
            title:localize(@"mods.action.change_version", nil)
            handler:^(UIContextualAction *action, UIView *sourceView, void (^completionHandler)(BOOL)) {
                completionHandler(YES);
                [weakSelf showDetailOfRow:row];
            }];
        changeVersion.backgroundColor = UIColor.systemBlueColor;
        [actions addObject:changeVersion];
    }
    UISwipeActionsConfiguration *configuration = [UISwipeActionsConfiguration configurationWithActions:actions];
    configuration.performsFirstActionWithFullSwipe = YES;
    return configuration;
}

@end

NS_ASSUME_NONNULL_END
