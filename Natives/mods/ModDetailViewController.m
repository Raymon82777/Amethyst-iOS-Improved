#import "ModDependencyResolver.h"
#import "ModDetailViewController.h"
#import "ModInstaller.h"
#import "ModVersionSelector.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

NS_ASSUME_NONNULL_BEGIN

static void *kDetailBusyContext = &kDetailBusyContext;
static const CGFloat kHeroIconSize = 56;

/* `value` when it is a non-empty string. */
static NSString * _Nullable StringOrNil(id _Nullable value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

#pragma mark - Shared helpers

NSString * _Nullable ModIOSWarningForProject(NSString *projectId) {
    static NSDictionary *warnings;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSString *path = [NSBundle.mainBundle pathForResource:@"ios_mod_warnings" ofType:@"plist"];
        NSDictionary *loaded = path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
        warnings = [loaded isKindOfClass:NSDictionary.class] ? loaded : @{};
    });
    return projectId.length > 0 ? StringOrNil(warnings[projectId]) : nil;
}

NSString *ModFormattedDownloads(NSNumber * _Nullable downloads) {
    double count = [downloads isKindOfClass:NSNumber.class] ? downloads.doubleValue : 0;
    NSArray<NSArray *> *units = @[@[@1e9, @"B"], @[@1e6, @"M"], @[@1e3, @"K"]];
    for (NSArray *unit in units) {
        double size = [unit[0] doubleValue];
        if (count >= size) {
            double value = count / size;
            return [NSString stringWithFormat:value >= 10 ? @"%.0f%@" : @"%.1f%@", value, unit[1]];
        }
    }
    return [NSString stringWithFormat:@"%.0f", count];
}

UIView *ModTagView(NSString *text, UIColor *color) {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    label.textColor = color;

    UIView *tag = [UIView new];
    tag.translatesAutoresizingMaskIntoConstraints = NO;
    tag.backgroundColor = [color colorWithAlphaComponent:0.15];
    tag.layer.cornerRadius = 6;
    [tag addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:tag.leadingAnchor constant:6],
        [label.trailingAnchor constraintEqualToAnchor:tag.trailingAnchor constant:-6],
        [label.topAnchor constraintEqualToAnchor:tag.topAnchor constant:2],
        [label.bottomAnchor constraintEqualToAnchor:tag.bottomAnchor constant:-2]
    ]];
    return tag;
}

UIView * _Nullable ModTagsAccessoryView(NSArray<UIView *> *tags) {
    if (tags.count == 0) {
        return nil;
    }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:tags];
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 4;
    CGSize size = [stack systemLayoutSizeFittingSize:UILayoutFittingCompressedSize];
    stack.frame = CGRectMake(0, 0, ceil(size.width), ceil(size.height));
    return stack;
}

#pragma mark - Versions

static BOOL IsRelease(NSDictionary *version) {
    NSString *type = StringOrNil(version[@"version_type"]);
    return !type || [type isEqualToString:@"release"];
}

static NSString *VersionTypeLabel(NSDictionary *version) {
    NSString *type = StringOrNil(version[@"version_type"]);
    if ([type isEqualToString:@"beta"]) return localize(@"mods.version.beta", nil);
    if ([type isEqualToString:@"alpha"]) return localize(@"mods.version.alpha", nil);
    return localize(@"mods.version.release", nil);
}

static UIColor *VersionTypeColor(NSDictionary *version) {
    NSString *type = StringOrNil(version[@"version_type"]);
    if ([type isEqualToString:@"beta"]) return UIColor.systemOrangeColor;
    if ([type isEqualToString:@"alpha"]) return UIColor.systemRedColor;
    return UIColor.systemGreenColor;
}

static NSString *VersionNumber(NSDictionary *version) {
    return StringOrNil(version[@"version_number"]) ?: StringOrNil(version[@"name"]) ?: StringOrNil(version[@"id"]) ?: @"?";
}

/* "0.6.0", or "0.6.0-beta.3 (Beta)" when the best version is not a release. */
static NSString *ButtonVersionLabel(NSDictionary *version) {
    if (IsRelease(version)) {
        return VersionNumber(version);
    }
    return [NSString stringWithFormat:@"%@ (%@)", VersionNumber(version), VersionTypeLabel(version)];
}

static NSString * _Nullable PublishedDateText(NSDictionary *version) {
    NSString *published = StringOrNil(version[@"date_published"]);
    if (!published) return nil;
    static NSISO8601DateFormatter *fractional, *plain;
    static NSDateFormatter *display;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fractional = [NSISO8601DateFormatter new];
        fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        plain = [NSISO8601DateFormatter new];
        display = [NSDateFormatter new];
        display.dateStyle = NSDateFormatterMediumStyle;
        display.timeStyle = NSDateFormatterNoStyle;
    });
    NSDate *date = [fractional dateFromString:published] ?: [plain dateFromString:published];
    return date ? [display stringFromDate:date] : nil;
}

