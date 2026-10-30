#import "ModInstaller.h"
#import "ModContentKind.h"
#import "ModFolder.h"
#import "ModVersionSelector.h"

NS_ASSUME_NONNULL_BEGIN

NSErrorDomain const ModInstallErrorDomain = @"ModInstallErrorDomain";

static NSString *const kDisabledSuffix = @".disabled";
static NSString *const kPartSuffix = @".part";
/* An old file waiting to be deleted (or put back) while a plan is applied. */
static NSString *const kOldSuffix = @".old";

#pragma mark - Helpers

/* YES if anything exists at `path`, including a broken symlink. */
static BOOL ItemExists(NSString *path) {
    return [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] != nil;
}

/* Same rule as ModFolder's import: "." and ".." would resolve to a folder and a "/" would point
   outside the mods folder. */
static BOOL IsPlainFileName(id _Nullable name) {
    if (![name isKindOfClass:NSString.class]) return NO;
    NSString *string = name;
    return string.length > 0 && ![string isEqualToString:@"."] && ![string isEqualToString:@".."] && ![string containsString:@"/"];
}

/* YES for the folder's own names: the record, and anything ending in ".part", ".old" or ".disabled". */
static BOOL IsReservedFileName(NSString *name) {
    if ([name isEqualToString:ModIndexFileName]) return YES;
    NSString *lower = name.lowercaseString;
    for (NSString *reserved in @[kPartSuffix, kOldSuffix, kDisabledSuffix]) {
        if ([lower hasSuffix:reserved]) return YES;
    }
    return NO;
}

/* YES when `name` ends in ".<extension>" in any case. */
static BOOL HasFileExtension(NSString *name, NSString *extension) {
    return [name.lowercaseString hasSuffix:[@"." stringByAppendingString:extension]];
}

/* The name a downloaded file is saved under, or nil when `name` cannot be used. It must be a plain file
   name ending in ".<extension>" ("jar" or "zip") in any case (the folder only lists that kind of file, so
   anything else would be installed but never shown) and is saved with a lowercase extension ("Foo.JAR"
   becomes "Foo.jar"). The folder's own names are refused: the record, and anything ending in ".part",
   ".old" or ".disabled". */
static NSString * _Nullable InstallFileName(id _Nullable name, NSString *extension) {
    if (!IsPlainFileName(name)) return nil;
    NSString *string = name;
    if (IsReservedFileName(string)) return nil;
    NSString *suffix = [@"." stringByAppendingString:extension];
    if (!HasFileExtension(string, extension) || string.length <= suffix.length) return nil;
    if (![string hasSuffix:suffix]) {
        string = [[string substringToIndex:string.length - suffix.length] stringByAppendingString:suffix];
    }
    return string;
}

static NSString * _Nullable NonEmptyString(id _Nullable value) {
    return [value isKindOfClass:NSString.class] && [(NSString *)value length] > 0 ? value : nil;
}

static NSError *InstallError(ModInstallError code, NSString * _Nullable fileName, NSString *message, NSError * _Nullable underlying) {
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionaryWithObject:message forKey:NSLocalizedDescriptionKey];
    if (fileName) userInfo[@"fileName"] = fileName;
    if (underlying) userInfo[NSUnderlyingErrorKey] = underlying;
    return [NSError errorWithDomain:ModInstallErrorDomain code:code userInfo:userInfo];
}

#pragma mark - ModInstallItem

/* One version of the plan, checked and ready to download. */
@interface ModInstallItem : NSObject
@property(nonatomic, strong) NSDictionary *version;
@property(nonatomic, strong) NSDictionary *file;
@property(nonatomic, copy) NSString *fileName;
@property(nonatomic, copy) NSString *partPath;
@property(nonatomic, strong) NSURL *url;
@property(nonatomic) BOOL usesSha1; // else sha512
@property(nonatomic, copy) NSString *expectedHash; // lowercase
@property(nonatomic, copy, nullable) NSString *projectId;

/* Filled in when the plan is applied. */
@property(nonatomic, copy, nullable) NSString *replacedKey; // index key of the same project's old file
@property(nonatomic, strong) NSMutableArray<NSString *> *replacedPaths;
@property(nonatomic) BOOL replacedWasDisabled;
@end

@implementation ModInstallItem
- (instancetype)init {
    self = [super init];
    _replacedPaths = [NSMutableArray new];
    return self;
}
@end

