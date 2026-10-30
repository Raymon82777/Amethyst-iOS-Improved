#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "LauncherPreferences.h"
#import "ModBrowseViewController.h"
#import "ModDetailViewController.h"
#import "ModInstallFlow.h"
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
static NSString *const kBannerCellID = @"ModBannerCell";

/* The line above the list: mods that don't fit the profile's version or loader win over updates. */
typedef NS_ENUM(NSInteger, ModsBanner) {
    ModsBannerNone,
    ModsBannerUpdates,
    ModsBannerMismatch
};

static NSString *GameRoot(void) {
    const char *gameDir = getenv("GAME_DIR");
    return gameDir ? @(gameDir) : @"";
}

/* `value` when it is a non-empty string. */
static NSString * _Nullable StringOrNil(id _Nullable value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

/* "Fabric" for "fabric"; unknown loaders as they are. */
static NSString *LoaderDisplayName(NSString *loader) {
    NSDictionary<NSString *, NSString *> *names = @{
        @"fabric": @"Fabric", @"quilt": @"Quilt", @"forge": @"Forge", @"neoforge": @"NeoForge"
    };
    return names[loader] ?: loader;
}

/* The profile's Minecraft version: the version JSON's, else for latest-release / latest-snapshot the
   latest version the launcher saved from the version manifest; @"" when unknown. */
static NSString *ResolvedGameVersion(ModProfileInfo *info, NSString * _Nullable versionId) {
    NSString *mc = StringOrNil(info.minecraftVersion);
    if (mc) {
        return mc;
    }
    if ([versionId isEqualToString:@"latest-release"]) {
        return StringOrNil(getPrefObject(@"internal.latest_version.release")) ?: @"";
    }
    if ([versionId isEqualToString:@"latest-snapshot"]) {
        return StringOrNil(getPrefObject(@"internal.latest_version.snapshot")) ?: @"";
    }
    return @"";
}

#pragma mark - Rows

/* One jar as shown in the list. Built on the work queue, read-only once published to the main queue
   (except `jar`, which only the work queue touches). */
@interface ModsRow : NSObject
@property(nonatomic) ModJar *jar;
@property(nonatomic, copy) NSString *fileName;
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL isFolder;                        // a folder pack (copied from `jar`, safe to read on the main queue)
@property(nonatomic, copy, nullable) NSDictionary *entry; // the record entry, nil when not identified
@property(nonatomic, copy) NSString *title;
@property(nonatomic, copy, nullable) NSString *subtitle; // the installed version (or the "Added manually" line)
@property(nonatomic, nullable) NSURL *iconURL;
@property(nonatomic, copy, nullable) NSString *sha1;       // Modrinth mods only
@property(nonatomic) BOOL mismatched;                      // made for another Minecraft version or loader
@property(nonatomic, copy, nullable) NSString *builtFor;   // what a mismatched mod was made for
@property(nonatomic, copy, nullable) NSDictionary *update; // Modrinth's newer version, when there is one
@end

@implementation ModsRow
@end

/* What one reload found; published to the main queue in one go. */
@interface ModsLoadResult : NSObject
@property(nonatomic, copy) NSArray<ModsRow *> *rows;
@property(nonatomic, copy) NSDictionary<NSString *, NSDictionary *> *availableUpdates;
@property(nonatomic, copy) NSArray<NSString *> *mismatchedFileNames;
@end

@implementation ModsLoadResult
@end

/* What the reload job remembers between runs. Work queue only. */
@interface ModsCheckState : NSObject
/* Hashes already looked up to fill in missing gameVersions/loaders, so a hash Modrinth does not answer
   for is not asked again while the screen is open. */
@property(nonatomic) NSMutableSet<NSString *> *backfillTried;
/* The last update check that worked: the hashes asked about, and the newest version per hash. While the
   installed mods stay the same (switching one on or off changes nothing here) it is reused instead of
   asking Modrinth again. */
@property(nonatomic, copy, nullable) NSDictionary *updateQuery;
@property(nonatomic, copy, nullable) NSDictionary<NSString *, NSDictionary *> *updateResult;
@end

@implementation ModsCheckState
- (instancetype)init {
    self = [super init];
    _backfillTried = [NSMutableSet new];
    return self;
}
@end

/* A mod row: icon, title, version line, and on the right an Update tag (when there is an update) beside
   the on/off switch (none for a folder pack). */
@interface ModsCell : UITableViewCell
@property(nonatomic, readonly) UISwitch *toggle;
@property(nonatomic, readonly) UIButton *updateButton;
@property(nonatomic, readonly) UIStackView *accessoryStack;
- (void)setShowsUpdate:(BOOL)showsUpdate showsToggle:(BOOL)showsToggle;
@end

@implementation ModsCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(nullable NSString *)reuseIdentifier {
    self = [super initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:reuseIdentifier];
    if (!self) return nil;
    _toggle = [UISwitch new];

    UIColor *color = UIColor.systemBlueColor;
    _updateButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [_updateButton setTitle:localize(@"mods.tag.update", nil) forState:UIControlStateNormal];
    _updateButton.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    _updateButton.tintColor = color;
    _updateButton.backgroundColor = [color colorWithAlphaComponent:0.15];
    _updateButton.layer.cornerRadius = 6;
    _updateButton.contentEdgeInsets = UIEdgeInsetsMake(3, 8, 3, 8);

    _accessoryStack = [[UIStackView alloc] initWithArrangedSubviews:@[_updateButton, _toggle]];
    _accessoryStack.axis = UILayoutConstraintAxisHorizontal;
    _accessoryStack.alignment = UIStackViewAlignmentCenter;
    _accessoryStack.spacing = 10;
    self.accessoryView = _accessoryStack;
    [self setShowsUpdate:NO showsToggle:YES];
    return self;
}

- (void)setShowsUpdate:(BOOL)showsUpdate showsToggle:(BOOL)showsToggle {
    self.updateButton.hidden = !showsUpdate;
    self.toggle.hidden = !showsToggle;
    CGSize size = [self.accessoryStack systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    self.accessoryStack.frame = CGRectMake(0, 0, ceil(size.width), ceil(size.height));
    [self setNeedsLayout];
}

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
   Any failed request (offline) leaves the record alone so the jars are tried again next time.
   Folder packs are never hashed or looked up. */
static BOOL IdentifyJars(NSArray<ModJar *> *jars, ModIndex *modIndex, ModrinthModsAPI *api, NSMutableDictionary *cache) {
    // Several jars can share a hash (copies of one file): each of them gets the result.
    NSMutableDictionary<NSString *, NSMutableArray<ModJar *> *> *jarsByHash = [NSMutableDictionary new];
    for (ModJar *jar in jars) {
        if (jar.isDirectory || modIndex.entries[jar.fileName]) continue;
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

/* The sha1 of a recorded jar: the one in the record, else the file's own. Lowercase. */
static NSString * _Nullable EntrySha1(ModJar *jar, NSDictionary *entry, NSMutableDictionary *cache) {
    return StringOrNil(entry[@"sha1"]).lowercaseString ?: CachedSha1(jar, cache);
}

/* YES when the entry says which Minecraft versions and loaders it was made for. */
static BOOL HasMatchFields(NSDictionary *entry) {
    return [entry[@"gameVersions"] isKindOfClass:NSArray.class] && [entry[@"loaders"] isKindOfClass:NSArray.class];
}

/* Fills in gameVersions and loaders of Modrinth entries recorded without them (one hash request).
   Returns YES if the record changed. A failed request (offline) is tried again next time. */
static BOOL BackfillMatchFields(NSArray<ModJar *> *jars, ModIndex *modIndex, ModrinthModsAPI *api,
                                NSMutableDictionary *cache, NSMutableSet<NSString *> *tried) {
    NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *fileNamesByHash = [NSMutableDictionary new];
    for (ModJar *jar in jars) {
        if (jar.isDirectory) continue;
        NSDictionary *entry = modIndex.entries[jar.fileName];
        if (!entry || !StringOrNil(entry[@"projectId"]) || HasMatchFields(entry)) continue;
        NSString *sha1 = EntrySha1(jar, entry, cache);
        if (!sha1 || [tried containsObject:sha1]) continue;
        NSMutableArray<NSString *> *sameHash = fileNamesByHash[sha1];
        if (!sameHash) {
            sameHash = [NSMutableArray new];
            fileNamesByHash[sha1] = sameHash;
        }
        [sameHash addObject:jar.fileName];
    }
    if (fileNamesByHash.count == 0) return NO;

    NSDictionary<NSString *, NSDictionary *> *versions = [api versionsForHashes:fileNamesByHash.allKeys];
    if (!versions) return NO;
    [tried addObjectsFromArray:fileNamesByHash.allKeys];

    BOOL changed = NO;
    for (NSString *sha1 in fileNamesByHash) {
        NSDictionary *version = VersionForHash(versions, sha1);
        id gameVersions = version[@"game_versions"];
        id loaders = version[@"loaders"];
        if (![gameVersions isKindOfClass:NSArray.class] || ![loaders isKindOfClass:NSArray.class]) continue;
        for (NSString *fileName in fileNamesByHash[sha1]) {
            NSMutableDictionary *entry = [modIndex.entries[fileName] mutableCopy];
            if (!entry) continue;
            entry[@"gameVersions"] = gameVersions;
            entry[@"loaders"] = loaders;
            modIndex.entries[fileName] = entry;
            changed = YES;
        }
    }
    return changed;
}

/* The newest version for the profile of the project each hash belongs to, keyed by the hash as given.
   Mods installed as a release are only offered releases. Asks Modrinth (two requests) only when the
   hashes differ from the last check that worked; nil when a request failed (offline). */
static NSDictionary<NSString *, NSDictionary *> * _Nullable LatestVersions(NSArray<NSString *> *releaseHashes,
        NSArray<NSString *> *otherHashes, NSArray<NSString *> *loaders, NSString *mc, ModrinthModsAPI *api,
        ModsCheckState *state) {
    NSDictionary *query = @{
        @"release": [releaseHashes sortedArrayUsingSelector:@selector(compare:)],
        @"other": [otherHashes sortedArrayUsingSelector:@selector(compare:)]
    };
    if (state.updateResult && [query isEqual:state.updateQuery]) {
        return state.updateResult;
    }
    NSDictionary<NSString *, NSDictionary *> *releases = [api latestVersionsForHashes:releaseHashes
        loaders:loaders gameVersion:mc versionTypes:@[@"release"]];
    if (!releases) return nil;
    NSDictionary<NSString *, NSDictionary *> *others = [api latestVersionsForHashes:otherHashes
        loaders:loaders gameVersion:mc versionTypes:nil];
    if (!others) return nil;

    NSMutableDictionary<NSString *, NSDictionary *> *result = [NSMutableDictionary new];
    for (NSString *sha1 in releaseHashes) {
        NSDictionary *version = VersionForHash(releases, sha1);
        if (version) result[sha1] = version;
    }
    for (NSString *sha1 in otherHashes) {
        NSDictionary *version = VersionForHash(others, sha1);
        if (version) result[sha1] = version;
    }
    state.updateQuery = query;
    state.updateResult = result;
    return result;
}

/* The newest of the Minecraft versions, e.g. "1.21.1" of ["1.21", "1.21.1"]. */
static NSString * _Nullable NewestGameVersion(NSArray *gameVersions) {
    NSString *newest;
    for (id each in gameVersions) {
        NSString *gameVersion = StringOrNil(each);
        if (gameVersion && (!newest || [gameVersion compare:newest options:NSNumericSearch] == NSOrderedDescending)) {
            newest = gameVersion;
        }
    }
    return newest;
}

/* What a mismatched mod was made for: its newest Minecraft version, or its loaders ("Fabric/Quilt")
   when the Minecraft version is the profile's and only the loader differs. */
static NSString * _Nullable BuiltForText(NSDictionary *entry, NSString *mc) {
    NSArray *gameVersions = entry[@"gameVersions"];
    if ([gameVersions containsObject:mc]) {
        NSMutableArray<NSString *> *names = [NSMutableArray new];
        for (id each in (NSArray *)entry[@"loaders"]) {
            NSString *loader = StringOrNil(each);
            if (loader) [names addObject:LoaderDisplayName(loader)];
        }
        return names.count > 0 ? [names componentsJoinedByString:@"/"] : nil;
    }
    return NewestGameVersion(gameVersions);
}

/* Scans the folder, prunes and fills in the record, then finds the mods that don't fit the profile and
   (for the ones that do) the updates. Builds the rows sorted by title. Packs never read jar metadata,
   and folder packs are never identified or checked (their rows have no record entry). */
static ModsLoadResult *LoadRows(ModFolder *folder, ModIndex *modIndex, ModrinthModsAPI *api, NSMutableDictionary *cache,
                                ModsCheckState *checkState, NSArray<NSString *> *loaders, NSString *mc) {
    ModContentKind *kind = folder.kind;
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
    if (BackfillMatchFields(jars, modIndex, api, cache, checkState.backfillTried)) {
        changed = YES;
    }
    if (changed) {
        [modIndex save:nil];
    }

    // Mods made for another version or loader, and the hashes of the others for the update check.
    // Entries that don't say what they were made for (the lookup failed) are neither flagged nor checked.
    NSMutableDictionary<NSString *, NSString *> *sha1ByFileName = [NSMutableDictionary new];
    NSMutableSet<NSString *> *mismatched = [NSMutableSet new];
    NSMutableArray<NSString *> *matching = [NSMutableArray new];
    NSMutableArray<NSString *> *releaseHashes = [NSMutableArray new];
    NSMutableArray<NSString *> *otherHashes = [NSMutableArray new];
    for (ModJar *jar in jars) {
        if (jar.isDirectory) continue;
        NSDictionary *entry = modIndex.entries[jar.fileName];
        if (!entry || !StringOrNil(entry[@"projectId"])) continue;
        NSString *sha1 = EntrySha1(jar, entry, cache);
        if (sha1) sha1ByFileName[jar.fileName] = sha1;
        if (!HasMatchFields(entry)) continue;
        if (![ModIndex entry:entry matchesLoaders:loaders gameVersion:mc]) {
            [mismatched addObject:jar.fileName];
            continue;
        }
        if (!sha1) continue;
        [matching addObject:jar.fileName];
        // Disabled mods are checked too: an update keeps them disabled. No type counts as a release.
        NSString *type = StringOrNil(entry[@"versionType"]);
        if (!type || [type isEqualToString:@"release"]) {
            [releaseHashes addObject:sha1];
        } else {
            [otherHashes addObject:sha1];
        }
    }

    NSMutableDictionary<NSString *, NSDictionary *> *updates = [NSMutableDictionary new];
    NSDictionary<NSString *, NSDictionary *> *latest = LatestVersions(releaseHashes, otherHashes, loaders, mc, api, checkState);
    for (NSString *fileName in matching) {
        NSDictionary *entry = modIndex.entries[fileName];
        NSDictionary *version = latest[sha1ByFileName[fileName]];
        NSString *versionId = StringOrNil(version[@"id"]);
        NSString *installedId = StringOrNil(entry[@"versionId"]);
        if (!versionId || (installedId && [versionId isEqualToString:installedId])) continue;
        if (![version[@"project_id"] isEqual:entry[@"projectId"]]) continue;
        updates[fileName] = version;
    }

    // Forget files that are gone.
    NSMutableSet *staleKeys = [NSMutableSet setWithArray:cache.allKeys];
    [staleKeys minusSet:fileNames];
    [cache removeObjectsForKeys:staleKeys.allObjects];

    NSString *manualLabel = localize(@"mods.row.manual", nil);
    NSMutableArray<ModsRow *> *rows = [NSMutableArray new];
    for (ModJar *jar in jars) {
        if (jar.isDirectory) {
            // A folder pack: no record entry, so no detail page, version change or update.
            ModsRow *row = [ModsRow new];
            row.jar = jar;
            row.isFolder = jar.isDirectory;
            row.fileName = jar.fileName;
            row.enabled = jar.enabled;
            row.title = jar.fileName;
            row.subtitle = localize(@"packs.row.folder", nil);
            [rows addObject:row];
            continue;
        }
        NSDictionary *entry = [modIndex.entries[jar.fileName] copy];
        NSString *title = StringOrNil(entry[@"title"]);
        NSString *version = StringOrNil(entry[@"versionNumber"]);
        if (kind.isMods && (!title || !version)) {
            NSDictionary *metadata = CachedMetadata(jar, cache);
            title = title ?: StringOrNil(metadata[@"name"]);
            version = version ?: StringOrNil(metadata[@"version"]);
        }
        if (!kind.isMods && !title && [jar.fileName.pathExtension.lowercaseString isEqualToString:kind.fileExtension]) {
            // "Faithful 32x.zip" is listed as "Faithful 32x".
            title = StringOrNil(jar.fileName.stringByDeletingPathExtension);
        }

        ModsRow *row = [ModsRow new];
        row.jar = jar;
        row.isFolder = jar.isDirectory;
        row.fileName = jar.fileName;
        row.enabled = jar.enabled;
        row.entry = entry;
        row.title = title ?: jar.fileName;
        if (entry) {
            row.subtitle = version;
            NSString *iconUrl = StringOrNil(entry[@"iconUrl"]);
            row.iconURL = iconUrl ? [NSURL URLWithString:iconUrl] : nil;
            row.sha1 = sha1ByFileName[jar.fileName];
            row.mismatched = [mismatched containsObject:jar.fileName];
            row.builtFor = row.mismatched ? BuiltForText(entry, mc) : nil;
            row.update = updates[jar.fileName];
        } else {
            row.subtitle = version ? [NSString stringWithFormat:@"%@ · %@", version, manualLabel] : manualLabel;
        }
        [rows addObject:row];
    }
    [rows sortUsingComparator:^NSComparisonResult(ModsRow *a, ModsRow *b) {
        NSComparisonResult result = [a.title localizedStandardCompare:b.title];
        return result != NSOrderedSame ? result : [a.fileName localizedStandardCompare:b.fileName];
    }];

    ModsLoadResult *result = [ModsLoadResult new];
    result.rows = rows;
    result.availableUpdates = updates;
    result.mismatchedFileNames = [mismatched.allObjects sortedArrayUsingSelector:@selector(compare:)];
    return result;
}

#pragma mark - ModsViewController

@interface ModsViewController () <UIDocumentPickerDelegate, UISearchResultsUpdating>
@property(nonatomic, readwrite) BOOL busy;
@property(nonatomic, readonly) BOOL isWorking; // operationRunning || reloading
@property(nonatomic, readwrite) BOOL operationRunning;
@property(nonatomic) BOOL reloading;
/* The navigation controller whose swipe back this screen turned off while an operation runs. */
@property(nonatomic, weak, nullable) UINavigationController *popGestureLockedController;
@property(nonatomic) BOOL reloadPending;
@property(nonatomic) BOOL loadedOnce;
@property(nonatomic) BOOL showFolderNotice;
@property(nonatomic) dispatch_queue_t workQueue;
@property(nonatomic) NSMutableDictionary *jarCache; // work queue only
@property(nonatomic) ModsCheckState *checkState;   // work queue only

@property(nonatomic) NSArray<ModsRow *> *rows;
@property(nonatomic) NSArray<ModsRow *> *visibleRows;
@property(nonatomic) NSDictionary<NSString *, ModsRow *> *rowsByFileName;
@property(nonatomic, readwrite) NSDictionary<NSString *, NSDictionary *> *availableUpdates;
@property(nonatomic, readwrite) NSArray<NSString *> *mismatchedFileNames;
/* Mismatched mods that the last Switch all found no version for ("No 1.21.4 version yet"). Lives as long
   as this screen; a profile's Minecraft version or loader can only change while the screen is closed. */
@property(nonatomic) NSSet<NSString *> *noVersionFileNames;

@property(nonatomic, nullable) UISearchController *searchController;
@property(nonatomic, nullable) UIBarButtonItem *addItem;
@property(nonatomic, nullable) UIBarButtonItem *importItem;
@property(nonatomic, nullable) UIActivityIndicatorView *spinner;
@end

@implementation ModsViewController

- (instancetype)initWithProfileName:(NSString *)profileName {
    return [self initWithProfileName:profileName kind:ModContentKind.mods];
}

- (instancetype)initWithProfileName:(NSString *)profileName kind:(ModContentKind *)kind {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    _profileName = [profileName copy];
    _kind = kind;
    _api = [ModrinthModsAPI new];
    _workQueue = dispatch_queue_create("net.kdt.pojavlaunch.mods", DISPATCH_QUEUE_SERIAL);
    _jarCache = [NSMutableDictionary new];
    _checkState = [ModsCheckState new];
    _rows = @[];
    _visibleRows = @[];
    _rowsByFileName = @{};
    _availableUpdates = @{};
    _mismatchedFileNames = @[];
    _noVersionFileNames = [NSSet set];

    NSString *versionId = PLProfiles.current.profiles[profileName][@"lastVersionId"];
    NSString *versionsDir = [GameRoot() stringByAppendingPathComponent:@"versions"];
    _info = [ModProfileInfo infoForVersionId:versionId ?: @"" versionsDir:versionsDir];
    _loaders = [kind loadersForProfileLoaders:_info.acceptedLoaders];
    _gameVersion = ResolvedGameVersion(_info, versionId);
    if (kind.isMods) {
        _profileDisplayName = _info.displayName;
        _filterChipText = _info.displayName;
    } else {
        _profileDisplayName = [NSString stringWithFormat:localize(@"packs.profile_name", nil), _gameVersion];
        _filterChipText = [NSString stringWithFormat:localize([kind stringKey:@"chip"], nil), _gameVersion];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize([self.kind stringKey:@"title"], nil);
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
    self.addItem.accessibilityLabel = localize([self.kind stringKey:@"action.add"], nil);
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.navigationItem.rightBarButtonItems = @[
        self.addItem,
        self.importItem,
        [[UIBarButtonItem alloc] initWithCustomView:self.spinner]
    ];
    [self updateBusyState];
}

- (void)dealloc {
    [self restorePopGesture];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateNavigationLock];
    // Also picks up files changed in the Files app while another screen was shown.
    [self reloadFromDisk];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    // A page pushed on top may swipe back to this one; viewWillAppear locks again on the way back.
    [self restorePopGesture];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.showFolderNotice) {
        self.showFolderNotice = NO;
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize([self.kind stringKey:@"title"], nil)
            message:localize([self.kind stringKey:@"alert.own_folder"], nil) preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"OK", nil) style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
    }
}

/* Sets up `folder` and `index`, first giving a profile on the shared game folder its own folder (for
   mods only a modded one; for packs any profile, once its Minecraft version is known).
   Returns the message to show instead of the list when the profile cannot have this content. */
- (nullable NSString *)prepareFolder {
    ModContentKind *kind = self.kind;
    if (kind.isMods && !self.info.isModded) {
        return localize(@"mods.empty.vanilla", nil);
    }
    if (self.gameVersion.length == 0) {
        return localize([kind stringKey:@"empty.unknown_version"], nil);
    }

    NSMutableDictionary *profile = PLProfiles.current.profiles[self.profileName];
    if (!profile) {
        return localize(kind.isMods ? @"mods.empty.vanilla" : [kind stringKey:@"empty.unknown_version"], nil);
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
        // Told on every move: one only happens while the profile is on the shared folder, e.g. again
        // after its Game directory was set back to ".".
        self.showFolderNotice = YES;
        [PLProfiles.current save];
        gameDir = newGameDir;
        if (self.gameDirChanged) {
            self.gameDirChanged(newGameDir);
        }
    }

    NSString *modsDir = [[ModFolder gameDirPathForGameDir:gameDir baseDir:baseDir] stringByAppendingPathComponent:kind.folderName];
    _folder = [[ModFolder alloc] initWithModsDir:modsDir kind:kind];
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
        if ([cell isKindOfClass:ModsCell.class]) {
            ((ModsCell *)cell).toggle.enabled = !busy;
            ((ModsCell *)cell).updateButton.enabled = !busy;
        } else if ([cell.accessoryView isKindOfClass:UIButton.class]) {
            // The banner's Update all / Switch all.
            ((UIButton *)cell.accessoryView).enabled = !busy;
        }
    }
    [self updateNavigationLock];
}

/* While an operation runs, no way back to the profile editor: there a second Mods screen could be opened
   on the same folder, whose reload would rescan it (deleting the running download's ".part") and whose
   record would overwrite this one's. Reloads alone do not lock, so a slow network never traps the user:
   a reload scans the folder only when it starts, a closed screen starts no further reload (see
   reloadFromDisk), and at worst a reload still running on a closed screen saves a record that misses a
   mod installed meanwhile from the new screen, which its next reload identifies again by hash. */
- (void)updateNavigationLock {
    BOOL locked = self.operationRunning;
    if (self.navigationItem.hidesBackButton != locked) {
        [self.navigationItem setHidesBackButton:locked animated:YES];
    }
    UINavigationController *navigationController = self.navigationController;
    if (!locked || navigationController.topViewController != self) {
        // Pages pushed on top keep their swipe back: it only returns here.
        [self restorePopGesture];
        return;
    }
    UIGestureRecognizer *popGesture = navigationController.interactivePopGestureRecognizer;
    if (!self.popGestureLockedController && popGesture.enabled) {
        popGesture.enabled = NO;
        self.popGestureLockedController = navigationController;
    }
}

/* Turns swipe back on again, if this screen turned it off. */
- (void)restorePopGesture {
    UINavigationController *navigationController = self.popGestureLockedController;
    navigationController.interactivePopGestureRecognizer.enabled = YES;
    self.popGestureLockedController = nil;
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
    ModsCheckState *checkState = self.checkState;
    NSArray<NSString *> *loaders = self.loaders;
    NSString *mc = self.gameVersion;
    dispatch_async(self.workQueue, ^{
        ModsLoadResult *result = LoadRows(folder, modIndex, api, cache, checkState, loaders, mc);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.reloading = NO;
            self.loadedOnce = YES;
            // Not once the screen was closed: another Mods screen may be using the folder by now, and
            // a rescan would delete its download in progress.
            if (self.reloadPending && self.navigationController) {
                // Asked for again while this one ran: start it right away, staying busy throughout.
                [self reloadFromDisk];
                [self publishResult:result];
                return;
            }
            [self updateBusyState];
            [self publishResult:result];
        });
    });
}