/* Project ids of the version's dependencies of `type` that name a project. */
static NSArray<NSString *> *DependencyProjectIds(NSDictionary *version, NSString *type) {
    id dependencies = version[@"dependencies"];
    if (![dependencies isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSString *> *ids = [NSMutableArray new];
    for (id dependency in (NSArray *)dependencies) {
        if (![dependency isKindOfClass:NSDictionary.class] || ![dependency[@"dependency_type"] isEqual:type]) continue;
        NSString *projectId = StringOrNil(dependency[@"project_id"]);
        if (projectId && ![ids containsObject:projectId]) [ids addObject:projectId];
    }
    return ids;
}

#pragma mark - Errors

static NSError *DisplayError(NSString *message, NSError * _Nullable underlying) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
    if (underlying) userInfo[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:underlying.domain ?: ModInstallErrorDomain code:underlying.code userInfo:userInfo];
}

static BOOL IsMissingDependency(NSError * _Nullable error) {
    return [error.domain isEqualToString:ModResolveErrorDomain] && error.code == ModResolveErrorMissingDependency;
}

/* Titles of Modrinth projects by id (one request; blocking). Projects it cannot find are left out. */
static NSDictionary<NSString *, NSString *> *ProjectTitles(NSArray<NSString *> *projectIds, ModrinthModsAPI *api) {
    if (projectIds.count == 0) return @{};
    NSDictionary<NSString *, NSDictionary *> *projects = [api projectsWithIds:projectIds];
    NSMutableDictionary<NSString *, NSString *> *titles = [NSMutableDictionary new];
    for (NSString *projectId in projects) {
        NSDictionary *project = projects[projectId];
        NSString *title = [project isKindOfClass:NSDictionary.class] ? StringOrNil(project[@"title"]) : nil;
        if (title) titles[projectId] = title;
    }
    return titles;
}

/* What to tell the user when no plan could be made (blocking: may look up the missing mod's title). */
static NSString *ResolveErrorMessage(NSError * _Nullable error, ModrinthModsAPI *api,
                                     NSDictionary<NSString *, NSString *> *knownTitles, NSString *profileName) {
    if (IsMissingDependency(error)) {
        NSString *projectId = StringOrNil(error.userInfo[@"projectId"]) ?: @"?";
        NSString *title = knownTitles[projectId] ?: ProjectTitles(@[projectId], api)[projectId] ?: projectId;
        return [NSString stringWithFormat:localize(@"mods.error.missing_dependency", nil), title, profileName];
    }
    return error.localizedDescription ?: localize(@"Error", nil);
}

#pragma mark - Fetch cache

/* Remembers Modrinth's answers while the page is open, so working the plan out again when installing
   costs no extra requests. Thread-safe. */
@interface ModFetchCache : NSObject
@property(nonatomic) NSMutableDictionary<NSString *, NSArray<NSDictionary *> *> *projectVersions;
@property(nonatomic) NSMutableDictionary<NSString *, NSDictionary *> *versions;
@end

@implementation ModFetchCache

- (instancetype)init {
    self = [super init];
    _projectVersions = [NSMutableDictionary new];
    _versions = [NSMutableDictionary new];
    return self;
}

- (void)setVersions:(NSArray<NSDictionary *> *)versions ofProject:(NSString *)projectId {
    @synchronized (self) {
        self.projectVersions[projectId] = versions;
    }
}

- (ModFetchProjectVersions)projectVersionsFetcherWithAPI:(ModrinthModsAPI *)api loaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc {
    return ^NSArray<NSDictionary *> * _Nullable(NSString *projectId) {
        NSArray<NSDictionary *> *cached;
        @synchronized (self) {
            cached = self.projectVersions[projectId];
        }
        if (cached) return cached;
        NSArray<NSDictionary *> *fetched = [api versionsOfProject:projectId loaders:loaders gameVersion:mc];
        if (fetched) {
            [self setVersions:fetched ofProject:projectId];
        }
        return fetched;
    };
}

- (ModFetchVersion)versionFetcherWithAPI:(ModrinthModsAPI *)api {
    return ^NSDictionary * _Nullable(NSString *versionId) {
        NSDictionary *cached;
        @synchronized (self) {
            cached = self.versions[versionId];
        }
        if (cached) return cached;
        NSDictionary *fetched = [api versionWithId:versionId];
        if (fetched) {
            @synchronized (self) {
                self.versions[versionId] = fetched;
            }
        }
        return fetched;
    };
}

@end

#pragma mark - Installed state

/* Which Modrinth projects the profile has, from the record plus the files' enabled state. */
@interface ModInstalledState : NSObject
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *enabledByProject; // what the resolver takes
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *versionIdByProject;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *titleByProject;
@end

@implementation ModInstalledState

- (BOOL)isEqual:(nullable id)other {
    if (self == other) return YES;
    if (![other isKindOfClass:ModInstalledState.class]) return NO;
    ModInstalledState *state = other;
    return [self.enabledByProject isEqualToDictionary:state.enabledByProject]
        && [self.versionIdByProject isEqualToDictionary:state.versionIdByProject]
        && [self.titleByProject isEqualToDictionary:state.titleByProject];
}

- (NSUInteger)hash {
    return self.enabledByProject.hash;
}

@end

/* `enabledByFileName` maps the jars on disk (names without ".disabled") to @(enabled); record entries
   without a file are ignored. Must only run while nothing else uses `index`. */
static ModInstalledState *InstalledStateOf(ModIndex *index, NSDictionary<NSString *, NSNumber *> *enabledByFileName) {
    NSMutableDictionary<NSString *, NSNumber *> *enabled = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSString *> *versionIds = [NSMutableDictionary new];
    NSMutableDictionary<NSString *, NSString *> *titles = [NSMutableDictionary new];
    // Sorted, so two files of one project always give the same answer.
    for (NSString *fileName in [index.entries.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSNumber *isEnabled = enabledByFileName[fileName];
        NSString *projectId = StringOrNil(index.entries[fileName][@"projectId"]);
        if (!isEnabled || !projectId) continue;
        if (enabled[projectId].boolValue && !isEnabled.boolValue) continue; // an enabled copy wins
        enabled[projectId] = isEnabled;
        NSDictionary *entry = index.entries[fileName];
        NSString *versionId = StringOrNil(entry[@"versionId"]);
        NSString *title = StringOrNil(entry[@"title"]);
        if (versionId) versionIds[projectId] = versionId; else [versionIds removeObjectForKey:projectId];
        if (title) titles[projectId] = title;
    }
    ModInstalledState *state = [ModInstalledState new];
    state.enabledByProject = enabled;
    state.versionIdByProject = versionIds;
    state.titleByProject = titles;
    return state;
}

#pragma mark - Rows

typedef NS_ENUM(NSInteger, ModDetailRowKind) {
    ModDetailRowHeader,
    ModDetailRowDescription,
    ModDetailRowStatus,
    ModDetailRowInstall,
    ModDetailRowNote,
    ModDetailRowVersion,
    ModDetailRowLink
};

@interface ModDetailRow : NSObject
@property(nonatomic) ModDetailRowKind kind;
@property(nonatomic, copy, nullable) NSString *text;
@property(nonatomic, copy, nullable) NSString *detail;
@property(nonatomic, nullable) UIColor *color;
@property(nonatomic, nullable) NSDictionary *version;
@property(nonatomic) BOOL spinner;
@property(nonatomic) BOOL enabled;
@end

@implementation ModDetailRow
+ (instancetype)rowOfKind:(ModDetailRowKind)kind text:(nullable NSString *)text {
    ModDetailRow *row = [self new];
    row.kind = kind;
    row.text = text;
    return row;
}
@end

@interface ModDetailSection : NSObject
@property(nonatomic, copy, nullable) NSString *title;
@property(nonatomic, copy) NSArray<ModDetailRow *> *rows;
@end

@implementation ModDetailSection
+ (instancetype)sectionWithTitle:(nullable NSString *)title rows:(NSArray<ModDetailRow *> *)rows {
    ModDetailSection *section = [self new];
    section.title = title;
    section.rows = rows;
    return section;
}
@end

#pragma mark - ModDetailViewController

@interface ModDetailViewController ()
@property(nonatomic) ModsViewController *mods;
@property(nonatomic, copy) NSString *projectId;
/* title, description, author, downloads, imageUrl, slug (from the search hit or the loaded project). */
@property(nonatomic, copy) NSDictionary *projectInfo;
@property(nonatomic) ModFetchCache *fetchCache;

@property(nonatomic) BOOL loading;
@property(nonatomic, copy, nullable) NSString *loadError;
@property(nonatomic, copy) NSArray<NSDictionary *> *compatibleVersions;
@property(nonatomic, nullable) NSDictionary *bestVersion;

/* Last state read while the Mods screen was idle; nil until then. */
@property(nonatomic, nullable) ModInstalledState *installed;
/* The dry run of the best version, for the dependency lines. */
@property(nonatomic, nullable) ModInstalledState *dryRunInstalled; // the state it ran with
@property(nonatomic) NSUInteger dryRunGeneration;
@property(nonatomic, nullable) ModInstallPlan *dryRunPlan;
@property(nonatomic, nullable) NSError *dryRunError;
@property(nonatomic) NSMutableDictionary<NSString *, NSString *> *titles; // project id -> title

@property(nonatomic) BOOL preparing; // working out the plan after a tap on Install
@property(nonatomic, copy) NSArray<ModDetailSection *> *sections;
@end

@implementation ModDetailViewController

- (instancetype)initWithModsController:(ModsViewController *)mods projectId:(NSString *)projectId hit:(nullable NSDictionary *)hit {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    _mods = mods;
    _projectId = [projectId copy];
    _projectInfo = [hit copy] ?: @{};
    _fetchCache = [ModFetchCache new];
    _compatibleVersions = @[];
    _titles = [NSMutableDictionary new];
    _sections = @[];
    _loading = YES;
    [mods addObserver:self forKeyPath:@"busy" options:0 context:kDetailBusyContext];
    return self;
}

- (void)dealloc {
    [_mods removeObserver:self forKeyPath:@"busy" context:kDetailBusyContext];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = [self projectTitle];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 44;
    [self refreshInstalledState];
    [self loadProject];
}

- (void)observeValueForKeyPath:(nullable NSString *)keyPath ofObject:(nullable id)object
                        change:(nullable NSDictionary<NSKeyValueChangeKey, id> *)change context:(nullable void *)context {
    if (context != kDetailBusyContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    __weak ModDetailViewController *weakSelf = self;
    void (^update)(void) = ^{
        ModDetailViewController *strongSelf = weakSelf;
        if (!strongSelf || !strongSelf.isViewLoaded) return;
        [strongSelf refreshInstalledState];
        [strongSelf reloadRows];
    };
    // `busy` changes on the main queue; hop there in case that ever changes.
    if (NSThread.isMainThread) {
        update();
    } else {
        dispatch_async(dispatch_get_main_queue(), update);
    }
}

#pragma mark Loading

- (NSString *)projectTitle {
    return StringOrNil(self.projectInfo[@"title"]) ?: self.installed.titleByProject[self.projectId] ?: self.projectId;
}

- (NSString *)titleOfProject:(NSString *)projectId {
    return self.titles[projectId] ?: self.installed.titleByProject[projectId] ?: projectId;
}

- (void)loadProject {
    self.loading = YES;
    self.loadError = nil;
    [self reloadRows];

    NSString *projectId = self.projectId;
    BOOL needsProject = StringOrNil(self.projectInfo[@"title"]) == nil;
    NSArray<NSString *> *loaders = self.mods.info.acceptedLoaders;
    NSString *mc = self.mods.info.minecraftVersion ?: @"";
    __weak ModDetailViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Its own client, so it never races the Mods screen's requests.
        ModrinthModsAPI *api = [ModrinthModsAPI new];
        NSDictionary *project;
        NSString *failure;
        if (needsProject) {
            NSDictionary<NSString *, NSDictionary *> *projects = [api projectsWithIds:@[projectId]];
            if (projects) {
                project = projects[projectId];
            } else {
                failure = api.lastError.localizedDescription ?: @"";
            }
        }
        NSArray<NSDictionary *> *versions = failure ? nil : [api versionsOfProject:projectId loaders:loaders gameVersion:mc];
        if (!failure && !versions) {
            failure = api.lastError.localizedDescription ?: @"";
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            ModDetailViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.loading = NO;
            if (failure) {
                strongSelf.loadError = failure;
                [strongSelf reloadRows];
                return;
            }
            if ([project isKindOfClass:NSDictionary.class]) {
                [strongSelf takeProject:project];
            }
            [strongSelf.fetchCache setVersions:versions ofProject:projectId];
            strongSelf.compatibleVersions = [ModVersionSelector compatibleVersionsNewestFirst:versions loaders:loaders gameVersion:mc];
            strongSelf.bestVersion = [ModVersionSelector bestVersionIn:versions loaders:loaders gameVersion:mc];
            strongSelf.title = [strongSelf projectTitle];
            [strongSelf startDryRunIfNeeded];
            [strongSelf reloadRows];
        });
    });
}

