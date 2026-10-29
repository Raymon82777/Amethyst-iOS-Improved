#import <CommonCrypto/CommonDigest.h>
#import "ModFolder.h"
#import "ModIndex.h"

NS_ASSUME_NONNULL_BEGIN

NSErrorDomain const ModFolderErrorDomain = @"ModFolderErrorDomain";

static NSString *const kDisabledSuffix = @".disabled";
static NSString *const kPartSuffix = @".part";
static NSString *const kCustomGameDirName = @"custom_gamedir";
static const NSUInteger kHashChunkSize = 1024 * 1024;

#pragma mark - Helpers

/* YES if anything exists at `path`, including a broken symlink. */
static BOOL ItemExists(NSString *path) {
    return [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] != nil;
}

static NSError *ExistsError(NSString *fileName) {
    return [NSError errorWithDomain:ModFolderErrorDomain code:ModFolderErrorExists
                           userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"A mod named %@ already exists.", fileName]}];
}

/* Feeds the file to `consume` in 1 MB chunks. NO if it cannot be opened or read. */
static BOOL ForEachChunk(NSString *path, void (^consume)(NSData *chunk)) {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!handle) return NO;
    BOOL ok = YES;
    BOOL finished = NO;
    while (!finished) {
        @autoreleasepool {
            NSData *chunk = [handle readDataUpToLength:kHashChunkSize error:nil];
            if (!chunk) {
                ok = NO;
                finished = YES;
            } else if (chunk.length == 0) {
                finished = YES;
            } else {
                consume(chunk);
            }
        }
    }
    [handle closeAndReturnError:nil];
    return ok;
}

static NSString *HexString(const unsigned char *bytes, NSUInteger length) {
    NSMutableString *hex = [NSMutableString stringWithCapacity:length * 2];
    for (NSUInteger i = 0; i < length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

#pragma mark - ModJar

@implementation ModJar
@end

#pragma mark - ModFolder

@implementation ModFolder

- (instancetype)initWithModsDir:(NSString *)modsDir {
    self = [super init];
    _modsDir = [modsDir copy];
    [NSFileManager.defaultManager createDirectoryAtPath:_modsDir withIntermediateDirectories:YES attributes:nil error:nil];
    return self;
}

- (NSArray<ModJar *> *)scanJars {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<ModJar *> *jars = [NSMutableArray new];
    for (NSString *name in [fm contentsOfDirectoryAtPath:self.modsDir error:nil] ?: @[]) {
        if ([name isEqualToString:ModIndexFileName]) continue;
        NSString *path = [self.modsDir stringByAppendingPathComponent:name];

        if ([name hasSuffix:kPartSuffix]) {
            [fm removeItemAtPath:path error:nil];
            continue;
        }

        BOOL enabled;
        NSString *fileName;
        if ([name hasSuffix:@".jar"]) {
            enabled = YES;
            fileName = name;
        } else if ([name hasSuffix:[@".jar" stringByAppendingString:kDisabledSuffix]]) {
            enabled = NO;
            fileName = [name substringToIndex:name.length - kDisabledSuffix.length];
        } else {
            continue;
        }

        BOOL isDirectory = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDirectory] || isDirectory) continue;

        ModJar *jar = [ModJar new];
        jar.fileName = fileName;
        jar.path = path;
        jar.enabled = enabled;
        [jars addObject:jar];
    }
    return [jars sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(ModJar *a, ModJar *b) {
        return [a.fileName caseInsensitiveCompare:b.fileName];
    }];
}

- (BOOL)setJar:(ModJar *)jar enabled:(BOOL)enabled error:(NSError **)error {
    if (jar.enabled == enabled) return YES;

    NSString *directory = [jar.path stringByDeletingLastPathComponent];
    NSString *targetName = enabled ? jar.fileName : [jar.fileName stringByAppendingString:kDisabledSuffix];
    NSString *targetPath = [directory stringByAppendingPathComponent:targetName];
    if (ItemExists(targetPath)) {
        if (error) *error = ExistsError(targetName);
        return NO;
    }
    if (![NSFileManager.defaultManager moveItemAtPath:jar.path toPath:targetPath error:error]) {
        return NO;
    }
    jar.path = targetPath;
    jar.enabled = enabled;
    return YES;
}

- (BOOL)deleteJar:(ModJar *)jar error:(NSError **)error {
    return [NSFileManager.defaultManager removeItemAtPath:jar.path error:error];
}

- (nullable NSString *)importJarFromURL:(NSURL *)url asFileName:(nullable NSString *)fileName replaceExisting:(BOOL)replace error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    // A name must be a single plain file name: "." and ".." would resolve to a folder, and a "/" would
    // point outside the mods folder.
    NSString *name = fileName ?: url.lastPathComponent;
    if (name.length == 0 || [name isEqualToString:@"."] || [name isEqualToString:@".."] || [name containsString:@"/"]) {
        if (error) {
            *error = [NSError errorWithDomain:NSCocoaErrorDomain code:NSFileWriteInvalidFileNameError
                                     userInfo:@{NSLocalizedDescriptionKey: @"The mod does not have a valid file name."}];
        }
        return nil;
    }

    NSString *targetPath = [self.modsDir stringByAppendingPathComponent:name];
    NSString *twinPath = [targetPath stringByAppendingString:kDisabledSuffix];
    BOOL clash = ItemExists(targetPath) || ItemExists(twinPath);
    if (clash && !replace) {
        if (error) *error = ExistsError(name);
        return nil;
    }

    // Copy beside the target first so an interrupted import leaves only a stray .part.
    NSString *partPath = [targetPath stringByAppendingString:kPartSuffix];
    [fm removeItemAtPath:partPath error:nil];
    if (![fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:partPath] error:error]) {
        [fm removeItemAtPath:partPath error:nil];
        return nil;
    }
    if (clash) {
        [fm removeItemAtPath:targetPath error:nil];
        [fm removeItemAtPath:twinPath error:nil];
    }
    if (![fm moveItemAtPath:partPath toPath:targetPath error:error]) {
        [fm removeItemAtPath:partPath error:nil];
        return nil;
    }
    return name;
}

