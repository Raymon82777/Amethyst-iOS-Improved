#import <CommonCrypto/CommonDigest.h>
#import "ModFolder.h"
#import "ModIndex.h"
#import "ModTest.h"

static NSString *MakeTempDir(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"ModFolderTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
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

static void testScanFindsEnabledAndDisabled(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"a.jar", @"a");
    WriteFile(dir, @"b.jar.disabled", @"b");
    WriteFile(dir, @"notes.txt", @"n");
    WriteFile(dir, ModIndexFileName, @"{}");
    [NSFileManager.defaultManager createDirectoryAtPath:[dir stringByAppendingPathComponent:@"folder.jar"] withIntermediateDirectories:NO attributes:nil error:nil];

    ModFolder *folder = [[ModFolder alloc] initWithModsDir:dir];
    NSArray<ModJar *> *jars = [folder scanJars];
    MT_EQUAL(@(jars.count), @2);
    if (jars.count == 2) {
        MT_EQUAL(jars[0].fileName, @"a.jar");
        MT_ASSERT(jars[0].enabled);
        MT_EQUAL(jars[0].path, [dir stringByAppendingPathComponent:@"a.jar"]);
        MT_EQUAL(jars[1].fileName, @"b.jar");
        MT_ASSERT(!jars[1].enabled);
        MT_EQUAL(jars[1].path, [dir stringByAppendingPathComponent:@"b.jar.disabled"]);
    }
    RemoveDir(dir);
}

static void testInitCreatesMissingDirectory(void) {
    NSString *root = MakeTempDir();
    NSString *dir = [root stringByAppendingPathComponent:@"profile/mods"];
    ModFolder *folder = [[ModFolder alloc] initWithModsDir:dir];
    BOOL isDirectory = NO;
    MT_ASSERT([NSFileManager.defaultManager fileExistsAtPath:dir isDirectory:&isDirectory] && isDirectory);
    MT_EQUAL(@([folder scanJars].count), @0);
    RemoveDir(root);
}

static void testStrayPartFilesAreRemoved(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"c.jar.part", @"partial");
    WriteFile(dir, @"a.jar", @"a");
    ModFolder *folder = [[ModFolder alloc] initWithModsDir:dir];
    NSArray<ModJar *> *jars = [folder scanJars];
    MT_EQUAL(@(jars.count), @1);
    MT_ASSERT(!Exists(dir, @"c.jar.part"));
    MT_ASSERT(Exists(dir, @"a.jar"));
    RemoveDir(dir);
}

static void testToggleRenames(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"a.jar", @"a");
    ModFolder *folder = [[ModFolder alloc] initWithModsDir:dir];
    ModJar *jar = [folder scanJars].firstObject;

    NSError *error = nil;
    MT_ASSERT([folder setJar:jar enabled:NO error:&error]);
    MT_EQUAL(error, nil);
    MT_ASSERT(!jar.enabled);
    MT_EQUAL(jar.path, [dir stringByAppendingPathComponent:@"a.jar.disabled"]);
    MT_ASSERT(Exists(dir, @"a.jar.disabled"));
    MT_ASSERT(!Exists(dir, @"a.jar"));

    MT_ASSERT([folder setJar:jar enabled:YES error:&error]);
    MT_ASSERT(jar.enabled);
    MT_EQUAL(jar.path, [dir stringByAppendingPathComponent:@"a.jar"]);
    MT_ASSERT(Exists(dir, @"a.jar"));
    MT_ASSERT(!Exists(dir, @"a.jar.disabled"));
    RemoveDir(dir);
}

static void testToggleRefusesToOverwrite(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"a.jar", @"enabled copy");
    WriteFile(dir, @"a.jar.disabled", @"disabled copy");
    ModFolder *folder = [[ModFolder alloc] initWithModsDir:dir];
    ModJar *jar = [ModJar new];
    jar.fileName = @"a.jar";
    jar.path = [dir stringByAppendingPathComponent:@"a.jar.disabled"];
    jar.enabled = NO;

    NSError *error = nil;
    MT_ASSERT(![folder setJar:jar enabled:YES error:&error]);
    MT_EQUAL(error.domain, ModFolderErrorDomain);
    MT_EQUAL(@(error.code), @(ModFolderErrorExists));
    MT_ASSERT(!jar.enabled);
    MT_EQUAL(ReadFile(dir, @"a.jar"), @"enabled copy");
    MT_EQUAL(ReadFile(dir, @"a.jar.disabled"), @"disabled copy");
    RemoveDir(dir);
}