/* Fills in what the search hit did not have from a Modrinth project object. */
- (void)takeProject:(NSDictionary *)project {
    NSMutableDictionary *info = [self.projectInfo mutableCopy];
    NSDictionary *mapping = @{@"title": @"title", @"description": @"description", @"slug": @"slug", @"imageUrl": @"icon_url"};
    for (NSString *key in mapping) {
        NSString *value = StringOrNil(project[mapping[key]]);
        if (!info[key] && value) info[key] = value;
    }
    if (!info[@"downloads"] && [project[@"downloads"] isKindOfClass:NSNumber.class]) {
        info[@"downloads"] = project[@"downloads"];
    }
    self.projectInfo = info;
}

/* Re-reads what is installed, but only while the Mods screen is idle (otherwise keeps the last state;
   this runs again when it goes idle). */
- (void)refreshInstalledState {
    ModsViewController *mods = self.mods;
    ModIndex *modIndex = mods.index;
    ModFolder *folder = mods.folder;
    if (mods.busy || !modIndex || !folder) {
        return;
    }
    // Only looks at the files (no scan: scanning deletes *.part files, which belongs to operations).
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableDictionary<NSString *, NSNumber *> *enabledByFileName = [NSMutableDictionary new];
    for (NSString *fileName in modIndex.entries) {
        NSString *path = [folder.modsDir stringByAppendingPathComponent:fileName];
        if ([fm fileExistsAtPath:path]) {
            enabledByFileName[fileName] = @YES;
        } else if ([fm fileExistsAtPath:[path stringByAppendingString:@".disabled"]]) {
            enabledByFileName[fileName] = @NO;
        }
    }
    ModInstalledState *state = InstalledStateOf(modIndex, enabledByFileName);
    if (![state isEqual:self.installed]) {
        self.installed = state;
        if (self.isViewLoaded) self.title = [self projectTitle];
        [self startDryRunIfNeeded];
    }
}

