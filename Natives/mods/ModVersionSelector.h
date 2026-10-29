#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Picks which Modrinth version of a project to install for a profile.
   Versions are Modrinth version objects (parsed JSON dictionaries).
   Foundation-only so it can be tested on the host (see `make test_mods`). */
@interface ModVersionSelector : NSObject

/* YES when the version's `loaders` intersect `loaders` and its `game_versions` contain `mc`. */
+ (BOOL)version:(NSDictionary *)version fitsLoaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc;

/* The newest compatible release; if there is no release, the newest beta; then the newest alpha. */
+ (nullable NSDictionary *)bestVersionIn:(NSArray<NSDictionary *> *)versions loaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc;

/* Only the compatible versions, sorted by `date_published` descending. */
+ (NSArray<NSDictionary *> *)compatibleVersionsNewestFirst:(NSArray<NSDictionary *> *)versions loaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc;

/* The file flagged `primary`, else the first file, else nil. */
+ (nullable NSDictionary *)primaryFileOfVersion:(NSDictionary *)version;

@end

NS_ASSUME_NONNULL_END