static void testDelete(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"b.jar.disabled", @"b");
    ModFolder *folder = [[ModFolder alloc] initWithModsDir:dir];
    ModJar *jar = [folder scanJars].firstObject;
    NSError *error = nil;
    MT_ASSERT([folder deleteJar:jar error:&error]);
    MT_ASSERT(!Exists(dir, @"b.jar.disabled"));
    MT_EQUAL(@([folder scanJars].count), @0);
    RemoveDir(dir);
}

static void testImportClash(void) {
    NSString *dir = MakeTempDir();
    NSString *sourceDir = MakeTempDir();
    WriteFile(dir, @"a.jar", @"old");
    WriteFile(sourceDir, @"a.jar", @"new");
    NSURL *source = [NSURL fileURLWithPath:[sourceDir stringByAppendingPathComponent:@"a.jar"]];
    ModFolder *folder = [[ModFolder alloc] initWithModsDir:dir];

    NSError *error = nil;
    NSString *written = [folder importJarFromURL:source asFileName:nil replaceExisting:NO error:&error];
    MT_EQUAL(written, nil);
    MT_EQUAL(error.domain, ModFolderErrorDomain);
    MT_EQUAL(@(error.code), @(ModFolderErrorExists));
    MT_EQUAL(ReadFile(dir, @"a.jar"), @"old");

    error = nil;
    written = [folder importJarFromURL:source asFileName:nil replaceExisting:YES error:&error];
    MT_EQUAL(written, @"a.jar");
    MT_EQUAL(error, nil);
    MT_EQUAL(ReadFile(dir, @"a.jar"), @"new");
    MT_ASSERT(!Exists(dir, @"a.jar.part"));
    RemoveDir(dir);
    RemoveDir(sourceDir);
}

static void testImportClashCountsDisabledTwin(void) {
    NSString *dir = MakeTempDir();
    NSString *sourceDir = MakeTempDir();
    WriteFile(dir, @"a.jar.disabled", @"old");
    WriteFile(sourceDir, @"a.jar", @"new");
    NSURL *source = [NSURL fileURLWithPath:[sourceDir stringByAppendingPathComponent:@"a.jar"]];
    ModFolder *folder = [[ModFolder alloc] initWithModsDir:dir];

    NSError *error = nil;
    MT_EQUAL([folder importJarFromURL:source asFileName:nil replaceExisting:NO error:&error], nil);
    MT_EQUAL(@(error.code), @(ModFolderErrorExists));
    MT_EQUAL(ReadFile(dir, @"a.jar.disabled"), @"old");
    MT_ASSERT(!Exists(dir, @"a.jar"));

    error = nil;
    MT_EQUAL([folder importJarFromURL:source asFileName:nil replaceExisting:YES error:&error], @"a.jar");
    MT_EQUAL(ReadFile(dir, @"a.jar"), @"new");
    MT_ASSERT(!Exists(dir, @"a.jar.disabled"));
    RemoveDir(dir);
    RemoveDir(sourceDir);
}

static void testImportAsFileName(void) {
    NSString *dir = MakeTempDir();
    NSString *sourceDir = MakeTempDir();
    WriteFile(sourceDir, @"download.tmp", @"data");
    NSURL *source = [NSURL fileURLWithPath:[sourceDir stringByAppendingPathComponent:@"download.tmp"]];
    ModFolder *folder = [[ModFolder alloc] initWithModsDir:dir];

    NSError *error = nil;
    MT_EQUAL([folder importJarFromURL:source asFileName:@"sodium.jar" replaceExisting:NO error:&error], @"sodium.jar");
    MT_EQUAL(ReadFile(dir, @"sodium.jar"), @"data");

    // A name can never escape the mods folder.
    MT_EQUAL([folder importJarFromURL:source asFileName:@"../escape.jar" replaceExisting:NO error:&error], @"escape.jar");
    MT_ASSERT(Exists(dir, @"escape.jar"));
    MT_ASSERT(!Exists([dir stringByDeletingLastPathComponent], @"escape.jar"));

    // A missing source file fails and leaves no .part behind.
    NSURL *missing = [NSURL fileURLWithPath:[sourceDir stringByAppendingPathComponent:@"missing.jar"]];
    error = nil;
    MT_EQUAL([folder importJarFromURL:missing asFileName:nil replaceExisting:NO error:&error], nil);
    MT_ASSERT(error != nil);
    MT_ASSERT(!Exists(dir, @"missing.jar.part"));
    RemoveDir(dir);
    RemoveDir(sourceDir);
}

