#import <CommonCrypto/CommonDigest.h>
#import "ModFolder.h"
#import "ModIndex.h"
#import "ModInstaller.h"
#import "ModTest.h"

#pragma mark - Helpers

static NSString *MakeTempDir(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"ModInstallerTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static void RemoveDir(NSString *dir) {
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}

static void WriteFile(NSString *dir, NSString *name, NSString *content) {
    [content writeToFile:[dir stringByAppendingPathComponent:name] atomically:NO encoding:NSUTF8StringEncoding error:nil];
}

static NSString *ReadFile(NSString *dir, NSString *name) {
    return [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:name] encoding:NSUTF8StringEncoding error:nil];
}

static BOOL Exists(NSString *dir, NSString *name) {
    return [NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:name]];
}

static NSArray<NSString *> *Listing(NSString *dir) {
    return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)];
}

static NSString *HexString(const unsigned char *bytes, int length) {
    NSMutableString *hex = [NSMutableString new];
    for (int i = 0; i < length; i++) [hex appendFormat:@"%02x", bytes[i]];
    return hex;
}

static NSString *Sha1Of(NSString *content) {
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
#pragma clang diagnostic pop
    return HexString(digest, CC_SHA1_DIGEST_LENGTH);
}

static NSString *Sha512Of(NSString *content) {
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char digest[CC_SHA512_DIGEST_LENGTH];
    CC_SHA512(data.bytes, (CC_LONG)data.length, digest);
    return HexString(digest, CC_SHA512_DIGEST_LENGTH);
}

static NSString *UrlFor(NSString *fileName) {
    return [@"https://cdn.example.com/" stringByAppendingString:fileName];
}

/* A Modrinth version with one primary file. `hashes` is what the version lists for the file. */
static NSDictionary *VersionWithHashes(NSString *projectId, NSString *versionId, NSString *fileName, NSDictionary *hashes) {
    return @{
        @"id": versionId,
        @"project_id": projectId,
        @"name": [@"Name of " stringByAppendingString:versionId],
        @"version_number": versionId,
        @"version_type": @"release",
        @"loaders": @[@"fabric"],
        @"game_versions": @[@"1.21.1"],
        @"files": @[@{@"url": UrlFor(fileName), @"filename": fileName, @"primary": @YES, @"hashes": hashes}],
        @"dependencies": @[]};
}

/* A version whose file really has the bytes `content` (what a fake downloader serves for it). */
static NSDictionary *Version(NSString *projectId, NSString *versionId, NSString *fileName, NSString *content) {
    return VersionWithHashes(projectId, versionId, fileName, @{@"sha1": Sha1Of(content), @"sha512": Sha512Of(content)});
}

static ModInstallPlan *Plan(NSArray<NSDictionary *> *versions, NSArray<NSString *> *enable) {
    ModInstallPlan *plan = [ModInstallPlan new];
    plan.versionsToInstall = versions;
    plan.projectIdsToEnable = enable;
    plan.incompatibleInstalledProjectIds = @[];
    plan.optionalProjectIds = @[];
    return plan;
}

/* Serves what `responses` says per URL: a string is written as the file's bytes, an NSError fails the
   download. Anything unlisted fails. Logs every requested URL. Async completes on another queue. */
static ModDownloader FakeDownloader(NSDictionary<NSString *, id> *responses, NSMutableArray<NSString *> *log, BOOL async) {
    return ^(NSURL *url, NSString *destPath, ModDownloadCompletion completion) {
        [log addObject:url.absoluteString];
        id response = responses[url.absoluteString];
        void (^deliver)(void) = ^{
            if ([response isKindOfClass:NSString.class]) {
                [(NSString *)response writeToFile:destPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
                completion(nil);
            } else if ([response isKindOfClass:NSError.class]) {
                completion(response);
            } else {
                completion([NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil]);
            }
        };
        if (async) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), deliver);
        } else {
            deliver();
        }
    };
}

/* Runs the install and waits for it. Also checks the completion block ran exactly once. */
static NSError *RunInstall(ModInstaller *installer, ModInstallPlan *plan, NSDictionary<NSString *, NSDictionary *> *projects) {
    __block NSError *result = nil;
    __block int calls = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [installer installPlan:plan projects:projects completion:^(NSError *error) {
        result = error;
        calls++;
        dispatch_semaphore_signal(done);
    }];
    long timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    MT_ASSERT(timedOut == 0);
    MT_EQUAL(@(calls), @1);
    return result;
}

