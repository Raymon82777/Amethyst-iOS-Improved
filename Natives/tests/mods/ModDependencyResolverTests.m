#import "ModDependencyResolver.h"
#import "ModTest.h"

static NSString *const kMC = @"1.21.1";

/* A Modrinth dependency entry; pass nil for a missing project or version id. */
static NSDictionary *Dep(NSString *projectId, NSString *versionId, NSString *type) {
    return @{@"project_id": projectId ?: (id)NSNull.null,
             @"version_id": versionId ?: (id)NSNull.null,
             @"file_name": NSNull.null,
             @"dependency_type": type};
}

static NSDictionary *VersionFor(NSString *versionId, NSString *projectId, NSString *date, NSString *game, NSArray *deps) {
    return @{
        @"id": versionId,
        @"project_id": projectId,
        @"version_number": versionId,
        @"version_type": @"release",
        @"date_published": date,
        @"loaders": @[@"fabric"],
        @"game_versions": @[game],
        @"files": @[@{@"url": @"https://cdn.modrinth.com/data/x/versions/x.jar",
                      @"filename": @"x.jar", @"primary": @YES}],
        @"dependencies": deps};
}

/* A fabric 1.21.1 release. */
static NSDictionary *Ver(NSString *versionId, NSString *projectId, NSArray *deps) {
    return VersionFor(versionId, projectId, @"2026-10-01T00:00:00Z", kMC, deps);
}

/* A canned Modrinth: `projects` maps project id to its versions, and every listed version is also
   fetchable by id. Fetches are logged so tests can assert what was (not) requested. */
@interface FakeModrinth : NSObject
@property(nonatomic) NSMutableDictionary<NSString *, NSArray *> *projects;
@property(nonatomic) NSMutableArray<NSString *> *projectFetches;
@property(nonatomic) NSMutableArray<NSString *> *versionFetches;
- (void)addProject:(NSString *)projectId versions:(NSArray *)versions;
- (ModDependencyResolver *)resolverWithInstalled:(NSDictionary<NSString *, NSNumber *> *)installed;
@end

@implementation FakeModrinth
- (instancetype)init {
    self = [super init];
    _projects = [NSMutableDictionary new];
    _projectFetches = [NSMutableArray new];
    _versionFetches = [NSMutableArray new];
    return self;
}
- (void)addProject:(NSString *)projectId versions:(NSArray *)versions {
    self.projects[projectId] = versions;
}
- (ModDependencyResolver *)resolverWithInstalled:(NSDictionary<NSString *, NSNumber *> *)installed {
    return [[ModDependencyResolver alloc] initWithLoaders:@[@"fabric"] gameVersion:kMC
        installedProjects:installed
        fetchProjectVersions:^NSArray<NSDictionary *> *(NSString *projectId) {
            [self.projectFetches addObject:projectId];
            return self.projects[projectId];
        }
        fetchVersion:^NSDictionary *(NSString *versionId) {
            [self.versionFetches addObject:versionId];
            for (NSArray *versions in self.projects.allValues) {
                for (NSDictionary *version in versions) {
                    if ([version[@"id"] isEqualToString:versionId]) return version;
                }
            }
            return nil;
        }];
}
@end

static NSArray *Ids(ModInstallPlan *plan) {
    return [plan.versionsToInstall valueForKey:@"id"];
}

static void testRootOnly(void) {
    FakeModrinth *net = [FakeModrinth new];
    NSDictionary *root = Ver(@"root-1", @"root", @[]);
    NSError *error = nil;
    ModInstallPlan *plan = [[net resolverWithInstalled:@{}] planForVersion:root error:&error];
    MT_ASSERT(plan != nil);
    MT_EQUAL(error, nil);
    MT_EQUAL(Ids(plan), (@[@"root-1"]));
    MT_EQUAL(plan.projectIdsToEnable, (@[]));
    MT_EQUAL(plan.incompatibleInstalledProjectIds, (@[]));
    MT_EQUAL(plan.optionalProjectIds, (@[]));
    MT_EQUAL(net.projectFetches, (@[]));
    MT_EQUAL(net.versionFetches, (@[]));
}

static void testInstallsMissingRequired(void) {
    FakeModrinth *net = [FakeModrinth new];
    [net addProject:@"A" versions:@[
        VersionFor(@"a-old", @"A", @"2026-08-01T00:00:00Z", kMC, @[]),
        VersionFor(@"a-new", @"A", @"2026-09-01T00:00:00Z", kMC, @[]),
        VersionFor(@"a-wrong-mc", @"A", @"2026-10-01T00:00:00Z", @"1.20.1", @[])]];
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(@"A", nil, @"required")]);
    ModInstallPlan *plan = [[net resolverWithInstalled:@{}] planForVersion:root error:nil];
    MT_EQUAL(Ids(plan), (@[@"root-1", @"a-new"]));
    MT_EQUAL(net.projectFetches, (@[@"A"]));
    MT_EQUAL(net.versionFetches, (@[]));
}