static void testImportKeepBothName(void) {
    NSString *dir = MakeTempDir();
    NSString *sourceDir = MakeTempDir();
    WriteFile(dir, @"a.jar", @"old");
    WriteFile(dir, @"a (2).jar.disabled", @"old2");
    WriteFile(sourceDir, @"a.jar", @"new");
    NSURL *source = [NSURL fileURLWithPath:[sourceDir stringByAppendingPathComponent:@"a.jar"]];
    ModFolder *folder = [[ModFolder alloc] initWithModsDir:dir];

    MT_EQUAL([folder uniqueFileNameFor:@"a.jar"], @"a (3).jar");
    MT_EQUAL([folder uniqueFileNameFor:@"b.jar"], @"b.jar");

    NSError *error = nil;
    NSString *written = [folder importJarFromURL:source asFileName:[folder uniqueFileNameFor:@"a.jar"] replaceExisting:NO error:&error];
    MT_EQUAL(written, @"a (3).jar");
    MT_EQUAL(ReadFile(dir, @"a (3).jar"), @"new");
    MT_EQUAL(ReadFile(dir, @"a.jar"), @"old");
    MT_EQUAL(ReadFile(dir, @"a (2).jar.disabled"), @"old2");
    RemoveDir(dir);
    RemoveDir(sourceDir);
}

static void testSha1KnownValue(void) {
    NSString *dir = MakeTempDir();
    WriteFile(dir, @"abc.jar", @"abc");
    NSString *path = [dir stringByAppendingPathComponent:@"abc.jar"];
    MT_EQUAL([ModFolder sha1OfFileAtPath:path], @"a9993e364706816aba3e25717850c26c9cd0d89d");
    MT_EQUAL([ModFolder sha512OfFileAtPath:path], @"ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f");
    MT_EQUAL([ModFolder sha1OfFileAtPath:[dir stringByAppendingPathComponent:@"missing.jar"]], nil);
    MT_EQUAL([ModFolder sha512OfFileAtPath:[dir stringByAppendingPathComponent:@"missing.jar"]], nil);
    RemoveDir(dir);
}

static void testHashSpansMultipleChunks(void) {
    NSString *dir = MakeTempDir();
    // 2.5 MB, so the file is read in three chunks.
    NSMutableData *data = [NSMutableData dataWithLength:2 * 1024 * 1024 + 512 * 1024];
    uint8_t *bytes = data.mutableBytes;
    for (NSUInteger i = 0; i < data.length; i++) bytes[i] = (uint8_t)(i * 31 + 7);
    NSString *path = [dir stringByAppendingPathComponent:@"big.jar"];
    [data writeToFile:path atomically:NO];

    unsigned char sha1[CC_SHA1_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1(data.bytes, (CC_LONG)data.length, sha1);
#pragma clang diagnostic pop
    unsigned char sha512[CC_SHA512_DIGEST_LENGTH];
    CC_SHA512(data.bytes, (CC_LONG)data.length, sha512);
    NSMutableString *expected1 = [NSMutableString new];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) [expected1 appendFormat:@"%02x", sha1[i]];
    NSMutableString *expected512 = [NSMutableString new];
    for (int i = 0; i < CC_SHA512_DIGEST_LENGTH; i++) [expected512 appendFormat:@"%02x", sha512[i]];

    MT_EQUAL([ModFolder sha1OfFileAtPath:path], expected1);
    MT_EQUAL([ModFolder sha512OfFileAtPath:path], expected512);
    RemoveDir(dir);
}

static void testIsSharedGameDir(void) {
    NSString *base = MakeTempDir();
    MT_ASSERT([ModFolder isSharedGameDir:nil baseDir:base]);
    MT_ASSERT([ModFolder isSharedGameDir:@"" baseDir:base]);
    MT_ASSERT([ModFolder isSharedGameDir:@"." baseDir:base]);
    MT_ASSERT([ModFolder isSharedGameDir:@"./" baseDir:base]);
    MT_ASSERT([ModFolder isSharedGameDir:@"./foo/.." baseDir:base]);
    MT_ASSERT([ModFolder isSharedGameDir:base baseDir:base]);
    MT_ASSERT(![ModFolder isSharedGameDir:@"./custom_gamedir/x" baseDir:base]);
    MT_ASSERT(![ModFolder isSharedGameDir:@"foo" baseDir:base]);
    MT_EQUAL([ModFolder gameDirPathForGameDir:@"./custom_gamedir/x" baseDir:base],
             [[base stringByAppendingPathComponent:@"custom_gamedir/x"] stringByStandardizingPath]);
    RemoveDir(base);
}