/* Works out what installing the best version would bring in, for the lines under the button. */
- (void)startDryRunIfNeeded {
    ModInstalledState *state = self.installed;
    NSDictionary *version = self.bestVersion;
    if (!state || !version || self.dryRunInstalled == state) {
        return;
    }
    self.dryRunInstalled = state;
    NSUInteger generation = ++self.dryRunGeneration;

    NSArray<NSString *> *loaders = self.mods.info.acceptedLoaders;
    NSString *mc = self.mods.info.minecraftVersion ?: @"";
    ModFetchCache *cache = self.fetchCache;
    __weak ModDetailViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ModrinthModsAPI *api = [ModrinthModsAPI new];
        ModDependencyResolver *resolver = [[ModDependencyResolver alloc] initWithLoaders:loaders gameVersion:mc
            installedProjects:state.enabledByProject
            fetchProjectVersions:[cache projectVersionsFetcherWithAPI:api loaders:loaders gameVersion:mc]
            fetchVersion:[cache versionFetcherWithAPI:api]];
        NSError *error;
        ModInstallPlan *plan = [resolver planForVersion:version error:&error];

        NSMutableArray<NSString *> *ids = [NSMutableArray new];
        if (plan) {
            for (NSDictionary *each in plan.versionsToInstall) {
                NSString *projectId = StringOrNil(each[@"project_id"]);
                if (projectId) [ids addObject:projectId];
            }
            [ids addObjectsFromArray:plan.projectIdsToEnable];
            [ids addObjectsFromArray:plan.incompatibleInstalledProjectIds];
            [ids addObjectsFromArray:plan.optionalProjectIds];
            [ids addObjectsFromArray:DependencyProjectIds(version, @"required")];
        } else if (IsMissingDependency(error)) {
            NSString *missing = StringOrNil(error.userInfo[@"projectId"]);
            if (missing) [ids addObject:missing];
        }
        NSDictionary<NSString *, NSString *> *titles = ProjectTitles(ids, api);

        dispatch_async(dispatch_get_main_queue(), ^{
            ModDetailViewController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.dryRunGeneration) return;
            strongSelf.dryRunPlan = plan;
            strongSelf.dryRunError = plan ? nil : error;
            [strongSelf.titles addEntriesFromDictionary:titles];
            [strongSelf reloadRows];
        });
    });
}