static void testRecursesAndAvoidsCycles(void) {
    FakeModrinth *net = [FakeModrinth new];
    // root -> A -> B -> A, and B also points back at the root's own project.
    [net addProject:@"A" versions:@[Ver(@"a-1", @"A", @[Dep(@"B", nil, @"required")])]];
    [net addProject:@"B" versions:@[Ver(@"b-1", @"B", @[Dep(@"A", nil, @"required"),
                                                         Dep(@"root", nil, @"required")])]];
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(@"A", nil, @"required")]);
    NSError *error = nil;
    ModInstallPlan *plan = [[net resolverWithInstalled:@{}] planForVersion:root error:&error];
    MT_EQUAL(error, nil);
    MT_EQUAL(Ids(plan), (@[@"root-1", @"a-1", @"b-1"]));
    MT_EQUAL(net.projectFetches, (@[@"A", @"B"]));
}

static void testFetchesSharedDependencyOnce(void) {
    FakeModrinth *net = [FakeModrinth new];
    // root -> A, B and both need C.
    [net addProject:@"A" versions:@[Ver(@"a-1", @"A", @[Dep(@"C", nil, @"required")])]];
    [net addProject:@"B" versions:@[Ver(@"b-1", @"B", @[Dep(@"C", nil, @"required")])]];
    [net addProject:@"C" versions:@[Ver(@"c-1", @"C", @[])]];
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(@"A", nil, @"required"), Dep(@"B", nil, @"required")]);
    ModInstallPlan *plan = [[net resolverWithInstalled:@{}] planForVersion:root error:nil];
    MT_EQUAL(Ids(plan), (@[@"root-1", @"a-1", @"b-1", @"c-1"]));
    MT_EQUAL(net.projectFetches, (@[@"A", @"B", @"C"]));
}

static void testSkipsInstalledEnabled(void) {
    FakeModrinth *net = [FakeModrinth new];
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(@"A", nil, @"required")]);
    ModInstallPlan *plan = [[net resolverWithInstalled:@{@"A": @YES}] planForVersion:root error:nil];
    MT_EQUAL(Ids(plan), (@[@"root-1"]));
    MT_EQUAL(plan.projectIdsToEnable, (@[]));
    MT_EQUAL(net.projectFetches, (@[]));
}

static void testReenablesInstalledDisabled(void) {
    FakeModrinth *net = [FakeModrinth new];
    // Listed twice, still switched on once; and no version of A is fetched.
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(@"A", nil, @"required"), Dep(@"A", nil, @"required")]);
    ModInstallPlan *plan = [[net resolverWithInstalled:@{@"A": @NO}] planForVersion:root error:nil];
    MT_EQUAL(Ids(plan), (@[@"root-1"]));
    MT_EQUAL(plan.projectIdsToEnable, (@[@"A"]));
    MT_EQUAL(net.projectFetches, (@[]));
    MT_EQUAL(net.versionFetches, (@[]));
}

static void testPinnedVersionUsedWhenItFits(void) {
    FakeModrinth *net = [FakeModrinth new];
    [net addProject:@"A" versions:@[
        VersionFor(@"a-pinned", @"A", @"2026-08-01T00:00:00Z", kMC, @[]),
        VersionFor(@"a-newer", @"A", @"2026-09-01T00:00:00Z", kMC, @[])]];
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(@"A", @"a-pinned", @"required")]);
    ModInstallPlan *plan = [[net resolverWithInstalled:@{}] planForVersion:root error:nil];
    MT_EQUAL(Ids(plan), (@[@"root-1", @"a-pinned"]));
    MT_EQUAL(net.versionFetches, (@[@"a-pinned"]));
    MT_EQUAL(net.projectFetches, (@[]));
}

static void testPinnedVersionReplacedWhenNotFit(void) {
    FakeModrinth *net = [FakeModrinth new];
    [net addProject:@"A" versions:@[
        VersionFor(@"a-pinned-120", @"A", @"2026-10-01T00:00:00Z", @"1.20.1", @[]),
        VersionFor(@"a-121", @"A", @"2026-09-01T00:00:00Z", kMC, @[])]];
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(@"A", @"a-pinned-120", @"required")]);
    ModInstallPlan *plan = [[net resolverWithInstalled:@{}] planForVersion:root error:nil];
    MT_EQUAL(Ids(plan), (@[@"root-1", @"a-121"]));
    MT_EQUAL(net.versionFetches, (@[@"a-pinned-120"]));
    MT_EQUAL(net.projectFetches, (@[@"A"]));
}