/* Records `fileName` in the saved index of `dir` as a mod of `projectId`. */
static void SeedIndex(NSString *dir, NSString *fileName, NSString *projectId) {
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];
    index.entries[fileName] = [@{@"projectId": projectId, @"versionId": @"old", @"requires": @[]} mutableCopy];
    [index save:nil];
}

static void AssertNoLeftovers(NSString *dir) {
    for (NSString *name in Listing(dir)) {
        MT_ASSERT(![name hasSuffix:@".part"]);
        MT_ASSERT(![name hasSuffix:@".old"]);
    }
}

#pragma mark - Tests

static void testInstallsAndRecords(void) {
    NSString *dir = MakeTempDir();
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];
    NSMutableArray *log = [NSMutableArray new];
    NSDictionary *versionB = VersionWithHashes(@"B", @"vb", @"b.jar", @{@"sha1": Sha1Of(@"beta").uppercaseString});
    NSDictionary *responses = @{UrlFor(@"a.jar"): @"alpha", UrlFor(@"b.jar"): @"beta"};
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:FakeDownloader(responses, log, NO)];

    NSError *error = RunInstall(installer, Plan(@[Version(@"A", @"va", @"a.jar", @"alpha"), versionB], @[]),
                                @{@"A": @{@"title": @"Alpha", @"slug": @"alpha-mod"}});
    MT_EQUAL(error, nil);
    MT_EQUAL(log, (@[UrlFor(@"a.jar"), UrlFor(@"b.jar")]));
    MT_EQUAL(ReadFile(dir, @"a.jar"), @"alpha");
    MT_EQUAL(ReadFile(dir, @"b.jar"), @"beta");
    AssertNoLeftovers(dir);

    MT_EQUAL(index.entries[@"a.jar"][@"projectId"], @"A");
    MT_EQUAL(index.entries[@"a.jar"][@"versionId"], @"va");
    MT_EQUAL(index.entries[@"a.jar"][@"title"], @"Alpha");
    MT_EQUAL(index.entries[@"a.jar"][@"slug"], @"alpha-mod");
    MT_EQUAL(index.entries[@"b.jar"][@"projectId"], @"B");
    MT_EQUAL(index.entries[@"b.jar"][@"title"], @"Name of vb");

    ModIndex *saved = [[ModIndex alloc] initWithModsDir:dir];
    MT_EQUAL(@(saved.entries.count), @2);
    MT_EQUAL(saved.entries[@"a.jar"][@"versionId"], @"va");
    RemoveDir(dir);
}

static void testCompletesOnAnotherQueue(void) {
    NSString *dir = MakeTempDir();
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];
    NSDictionary *responses = @{UrlFor(@"a.jar"): @"alpha", UrlFor(@"b.jar"): @"beta"};
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:FakeDownloader(responses, [NSMutableArray new], YES)];

    NSError *error = RunInstall(installer, Plan(@[Version(@"A", @"va", @"a.jar", @"alpha"), Version(@"B", @"vb", @"b.jar", @"beta")], @[]), @{});
    MT_EQUAL(error, nil);
    MT_EQUAL(ReadFile(dir, @"a.jar"), @"alpha");
    MT_EQUAL(ReadFile(dir, @"b.jar"), @"beta");
    MT_EQUAL(@(index.entries.count), @2);
    AssertNoLeftovers(dir);
    RemoveDir(dir);
}

static void testHashMismatchRollsBack(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"keep.jar", @"keep");
    SeedIndex(dir, @"keep.jar", @"K");
    NSArray *before = Listing(dir);
    NSString *indexBefore = ReadFile(dir, ModIndexFileName);
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];

    NSDictionary *responses = @{UrlFor(@"a.jar"): @"alpha", UrlFor(@"b.jar"): @"tampered"};
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:FakeDownloader(responses, [NSMutableArray new], NO)];
    NSError *error = RunInstall(installer, Plan(@[Version(@"A", @"va", @"a.jar", @"alpha"), Version(@"B", @"vb", @"b.jar", @"beta")], @[]), @{});

    MT_EQUAL(error.domain, ModInstallErrorDomain);
    MT_EQUAL(@(error.code), @(ModInstallErrorHashMismatch));
    MT_EQUAL(error.userInfo[@"fileName"], @"b.jar");
    MT_EQUAL(Listing(dir), before);
    MT_EQUAL(ReadFile(dir, ModIndexFileName), indexBefore);
    MT_EQUAL(ReadFile(dir, @"keep.jar"), @"keep");
    MT_EQUAL(index.entries.allKeys, (@[@"keep.jar"]));
    RemoveDir(dir);
}