- (NSString *)uniqueFileNameFor:(NSString *)fileName {
    NSString *stem = fileName.stringByDeletingPathExtension;
    NSString *extension = fileName.pathExtension;
    NSString *candidate = fileName;
    for (NSUInteger n = 2; ; n++) {
        NSString *path = [self.modsDir stringByAppendingPathComponent:candidate];
        if (!ItemExists(path) && !ItemExists([path stringByAppendingString:kDisabledSuffix])) {
            return candidate;
        }
        candidate = [NSString stringWithFormat:@"%@ (%lu)", stem, (unsigned long)n];
        if (extension.length > 0) {
            candidate = [candidate stringByAppendingPathExtension:extension];
        }
    }
}

#pragma mark Hashing

// SHA-1 is only used to match Modrinth's file hashes, never for security.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
+ (nullable NSString *)sha1OfFileAtPath:(NSString *)path {
    __block CC_SHA1_CTX context;
    CC_SHA1_Init(&context);
    BOOL ok = ForEachChunk(path, ^(NSData *chunk) {
        CC_SHA1_Update(&context, chunk.bytes, (CC_LONG)chunk.length);
    });
    if (!ok) return nil;
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &context);
    return HexString(digest, CC_SHA1_DIGEST_LENGTH);
}
#pragma clang diagnostic pop

+ (nullable NSString *)sha512OfFileAtPath:(NSString *)path {
    __block CC_SHA512_CTX context;
    CC_SHA512_Init(&context);
    BOOL ok = ForEachChunk(path, ^(NSData *chunk) {
        CC_SHA512_Update(&context, chunk.bytes, (CC_LONG)chunk.length);
    });
    if (!ok) return nil;
    unsigned char digest[CC_SHA512_DIGEST_LENGTH];
    CC_SHA512_Final(digest, &context);
    return HexString(digest, CC_SHA512_DIGEST_LENGTH);
}

#pragma mark Game folder

+ (NSString *)gameDirPathForGameDir:(nullable NSString *)gameDir baseDir:(NSString *)baseDir {
    // Joined the way JavaLauncher builds the folder the game runs in ("<base>/<gameDir>", standardized),
    // so an absolute value such as "/foo" also lands inside the base folder.
    NSString *relative = gameDir.length > 0 ? gameDir : @".";
    return [NSString stringWithFormat:@"%@/%@", baseDir, relative].stringByStandardizingPath;
}

+ (BOOL)isSharedGameDir:(nullable NSString *)gameDir baseDir:(NSString *)baseDir {
    NSString *gameDirPath = [self gameDirPathForGameDir:gameDir baseDir:baseDir];
    return [gameDirPath isEqualToString:baseDir.stringByStandardizingPath];
}

+ (NSString *)safeFolderName:(NSString *)profileName {
    NSCharacterSet *controls = NSCharacterSet.controlCharacterSet;
    NSCharacterSet *whitespace = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSMutableString *name = [NSMutableString stringWithCapacity:profileName.length];
    for (NSUInteger i = 0; i < profileName.length; i++) {
        unichar c = [profileName characterAtIndex:i];
        if (c == '/' || c == '\\' || c == ':' || [controls characterIsMember:c]) {
            c = '_';
        }
        [name appendFormat:@"%C", c];
    }

    // Leading whitespace and dots go together, so ". .." cannot leave a "." or ".." behind.
    NSMutableCharacterSet *leading = [whitespace mutableCopy];
    [leading addCharactersInString:@"."];
    NSUInteger start = 0;
    while (start < name.length && [leading characterIsMember:[name characterAtIndex:start]]) {
        start++;
    }
    NSString *result = [[name substringFromIndex:start] stringByTrimmingCharactersInSet:whitespace];
    if (result.length == 0 || [result isEqualToString:@"."] || [result isEqualToString:@".."]) {
        return @"Profile";
    }
    return result;
}

+ (nullable NSString *)migrateProfileNamed:(NSString *)profileName baseDir:(NSString *)baseDir error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *customRoot = [baseDir stringByAppendingPathComponent:kCustomGameDirName];
    NSString *safeName = [self safeFolderName:profileName];

    NSString *folderName = safeName;
    for (NSUInteger n = 2; ItemExists([customRoot stringByAppendingPathComponent:folderName]); n++) {
        folderName = [NSString stringWithFormat:@"%@ (%lu)", safeName, (unsigned long)n];
    }

    NSString *folderPath = [customRoot stringByAppendingPathComponent:folderName];
    if (![fm createDirectoryAtPath:[folderPath stringByAppendingPathComponent:@"mods"] withIntermediateDirectories:YES attributes:nil error:error]) {
        return nil;
    }

    NSString *sourceOptions = [baseDir stringByAppendingPathComponent:@"options.txt"];
    NSString *targetOptions = [folderPath stringByAppendingPathComponent:@"options.txt"];
    if (ItemExists(sourceOptions) && !ItemExists(targetOptions)) {
        if (![fm copyItemAtPath:sourceOptions toPath:targetOptions error:error]) {
            return nil;
        }
    }
    return [NSString stringWithFormat:@"./%@/%@", kCustomGameDirName, folderName];
}

@end

NS_ASSUME_NONNULL_END
