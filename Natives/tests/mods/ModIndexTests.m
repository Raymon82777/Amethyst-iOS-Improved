#import "ModIndex.h"
#import "ModTest.h"

static NSString *MakeTempDir(void) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"ModIndexTests-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

static void RemoveDir(NSString *dir) {
    [NSFileManager.defaultManager removeItemAtPath:dir error:nil];
}

static void testRoundTrip(void) {
    NSString *dir = MakeTempDir();
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];
    MT_EQUAL(@(index.entries.count), @0);

    NSMutableDictionary *entry = [@{
        @"projectId": @"AANobbMI",
        @"versionId": @"v1",
        @"slug": @"sodium",
        @"title": @"Sodium",
        @"versionNumber": @"0.6.0",
        @"versionType": @"release",
        @"requires": @[@"P7dR8mSH"],
        @"gameVersions": @[@"1.21.1"],
        @"loaders": @[@"fabric", @"quilt"]} mutableCopy];
    index.entries[@"sodium.jar"] = entry;
    [index.unknownHashes addObject:@"deadbeef"];

    NSError *error = nil;
    MT_ASSERT([index save:&error]);
    MT_EQUAL(error, nil);

    ModIndex *reloaded = [[ModIndex alloc] initWithModsDir:dir];
    MT_EQUAL(reloaded.entries, index.entries);
    MT_EQUAL(reloaded.unknownHashes, index.unknownHashes);
    MT_ASSERT([reloaded.entries[@"sodium.jar"] isKindOfClass:NSMutableDictionary.class]);

    NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:ModIndexFileName]];
    MT_ASSERT(data != nil);
    NSDictionary *onDisk = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    MT_EQUAL(onDisk[@"formatVersion"], @1);
    RemoveDir(dir);
}

static void testSaveCreatesMissingDirectory(void) {
    NSString *dir = [MakeTempDir() stringByAppendingPathComponent:@"profile/mods"];
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];
    index.entries[@"a.jar"] = [@{@"projectId": @"A"} mutableCopy];
    NSError *error = nil;
    MT_ASSERT([index save:&error]);
    ModIndex *reloaded = [[ModIndex alloc] initWithModsDir:dir];
    MT_EQUAL(reloaded.entries[@"a.jar"][@"projectId"], @"A");
    RemoveDir([[dir stringByDeletingLastPathComponent] stringByDeletingLastPathComponent]);
}