#pragma mark Rows

- (nullable NSString *)installedVersionId {
    return self.installed.versionIdByProject[self.projectId];
}

- (BOOL)canStartInstall {
    ModsViewController *mods = self.mods;
    return !mods.busy && !self.preparing && self.installed && mods.folder && mods.index;
}

- (NSString *)titlesOf:(NSArray<NSString *> *)projectIds {
    NSMutableArray<NSString *> *titles = [NSMutableArray new];
    for (NSString *projectId in projectIds) {
        [titles addObject:[self titleOfProject:projectId]];
    }
    return [titles componentsJoinedByString:@", "];
}

/* The lines under the Install button. */
- (NSArray<ModDetailRow *> *)noteRows {
    NSMutableArray<ModDetailRow *> *rows = [NSMutableArray new];
    void (^add)(NSString *, UIColor *) = ^(NSString *text, UIColor *color) {
        ModDetailRow *row = [ModDetailRow rowOfKind:ModDetailRowNote text:text];
        row.color = color;
        [rows addObject:row];
    };

    NSString *warning = ModIOSWarningForProject(self.projectId);
    if (warning) {
        add([NSString stringWithFormat:localize(@"mods.detail.ios_warning", nil), warning], UIColor.systemOrangeColor);
    }
    if (!self.bestVersion) {
        return rows;
    }
    if (IsMissingDependency(self.dryRunError)) {
        NSString *missing = StringOrNil(self.dryRunError.userInfo[@"projectId"]) ?: @"?";
        add([NSString stringWithFormat:localize(@"mods.error.missing_dependency", nil),
            [self titleOfProject:missing], self.mods.info.displayName], UIColor.systemRedColor);
        return rows;
    }
    ModInstallPlan *plan = self.dryRunPlan;
    if (!plan) {
        return rows;
    }

    NSMutableArray<NSString *> *alsoInstalls = [NSMutableArray new];
    for (NSUInteger i = 1; i < plan.versionsToInstall.count; i++) {
        NSString *projectId = StringOrNil(plan.versionsToInstall[i][@"project_id"]);
        if (projectId && ![alsoInstalls containsObject:projectId]) [alsoInstalls addObject:projectId];
    }
    NSMutableArray<NSString *> *alreadyInstalled = [NSMutableArray new];
    for (NSString *projectId in DependencyProjectIds(self.bestVersion, @"required")) {
        if (![projectId isEqualToString:self.projectId] && self.installed.enabledByProject[projectId].boolValue) {
            [alreadyInstalled addObject:projectId];
        }
    }

    UIColor *secondary = UIColor.secondaryLabelColor;
    if (alsoInstalls.count > 0) {
        add([NSString stringWithFormat:localize(@"mods.detail.also_installs", nil), [self titlesOf:alsoInstalls]], secondary);
    }
    if (plan.projectIdsToEnable.count > 0) {
        add([NSString stringWithFormat:localize(@"mods.detail.turns_on", nil), [self titlesOf:plan.projectIdsToEnable]], secondary);
    }
    if (alreadyInstalled.count > 0) {
        add([NSString stringWithFormat:localize(@"mods.detail.already_installed", nil), [self titlesOf:alreadyInstalled]], secondary);
    }
    if (plan.incompatibleInstalledProjectIds.count > 0) {
        add([NSString stringWithFormat:localize(@"mods.detail.conflicts", nil), [self titlesOf:plan.incompatibleInstalledProjectIds]], UIColor.systemOrangeColor);
    }
    if (plan.optionalProjectIds.count > 0) {
        add([NSString stringWithFormat:localize(@"mods.detail.works_with", nil), [self titlesOf:plan.optionalProjectIds]], secondary);
    }
    return rows;
}