- (void)publishResult:(ModsLoadResult *)result {
    self.availableUpdates = result.availableUpdates;
    self.mismatchedFileNames = result.mismatchedFileNames;
    // A mod that fits again (switched from its detail page, or deleted) loses its "no version yet" note.
    NSMutableSet<NSString *> *noVersion = [self.noVersionFileNames mutableCopy];
    [noVersion intersectSet:[NSSet setWithArray:result.mismatchedFileNames]];
    self.noVersionFileNames = noVersion;
    [self publishRows:result.rows];
}

- (void)publishRows:(NSArray<ModsRow *> *)rows {
    self.rows = rows;
    NSMutableDictionary *byFileName = [NSMutableDictionary new];
    for (ModsRow *row in rows) {
        byFileName[row.fileName] = row;
    }
    self.rowsByFileName = byFileName;
    [self applyFilter];
    [self showMessage:rows.count == 0 ? localize([self.kind stringKey:@"empty.none"], nil) : nil];
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

/* Runs `confirmed` at once, or after asking when enabled mods need `row`. Packs have no dependencies,
   so for them it never asks. */
- (void)confirmRemovingRow:(ModsRow *)row actionTitle:(NSString *)actionTitle
                 confirmed:(void (^)(void))confirmed cancelled:(nullable void (^)(void))cancelled {
    NSArray<NSString *> *titles = self.kind.isMods ? [self enabledDependentTitlesOfRow:row] : @[];
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
    return indexPath ? [self modRowAtIndexPath:indexPath] : nil;
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

#pragma mark Updates and version changes

- (ModInstallFlow *)makeInstallFlow {
    return [[ModInstallFlow alloc] initWithKind:self.kind loaders:self.loaders gameVersion:self.gameVersion
        profileName:self.profileDisplayName fetchCache:[ModFetchCache new]];
}

/* `fileNames` in the order of the list (by title); names without a row are left out. */
- (NSArray<NSString *> *)fileNamesInListOrder:(NSArray<NSString *> *)fileNames {
    NSSet<NSString *> *wanted = [NSSet setWithArray:fileNames];
    NSMutableArray<NSString *> *ordered = [NSMutableArray new];
    for (ModsRow *row in self.rows) {
        if ([wanted containsObject:row.fileName]) {
            [ordered addObject:row.fileName];
        }
    }
    return ordered;
}

- (NSDictionary<NSString *, NSString *> *)titlesOfFileNames:(NSArray<NSString *> *)fileNames {
    NSMutableDictionary<NSString *, NSString *> *titles = [NSMutableDictionary new];
    for (NSString *fileName in fileNames) {
        titles[fileName] = self.rowsByFileName[fileName].title ?: fileName;
    }
    return titles;
}

/* Project id -> title of every Modrinth mod in the list (saves a lookup when naming a missing dependency). */
- (NSDictionary<NSString *, NSString *> *)knownProjectTitles {
    NSMutableDictionary<NSString *, NSString *> *titles = [NSMutableDictionary new];
    for (ModsRow *row in self.rows) {
        NSString *projectId = [self projectIdOfRow:row];
        if (projectId) titles[projectId] = row.title;
    }
    return titles;
}

/* "Sodium: <what went wrong>" */
static NSString *FailureLine(NSString *title, NSString *message) {
    return [NSString stringWithFormat:localize(@"mods.error.failed_mod", nil), title, message];
}

/* One error listing every mod that failed, or nil when none did. */
static NSError * _Nullable FailureSummary(NSArray<NSString *> *lines, NSString *messageKey) {
    if (lines.count == 0) {
        return nil;
    }
    NSString *message = [NSString stringWithFormat:localize(messageKey, nil), [lines componentsJoinedByString:@"\n\n"]];
    return ModDisplayError(message, nil);
}

/* Installs each version (jar file name -> Modrinth version) as its own set, one after the other in one
   operation, so one failure does not stop the others. Failures are shown together at the end. */
- (void)installVersions:(NSDictionary<NSString *, NSDictionary *> *)versions failureKey:(NSString *)failureKey {
    if (self.busy || !self.folder || !self.index || versions.count == 0) {
        return;
    }
    NSArray<NSString *> *fileNames = [self fileNamesInListOrder:versions.allKeys];
    NSDictionary<NSString *, NSString *> *titles = [self titlesOfFileNames:fileNames];
    NSDictionary<NSString *, NSString *> *knownTitles = [self knownProjectTitles];
    ModInstallFlow *flow = [self makeInstallFlow];
    ModFolder *folder = self.folder;
    ModIndex *modIndex = self.index;
    ModrinthModsAPI *api = self.api;
    dispatch_queue_t queue = self.workQueue;
    [self runOperation:^(void (^done)(NSError * _Nullable)) {
        dispatch_async(queue, ^{
            NSMutableArray<NSString *> *failures = [NSMutableArray new];
            for (NSString *fileName in fileNames) {
                NSString *title = titles[fileName] ?: fileName;
                NSDictionary *version = versions[fileName];
                if (!version) continue;
                NSError *error = [flow installVersion:version title:title index:modIndex folder:folder
                    api:api knownTitles:knownTitles];
                if (error) {
                    [failures addObject:FailureLine(title, error.localizedDescription ?: @"")];
                }
            }
            done(FailureSummary(failures, failureKey));
        });
    }];
}

/* The Update tag of a row: installs that mod's newer version. */
- (void)updateTapped:(UIButton *)sender {
    ModsRow *row = [self rowForView:sender];
    NSDictionary *version = row ? self.availableUpdates[row.fileName] : nil;
    if (!row || !version || self.busy) {
        return;
    }
    [self installVersions:@{row.fileName: version} failureKey:[self.kind stringKey:@"error.update_failed"]];
}

- (void)actionUpdateAll {
    [self installVersions:self.availableUpdates failureKey:[self.kind stringKey:@"error.update_failed"]];
}

/* Replaces every mismatched mod with its newest version for the profile (a release when there is one,
   as when installing), each as its own set. Mods with no such version keep their file and their flag. */
- (void)actionSwitchAll {
    if (self.busy || !self.folder || !self.index) {
        return;
    }
    NSMutableArray<NSString *> *fileNames = [NSMutableArray new];
    NSMutableDictionary<NSString *, NSString *> *hashes = [NSMutableDictionary new];
    for (NSString *fileName in [self fileNamesInListOrder:self.mismatchedFileNames]) {
        NSString *sha1 = self.rowsByFileName[fileName].sha1;
        if (!sha1) continue; // the file could not be read; it stays flagged
        [fileNames addObject:fileName];
        hashes[fileName] = sha1;
    }
    if (fileNames.count == 0) {
        return;
    }
    NSDictionary<NSString *, NSString *> *titles = [self titlesOfFileNames:fileNames];
    NSDictionary<NSString *, NSString *> *knownTitles = [self knownProjectTitles];
    ModInstallFlow *flow = [self makeInstallFlow];
    NSArray<NSString *> *loaders = flow.loaders;
    NSString *mc = flow.gameVersion;
    ModFolder *folder = self.folder;
    ModIndex *modIndex = self.index;
    ModrinthModsAPI *api = self.api;
    dispatch_queue_t queue = self.workQueue;
    NSString *failureKey = [self.kind stringKey:@"error.switch_failed"];
    __weak ModsViewController *weakSelf = self;
    [self runOperation:^(void (^done)(NSError * _Nullable)) {
        dispatch_async(queue, ^{
            NSArray<NSString *> *allHashes = hashes.allValues;
            NSDictionary<NSString *, NSDictionary *> *releases = [api latestVersionsForHashes:allHashes
                loaders:loaders gameVersion:mc versionTypes:@[@"release"]];
            if (!releases) {
                NSString *reason = api.lastError.localizedDescription ?: @"";
                done(ModDisplayError([NSString stringWithFormat:localize(@"mods.error.network", nil), reason], api.lastError));
                return;
            }
            NSMutableArray<NSString *> *leftovers = [NSMutableArray new];
            for (NSString *sha1 in allHashes) {
                if (!VersionForHash(releases, sha1)) [leftovers addObject:sha1];
            }
            // Any type for the mods without a release (no request when there are none).
            NSDictionary<NSString *, NSDictionary *> *others = [api latestVersionsForHashes:leftovers
                loaders:loaders gameVersion:mc versionTypes:nil];
            NSString *othersFailure = others ? nil : [NSString stringWithFormat:localize(@"mods.error.network", nil),
                api.lastError.localizedDescription ?: @""];

            NSMutableSet<NSString *> *noVersion = [NSMutableSet new];
            NSMutableArray<NSString *> *failures = [NSMutableArray new];
            for (NSString *fileName in fileNames) {
                NSString *title = titles[fileName] ?: fileName;
                NSString *sha1 = hashes[fileName] ?: @"";
                NSDictionary *version = VersionForHash(releases, sha1);
                if (!version && others) {
                    version = VersionForHash(others, sha1);
                }
                if (!version) {
                    if (othersFailure) {
                        [failures addObject:FailureLine(title, othersFailure)];
                    } else {
                        [noVersion addObject:fileName];
                    }
                    continue;
                }
                NSError *error = [flow installVersion:version title:title index:modIndex folder:folder
                    api:api knownTitles:knownTitles];
                if (error) {
                    [failures addObject:FailureLine(title, error.localizedDescription ?: @"")];
                }
            }
            // Queued before `done`'s own hop to the main queue, so the reload that `done` starts shows the notes.
            dispatch_async(dispatch_get_main_queue(), ^{
                weakSelf.noVersionFileNames = noVersion;
            });
            done(FailureSummary(failures, failureKey));
        });
    }];
}

/* The banner's button. */
- (void)bannerAction:(UIButton *)sender {
    if (self.busy) {
        return;
    }
    switch ([self currentBanner]) {
        case ModsBannerMismatch:
            [self actionSwitchAll];
            break;
        case ModsBannerUpdates:
            [self actionUpdateAll];
            break;
        case ModsBannerNone:
            break;
    }
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
    // The type the system knows for ".jar" (packs: ".zip") files; any file if it knows none
    // (importJarAtURL: checks the name).
    UTType *jarType = [UTType typeWithFilenameExtension:self.kind.fileExtension];
    NSArray<UTType *> *types = @[jarType ?: UTTypeData];
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
    NSString *extension = self.kind.fileExtension;
    NSString *fileName = url.lastPathComponent;
    if (![fileName.pathExtension.lowercaseString isEqualToString:extension]) {
        showDialog(localize(@"Error", nil), localize([self.kind stringKey:@"import.not_jar"], nil));
        return;
    }
    // The folder only lists lowercase ".jar" (packs: ".zip") files.
    if (![fileName.pathExtension isEqualToString:extension]) {
        fileName = [fileName.stringByDeletingPathExtension stringByAppendingPathExtension:extension];
    }

    NSString *path = [self.folder.modsDir stringByAppendingPathComponent:fileName];
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL clash = [fm fileExistsAtPath:path] || [fm fileExistsAtPath:[path stringByAppendingString:@".disabled"]];
    if (!clash) {
        [self importURL:url asFileName:fileName replace:NO keepBoth:NO];
        return;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:fileName
        message:localize([self.kind stringKey:@"import.exists"], nil) preferredStyle:UIAlertControllerStyleAlert];
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

/* Mismatched mods win over updates (spec §12b); nothing before the first reload. */
- (ModsBanner)currentBanner {
    if (!self.loadedOnce) {
        return ModsBannerNone;
    }
    if (self.mismatchedFileNames.count > 0) {
        return ModsBannerMismatch;
    }
    return self.availableUpdates.count > 0 ? ModsBannerUpdates : ModsBannerNone;
}

/* The banner, when there is one, is a section of its own above the mods. */
- (NSInteger)modsSection {
    return [self currentBanner] == ModsBannerNone ? 0 : 1;
}

- (nullable ModsRow *)modRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section != [self modsSection] || indexPath.row < 0 || indexPath.row >= (NSInteger)self.visibleRows.count) {
        return nil;
    }
    return self.visibleRows[indexPath.row];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.folder ? [self modsSection] + 1 : 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == [self modsSection] ? self.visibleRows.count : 1;
}

- (nullable NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (!self.loadedOnce || section != 0) {
        return nil;
    }
    return [self headerText];
}

/* "6 mods · Fabric 0.16.5 · 1.21.1" (no loader version when it is unknown); packs have no loader:
   "3 resource packs · 1.21.1". */
- (NSString *)headerText {
    NSUInteger count = self.rows.count;
    NSMutableArray<NSString *> *parts = [NSMutableArray new];
    [parts addObject:count == 1 ? localize([self.kind stringKey:@"header.count.one"], nil)
        : [NSString stringWithFormat:localize([self.kind stringKey:@"header.count.other"], nil), (int)count]];

    NSString *loader = self.kind.isMods ? self.info.loader : nil;
    NSString *loaderName = loader ? LoaderDisplayName(loader) : nil;
    if (loaderName) {
        NSString *loaderVersion = self.info.loaderVersion;
        [parts addObject:loaderVersion.length > 0 ? [NSString stringWithFormat:@"%@ %@", loaderName, loaderVersion] : loaderName];
    }
    if (self.gameVersion.length > 0) {
        [parts addObject:self.gameVersion];
    }
    return [parts componentsJoinedByString:@" · "];
}

/* "3 updates available" or "2 mods don't match Minecraft 1.21.4". */
- (NSString *)bannerText {
    if ([self currentBanner] == ModsBannerMismatch) {
        NSUInteger count = self.mismatchedFileNames.count;
        NSString *mc = self.gameVersion;
        return count == 1 ? [NSString stringWithFormat:localize([self.kind stringKey:@"banner.mismatch.one"], nil), mc]
            : [NSString stringWithFormat:localize([self.kind stringKey:@"banner.mismatch.other"], nil), (int)count, mc];
    }
    NSUInteger count = self.availableUpdates.count;
    return count == 1 ? localize(@"mods.banner.updates.one", nil)
        : [NSString stringWithFormat:localize(@"mods.banner.updates.other", nil), (int)count];
}

- (UITableViewCell *)bannerCellForTableView:(UITableView *)tableView {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kBannerCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:kBannerCellID];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.textLabel.numberOfLines = 0;
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        [button addTarget:self action:@selector(bannerAction:) forControlEvents:UIControlEventTouchUpInside];
        cell.accessoryView = button;
    }
    BOOL mismatch = [self currentBanner] == ModsBannerMismatch;
    cell.imageView.image = [UIImage systemImageNamed:mismatch ? @"exclamationmark.triangle.fill" : @"arrow.down.circle.fill"];
    cell.imageView.tintColor = mismatch ? UIColor.systemOrangeColor : UIColor.systemBlueColor;
    cell.textLabel.text = [self bannerText];

    UIButton *button = (UIButton *)cell.accessoryView;
    [button setTitle:localize(mismatch ? @"mods.banner.switch_all" : @"mods.banner.update_all", nil) forState:UIControlStateNormal];
    [button sizeToFit];
    button.enabled = !self.busy;
    return cell;
}

