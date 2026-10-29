#import <Foundation/Foundation.h>
#import "installer/modpack/ModpackAPI.h"

NS_ASSUME_NONNULL_BEGIN

/* The Modrinth calls the Mods screens need, built on ModpackAPI (base URL https://api.modrinth.com/v2,
   User-Agent from [ModpackAPI userAgent]).
   Every method is synchronous and blocks until the request finishes: never call them on the main
   thread. On failure they return nil and set `lastError`. */
@interface ModrinthModsAPI : ModpackAPI

/* Searches for mods that run on `loaders` and `mc` and work client-side. `query` may be empty, which
   lists the most downloaded mods instead. Loads 50 hits starting at `previous.count`, appends them to
   `previous` (or to a new array when nil) and returns that array; sets `reachedLastPage`. Each hit has
   the keys id, slug, title, description, author, downloads, imageUrl (a missing value is left out). */
- (nullable NSMutableArray<NSDictionary *> *)searchMods:(NSString *)query
                                                loaders:(NSArray<NSString *> *)loaders
                                            gameVersion:(NSString *)mc
                                               previous:(nullable NSMutableArray *)previous;

/* The project's Modrinth version objects for those loaders and Minecraft version, newest first. */
- (nullable NSArray<NSDictionary *> *)versionsOfProject:(NSString *)projectId
                                                loaders:(NSArray<NSString *> *)loaders
                                            gameVersion:(NSString *)mc;

- (nullable NSDictionary *)versionWithId:(NSString *)versionId;

/* Project objects keyed by project id. An empty `ids` returns an empty dictionary without a request. */
- (nullable NSDictionary<NSString *, NSDictionary *> *)projectsWithIds:(NSArray<NSString *> *)ids;

/* The version each sha1 file hash belongs to, keyed by hash (hashes Modrinth does not know are
   missing). An empty `sha1s` returns an empty dictionary without a request. */
- (nullable NSDictionary<NSString *, NSDictionary *> *)versionsForHashes:(NSArray<NSString *> *)sha1s;

/* The newest version for the loaders and Minecraft version of the project each sha1 file hash belongs
   to, keyed by hash. `types` limits the release types ("release", "beta", "alpha"); nil allows all.
   An empty `sha1s` returns an empty dictionary without a request. */
- (nullable NSDictionary<NSString *, NSDictionary *> *)latestVersionsForHashes:(NSArray<NSString *> *)sha1s
                                                                       loaders:(NSArray<NSString *> *)loaders
                                                                   gameVersion:(NSString *)mc
                                                                  versionTypes:(nullable NSArray<NSString *> *)types;

@end

NS_ASSUME_NONNULL_END
