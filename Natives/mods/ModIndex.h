#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Name of the record file kept in each profile's mods folder. */
extern NSString *const ModIndexFileName; // @".amethyst-mods.json"

/* The per-folder record of which Modrinth project/version each jar came from.

   Stored as `<modsDir>/.amethyst-mods.json`:
     {"formatVersion": 1, "mods": {"<jar name>": {entry}}, "unknownHashes": ["<sha1>"]}
   Keys of `entries` are jar file names WITHOUT the `.disabled` suffix.

   An entry may contain: projectId, versionId, slug, title, versionNumber, versionType,
   iconUrl, sha1, requires (array of project ids), gameVersions, loaders.
   Foundation-only so it can be tested on the host (see `make test_mods`). */
@interface ModIndex : NSObject

/* A missing, unreadable or corrupt file gives an empty index. */
- (instancetype)initWithModsDir:(NSString *)modsDir;

@property(nonatomic, readonly) NSString *modsDir;
@property(nonatomic, readonly) NSMutableDictionary<NSString *, NSMutableDictionary *> *entries;
/* SHA-1s of jars Modrinth did not recognise, so they are not looked up again. */
@property(nonatomic, readonly) NSMutableSet<NSString *> *unknownHashes;

/* The file name of the entry whose `projectId` matches, or nil. */
- (nullable NSString *)fileNameForProjectId:(NSString *)projectId;

/* File names (sorted) of entries whose `requires` contains `projectId`. */
- (NSArray<NSString *> *)fileNamesRequiringProject:(NSString *)projectId;

/* Drops entries whose file name is not in `existingFileNames`. */
- (void)pruneEntriesNotIn:(NSSet<NSString *> *)existingFileNames;

/* Creates the mods folder if needed, then writes the record atomically (pretty-printed, sorted keys). */
- (BOOL)save:(NSError **)error;

/* YES when the entry's `loaders` intersect `loaders` and its `gameVersions` contain `mc`.
   An entry missing either field never matches. */
+ (BOOL)entry:(NSDictionary *)entry matchesLoaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc;

/* Builds an entry from a Modrinth version, the file that was installed, and (optionally) its project.
   Keys whose source value is missing are omitted. */
+ (NSMutableDictionary *)entryForVersion:(NSDictionary *)version file:(NSDictionary *)file project:(nullable NSDictionary *)project;

@end

NS_ASSUME_NONNULL_END
