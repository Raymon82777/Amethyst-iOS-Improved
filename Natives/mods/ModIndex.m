#import "ModIndex.h"

NS_ASSUME_NONNULL_BEGIN

NSString *const ModIndexFileName = @".amethyst-mods.json";

static const NSInteger kModIndexFormatVersion = 1;

#pragma mark - Helpers

/* Copies `source[sourceKey]` to `target[targetKey]` when it is an instance of `cls`
   (so JSON nulls and wrong types are left out). */
static void CopyValue(NSMutableDictionary *target, NSString *targetKey, NSDictionary * _Nullable source, NSString *sourceKey, Class cls) {
    id value = source[sourceKey];
    if ([value isKindOfClass:cls]) {
        target[targetKey] = value;
    }
}

@interface ModIndex ()
@property(nonatomic, readwrite) NSString *modsDir;
@property(nonatomic, readwrite) NSMutableDictionary<NSString *, NSMutableDictionary *> *entries;
@property(nonatomic, readwrite) NSMutableSet<NSString *> *unknownHashes;
@end

@implementation ModIndex

- (instancetype)initWithModsDir:(NSString *)modsDir {
    self = [super init];
    _modsDir = [modsDir copy];
    _entries = [NSMutableDictionary new];
    _unknownHashes = [NSMutableSet new];
    [self load];
    return self;
}

- (NSString *)filePath {
    return [self.modsDir stringByAppendingPathComponent:ModIndexFileName];
}

- (void)load {
    NSData *data = [NSData dataWithContentsOfFile:[self filePath]];
    if (!data) return;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:NSDictionary.class]) return;

    id mods = root[@"mods"];
    if ([mods isKindOfClass:NSDictionary.class]) {
        [(NSDictionary *)mods enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
            if ([key isKindOfClass:NSString.class] && [value isKindOfClass:NSDictionary.class]) {
                self.entries[key] = [value mutableCopy];
            }
        }];
    }

    id hashes = root[@"unknownHashes"];
    if ([hashes isKindOfClass:NSArray.class]) {
        for (id hash in (NSArray *)hashes) {
            if ([hash isKindOfClass:NSString.class]) {
                [self.unknownHashes addObject:hash];
            }
        }
    }
}

- (nullable NSString *)fileNameForProjectId:(NSString *)projectId {
    // Sorted so the answer is stable if two files somehow share a project.
    for (NSString *fileName in [self.entries.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        if ([self.entries[fileName][@"projectId"] isEqual:projectId]) {
            return fileName;
        }
    }
    return nil;
}

- (NSArray<NSString *> *)fileNamesRequiringProject:(NSString *)projectId {
    NSMutableArray<NSString *> *names = [NSMutableArray new];
    for (NSString *fileName in [self.entries.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        id requiredIds = self.entries[fileName][@"requires"];
        if ([requiredIds isKindOfClass:NSArray.class] && [requiredIds containsObject:projectId]) {
            [names addObject:fileName];
        }
    }
    return names;
}

- (void)pruneEntriesNotIn:(NSSet<NSString *> *)existingFileNames {
    for (NSString *fileName in self.entries.allKeys) {
        if (![existingFileNames containsObject:fileName]) {
            [self.entries removeObjectForKey:fileName];
        }
    }
}

- (BOOL)save:(NSError **)error {
    NSDictionary *root = @{
        @"formatVersion": @(kModIndexFormatVersion),
        @"mods": self.entries,
        @"unknownHashes": [self.unknownHashes.allObjects sortedArrayUsingSelector:@selector(compare:)]};
    if (![NSJSONSerialization isValidJSONObject:root]) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSPropertyListWriteInvalidError
                                     userInfo:@{NSLocalizedDescriptionKey: @"The mod record contains values that cannot be saved."}];
        }
        return NO;
    }

    NSData *data = [NSJSONSerialization dataWithJSONObject:root
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:error];
    if (!data) return NO;

    if (![NSFileManager.defaultManager createDirectoryAtPath:self.modsDir withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }
    return [data writeToFile:[self filePath] options:NSDataWritingAtomic error:error];
}

+ (BOOL)entry:(NSDictionary *)entry matchesLoaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc {
    id entryLoaders = entry[@"loaders"];
    id gameVersions = entry[@"gameVersions"];
    if (![entryLoaders isKindOfClass:NSArray.class] || ![gameVersions isKindOfClass:NSArray.class]) return NO;
    if (![gameVersions containsObject:mc]) return NO;
    for (NSString *loader in loaders) {
        if ([entryLoaders containsObject:loader]) return YES;
    }
    return NO;
}

+ (NSMutableDictionary *)entryForVersion:(NSDictionary *)version file:(NSDictionary *)file project:(nullable NSDictionary *)project {
    NSMutableDictionary *entry = [NSMutableDictionary new];
    CopyValue(entry, @"projectId", version, @"project_id", NSString.class);
    CopyValue(entry, @"versionId", version, @"id", NSString.class);
    CopyValue(entry, @"versionNumber", version, @"version_number", NSString.class);
    CopyValue(entry, @"versionType", version, @"version_type", NSString.class);
    CopyValue(entry, @"gameVersions", version, @"game_versions", NSArray.class);
    CopyValue(entry, @"loaders", version, @"loaders", NSArray.class);

    id hashes = file[@"hashes"];
    if ([hashes isKindOfClass:NSDictionary.class]) {
        CopyValue(entry, @"sha1", hashes, @"sha1", NSString.class);
    }

    NSMutableArray<NSString *> *requiredIds = [NSMutableArray new];
    id dependencies = version[@"dependencies"];
    if ([dependencies isKindOfClass:NSArray.class]) {
        for (id dependency in (NSArray *)dependencies) {
            if (![dependency isKindOfClass:NSDictionary.class]) continue;
            if (![dependency[@"dependency_type"] isEqual:@"required"]) continue;
            id projectId = dependency[@"project_id"];
            if ([projectId isKindOfClass:NSString.class]) {
                [requiredIds addObject:projectId];
            }
        }
    }
    entry[@"requires"] = requiredIds;

    CopyValue(entry, @"title", project, @"title", NSString.class);
    if (!entry[@"title"]) {
        CopyValue(entry, @"title", version, @"name", NSString.class);
    }
    CopyValue(entry, @"slug", project, @"slug", NSString.class);
    CopyValue(entry, @"iconUrl", project, @"icon_url", NSString.class);
    return entry;
}

@end

NS_ASSUME_NONNULL_END