static void testDownloadFailureRollsBack(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"keep.jar", @"keep");
    SeedIndex(dir, @"keep.jar", @"K");
    NSArray *before = Listing(dir);
    NSString *indexBefore = ReadFile(dir, ModIndexFileName);
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];

    NSError *offline = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil];
    NSDictionary *responses = @{UrlFor(@"a.jar"): @"alpha", UrlFor(@"b.jar"): offline};
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:FakeDownloader(responses, [NSMutableArray new], NO)];
    NSError *error = RunInstall(installer, Plan(@[Version(@"A", @"va", @"a.jar", @"alpha"), Version(@"B", @"vb", @"b.jar", @"beta")], @[]), @{});

    MT_EQUAL(error.domain, ModInstallErrorDomain);
    MT_EQUAL(@(error.code), @(ModInstallErrorDownload));
    MT_EQUAL(error.userInfo[@"fileName"], @"b.jar");
    MT_EQUAL(error.userInfo[NSUnderlyingErrorKey], offline);
    MT_EQUAL(Listing(dir), before);
    MT_EQUAL(ReadFile(dir, ModIndexFileName), indexBefore);
    MT_EQUAL(index.entries.allKeys, (@[@"keep.jar"]));
    RemoveDir(dir);
}

static void testReplaceKeepsDisabledState(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"sodium-0.5.jar.disabled", @"old sodium");
    SeedIndex(dir, @"sodium-0.5.jar", @"S");
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];

    NSDictionary *responses = @{UrlFor(@"sodium-0.6.jar"): @"new sodium"};
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:FakeDownloader(responses, [NSMutableArray new], NO)];
    NSError *error = RunInstall(installer, Plan(@[Version(@"S", @"s06", @"sodium-0.6.jar", @"new sodium")], @[]), @{});

    MT_EQUAL(error, nil);
    MT_EQUAL(ReadFile(dir, @"sodium-0.6.jar.disabled"), @"new sodium");
    MT_ASSERT(!Exists(dir, @"sodium-0.6.jar"));
    MT_ASSERT(!Exists(dir, @"sodium-0.5.jar.disabled"));
    MT_ASSERT(!Exists(dir, @"sodium-0.5.jar"));
    AssertNoLeftovers(dir);
    MT_EQUAL(index.entries.allKeys, (@[@"sodium-0.6.jar"]));
    MT_EQUAL(index.entries[@"sodium-0.6.jar"][@"versionId"], @"s06");

    ModIndex *saved = [[ModIndex alloc] initWithModsDir:dir];
    MT_EQUAL(saved.entries.allKeys, (@[@"sodium-0.6.jar"]));
    RemoveDir(dir);
}

static void testReplaceKeepsEnabledStateAndSameName(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"lithium.jar", @"old lithium");
    SeedIndex(dir, @"lithium.jar", @"L");
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];

    NSDictionary *responses = @{UrlFor(@"lithium.jar"): @"new lithium"};
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:FakeDownloader(responses, [NSMutableArray new], NO)];
    NSError *error = RunInstall(installer, Plan(@[Version(@"L", @"l2", @"lithium.jar", @"new lithium")], @[]), @{});

    MT_EQUAL(error, nil);
    MT_EQUAL(ReadFile(dir, @"lithium.jar"), @"new lithium");
    MT_EQUAL(index.entries.allKeys, (@[@"lithium.jar"]));
    MT_EQUAL(index.entries[@"lithium.jar"][@"versionId"], @"l2");
    MT_EQUAL(Listing(dir), (@[ModIndexFileName, @"lithium.jar"]));
    RemoveDir(dir);
}