static void testSafeFolderNameStripsPathCharacters(void) {
    NSString *name = [ModFolder safeFolderName:@"../a/b:c"];
    MT_ASSERT([name rangeOfString:@"/"].location == NSNotFound);
    MT_ASSERT([name rangeOfString:@":"].location == NSNotFound);
    MT_ASSERT(![name hasPrefix:@"."]);
    MT_EQUAL(name, @"_a_b_c");
    MT_EQUAL([ModFolder safeFolderName:@"a\\b"], @"a_b");
    MT_EQUAL([ModFolder safeFolderName:@"  Fab\tric "], @"Fab_ric");
    MT_EQUAL([ModFolder safeFolderName:@"Fabric 1.21"], @"Fabric 1.21");
    MT_EQUAL([ModFolder safeFolderName:@""], @"Profile");
    MT_EQUAL([ModFolder safeFolderName:@"..."], @"Profile");
    MT_EQUAL([ModFolder safeFolderName:@"  "], @"Profile");
}

static void testMigrateCreatesFolderAndCopiesOptions(void) {
    NSString *base = MakeTempDir();
    WriteFile(base, @"options.txt", @"fov:90");
    NSError *error = nil;
    NSString *gameDir = [ModFolder migrateProfileNamed:@"Fab" baseDir:base error:&error];
    MT_EQUAL(gameDir, @"./custom_gamedir/Fab");
    MT_EQUAL(error, nil);

    NSString *folder = [base stringByAppendingPathComponent:@"custom_gamedir/Fab"];
    BOOL isDirectory = NO;
    MT_ASSERT([NSFileManager.defaultManager fileExistsAtPath:[folder stringByAppendingPathComponent:@"mods"] isDirectory:&isDirectory] && isDirectory);
    MT_EQUAL(ReadFile(folder, @"options.txt"), @"fov:90");
    MT_EQUAL(ReadFile(base, @"options.txt"), @"fov:90");
    MT_ASSERT(![ModFolder isSharedGameDir:gameDir baseDir:base]);
    RemoveDir(base);
}

static void testMigrateSuffixesExistingFolder(void) {
    NSString *base = MakeTempDir();
    [NSFileManager.defaultManager createDirectoryAtPath:[base stringByAppendingPathComponent:@"custom_gamedir/Fab"] withIntermediateDirectories:YES attributes:nil error:nil];
    WriteFile([base stringByAppendingPathComponent:@"custom_gamedir"], @"Fab (2)", @"a plain file");

    NSError *error = nil;
    MT_EQUAL([ModFolder migrateProfileNamed:@"Fab" baseDir:base error:&error], @"./custom_gamedir/Fab (3)");
    MT_ASSERT(Exists(base, @"custom_gamedir/Fab (3)/mods"));
    MT_EQUAL(ReadFile([base stringByAppendingPathComponent:@"custom_gamedir"], @"Fab (2)"), @"a plain file");

    [NSFileManager.defaultManager removeItemAtPath:[base stringByAppendingPathComponent:@"custom_gamedir/Fab (2)"] error:nil];
    MT_EQUAL([ModFolder migrateProfileNamed:@"Fab" baseDir:base error:&error], @"./custom_gamedir/Fab (2)");
    RemoveDir(base);
}

static void testMigrateDoesNotOverwriteOptions(void) {
    NSString *base = MakeTempDir();
    WriteFile(base, @"servers.dat", @"keep");
    NSError *error = nil;
    NSString *gameDir = [ModFolder migrateProfileNamed:@"Fab" baseDir:base error:&error];
    MT_EQUAL(gameDir, @"./custom_gamedir/Fab");
    MT_ASSERT(!Exists(base, @"options.txt"));
    MT_ASSERT(!Exists(base, @"custom_gamedir/Fab/options.txt"));
    MT_EQUAL(ReadFile(base, @"servers.dat"), @"keep");

    NSArray *baseContents = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:base error:nil] sortedArrayUsingSelector:@selector(compare:)];
    MT_EQUAL(baseContents, (@[@"custom_gamedir", @"servers.dat"]));
    RemoveDir(base);
}

void ModFolderTests(void) {
    MT_RUN(testScanFindsEnabledAndDisabled);
    MT_RUN(testInitCreatesMissingDirectory);
    MT_RUN(testStrayPartFilesAreRemoved);
    MT_RUN(testToggleRenames);
    MT_RUN(testToggleRefusesToOverwrite);
    MT_RUN(testDelete);
    MT_RUN(testImportClash);
    MT_RUN(testImportClashCountsDisabledTwin);
    MT_RUN(testImportAsFileName);
    MT_RUN(testImportKeepBothName);
    MT_RUN(testSha1KnownValue);
    MT_RUN(testHashSpansMultipleChunks);
    MT_RUN(testIsSharedGameDir);
    MT_RUN(testSafeFolderNameStripsPathCharacters);
    MT_RUN(testMigrateCreatesFolderAndCopiesOptions);
    MT_RUN(testMigrateSuffixesExistingFolder);
    MT_RUN(testMigrateDoesNotOverwriteOptions);
}
