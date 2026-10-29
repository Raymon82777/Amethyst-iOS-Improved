#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/* Loader and Minecraft version of a launcher profile's version JSON.
   Foundation-only so it can be tested on the host (see `make test_mods`). */
@interface ModProfileInfo : NSObject

@property(nonatomic, readonly, nullable) NSString *minecraftVersion;
@property(nonatomic, readonly, nullable) NSString *loader; // @"fabric" @"quilt" @"forge" @"neoforge", nil = vanilla
@property(nonatomic, readonly, nullable) NSString *loaderVersion;
@property(nonatomic, readonly) NSArray<NSString *> *acceptedLoaders; // empty when vanilla
@property(nonatomic, readonly) BOOL isModded;
@property(nonatomic, readonly) NSString *displayName; // e.g. @"Fabric · 1.21.1"

/* Reads <versionsDir>/<versionId>/<versionId>.json; falls back to id patterns if unreadable. */
+ (instancetype)infoForVersionId:(NSString *)versionId versionsDir:(NSString *)versionsDir;
+ (instancetype)infoForVersionId:(NSString *)versionId json:(nullable NSDictionary *)json;
+ (NSArray<NSString *> *)acceptedLoadersForLoader:(nullable NSString *)loader minecraftVersion:(nullable NSString *)mc;

@end

NS_ASSUME_NONNULL_END