- (ModDetailRow *)installRow {
    ModDetailRow *row = [ModDetailRow rowOfKind:ModDetailRowInstall text:nil];
    NSString *label = ButtonVersionLabel(self.bestVersion);
    NSString *installedVersionId = [self installedVersionId];
    BOOL isInstalled = self.installed.enabledByProject[self.projectId] != nil;
    if (installedVersionId && [installedVersionId isEqualToString:StringOrNil(self.bestVersion[@"id"])]) {
        row.text = localize(@"mods.detail.installed", nil);
        row.enabled = NO;
    } else {
        row.text = [NSString stringWithFormat:localize(isInstalled ? @"mods.detail.update" : @"mods.detail.install", nil), label];
        row.enabled = [self canStartInstall];
    }
    row.spinner = self.preparing || self.mods.busy;
    return row;
}

- (void)rebuildSections {
    NSMutableArray<ModDetailSection *> *sections = [NSMutableArray new];

    NSMutableArray<ModDetailRow *> *hero = [NSMutableArray arrayWithObject:[ModDetailRow rowOfKind:ModDetailRowHeader text:[self projectTitle]]];
    NSString *description = StringOrNil(self.projectInfo[@"description"]);
    if (description) {
        [hero addObject:[ModDetailRow rowOfKind:ModDetailRowDescription text:description]];
    }
    [sections addObject:[ModDetailSection sectionWithTitle:nil rows:hero]];

    NSMutableArray<ModDetailRow *> *install = [NSMutableArray new];
    if (self.loading) {
        ModDetailRow *row = [ModDetailRow rowOfKind:ModDetailRowStatus text:localize(@"mods.detail.loading", nil)];
        row.spinner = YES;
        [install addObject:row];
    } else if (self.loadError) {
        ModDetailRow *row = [ModDetailRow rowOfKind:ModDetailRowStatus
            text:[NSString stringWithFormat:localize(@"mods.detail.load_error", nil), self.loadError]];
        row.detail = localize(@"mods.detail.retry", nil);
        row.enabled = YES; // tap to try again
        [install addObject:row];
    } else if (!self.bestVersion) {
        [install addObject:[ModDetailRow rowOfKind:ModDetailRowStatus
            text:[NSString stringWithFormat:localize(@"mods.detail.no_version", nil), self.mods.info.displayName]]];
    } else {
        [install addObject:[self installRow]];
    }
    [install addObjectsFromArray:[self noteRows]];
    [sections addObject:[ModDetailSection sectionWithTitle:nil rows:install]];

    if (self.compatibleVersions.count > 0) {
        NSString *installedVersionId = [self installedVersionId];
        BOOL canInstall = [self canStartInstall];
        NSMutableArray<ModDetailRow *> *versions = [NSMutableArray new];
        for (NSDictionary *version in self.compatibleVersions) {
            ModDetailRow *row = [ModDetailRow rowOfKind:ModDetailRowVersion text:VersionNumber(version)];
            row.detail = PublishedDateText(version);
            row.version = version;
            BOOL isInstalled = installedVersionId && [installedVersionId isEqualToString:StringOrNil(version[@"id"])];
            row.enabled = canInstall && !isInstalled;
            [versions addObject:row];
        }
        [sections addObject:[ModDetailSection sectionWithTitle:
            [NSString stringWithFormat:localize(@"mods.detail.versions", nil), self.mods.info.displayName] rows:versions]];
    }

    ModDetailRow *link = [ModDetailRow rowOfKind:ModDetailRowLink text:localize(@"mods.detail.view_on_modrinth", nil)];
    link.enabled = YES;
    [sections addObject:[ModDetailSection sectionWithTitle:nil rows:@[link]]];
    self.sections = sections;
}

- (void)reloadRows {
    if (!self.isViewLoaded) return;
    [self rebuildSections];
    [self.tableView reloadData];
}

#pragma mark Install

- (void)confirmWithTitle:(NSString *)title message:(NSString *)message then:(void (^)(void))confirmed {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"mods.action.install_anyway", nil) style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *action) {
            confirmed();
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}

/* Install (or switch to) `version`: confirm the iOS warning, work out the plan to confirm conflicts, then
   install as an operation of the Mods screen. */
- (void)installVersion:(NSDictionary *)version {
    if (![self canStartInstall]) {
        return;
    }
    NSString *warning = ModIOSWarningForProject(self.projectId);
    if (!warning) {
        [self prepareInstallOfVersion:version];
        return;
    }
    __weak ModDetailViewController *weakSelf = self;
    [self confirmWithTitle:[self projectTitle]
        message:[NSString stringWithFormat:localize(@"mods.alert.ios_warning", nil), [self projectTitle], warning]
        then:^{
            [weakSelf prepareInstallOfVersion:version];
        }];
}

/* Resolves `version` against what is installed now (the Mods screen is idle, so the record may be read)
   to find conflicts to ask about, then starts the install. */
