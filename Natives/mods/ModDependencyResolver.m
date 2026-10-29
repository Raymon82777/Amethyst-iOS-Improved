#import "ModDependencyResolver.h"
#import "ModVersionSelector.h"

NS_ASSUME_NONNULL_BEGIN

NSErrorDomain const ModResolveErrorDomain = @"ModResolveErrorDomain";

#pragma mark - Helpers

/* `value` when it is a non-empty string (so JSON nulls and wrong types give nil). */
static NSString * _Nullable StringValue(id _Nullable value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

/* The entries of the version's `dependencies` whose `dependency_type` is `type`. */
static NSArray<NSDictionary *> *DependenciesOfType(NSDictionary *version, NSString *type) {
    id dependencies = version[@"dependencies"];
    if (![dependencies isKindOfClass:NSArray.class]) return @[];
    NSMutableArray<NSDictionary *> *matches = [NSMutableArray new];
    for (id dependency in dependencies) {
        if ([dependency isKindOfClass:NSDictionary.class] && [dependency[@"dependency_type"] isEqual:type]) {
            [matches addObject:dependency];
        }
    }
    return matches;
}

static NSError *NetworkError(NSString *what) {
    return [NSError errorWithDomain:ModResolveErrorDomain code:ModResolveErrorNetwork
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Could not load %@ from Modrinth.", what]}];
}

static NSError *MissingDependencyError(NSString *projectId) {
    return [NSError errorWithDomain:ModResolveErrorDomain code:ModResolveErrorMissingDependency
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"A required mod (%@) has no version for this profile's loader and Minecraft version.", projectId],
                                      @"projectId": projectId}];
}

#pragma mark - ModInstallPlan

@implementation ModInstallPlan
@end

#pragma mark - ModDependencyResolver

@interface ModDependencyResolver ()
@property(nonatomic, copy) NSArray<NSString *> *loaders;
@property(nonatomic, copy) NSString *gameVersion;
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *installed;
@property(nonatomic, copy) ModFetchProjectVersions fetchProjectVersions;
@property(nonatomic, copy) ModFetchVersion fetchVersion;
@end

@implementation ModDependencyResolver

- (instancetype)initWithLoaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc
              installedProjects:(NSDictionary<NSString *, NSNumber *> *)installed
           fetchProjectVersions:(ModFetchProjectVersions)fetchProjectVersions
                   fetchVersion:(ModFetchVersion)fetchVersion {
    self = [super init];
    _loaders = [loaders copy];
    _gameVersion = [mc copy];
    _installed = [installed copy];
    _fetchProjectVersions = [fetchProjectVersions copy];
    _fetchVersion = [fetchVersion copy];
    return self;
}

/* Handles one `required` dependency entry: skips it, queues it to be switched on, or appends the
   version to install to `versions`. Returns NO with `error` set if it cannot be resolved. */
- (BOOL)resolveRequiredDependency:(NSDictionary *)dependency
                          visited:(NSMutableSet<NSString *> *)visited
                         toEnable:(NSMutableArray<NSString *> *)toEnable
                         versions:(NSMutableArray<NSDictionary *> *)versions
                            error:(NSError **)error {
    NSString * _Nullable projectId = StringValue(dependency[@"project_id"]);
    NSString * _Nullable versionId = StringValue(dependency[@"version_id"]);
    NSDictionary * _Nullable pinned = nil;

    if (!projectId) {
        if (!versionId) return YES; // nothing to identify the dependency by
        // Only a version is named, so that version tells us which project it is.
        pinned = self.fetchVersion(versionId);
        projectId = StringValue(pinned[@"project_id"]);
        if (!projectId) {
            if (error) *error = NetworkError([NSString stringWithFormat:@"version %@", versionId]);
            return NO;
        }
    }

    if ([visited containsObject:projectId]) return YES;
    [visited addObject:projectId];

    NSNumber * _Nullable installedState = self.installed[projectId];
    if (installedState) {
        if (!installedState.boolValue) [toEnable addObject:projectId];
        return YES;
    }

    if (!pinned && versionId) pinned = self.fetchVersion(versionId);
    if (pinned && [ModVersionSelector version:pinned fitsLoaders:self.loaders gameVersion:self.gameVersion]) {
        [versions addObject:pinned];
        return YES;
    }

    // No pin, the pin does not fit this profile, or it no longer exists: take the best version of the project.
    NSArray<NSDictionary *> * _Nullable projectVersions = self.fetchProjectVersions(projectId);
    if (!projectVersions) {
        if (error) *error = NetworkError([NSString stringWithFormat:@"the versions of %@", projectId]);
        return NO;
    }
    NSDictionary * _Nullable best = [ModVersionSelector bestVersionIn:projectVersions loaders:self.loaders gameVersion:self.gameVersion];
    if (!best) {
        if (error) *error = MissingDependencyError(projectId);
        return NO;
    }
    [versions addObject:best];
    return YES;
}

- (nullable ModInstallPlan *)planForVersion:(NSDictionary *)rootVersion error:(NSError **)error {
    NSString * _Nullable rootProjectId = StringValue(rootVersion[@"project_id"]);
    NSMutableSet<NSString *> *visited = [NSMutableSet new];
    if (rootProjectId) [visited addObject:rootProjectId];

    NSMutableArray<NSDictionary *> *versions = [NSMutableArray arrayWithObject:rootVersion];
    NSMutableArray<NSString *> *toEnable = [NSMutableArray new];

    // `versions` grows while it is walked, which visits dependencies of dependencies (each project once).
    for (NSUInteger i = 0; i < versions.count; i++) {
        for (NSDictionary *dependency in DependenciesOfType(versions[i], @"required")) {
            if (![self resolveRequiredDependency:dependency visited:visited toEnable:toEnable versions:versions error:error]) {
                return nil;
            }
        }
    }

    NSMutableArray<NSString *> *incompatible = [NSMutableArray new];
    for (NSDictionary *version in versions) {
        for (NSDictionary *dependency in DependenciesOfType(version, @"incompatible")) {
            NSString * _Nullable projectId = StringValue(dependency[@"project_id"]);
            if (projectId && self.installed[projectId] && ![incompatible containsObject:projectId]) {
                [incompatible addObject:projectId];
            }
        }
    }

    NSMutableArray<NSString *> *optional = [NSMutableArray new];
    for (NSDictionary *dependency in DependenciesOfType(rootVersion, @"optional")) {
        NSString * _Nullable projectId = StringValue(dependency[@"project_id"]);
        if (projectId && !self.installed[projectId] && ![optional containsObject:projectId]) {
            [optional addObject:projectId];
        }
    }

    ModInstallPlan *plan = [ModInstallPlan new];
    plan.versionsToInstall = versions;
    plan.projectIdsToEnable = toEnable;
    plan.incompatibleInstalledProjectIds = incompatible;
    plan.optionalProjectIds = optional;
    return plan;
}

@end

NS_ASSUME_NONNULL_END