static void testPinnedVersionNotFoundFallsBack(void) {
    FakeModrinth *net = [FakeModrinth new];
    [net addProject:@"A" versions:@[Ver(@"a-1", @"A", @[])]];
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(@"A", @"a-gone", @"required")]);
    ModInstallPlan *plan = [[net resolverWithInstalled:@{}] planForVersion:root error:nil];
    MT_EQUAL(Ids(plan), (@[@"root-1", @"a-1"]));
    MT_EQUAL(net.versionFetches, (@[@"a-gone"]));
    MT_EQUAL(net.projectFetches, (@[@"A"]));
}

static void testVersionIdOnlyDependency(void) {
    FakeModrinth *net = [FakeModrinth new];
    [net addProject:@"A" versions:@[
        VersionFor(@"a-pinned", @"A", @"2026-08-01T00:00:00Z", kMC, @[Dep(@"B", nil, @"required")]),
        VersionFor(@"a-newer", @"A", @"2026-09-01T00:00:00Z", kMC, @[])]];
    [net addProject:@"B" versions:@[Ver(@"b-1", @"B", @[])]];
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(nil, @"a-pinned", @"required")]);
    NSError *error = nil;
    ModInstallPlan *plan = [[net resolverWithInstalled:@{}] planForVersion:root error:&error];
    MT_EQUAL(error, nil);
    // The fetched version supplies the project id and, since it fits, is used as is.
    MT_EQUAL(Ids(plan), (@[@"root-1", @"a-pinned", @"b-1"]));
    MT_EQUAL(net.versionFetches, (@[@"a-pinned"]));
    MT_EQUAL(net.projectFetches, (@[@"B"]));
}

static void testVersionIdOnlyDependencyAlreadyInstalled(void) {
    FakeModrinth *net = [FakeModrinth new];
    [net addProject:@"A" versions:@[Ver(@"a-1", @"A", @[])]];
    [net addProject:@"C" versions:@[Ver(@"c-1", @"C", @[])]];
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(nil, @"a-1", @"required"), Dep(nil, @"c-1", @"required")]);
    ModInstallPlan *plan = [[net resolverWithInstalled:@{@"A": @YES, @"C": @NO}] planForVersion:root error:nil];
    MT_EQUAL(Ids(plan), (@[@"root-1"]));
    MT_EQUAL(plan.projectIdsToEnable, (@[@"C"]));
    MT_EQUAL(net.projectFetches, (@[]));
}

static void testVersionIdOnlyDependencyUnfetchableAborts(void) {
    FakeModrinth *net = [FakeModrinth new];
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(nil, @"a-gone", @"required")]);
    NSError *error = nil;
    ModInstallPlan *plan = [[net resolverWithInstalled:@{}] planForVersion:root error:&error];
    MT_EQUAL(plan, nil);
    MT_EQUAL(error.domain, ModResolveErrorDomain);
    MT_EQUAL(@(error.code), @(ModResolveErrorNetwork));
}

static void testMissingDependencyAborts(void) {
    FakeModrinth *net = [FakeModrinth new];
    [net addProject:@"A" versions:@[VersionFor(@"a-old-mc", @"A", @"2026-10-01T00:00:00Z", @"1.20.1", @[])]];
    [net addProject:@"B" versions:@[]];
    NSError *error = nil;
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(@"A", nil, @"required")]);
    ModInstallPlan *plan = [[net resolverWithInstalled:@{}] planForVersion:root error:&error];
    MT_EQUAL(plan, nil);
    MT_EQUAL(error.domain, ModResolveErrorDomain);
    MT_EQUAL(@(error.code), @(ModResolveErrorMissingDependency));
    MT_EQUAL(error.userInfo[@"projectId"], @"A");

    // A project with no versions at all is missing too (an empty list is not a network error).
    error = nil;
    root = Ver(@"root-2", @"root", @[Dep(@"B", nil, @"required")]);
    plan = [[net resolverWithInstalled:@{}] planForVersion:root error:&error];
    MT_EQUAL(plan, nil);
    MT_EQUAL(@(error.code), @(ModResolveErrorMissingDependency));
    MT_EQUAL(error.userInfo[@"projectId"], @"B");
}

static void testNetworkErrorAborts(void) {
    FakeModrinth *net = [FakeModrinth new]; // "A" is unknown, so its fetch returns nil
    NSError *error = nil;
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(@"A", nil, @"required")]);
    ModInstallPlan *plan = [[net resolverWithInstalled:@{}] planForVersion:root error:&error];
    MT_EQUAL(plan, nil);
    MT_EQUAL(error.domain, ModResolveErrorDomain);
    MT_EQUAL(@(error.code), @(ModResolveErrorNetwork));
}