static void testDownloadOverExistingSameNameReplacesIt(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"foo.jar", @"hand added");
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];

    NSDictionary *responses = @{UrlFor(@"foo.jar"): @"downloaded"};
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:FakeDownloader(responses, [NSMutableArray new], NO)];
    NSError *error = RunInstall(installer, Plan(@[Version(@"F", @"f1", @"foo.jar", @"downloaded")], @[]), @{});

    MT_EQUAL(error, nil);
    MT_EQUAL(ReadFile(dir, @"foo.jar"), @"downloaded");
    MT_EQUAL(Listing(dir), (@[ModIndexFileName, @"foo.jar"]));
    MT_EQUAL(index.entries[@"foo.jar"][@"projectId"], @"F");
    RemoveDir(dir);
}

static void testSameNameDisabledTwinStaysDisabled(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"foo.jar.disabled", @"hand added, switched off");
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];

    NSDictionary *responses = @{UrlFor(@"foo.jar"): @"downloaded"};
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:FakeDownloader(responses, [NSMutableArray new], NO)];
    NSError *error = RunInstall(installer, Plan(@[Version(@"F", @"f1", @"foo.jar", @"downloaded")], @[]), @{});

    MT_EQUAL(error, nil);
    MT_EQUAL(ReadFile(dir, @"foo.jar.disabled"), @"downloaded");
    MT_EQUAL(Listing(dir), (@[ModIndexFileName, @"foo.jar.disabled"]));
    MT_EQUAL(index.entries.allKeys, (@[@"foo.jar"]));
    RemoveDir(dir);
}

static void testEnablesRequestedProjects(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"a.jar.disabled", @"library");
    WriteFile(dir, @"c.jar.disabled", @"unrelated, stays off");
    SeedIndex(dir, @"a.jar", @"A");
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];
    index.entries[@"c.jar"] = [@{@"projectId": @"C"} mutableCopy];

    NSDictionary *responses = @{UrlFor(@"b.jar"): @"beta"};
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:FakeDownloader(responses, [NSMutableArray new], NO)];
    NSError *error = RunInstall(installer, Plan(@[Version(@"B", @"vb", @"b.jar", @"beta")], @[@"A"]), @{});

    MT_EQUAL(error, nil);
    MT_EQUAL(ReadFile(dir, @"a.jar"), @"library");
    MT_ASSERT(!Exists(dir, @"a.jar.disabled"));
    MT_EQUAL(ReadFile(dir, @"c.jar.disabled"), @"unrelated, stays off");
    MT_EQUAL(ReadFile(dir, @"b.jar"), @"beta");
    MT_EQUAL(index.entries[@"a.jar"][@"projectId"], @"A");
    AssertNoLeftovers(dir);
    RemoveDir(dir);
}

static void testSha512FallbackAndNoHash(void) {
    NSString *dir = MakeTempDir();
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];
    NSDictionary *responses = @{UrlFor(@"a.jar"): @"alpha", UrlFor(@"b.jar"): @"beta"};
    NSMutableArray *log = [NSMutableArray new];
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:FakeDownloader(responses, log, NO)];

    // Only a sha512: that is what gets checked.
    NSDictionary *onlySha512 = VersionWithHashes(@"A", @"va", @"a.jar", @{@"sha512": Sha512Of(@"alpha")});
    MT_EQUAL(RunInstall(installer, Plan(@[onlySha512], @[]), @{}), nil);
    MT_EQUAL(ReadFile(dir, @"a.jar"), @"alpha");

    // A wrong sha512 is a mismatch.
    NSDictionary *wrongSha512 = VersionWithHashes(@"B", @"vb", @"b.jar", @{@"sha512": Sha512Of(@"something else")});
    NSError *error = RunInstall(installer, Plan(@[wrongSha512], @[]), @{});
    MT_EQUAL(@(error.code), @(ModInstallErrorHashMismatch));
    MT_ASSERT(!Exists(dir, @"b.jar"));

    // sha1 wins when both are listed: a wrong sha1 fails even beside a right sha512.
    NSDictionary *badSha1 = VersionWithHashes(@"B", @"vb", @"b.jar", @{@"sha1": Sha1Of(@"nope"), @"sha512": Sha512Of(@"beta")});
    error = RunInstall(installer, Plan(@[badSha1], @[]), @{});
    MT_EQUAL(@(error.code), @(ModInstallErrorHashMismatch));

    // No hash at all cannot be verified, so nothing is installed.
    NSDictionary *noHash = VersionWithHashes(@"B", @"vb", @"b.jar", @{});
    NSArray *before = Listing(dir);
    error = RunInstall(installer, Plan(@[noHash], @[]), @{});
    MT_EQUAL(error.domain, ModInstallErrorDomain);
    MT_EQUAL(@(error.code), @(ModInstallErrorNoHash));
    MT_EQUAL(error.userInfo[@"fileName"], @"b.jar");
    MT_EQUAL(Listing(dir), before);
    MT_EQUAL(index.entries.allKeys, (@[@"a.jar"]));
    RemoveDir(dir);
}