/* The version line: "0.6.0", "0.5.11 → 0.6.0" with an update, or "0.6.0 · Built for 1.21.1" (in orange)
   for a mod made for another Minecraft version or loader. */
- (nullable NSString *)subtitleForRow:(ModsRow *)row warning:(BOOL *)warning {
    *warning = NO;
    if (row.mismatched) {
        *warning = YES;
        NSString *note = [self.noVersionFileNames containsObject:row.fileName]
            ? [NSString stringWithFormat:localize(@"mods.row.no_version", nil), self.gameVersion]
            : [NSString stringWithFormat:localize(@"mods.row.built_for", nil), row.builtFor ?: @"?"];
        return row.subtitle ? [NSString stringWithFormat:@"%@ · %@", row.subtitle, note] : note;
    }
    if (row.update) {
        NSString *newVersion = StringOrNil(row.update[@"version_number"]) ?: StringOrNil(row.update[@"name"]) ?: @"?";
        return [NSString stringWithFormat:@"%@ → %@", row.subtitle ?: @"?", newVersion];
    }
    return row.subtitle;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModsRow *row = [self modRowAtIndexPath:indexPath];
    if (!row) {
        return [self bannerCellForTableView:tableView];
    }

    ModsCell *cell = (ModsCell *)[tableView dequeueReusableCellWithIdentifier:kModCellID];
    if (!cell) {
        cell = [[ModsCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kModCellID];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.imageView.frame = CGRectMake(0, 0, 40, 40);
        cell.imageView.isSizeFixed = YES;
        [cell.toggle addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
        [cell.updateButton addTarget:self action:@selector(updateTapped:) forControlEvents:UIControlEventTouchUpInside];
    }

    cell.textLabel.text = row.title;
    BOOL warning = NO;
    cell.detailTextLabel.text = [self subtitleForRow:row warning:&warning];
    cell.detailTextLabel.textColor = warning ? UIColor.systemOrangeColor : UIColor.secondaryLabelColor;
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

    // Folder packs cannot be switched off (renaming a folder does not hide it from the game).
    [cell setShowsUpdate:row.update != nil showsToggle:!row.isFolder];
    cell.updateButton.enabled = !self.busy;
    [cell.toggle setOn:row.enabled animated:NO];
    cell.toggle.enabled = !self.busy;
    cell.contentView.alpha = row.enabled ? 1 : kDisabledRowAlpha;
    return cell;
}

#pragma mark UITableViewDelegate

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    ModsRow *row = [self modRowAtIndexPath:indexPath];
    return row && [self projectIdOfRow:row] != nil;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ModsRow *row = [self modRowAtIndexPath:indexPath];
    if (row) {
        [self showDetailOfRow:row];
    }
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return !self.busy && [self modRowAtIndexPath:indexPath] != nil;
}

- (nullable UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModsRow *row = [self modRowAtIndexPath:indexPath];
    if (self.busy || !row) {
        return [UISwipeActionsConfiguration configurationWithActions:@[]];
    }
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