#pragma mark - ModInstaller

@interface ModInstaller ()
@property(nonatomic, strong) ModIndex *index;
@property(nonatomic, copy) ModDownloader downloader;
@property(nonatomic, strong) ModContentKind *kind;
@end

@implementation ModInstaller

+ (NSString *)userAgent {
    NSString *version = NonEmptyString(NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"]) ?: @"dev";
    return [NSString stringWithFormat:@"Amethyst-iOS/%@ (github.com/Raymon82777/Amethyst-iOS-Improved)", version];
}

+ (ModDownloader)defaultDownloader {
    return ^(NSURL *url, NSString *destPath, ModDownloadCompletion completion) {
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        [request setValue:[ModInstaller userAgent] forHTTPHeaderField:@"User-Agent"];
        NSURLSessionDownloadTask *task = [NSURLSession.sharedSession downloadTaskWithRequest:request
                completionHandler:^(NSURL * _Nullable location, NSURLResponse * _Nullable response, NSError * _Nullable error) {
            if (error) {
                completion(error);
                return;
            }
            if ([response isKindOfClass:NSHTTPURLResponse.class]) {
                NSInteger status = ((NSHTTPURLResponse *)response).statusCode;
                if (status < 200 || status > 299) {
                    completion([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse
                                               userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"The server answered with HTTP %ld.", (long)status]}]);
                    return;
                }
            }
            if (!location) {
                completion([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotCreateFile userInfo:nil]);
                return;
            }
            // The temporary file is deleted as soon as this handler returns, so move it now.
            NSFileManager *fm = NSFileManager.defaultManager;
            [fm removeItemAtPath:destPath error:nil];
            NSError *moveError = nil;
            if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:destPath] error:&moveError]) {
                completion(moveError);
                return;
            }
            completion(nil);
        }];
        [task resume];
    };
}

- (instancetype)initWithIndex:(ModIndex *)index downloader:(ModDownloader)downloader kind:(ModContentKind *)kind {
    self = [super init];
    _index = index;
    _downloader = [downloader copy];
    _kind = kind;
    return self;
}

- (instancetype)initWithIndex:(ModIndex *)index downloader:(ModDownloader)downloader {
    return [self initWithIndex:index downloader:downloader kind:ModContentKind.mods];
}

#pragma mark Install

- (void)installPlan:(ModInstallPlan *)plan
           projects:(NSDictionary<NSString *, NSDictionary *> *)projects
         completion:(void (^)(NSError * _Nullable error))completion {
    NSError *error = nil;
    NSArray<ModInstallItem *> *items = [self itemsForPlan:plan error:&error];
    if (!items) {
        completion(error);
        return;
    }

    NSError *directoryError = nil;
    if (![NSFileManager.defaultManager createDirectoryAtPath:self.index.modsDir withIntermediateDirectories:YES attributes:nil error:&directoryError]) {
        completion(InstallError(ModInstallErrorFileSystem, nil, @"The mods folder could not be created.", directoryError));
        return;
    }
    [self downloadItems:items atIndex:0 plan:plan projects:projects completion:completion];
}