static void testCorruptFileGivesEmptyIndex(void) {
    NSString *dir = MakeTempDir();
    [@"{not json" writeToFile:[dir stringByAppendingPathComponent:ModIndexFileName] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ModIndex *index = [[ModIndex alloc] initWithModsDir:dir];
    MT_EQUAL(@(index.entries.count), @0);
    MT_EQUAL(@(index.unknownHashes.count), @0);

    // Valid JSON with the wrong shapes is tolerated too.
    [@"{\"formatVersion\":1,\"mods\":[1,2],\"unknownHashes\":{\"a\":1}}" writeToFile:[dir stringByAppendingPathComponent:ModIndexFileName] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ModIndex *wrongTypes = [[ModIndex alloc] initWithModsDir:dir];
    MT_EQUAL(@(wrongTypes.entries.count), @0);
    MT_EQUAL(@(wrongTypes.unknownHashes.count), @0);

    [@"[1,2,3]" writeToFile:[dir stringByAppendingPathComponent:ModIndexFileName] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    MT_EQUAL(@([[ModIndex alloc] initWithModsDir:dir].entries.count), @0);
    RemoveDir(dir);
}

static void testFileNameForProjectId(void) {
    ModIndex *index = [[ModIndex alloc] initWithModsDir:MakeTempDir()];
    index.entries[@"a.jar"] = [@{@"projectId": @"PA"} mutableCopy];
    index.entries[@"b.jar"] = [@{@"projectId": @"PB"} mutableCopy];
    MT_EQUAL([index fileNameForProjectId:@"PB"], @"b.jar");
    MT_EQUAL([index fileNameForProjectId:@"PA"], @"a.jar");
    MT_EQUAL([index fileNameForProjectId:@"missing"], nil);
}

static void testFileNamesRequiringProject(void) {
    ModIndex *index = [[ModIndex alloc] initWithModsDir:MakeTempDir()];
    index.entries[@"A.jar"] = [@{@"projectId": @"PA", @"requires": @[@"P", @"Q"]} mutableCopy];
    index.entries[@"B.jar"] = [@{@"projectId": @"PB", @"requires": @[@"P"]} mutableCopy];
    index.entries[@"C.jar"] = [@{@"projectId": @"PC"} mutableCopy];
    NSSet *names = [NSSet setWithArray:[index fileNamesRequiringProject:@"P"]];
    MT_EQUAL(names, (([NSSet setWithObjects:@"A.jar", @"B.jar", nil])));
    MT_EQUAL(@([index fileNamesRequiringProject:@"nobody"].count), @0);
}

static void testPruneRemovesEntriesForMissingFiles(void) {
    ModIndex *index = [[ModIndex alloc] initWithModsDir:MakeTempDir()];
    index.entries[@"a.jar"] = [@{@"projectId": @"PA"} mutableCopy];
    index.entries[@"b.jar"] = [@{@"projectId": @"PB"} mutableCopy];
    [index pruneEntriesNotIn:[NSSet setWithObject:@"a.jar"]];
    MT_EQUAL(index.entries.allKeys, (@[@"a.jar"]));
}

static void testEntryMatches(void) {
    NSDictionary *entry = @{@"gameVersions": @[@"1.21.1"], @"loaders": @[@"fabric"]};
    MT_ASSERT([ModIndex entry:entry matchesLoaders:@[@"fabric"] gameVersion:@"1.21.1"]);
    MT_ASSERT(![ModIndex entry:entry matchesLoaders:@[@"fabric"] gameVersion:@"1.21.4"]);
    MT_ASSERT([ModIndex entry:entry matchesLoaders:(@[@"quilt", @"fabric"]) gameVersion:@"1.21.1"]);
    MT_ASSERT(![ModIndex entry:entry matchesLoaders:@[@"forge"] gameVersion:@"1.21.1"]);
    MT_ASSERT(![ModIndex entry:entry matchesLoaders:@[] gameVersion:@"1.21.1"]);
    MT_ASSERT(![ModIndex entry:@{@"loaders": @[@"fabric"]} matchesLoaders:@[@"fabric"] gameVersion:@"1.21.1"]);
    MT_ASSERT(![ModIndex entry:@{@"gameVersions": @[@"1.21.1"]} matchesLoaders:@[@"fabric"] gameVersion:@"1.21.1"]);
}

static void testEntryForVersionMapsFields(void) {
    NSDictionary *version = @{
        @"id": @"ver1",
        @"project_id": @"AANobbMI",
        @"name": @"Sodium 0.6.0",
        @"version_number": @"0.6.0",
        @"version_type": @"release",
        @"game_versions": @[@"1.21.1"],
        @"loaders": @[@"fabric", @"quilt"],
        @"dependencies": @[
            @{@"project_id": @"P7dR8mSH", @"dependency_type": @"required"},
            @{@"project_id": @"OPTIONAL1", @"dependency_type": @"optional"},
            @{@"version_id": @"onlyVersion", @"dependency_type": @"required"}]};
    NSDictionary *file = @{@"filename": @"sodium.jar", @"hashes": @{@"sha1": @"abc123", @"sha512": @"zzz"}};
    NSDictionary *project = @{@"title": @"Sodium", @"slug": @"sodium", @"icon_url": @"https://cdn.modrinth.com/icon.png"};

    NSMutableDictionary *entry = [ModIndex entryForVersion:version file:file project:project];
    MT_EQUAL(entry[@"projectId"], @"AANobbMI");
    MT_EQUAL(entry[@"versionId"], @"ver1");
    MT_EQUAL(entry[@"versionNumber"], @"0.6.0");
    MT_EQUAL(entry[@"versionType"], @"release");
    MT_EQUAL(entry[@"gameVersions"], (@[@"1.21.1"]));
    MT_EQUAL(entry[@"loaders"], (@[@"fabric", @"quilt"]));
    MT_EQUAL(entry[@"sha1"], @"abc123");
    MT_EQUAL(entry[@"requires"], (@[@"P7dR8mSH"]));
    MT_EQUAL(entry[@"title"], @"Sodium");
    MT_EQUAL(entry[@"slug"], @"sodium");
    MT_EQUAL(entry[@"iconUrl"], @"https://cdn.modrinth.com/icon.png");

    // Without project info the title falls back to the version name and the rest is omitted.
    NSMutableDictionary *bare = [ModIndex entryForVersion:version file:file project:nil];
    MT_EQUAL(bare[@"title"], @"Sodium 0.6.0");
    MT_EQUAL(bare[@"slug"], nil);
    MT_EQUAL(bare[@"iconUrl"], nil);
    MT_EQUAL(bare[@"projectId"], @"AANobbMI");

    // JSON nulls are omitted instead of stored.
    NSDictionary *nullIcon = @{@"title": @"Sodium", @"slug": @"sodium", @"icon_url": NSNull.null};
    MT_EQUAL([ModIndex entryForVersion:version file:file project:nullIcon][@"iconUrl"], nil);
    MT_EQUAL([ModIndex entryForVersion:version file:@{} project:nil][@"sha1"], nil);
}

void ModIndexTests(void) {
    MT_RUN(testRoundTrip);
    MT_RUN(testSaveCreatesMissingDirectory);
    MT_RUN(testCorruptFileGivesEmptyIndex);
    MT_RUN(testFileNameForProjectId);
    MT_RUN(testFileNamesRequiringProject);
    MT_RUN(testPruneRemovesEntriesForMissingFiles);
    MT_RUN(testEntryMatches);
    MT_RUN(testEntryForVersionMapsFields);
}