- (void)prepareInstallOfVersion:(NSDictionary *)version {
    [self refreshInstalledState];
    if (![self canStartInstall]) {
        return;
    }
    ModInstalledState *state = self.installed;
    self.preparing = YES;
    [self reloadRows];

    NSArray<NSString *> *loaders = self.mods.info.acceptedLoaders;
    NSString *mc = self.mods.info.minecraftVersion ?: @"";
    NSString *profileName = self.mods.info.displayName;
    ModFetchCache *cache = self.fetchCache;
    NSDictionary<NSString *, NSString *> *knownTitles = [self.titles copy];
    __weak ModDetailViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        ModrinthModsAPI *api = [ModrinthModsAPI new];
        ModDependencyResolver *resolver = [[ModDependencyResolver alloc] initWithLoaders:loaders gameVersion:mc
            installedProjects:state.enabledByProject
            fetchProjectVersions:[cache projectVersionsFetcherWithAPI:api loaders:loaders gameVersion:mc]
            fetchVersion:[cache versionFetcherWithAPI:api]];
        NSError *error;
        ModInstallPlan *plan = [resolver planForVersion:version error:&error];
        NSString *failure = plan ? nil : ResolveErrorMessage(error, api, knownTitles, profileName);
        NSArray<NSString *> *conflicts = plan.incompatibleInstalledProjectIds ?: @[];
        NSDictionary<NSString *, NSString *> *titles = ProjectTitles(conflicts, api);

        dispatch_async(dispatch_get_main_queue(), ^{
            ModDetailViewController *strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf.preparing = NO;
            [strongSelf.titles addEntriesFromDictionary:titles];
            [strongSelf reloadRows];
            if (failure) {
                showDialog(localize(@"Error", nil), failure);
                return;
            }
            if (conflicts.count == 0) {
                [strongSelf startInstallOfVersion:version];
                return;
            }
            [strongSelf confirmWithTitle:[strongSelf projectTitle]
                message:[NSString stringWithFormat:localize(@"mods.alert.incompatible", nil),
                    [strongSelf projectTitle], [strongSelf titlesOf:conflicts]]
                then:^{
                    [weakSelf startInstallOfVersion:version];
                }];
        });
    });
}

/* The install itself, as one operation of the Mods screen: re-reads the installed state (now that the
   operation owns the folder), resolves again (answers are cached), loads the projects, installs. */
- (void)startInstallOfVersion:(NSDictionary *)version {
    ModsViewController *mods = self.mods;
    ModIndex *modIndex = mods.index;
    ModFolder *folder = mods.folder;
    // The Mods screen may have started something while an alert was up.
    if (mods.busy || !modIndex || !folder) {
        return;
    }
    ModrinthModsAPI *api = mods.api;
    NSArray<NSString *> *loaders = mods.info.acceptedLoaders;
    NSString *mc = mods.info.minecraftVersion ?: @"";
    NSString *profileName = mods.info.displayName;
    NSString *rootTitle = [self projectTitle];
    ModFetchCache *cache = self.fetchCache;
    NSDictionary<NSString *, NSString *> *knownTitles = [self.titles copy];
    __weak ModDetailViewController *weakSelf = self;
    [mods runOperation:^(void (^done)(NSError * _Nullable)) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSMutableDictionary<NSString *, NSNumber *> *enabledByFileName = [NSMutableDictionary new];
            for (ModJar *jar in [folder scanJars]) {
                enabledByFileName[jar.fileName] = @(jar.enabled);
            }
            ModInstalledState *state = InstalledStateOf(modIndex, enabledByFileName);
            ModDependencyResolver *resolver = [[ModDependencyResolver alloc] initWithLoaders:loaders gameVersion:mc
                installedProjects:state.enabledByProject
                fetchProjectVersions:[cache projectVersionsFetcherWithAPI:api loaders:loaders gameVersion:mc]
                fetchVersion:[cache versionFetcherWithAPI:api]];
            NSError *resolveError;
            ModInstallPlan *plan = [resolver planForVersion:version error:&resolveError];
            if (!plan) {
                done(DisplayError(ResolveErrorMessage(resolveError, api, knownTitles, profileName), resolveError));
                return;
            }

            NSMutableArray<NSString *> *projectIds = [NSMutableArray new];
            for (NSDictionary *each in plan.versionsToInstall) {
                NSString *projectId = StringOrNil(each[@"project_id"]);
                if (projectId) [projectIds addObject:projectId];
            }
            NSDictionary<NSString *, NSDictionary *> *projects = [api projectsWithIds:projectIds];
            if (!projects) {
                NSString *reason = api.lastError.localizedDescription ?: @"";
                done(DisplayError([NSString stringWithFormat:localize(@"mods.error.network", nil), reason], api.lastError));
                return;
            }

            ModInstaller *installer = [[ModInstaller alloc] initWithIndex:modIndex downloader:[ModInstaller defaultDownloader]];
            [installer installPlan:plan projects:projects completion:^(NSError * _Nullable error) {
                if (error) {
                    NSString *fileName = StringOrNil(error.userInfo[@"fileName"]) ?: rootTitle;
                    done(DisplayError([NSString stringWithFormat:localize(@"mods.error.install", nil),
                        fileName, error.localizedDescription ?: @""], error));
                    return;
                }
                done(nil);
                // Queued after `done`'s own hop to the main queue, so the list reload has started.
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf installFinished];
                });
            }];
        });
    }];
}