static void testUnusableVersionsFailBeforeTouchingAnything(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"keep.jar", @"keep");
    NSArray *before = Listing(dir);
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];
    NSMutableArray *log = [NSMutableArray new];
    NSDictionary *responses = @{UrlFor(@"a.jar"): @"alpha"};
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:FakeDownloader(responses, log, NO)];
    NSDictionary *good = Version(@"A", @"va", @"a.jar", @"alpha");

    for (NSString *badName in @[@"", @".", @"..", @"../escape.jar", @"sub/b.jar"]) {
        NSError *error = RunInstall(installer, Plan(@[good, Version(@"B", @"vb", badName, @"beta")], @[]), @{});
        MT_EQUAL(error.domain, ModInstallErrorDomain);
        MT_EQUAL(@(error.code), @(ModInstallErrorFileSystem));
        MT_EQUAL(Listing(dir), before);
        MT_ASSERT(!Exists([dir stringByDeletingLastPathComponent], @"escape.jar"));
    }

    // No file at all, and a file without a URL.
    NSMutableDictionary *noFiles = [Version(@"B", @"vb", @"b.jar", @"beta") mutableCopy];
    noFiles[@"files"] = @[];
    NSError *error = RunInstall(installer, Plan(@[good, noFiles], @[]), @{});
    MT_EQUAL(@(error.code), @(ModInstallErrorDownload));

    NSMutableDictionary *noUrl = [Version(@"B", @"vb", @"b.jar", @"beta") mutableCopy];
    noUrl[@"files"] = @[@{@"filename": @"b.jar", @"primary": @YES, @"hashes": @{@"sha1": Sha1Of(@"beta")}}];
    error = RunInstall(installer, Plan(@[good, noUrl], @[]), @{});
    MT_EQUAL(@(error.code), @(ModInstallErrorDownload));

    MT_EQUAL(Listing(dir), before);
    MT_EQUAL(@(index.entries.count), @0);
    MT_EQUAL(@(log.count), @0);
    RemoveDir(dir);
}

/* Names the folder would not list (or that are its own) are refused before anything is downloaded, so
   a plan that has one installs nothing. */
static void testNonJarAndReservedNamesAreRefused(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"keep.jar", @"keep");
    SeedIndex(dir, @"keep.jar", @"K");
    NSArray *before = Listing(dir);
    NSString *indexBefore = ReadFile(dir, ModIndexFileName);
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];
    NSMutableArray *log = [NSMutableArray new];
    NSDictionary *responses = @{UrlFor(@"a.jar"): @"alpha"};
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:FakeDownloader(responses, log, NO)];
    NSDictionary *good = Version(@"A", @"va", @"a.jar", @"alpha");

    NSArray<NSString *> *badNames = @[@"b.zip", @"b", @".jar", @"b.jar.disabled", @"b.jar.part", @"b.jar.old",
                                      @"b.JAR.DISABLED", ModIndexFileName];
    for (NSString *badName in badNames) {
        NSError *error = RunInstall(installer, Plan(@[good, Version(@"B", @"vb", badName, @"beta")], @[]), @{});
        MT_EQUAL(error.domain, ModInstallErrorDomain);
        MT_EQUAL(@(error.code), @(ModInstallErrorFileSystem));
        MT_EQUAL(error.userInfo[@"fileName"], badName);
        MT_EQUAL(Listing(dir), before);
        MT_EQUAL(ReadFile(dir, ModIndexFileName), indexBefore);
    }
    MT_EQUAL(index.entries.allKeys, (@[@"keep.jar"]));
    MT_EQUAL(@(log.count), @0);
    RemoveDir(dir);
}

