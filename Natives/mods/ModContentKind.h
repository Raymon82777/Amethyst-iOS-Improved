#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, ModContentType) {
    ModContentTypeMods,
    ModContentTypeResourcePacks,
    ModContentTypeShaderPacks
};

/* Describes one kind of per-profile content (mods, resource packs or shader packs):
   where it lives, what its files look like, and how Modrinth is queried for it.
   Immutable; use the shared instances below.
   Foundation-only so it can be tested on the host (see `make test_mods`). */
@interface ModContentKind : NSObject

+ (instancetype)mods;
+ (instancetype)resourcePacks;
+ (instancetype)shaderPacks;

@property(nonatomic, readonly) ModContentType type;
/* Folder inside the profile's game folder: "mods", "resourcepacks", "shaderpacks". */
@property(nonatomic, readonly) NSString *folderName;
/* Lowercase, no dot: "jar", "zip", "zip". */
@property(nonatomic, readonly) NSString *fileExtension;
/* Modrinth project type: "mod", "resourcepack", "shader". */
@property(nonatomic, readonly) NSString *projectType;
/* Prefix of this kind's localization keys: "mods", "resourcepacks", "shaderpacks". */
@property(nonatomic, readonly) NSString *stringPrefix;
/* YES when the folder can hold folder entries (unzipped packs) as well as files. */
@property(nonatomic, readonly) BOOL listsFolders;
/* YES for mods only: they need a loader, resolve dependencies, use the client_side facet,
   get iOS warnings and have jar metadata. */
@property(nonatomic, readonly) BOOL isMods;

/* Loaders for version requests and matching: mods → `profileLoaders`; packs → their fixed list
   (resource packs @[@"minecraft"], shader packs @[@"iris", @"optifine"]). */
- (NSArray<NSString *> *)loadersForProfileLoaders:(NSArray<NSString *> *)profileLoaders;

/* Loaders for search's `categories:` facet: mods → `profileLoaders`; resource packs → @[];
   shader packs → @[@"iris", @"optifine"]. */
- (NSArray<NSString *> *)searchCategoriesForProfileLoaders:(NSArray<NSString *> *)profileLoaders;

/* "<stringPrefix>.<suffix>", e.g. [ModContentKind.resourcePacks stringKey:@"title"] → @"resourcepacks.title". */
- (NSString *)stringKey:(NSString *)suffix;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