/* Back to the installed list: pop to it, or close Browse when this page is shown there. */
- (void)installFinished {
    UINavigationController *navigationController = self.navigationController;
    if (!navigationController) {
        return;
    }
    if ([navigationController.viewControllers containsObject:self.mods]) {
        [navigationController popToViewController:self.mods animated:YES];
    } else if (navigationController.presentingViewController) {
        [navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
    }
}

- (void)openOnModrinth {
    NSString *slug = StringOrNil(self.projectInfo[@"slug"]) ?: self.projectId;
    NSMutableCharacterSet *allowed = NSCharacterSet.URLPathAllowedCharacterSet.mutableCopy;
    [allowed removeCharactersInString:@"/"];
    NSString *escaped = [slug stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: slug;
    NSURL *url = [NSURL URLWithString:[@"https://modrinth.com/mod/" stringByAppendingString:escaped]];
    if (url) {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
}

#pragma mark UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.sections[section].rows.count;
}

- (nullable NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.sections[section].title;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ModDetailRow *row = self.sections[indexPath.section].rows[indexPath.row];
    NSString *identifier = [NSString stringWithFormat:@"ModDetail%ld", (long)row.kind];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:identifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:identifier];
        cell.textLabel.numberOfLines = 0;
        cell.detailTextLabel.numberOfLines = 0;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        if (row.kind == ModDetailRowHeader) {
            cell.imageView.frame = CGRectMake(0, 0, kHeroIconSize, kHeroIconSize);
            cell.imageView.isSizeFixed = YES;
            cell.imageView.layer.cornerRadius = 10;
            cell.imageView.clipsToBounds = YES;
        }
    }
    cell.textLabel.text = row.text;
    cell.detailTextLabel.text = row.detail;
    cell.textLabel.textAlignment = NSTextAlignmentNatural;
    cell.textLabel.textColor = UIColor.labelColor;
    cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    cell.selectionStyle = row.enabled ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.accessoryView = nil;
    if (row.spinner) {
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
    }

    switch (row.kind) {
        case ModDetailRowHeader: {
            cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle3];
            NSMutableArray<NSString *> *parts = [NSMutableArray new];
            NSString *author = StringOrNil(self.projectInfo[@"author"]);
            if (author) {
                [parts addObject:[NSString stringWithFormat:localize(@"mods.detail.by", nil), author]];
            }
            if ([self.projectInfo[@"downloads"] isKindOfClass:NSNumber.class]) {
                [parts addObject:[NSString stringWithFormat:localize(@"mods.detail.downloads", nil),
                    ModFormattedDownloads(self.projectInfo[@"downloads"])]];
            }
            cell.detailTextLabel.text = parts.count > 0 ? [parts componentsJoinedByString:@" · "] : nil;
            UIImage *placeholder = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(kHeroIconSize, kHeroIconSize)];
            NSString *iconUrl = StringOrNil(self.projectInfo[@"imageUrl"]);
            NSURL *url = iconUrl ? [NSURL URLWithString:iconUrl] : nil;
            if (url) {
                [cell.imageView setImageWithURL:url placeholderImage:placeholder];
            } else {
                [cell.imageView cancelImageDownloadTask];
                cell.imageView.image = placeholder;
            }
            break;
        }
        case ModDetailRowDescription:
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
            break;
        case ModDetailRowStatus:
            cell.textLabel.textColor = UIColor.secondaryLabelColor;
            break;
        case ModDetailRowInstall:
            cell.textLabel.textAlignment = NSTextAlignmentCenter;
            cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
            cell.textLabel.textColor = row.enabled ? self.view.tintColor : UIColor.secondaryLabelColor;
            break;
        case ModDetailRowNote:
            cell.textLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
            cell.textLabel.textColor = row.color ?: UIColor.secondaryLabelColor;
            break;
        case ModDetailRowVersion: {
            NSDictionary *version = row.version ?: @{};
            NSMutableArray<UIView *> *tags = [NSMutableArray arrayWithObject:ModTagView(VersionTypeLabel(version), VersionTypeColor(version))];
            NSString *installedVersionId = [self installedVersionId];
            if (installedVersionId && [installedVersionId isEqualToString:StringOrNil(version[@"id"])]) {
                [tags addObject:ModTagView(localize(@"mods.tag.installed", nil), UIColor.secondaryLabelColor)];
            }
            cell.accessoryView = ModTagsAccessoryView(tags);
            break;
        }
        case ModDetailRowLink:
            cell.textLabel.textColor = self.view.tintColor;
            cell.accessoryView = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.up.right.square"]];
            break;
    }
    return cell;
}

#pragma mark UITableViewDelegate

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return self.sections[indexPath.section].rows[indexPath.row].enabled;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    ModDetailRow *row = self.sections[indexPath.section].rows[indexPath.row];
    if (!row.enabled) {
        return;
    }
    switch (row.kind) {
        case ModDetailRowInstall:
            if (self.bestVersion) [self installVersion:self.bestVersion];
            break;
        case ModDetailRowVersion:
            if (row.version) [self installVersion:row.version];
            break;
        case ModDetailRowStatus:
            if (self.loadError) [self loadProject];
            break;
        case ModDetailRowLink:
            [self openOnModrinth];
            break;
        default:
            break;
    }
}

@end

NS_ASSUME_NONNULL_END