/* Checks every version of the plan before anything is downloaded or touched. */
- (nullable NSArray<ModInstallItem *> *)itemsForPlan:(ModInstallPlan *)plan error:(NSError **)error {
    NSMutableArray<ModInstallItem *> *items = [NSMutableArray new];
    for (NSDictionary *version in plan.versionsToInstall) {
        NSDictionary *file = [ModVersionSelector primaryFileOfVersion:version];
        if (!file) {
            *error = InstallError(ModInstallErrorDownload, nil, @"A mod version has no file to download.", nil);
            return nil;
        }
        id publishedName = file[@"filename"];
        NSString *extension = self.kind.fileExtension;
        NSString *fileName = InstallFileName(publishedName, extension);
        if (!fileName) {
            NSString *published = NonEmptyString(publishedName);
            BOOL wrongExtension = published && IsPlainFileName(published) && !IsReservedFileName(published)
                && !HasFileExtension(published, extension);
            NSString *message = wrongExtension
                ? [NSString stringWithFormat:@"%@ is not a .%@ file.", published, extension]
                : @"The mod does not have a valid file name.";
            *error = InstallError(ModInstallErrorFileSystem, published, message, nil);
            return nil;
        }
        NSString *urlString = NonEmptyString(file[@"url"]);
        NSURL *url = urlString ? [NSURL URLWithString:urlString] : nil;
        if (!url) {
            *error = InstallError(ModInstallErrorDownload, fileName, @"The mod file has no download address.", nil);
            return nil;
        }

        id hashes = file[@"hashes"];
        NSString *sha1 = [hashes isKindOfClass:NSDictionary.class] ? NonEmptyString(hashes[@"sha1"]) : nil;
        NSString *sha512 = [hashes isKindOfClass:NSDictionary.class] ? NonEmptyString(hashes[@"sha512"]) : nil;
        if (!sha1 && !sha512) {
            *error = InstallError(ModInstallErrorNoHash, fileName, @"The mod file cannot be verified because no hash is listed for it.", nil);
            return nil;
        }

        ModInstallItem *item = [ModInstallItem new];
        item.version = version;
        item.file = file;
        item.fileName = fileName;
        item.partPath = [[self.index.modsDir stringByAppendingPathComponent:fileName] stringByAppendingString:kPartSuffix];
        item.url = url;
        item.usesSha1 = sha1 != nil;
        item.expectedHash = (sha1 ?: sha512).lowercaseString;
        item.projectId = NonEmptyString(version[@"project_id"]);
        [items addObject:item];
    }
    return items;
}

/* Downloads and verifies one file at a time, then applies the plan. The downloader may call back
   synchronously or on another queue. */
- (void)downloadItems:(NSArray<ModInstallItem *> *)items
              atIndex:(NSUInteger)position
                 plan:(ModInstallPlan *)plan
             projects:(NSDictionary<NSString *, NSDictionary *> *)projects
           completion:(void (^)(NSError * _Nullable error))completion {
    if (position >= items.count) {
        completion([self commitItems:items enableProjectIds:plan.projectIdsToEnable projects:projects]);
        return;
    }

    ModInstallItem *item = items[position];
    [NSFileManager.defaultManager removeItemAtPath:item.partPath error:nil];
    __block BOOL handled = NO; // a downloader that calls back twice is ignored the second time
    self.downloader(item.url, item.partPath, ^(NSError * _Nullable downloadError) {
        if (handled) return;
        handled = YES;

        NSError *failure = downloadError
            ? InstallError(ModInstallErrorDownload, item.fileName, [NSString stringWithFormat:@"%@ could not be downloaded.", item.fileName], downloadError)
            : [self verifyItem:item];
        if (failure) {
            for (ModInstallItem *each in items) {
                [NSFileManager.defaultManager removeItemAtPath:each.partPath error:nil];
            }
            completion(failure);
            return;
        }
        [self downloadItems:items atIndex:position + 1 plan:plan projects:projects completion:completion];
    });
}

- (nullable NSError *)verifyItem:(ModInstallItem *)item {
    NSString *actual = item.usesSha1 ? [ModFolder sha1OfFileAtPath:item.partPath] : [ModFolder sha512OfFileAtPath:item.partPath];
    if (!actual) {
        return InstallError(ModInstallErrorDownload, item.fileName, [NSString stringWithFormat:@"%@ was not saved.", item.fileName], nil);
    }
    if (![actual isEqualToString:item.expectedHash]) {
        return InstallError(ModInstallErrorHashMismatch, item.fileName,
                            [NSString stringWithFormat:@"%@ does not match its published checksum.", item.fileName], nil);
    }
    return nil;
}

/* Swaps the verified files in and records them. Old files are first renamed aside to "<name>.old", so
   any failure can put everything back; they are deleted only once the record has been saved. */
