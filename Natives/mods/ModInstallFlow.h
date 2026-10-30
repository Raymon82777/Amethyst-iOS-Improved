#import <Foundation/Foundation.h>
#import "ModContentKind.h"
#import "ModDependencyResolver.h"
#import "ModFolder.h"
#import "ModIndex.h"
#import "ModrinthModsAPI.h"

NS_ASSUME_NONNULL_BEGIN

/* YES when a resolve failed because a required dependency has no version for the profile. */
BOOL ModIsMissingDependency(NSError * _Nullable error);

/* An error whose localizedDescription is `message`, with `underlying`'s domain and code. */
NSError *ModDisplayError(NSString *message, NSError * _Nullable underlying);

/* Titles of Modrinth projects by id (one request; blocking). Projects it cannot find are left out. */
NSDictionary<NSString *, NSString *> *ModProjectTitles(NSArray<NSString *> *projectIds, ModrinthModsAPI *api);

/* What to tell the user when no plan could be made (blocking: may look up the missing mod's title).
   `profileName` is the profile's display name, e.g. "Fabric · 1.21.1". */
NSString *ModResolveErrorMessage(NSError * _Nullable error, ModrinthModsAPI *api,
                                 NSDictionary<NSString *, NSString *> *knownTitles, NSString *profileName);

/* Remembers Modrinth's answers for as long as it is kept, so working a plan out again (or for several
   mods in a row) costs no extra requests. Thread-safe. */
@interface ModFetchCache : NSObject
- (void)setVersions:(NSArray<NSDictionary *> *)versions ofProject:(NSString *)projectId;
- (ModFetchProjectVersions)projectVersionsFetcherWithAPI:(ModrinthModsAPI *)api loaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc;
- (ModFetchVersion)versionFetcherWithAPI:(ModrinthModsAPI *)api;
@end

/* Which Modrinth projects a profile has, from the record plus the files' enabled state. */
@interface ModInstalledState : NSObject
@property(nonatomic, copy) NSDictionary<NSString *, NSNumber *> *enabledByProject; // what the resolver takes
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *versionIdByProject;
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *titleByProject;

/* `enabledByFileName` maps the jars on disk (names without ".disabled") to @(enabled); record entries
   without a file are ignored. Must only run while nothing else uses `index`. */
+ (instancetype)stateOfIndex:(ModIndex *)index enabledByFileName:(NSDictionary<NSString *, NSNumber *> *)enabledByFileName;

/* Same, from a scan of `folder` (which deletes stray *.part files, so only call it from inside an
   operation of the Mods screen). */
+ (instancetype)stateOfIndex:(ModIndex *)index folder:(ModFolder *)folder;
@end

/* Resolving and installing Modrinth versions for one profile, shared by the mod detail page and the
   Installed Mods screen's Update / Switch actions. */
@interface ModInstallFlow : NSObject

/* `kind` is the content being installed. `loaders` are the loaders to request versions for (the profile's
   accepted loaders for mods, `[kind loadersForProfileLoaders:]` for packs) and `mc` the Minecraft
   version, `profileName` the profile's display name (for messages). Every resolver made by this flow
   fetches through `fetchCache`. */
- (instancetype)initWithKind:(ModContentKind *)kind loaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc
                 profileName:(NSString *)profileName fetchCache:(ModFetchCache *)fetchCache;

/* The same for mods (`ModContentKind.mods`). */
- (instancetype)initWithLoaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc
                    profileName:(NSString *)profileName fetchCache:(ModFetchCache *)fetchCache;

@property(nonatomic, readonly) ModContentKind *kind;
@property(nonatomic, readonly, copy) NSArray<NSString *> *loaders;
@property(nonatomic, readonly, copy) NSString *gameVersion;
@property(nonatomic, readonly, copy) NSString *profileName;
@property(nonatomic, readonly) ModFetchCache *fetchCache;

/* A resolver for the profile that fetches with `api` through the cache. */
- (ModDependencyResolver *)resolverWithInstalledProjects:(NSDictionary<NSString *, NSNumber *> *)installed
                                                     api:(ModrinthModsAPI *)api;

/* What installing `version` involves. For mods it is the resolver's plan (the version plus its required
   dependencies); for packs it is that one version (`+[ModInstallPlan planForSingleVersion:]`, never
   fails). Blocking. Returns nil with `error` set when a mod's dependencies cannot be resolved. */
- (nullable ModInstallPlan *)planForVersion:(NSDictionary *)version
                          installedProjects:(NSDictionary<NSString *, NSNumber *> *)installed
                                        api:(ModrinthModsAPI *)api error:(NSError **)error;

/* Installs `version` and whatever it requires as one set (see ModInstaller): reads what is installed
   now (scans `folder`), resolves, loads the projects, installs. Blocking, so call it off the main queue,
   and only from inside an operation of the Mods screen (it reads and changes `index`).
   Returns nil when the whole set is in, else an error whose localizedDescription is ready to show.
   `title` names the mod in the message when the failing file is unknown; `knownTitles` (project id ->
   title) saves a lookup when a dependency is missing. */
- (nullable NSError *)installVersion:(NSDictionary *)version
                               title:(NSString *)title
                               index:(ModIndex *)index
                              folder:(ModFolder *)folder
                                 api:(ModrinthModsAPI *)api
                         knownTitles:(NSDictionary<NSString *, NSString *> *)knownTitles;

@end

NS_ASSUME_NONNULL_END
