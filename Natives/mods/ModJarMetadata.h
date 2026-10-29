#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* The display name and version a mod jar declares about itself, for mods that are not on Modrinth. */
@interface ModJarMetadata : NSObject

/* @{@"name": …, @"version": …} (either key may be missing) read from the first of fabric.mod.json,
   quilt.mod.json, META-INF/mods.toml and META-INF/neoforge.mods.toml found in the jar; nil when the
   jar cannot be opened or none of them gives a name or version. Reads the file: call off the main thread. */
+ (nullable NSDictionary<NSString *, NSString *> *)metadataForJarAtPath:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