- (nullable NSError *)commitItems:(NSArray<ModInstallItem *> *)items
                 enableProjectIds:(NSArray<NSString *> *)enableProjectIds
                         projects:(NSDictionary<NSString *, NSDictionary *> *)projects {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = self.index.modsDir;
    NSMutableArray<NSArray<NSString *> *> *movedAside = [NSMutableArray new]; // @[original path, ".old" path]
    NSMutableArray<NSString *> *installed = [NSMutableArray new];             // new files in place
    NSMutableArray<NSArray<NSString *> *> *switchedOn = [NSMutableArray new]; // @[".disabled" path, enabled path]

    void (^rollBack)(void) = ^{
        for (NSArray<NSString *> *pair in switchedOn.reverseObjectEnumerator) {
            [fm moveItemAtPath:pair[1] toPath:pair[0] error:nil];
        }
        for (NSString *path in installed) {
            [fm removeItemAtPath:path error:nil];
        }
        for (NSArray<NSString *> *pair in movedAside.reverseObjectEnumerator) {
            [fm moveItemAtPath:pair[1] toPath:pair[0] error:nil];
        }
        for (ModInstallItem *item in items) {
            [fm removeItemAtPath:item.partPath error:nil];
        }
    };

    // What each version replaces: the file recorded for its project, and any file already using the
    // downloaded name (recorded or not), enabled or disabled.
    for (ModInstallItem *item in items) {
        NSMutableArray<NSString *> *names = [NSMutableArray arrayWithObject:item.fileName];
        NSString *recorded = item.projectId ? [self.index fileNameForProjectId:item.projectId] : nil;
        if (recorded && IsPlainFileName(recorded)) {
            item.replacedKey = recorded;
            if (![recorded isEqualToString:item.fileName]) [names addObject:recorded];
        }
        for (NSString *name in names) {
            NSString *path = [dir stringByAppendingPathComponent:name];
            NSString *twin = [path stringByAppendingString:kDisabledSuffix];
            if (ItemExists(path)) [item.replacedPaths addObject:path];
            if (ItemExists(twin)) {
                [item.replacedPaths addObject:twin];
                item.replacedWasDisabled = YES;
            }
        }
    }

    for (ModInstallItem *item in items) {
        for (NSString *path in item.replacedPaths) {
            NSString *aside = [path stringByAppendingString:kOldSuffix];
            [fm removeItemAtPath:aside error:nil];
            NSError *moveError = nil;
            if (![fm moveItemAtPath:path toPath:aside error:&moveError]) {
                rollBack();
                return InstallError(ModInstallErrorFileSystem, item.fileName,
                                    [NSString stringWithFormat:@"The old version of %@ could not be replaced.", item.fileName], moveError);
            }
            [movedAside addObject:@[path, aside]];
        }
    }

    for (ModInstallItem *item in items) {
        NSString *finalName = item.replacedWasDisabled ? [item.fileName stringByAppendingString:kDisabledSuffix] : item.fileName;
        NSString *target = [dir stringByAppendingPathComponent:finalName];
        NSError *moveError = nil;
        if (![fm moveItemAtPath:item.partPath toPath:target error:&moveError]) {
            rollBack();
            return InstallError(ModInstallErrorFileSystem, item.fileName,
                                [NSString stringWithFormat:@"%@ could not be installed.", item.fileName], moveError);
        }
        [installed addObject:target];
    }

    for (NSString *projectId in enableProjectIds) {
        NSString *name = [self.index fileNameForProjectId:projectId];
        if (!name || !IsPlainFileName(name)) continue;
        NSString *enabledPath = [dir stringByAppendingPathComponent:name];
        NSString *disabledPath = [enabledPath stringByAppendingString:kDisabledSuffix];
        if (!ItemExists(disabledPath)) continue;
        NSError *moveError = nil;
        if (![fm moveItemAtPath:disabledPath toPath:enabledPath error:&moveError]) {
            rollBack();
            return InstallError(ModInstallErrorFileSystem, name,
                                [NSString stringWithFormat:@"%@ could not be switched on.", name], moveError);
        }
        [switchedOn addObject:@[disabledPath, enabledPath]];
    }

    for (ModInstallItem *item in items) {
        if (item.replacedKey && ![item.replacedKey isEqualToString:item.fileName]) {
            [self.index.entries removeObjectForKey:item.replacedKey];
        }
        NSDictionary *project = item.projectId ? projects[item.projectId] : nil;
        if (![project isKindOfClass:NSDictionary.class]) project = nil;
        self.index.entries[item.fileName] = [ModIndex entryForVersion:item.version file:item.file project:project];
    }

    // If saving fails the files stay installed (they are the user's mods now); only the record is behind.
    NSError *saveError = nil;
    BOOL saved = [self.index save:&saveError];
    for (NSArray<NSString *> *pair in movedAside) {
        [fm removeItemAtPath:pair[1] error:nil];
    }
    if (!saved) {
        return InstallError(ModInstallErrorFileSystem, ModIndexFileName, @"The mods were installed, but the mod record could not be saved.", saveError);
    }
    return nil;
}

@end

NS_ASSUME_NONNULL_END
