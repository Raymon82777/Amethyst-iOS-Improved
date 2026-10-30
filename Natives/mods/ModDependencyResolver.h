#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const ModResolveErrorDomain; // @"ModResolveErrorDomain"

typedef NS_ENUM(NSInteger, ModResolveError) {
    /* A fetch failed (or returned an unusable answer), so the plan cannot be trusted. */
    ModResolveErrorNetwork = 1,
    /* A required dependency has no version for this loader and Minecraft version.
       userInfo[@"projectId"] is the project that could not be satisfied. */
    ModResolveErrorMissingDependency = 2
};

/* All versions of a project (Modrinth version objects); nil means the request failed. */
typedef NSArray<NSDictionary *> * _Nullable (^ModFetchProjectVersions)(NSString *projectId);
/* One version by id; nil means the request failed or the version does not exist. */
typedef NSDictionary * _Nullable (^ModFetchVersion)(NSString *versionId);

/* What installing one version involves. */
@interface ModInstallPlan : NSObject
/* The chosen version first, then its required dependencies in discovery order. */
@property(nonatomic, copy) NSArray<NSDictionary *> *versionsToInstall;
/* Required dependencies that are installed but disabled, so they only need switching on. */
@property(nonatomic, copy) NSArray<NSString *> *projectIdsToEnable;
/* Installed projects (enabled or disabled) that any version in the plan declares incompatible. */
@property(nonatomic, copy) NSArray<NSString *> *incompatibleInstalledProjectIds;
/* The chosen version's optional dependencies that are not installed. */
@property(nonatomic, copy) NSArray<NSString *> *optionalProjectIds;
@end

@interface ModInstallPlan (Single)
/* versionsToInstall = @[version]; every other list empty. For kinds that don't resolve dependencies
   (resource packs and shader packs). */
+ (instancetype)planForSingleVersion:(NSDictionary *)version;
@end

/* Works out what to install for a chosen Modrinth version: its required dependencies (recursively),
   which installed-but-disabled mods to switch back on, and which installed mods conflict.
   Fetching is injected as synchronous blocks, so there is no network or threading in here and it can be
   tested on the host (see `make test_mods`). */
@interface ModDependencyResolver : NSObject

/* `loaders` and `mc` are the profile's (see ModVersionSelector). `installed` maps each installed
   project id to @(enabled). */
- (instancetype)initWithLoaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc
              installedProjects:(NSDictionary<NSString *, NSNumber *> *)installed
           fetchProjectVersions:(ModFetchProjectVersions)fetchProjectVersions
                   fetchVersion:(ModFetchVersion)fetchVersion;

/* Synchronous. Returns nil with `error` set (ModResolveErrorDomain) if a required dependency cannot be
   resolved. Each project is fetched at most once; dependency cycles end. */
- (nullable ModInstallPlan *)planForVersion:(NSDictionary *)rootVersion error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
