#import "ModInstallFlow.h"
#import "ModInstaller.h"
#import "utils.h"

NS_ASSUME_NONNULL_BEGIN

/* `value` when it is a non-empty string. */
static NSString * _Nullable StringOrNil(id _Nullable value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

#pragma mark - Errors

BOOL ModIsMissingDependency(NSError * _Nullable error) {
    return [error.domain isEqualToString:ModResolveErrorDomain] && error.code == ModResolveErrorMissingDependency;
}

NSError *ModDisplayError(NSString *message, NSError * _Nullable underlying) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
    if (underlying) userInfo[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:underlying.domain ?: ModInstallErrorDomain code:underlying.code userInfo:userInfo];
}

NSDictionary<NSString *, NSString *> *ModProjectTitles(NSArray<NSString *> *projectIds, ModrinthModsAPI *api) {
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

NSString *ModResolveErrorMessage(NSError * _Nullable error, ModrinthModsAPI *api,
                                 NSDictionary<NSString *, NSString *> *knownTitles, NSString *profileName) {
    if (ModIsMissingDependency(error)) {
        NSString *projectId = StringOrNil(error.userInfo[@"projectId"]) ?: @"?";
        NSString *title = knownTitles[projectId] ?: ModProjectTitles(@[projectId], api)[projectId] ?: projectId;
        return [NSString stringWithFormat:localize(@"mods.error.missing_dependency", nil), title, profileName];
    }
    return error.localizedDescription ?: localize(@"Error", nil);
}

#pragma mark - ModFetchCache

@interface ModFetchCache ()
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

#pragma mark - ModInstalledState

@implementation ModInstalledState

+ (instancetype)stateOfIndex:(ModIndex *)index enabledByFileName:(NSDictionary<NSString *, NSNumber *> *)enabledByFileName {
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
    ModInstalledState *state = [self new];
    state.enabledByProject = enabled;
    state.versionIdByProject = versionIds;
    state.titleByProject = titles;
    return state;
}

+ (instancetype)stateOfIndex:(ModIndex *)index folder:(ModFolder *)folder {
    NSMutableDictionary<NSString *, NSNumber *> *enabledByFileName = [NSMutableDictionary new];
    for (ModJar *jar in [folder scanJars]) {
        enabledByFileName[jar.fileName] = @(jar.enabled);
    }
    return [self stateOfIndex:index enabledByFileName:enabledByFileName];
}

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

#pragma mark - ModInstallFlow

@implementation ModInstallFlow

- (instancetype)initWithLoaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc
                    profileName:(NSString *)profileName fetchCache:(ModFetchCache *)fetchCache {
    return [self initWithKind:ModContentKind.mods loaders:loaders gameVersion:mc profileName:profileName fetchCache:fetchCache];
}

- (instancetype)initWithKind:(ModContentKind *)kind loaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc
                 profileName:(NSString *)profileName fetchCache:(ModFetchCache *)fetchCache {
    self = [super init];
    _kind = kind;
    _loaders = [loaders copy];
    _gameVersion = [mc copy];
    _profileName = [profileName copy];
    _fetchCache = fetchCache;
    return self;
}

- (ModDependencyResolver *)resolverWithInstalledProjects:(NSDictionary<NSString *, NSNumber *> *)installed
                                                     api:(ModrinthModsAPI *)api {
    ModFetchCache *cache = self.fetchCache;
    return [[ModDependencyResolver alloc] initWithLoaders:self.loaders gameVersion:self.gameVersion
        installedProjects:installed
        fetchProjectVersions:[cache projectVersionsFetcherWithAPI:api loaders:self.loaders gameVersion:self.gameVersion]
        fetchVersion:[cache versionFetcherWithAPI:api]];
}

- (nullable ModInstallPlan *)planForVersion:(NSDictionary *)version
                          installedProjects:(NSDictionary<NSString *, NSNumber *> *)installed
                                        api:(ModrinthModsAPI *)api error:(NSError **)error {
    if (!self.kind.isMods) {
        return [ModInstallPlan planForSingleVersion:version];
    }
    return [[self resolverWithInstalledProjects:installed api:api] planForVersion:version error:error];
}

- (nullable NSError *)installVersion:(NSDictionary *)version
                               title:(NSString *)title
                               index:(ModIndex *)index
                              folder:(ModFolder *)folder
                                 api:(ModrinthModsAPI *)api
                         knownTitles:(NSDictionary<NSString *, NSString *> *)knownTitles {
    ModInstalledState *state = [ModInstalledState stateOfIndex:index folder:folder];
    NSError *resolveError;
    ModInstallPlan *plan = [self planForVersion:version installedProjects:state.enabledByProject api:api error:&resolveError];
    if (!plan) {
        return ModDisplayError(ModResolveErrorMessage(resolveError, api, knownTitles, self.profileName), resolveError);
    }

    NSMutableArray<NSString *> *projectIds = [NSMutableArray new];
    for (NSDictionary *each in plan.versionsToInstall) {
        NSString *projectId = StringOrNil(each[@"project_id"]);
        if (projectId) [projectIds addObject:projectId];
    }
    NSDictionary<NSString *, NSDictionary *> *projects = [api projectsWithIds:projectIds];
    if (!projects) {
        NSString *reason = api.lastError.localizedDescription ?: @"";
        return ModDisplayError([NSString stringWithFormat:localize(@"mods.error.network", nil), reason], api.lastError);
    }

    // The installer calls back on another queue; this waits for it, so a caller can install several
    // sets one after the other.
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:[ModInstaller defaultDownloader] kind:self.kind];
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    __block NSError *installError = nil;
    [installer installPlan:plan projects:projects completion:^(NSError * _Nullable error) {
        installError = error;
        dispatch_semaphore_signal(finished);
    }];
    dispatch_semaphore_wait(finished, DISPATCH_TIME_FOREVER);

    if (installError) {
        NSString *fileName = StringOrNil(installError.userInfo[@"fileName"]) ?: title;
        return ModDisplayError([NSString stringWithFormat:localize(@"mods.error.install", nil),
            fileName, installError.localizedDescription ?: @""], installError);
    }
    return nil;
}

@end

NS_ASSUME_NONNULL_END