/* An uppercase ".JAR" is saved as ".jar", the only kind the folder lists. */
static void testUppercaseJarIsSavedLowercase(void) {
    NSString *dir = MakeTempDir();
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];
    NSMutableArray *log = [NSMutableArray new];
    NSDictionary *responses = @{UrlFor(@"Upper.JAR"): @"upper"};
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:FakeDownloader(responses, log, NO)];

    NSError *error = RunInstall(installer, Plan(@[Version(@"U", @"vu", @"Upper.JAR", @"upper")], @[]), @{});
    MT_EQUAL(error, nil);
    MT_EQUAL(log, (@[UrlFor(@"Upper.JAR")]));
    MT_EQUAL(Listing(dir), (@[ModIndexFileName, @"Upper.jar"]));
    MT_EQUAL(ReadFile(dir, @"Upper.jar"), @"upper");
    MT_EQUAL(index.entries.allKeys, (@[@"Upper.jar"]));
    MT_EQUAL(index.entries[@"Upper.jar"][@"projectId"], @"U");

    NSArray<ModJar *> *jars = [[[ModFolder alloc] initWithModsDir:dir] scanJars];
    MT_EQUAL(@(jars.count), @1);
    MT_EQUAL(jars.firstObject.fileName, @"Upper.jar");
    MT_ASSERT(jars.firstObject.enabled);
    RemoveDir(dir);
}

/* Switching a dependency on fails late (its enabled name is taken), after a replacement has already
   been swapped in. Everything must be put back. */
static void testFailureAfterSwapRestoresEverything(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"a-1.jar.disabled", @"old a");
    WriteFile(dir, @"dep.jar.disabled", @"dep off");
    WriteFile(dir, @"dep.jar", @"dep clash");
    SeedIndex(dir, @"a-1.jar", @"A");
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];
    index.entries[@"dep.jar"] = [@{@"projectId": @"D"} mutableCopy];
    [index save:nil];
    NSArray *before = Listing(dir);
    NSString *indexBefore = ReadFile(dir, ModIndexFileName);

    NSDictionary *responses = @{UrlFor(@"a-2.jar"): @"new a"};
    ModInstaller *installer = [[ModInstaller alloc] initWithIndex:index downloader:FakeDownloader(responses, [NSMutableArray new], NO)];
    NSError *error = RunInstall(installer, Plan(@[Version(@"A", @"a2", @"a-2.jar", @"new a")], @[@"D"]), @{});

    MT_EQUAL(error.domain, ModInstallErrorDomain);
    MT_EQUAL(@(error.code), @(ModInstallErrorFileSystem));
    MT_EQUAL(error.userInfo[@"fileName"], @"dep.jar");
    MT_EQUAL(Listing(dir), before);
    MT_EQUAL(ReadFile(dir, @"a-1.jar.disabled"), @"old a");
    MT_EQUAL(ReadFile(dir, @"dep.jar.disabled"), @"dep off");
    MT_EQUAL(ReadFile(dir, @"dep.jar"), @"dep clash");
    MT_EQUAL(ReadFile(dir, ModIndexFileName), indexBefore);
    MT_EQUAL(index.entries[@"a-1.jar"][@"projectId"], @"A");
    MT_ASSERT(index.entries[@"a-2.jar"] == nil);
    RemoveDir(dir);
}

static void testUserAgent(void) {
    NSString *agent = [ModInstaller userAgent];
    MT_ASSERT([agent hasPrefix:@"Amethyst-iOS/"]);
    MT_ASSERT([agent containsString:@"github.com/Raymon82777/Amethyst-iOS-Improved"]);
}

void ModInstallerTests(void) {
    MT_RUN(testInstallsAndRecords);
    MT_RUN(testCompletesOnAnotherQueue);
    MT_RUN(testHashMismatchRollsBack);
    MT_RUN(testDownloadFailureRollsBack);
    MT_RUN(testReplaceKeepsDisabledState);
    MT_RUN(testReplaceKeepsEnabledStateAndSameName);
    MT_RUN(testDownloadOverExistingSameNameReplacesIt);
    MT_RUN(testSameNameDisabledTwinStaysDisabled);
    MT_RUN(testEnablesRequestedProjects);
    MT_RUN(testSha512FallbackAndNoHash);
    MT_RUN(testUnusableVersionsFailBeforeTouchingAnything);
    MT_RUN(testNonJarAndReservedNamesAreRefused);
    MT_RUN(testUppercaseJarIsSavedLowercase);
    MT_RUN(testFailureAfterSwapRestoresEverything);
    MT_RUN(testUserAgent);
}