static void testIncompatibleAndOptional(void) {
    FakeModrinth *net = [FakeModrinth new];
    [net addProject:@"A" versions:@[Ver(@"a-1", @"A", @[Dep(@"Z", nil, @"incompatible")])]];
    NSDictionary *root = Ver(@"root-1", @"root", @[
        Dep(@"X", nil, @"incompatible"),
        Dep(@"X", nil, @"incompatible"),
        Dep(@"W", nil, @"incompatible"),
        Dep(@"Y", nil, @"optional"),
        Dep(@"Y", nil, @"optional"),
        Dep(@"V", nil, @"optional"),
        Dep(@"A", nil, @"required")]);

    // X (enabled) and Z (disabled, conflicting only through a dependency) are installed; W is not.
    // Optional V is already installed, so only Y is suggested.
    NSDictionary *installed = @{@"X": @YES, @"Z": @NO, @"V": @YES};
    ModInstallPlan *plan = [[net resolverWithInstalled:installed] planForVersion:root error:nil];
    MT_EQUAL(Ids(plan), (@[@"root-1", @"a-1"]));
    MT_EQUAL(plan.incompatibleInstalledProjectIds, (@[@"X", @"Z"]));
    MT_EQUAL(plan.optionalProjectIds, (@[@"Y"]));

    // Nothing conflicting is installed.
    plan = [[net resolverWithInstalled:@{}] planForVersion:root error:nil];
    MT_EQUAL(plan.incompatibleInstalledProjectIds, (@[]));
    MT_EQUAL(plan.optionalProjectIds, (@[@"Y", @"V"]));
}

static void testOptionalOnlyFromRoot(void) {
    FakeModrinth *net = [FakeModrinth new];
    [net addProject:@"A" versions:@[Ver(@"a-1", @"A", @[Dep(@"Q", nil, @"optional")])]];
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(@"A", nil, @"required")]);
    ModInstallPlan *plan = [[net resolverWithInstalled:@{}] planForVersion:root error:nil];
    MT_EQUAL(plan.optionalProjectIds, (@[]));
    MT_EQUAL(net.projectFetches, (@[@"A"]));
}

static void testEmbeddedIgnored(void) {
    FakeModrinth *net = [FakeModrinth new];
    NSDictionary *root = Ver(@"root-1", @"root", @[Dep(@"E", nil, @"embedded"), Dep(nil, @"e-1", @"embedded")]);
    ModInstallPlan *plan = [[net resolverWithInstalled:@{@"E": @YES}] planForVersion:root error:nil];
    MT_EQUAL(Ids(plan), (@[@"root-1"]));
    MT_EQUAL(plan.projectIdsToEnable, (@[]));
    MT_EQUAL(plan.incompatibleInstalledProjectIds, (@[]));
    MT_EQUAL(plan.optionalProjectIds, (@[]));
    MT_EQUAL(net.projectFetches, (@[]));
    MT_EQUAL(net.versionFetches, (@[]));
}

/* Packs never resolve dependencies: a required one is ignored and nothing is fetched. */
static void testSingleVersionPlanIgnoresDependencies(void) {
    NSMutableDictionary *version = [Ver(@"pack-1", @"PACK", @[]) mutableCopy];
    version[@"dependencies"] = @[@{@"project_id": @"MOD", @"dependency_type": @"required"}];
    ModInstallPlan *plan = [ModInstallPlan planForSingleVersion:version];
    MT_EQUAL(plan.versionsToInstall, (@[version]));
    MT_EQUAL(plan.projectIdsToEnable, (@[]));
    MT_EQUAL(plan.incompatibleInstalledProjectIds, (@[]));
    MT_EQUAL(plan.optionalProjectIds, (@[]));
}

void ModDependencyResolverTests(void) {
    MT_RUN(testRootOnly);
    MT_RUN(testInstallsMissingRequired);
    MT_RUN(testRecursesAndAvoidsCycles);
    MT_RUN(testFetchesSharedDependencyOnce);
    MT_RUN(testSkipsInstalledEnabled);
    MT_RUN(testReenablesInstalledDisabled);
    MT_RUN(testPinnedVersionUsedWhenItFits);
    MT_RUN(testPinnedVersionReplacedWhenNotFit);
    MT_RUN(testPinnedVersionNotFoundFallsBack);
    MT_RUN(testVersionIdOnlyDependency);
    MT_RUN(testVersionIdOnlyDependencyAlreadyInstalled);
    MT_RUN(testVersionIdOnlyDependencyUnfetchableAborts);
    MT_RUN(testMissingDependencyAborts);
    MT_RUN(testNetworkErrorAborts);
    MT_RUN(testIncompatibleAndOptional);
    MT_RUN(testOptionalOnlyFromRoot);
    MT_RUN(testEmbeddedIgnored);
    MT_RUN(testSingleVersionPlanIgnoresDependencies);
}
