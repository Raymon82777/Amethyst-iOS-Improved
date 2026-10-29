#import "ModVersionSelector.h"
#import "ModTest.h"

static NSDictionary *Version(NSString *versionId, NSString *type, NSString *date, NSArray<NSString *> *loaders, NSArray<NSString *> *games) {
    return @{
        @"id": versionId,
        @"project_id": @"proj",
        @"version_number": versionId,
        @"version_type": type,
        @"date_published": date,
        @"loaders": loaders,
        @"game_versions": games,
        @"files": @[@{@"url": @"https://cdn.modrinth.com/data/proj/versions/x.jar",
                      @"filename": @"x.jar", @"primary": @YES}],
        @"dependencies": @[]};
}

static void testPrefersNewestRelease(void) {
    NSArray *versions = @[
        Version(@"r-aug", @"release", @"2026-08-01T12:00:00.000000Z", @[@"fabric"], @[@"1.21.1"]),
        Version(@"b-nov", @"beta", @"2026-11-01T12:00:00.000000Z", @[@"fabric"], @[@"1.21.1"]),
        Version(@"r-oct", @"release", @"2026-10-01T12:34:56.123456Z", @[@"fabric"], @[@"1.21.1"])];
    NSDictionary *best = [ModVersionSelector bestVersionIn:versions loaders:@[@"fabric"] gameVersion:@"1.21.1"];
    MT_EQUAL(best[@"id"], @"r-oct");
}

static void testFallsBackToBetaThenAlpha(void) {
    NSArray *betaAndAlpha = @[
        Version(@"a-nov", @"alpha", @"2026-11-01T00:00:00Z", @[@"fabric"], @[@"1.21.1"]),
        Version(@"b-sep", @"beta", @"2026-09-01T00:00:00Z", @[@"fabric"], @[@"1.21.1"])];
    MT_EQUAL([ModVersionSelector bestVersionIn:betaAndAlpha loaders:@[@"fabric"] gameVersion:@"1.21.1"][@"id"], @"b-sep");

    NSArray *onlyAlpha = @[
        Version(@"a-sep", @"alpha", @"2026-09-01T00:00:00Z", @[@"fabric"], @[@"1.21.1"]),
        Version(@"a-nov", @"alpha", @"2026-11-01T00:00:00Z", @[@"fabric"], @[@"1.21.1"])];
    MT_EQUAL([ModVersionSelector bestVersionIn:onlyAlpha loaders:@[@"fabric"] gameVersion:@"1.21.1"][@"id"], @"a-nov");
}

static void testIgnoresWrongLoaderOrGame(void) {
    NSArray *versions = @[
        Version(@"forge-new", @"release", @"2026-11-01T00:00:00Z", @[@"forge"], @[@"1.21.1"]),
        Version(@"fabric-old-mc", @"release", @"2026-10-15T00:00:00Z", @[@"fabric"], @[@"1.20.4"]),
        Version(@"fabric-ok", @"release", @"2026-09-01T00:00:00Z", @[@"fabric", @"quilt"], @[@"1.21", @"1.21.1"])];
    MT_EQUAL([ModVersionSelector bestVersionIn:versions loaders:@[@"fabric"] gameVersion:@"1.21.1"][@"id"], @"fabric-ok");
    // A quilt profile accepts fabric mods, so it queries with both.
    MT_EQUAL([ModVersionSelector bestVersionIn:versions loaders:(@[@"quilt", @"fabric"]) gameVersion:@"1.21.1"][@"id"], @"fabric-ok");
    MT_ASSERT([ModVersionSelector version:versions[2] fitsLoaders:@[@"quilt"] gameVersion:@"1.21.1"]);
    MT_ASSERT(![ModVersionSelector version:versions[0] fitsLoaders:@[@"fabric"] gameVersion:@"1.21.1"]);
    MT_ASSERT(![ModVersionSelector version:versions[1] fitsLoaders:@[@"fabric"] gameVersion:@"1.21.1"]);
}

static void testNilWhenNothingFits(void) {
    NSArray *versions = @[
        Version(@"forge-only", @"release", @"2026-11-01T00:00:00Z", @[@"forge"], @[@"1.21.1"])];
    MT_EQUAL([ModVersionSelector bestVersionIn:versions loaders:@[@"fabric"] gameVersion:@"1.21.1"], nil);
    MT_EQUAL([ModVersionSelector bestVersionIn:@[] loaders:@[@"fabric"] gameVersion:@"1.21.1"], nil);
    // A vanilla profile has no accepted loaders, so nothing can fit.
    MT_EQUAL([ModVersionSelector bestVersionIn:versions loaders:@[] gameVersion:@"1.21.1"], nil);
}

static void testPrimaryFileWins(void) {
    NSDictionary *secondary = @{@"filename": @"sources.jar", @"primary": @NO};
    NSDictionary *primary = @{@"filename": @"mod.jar", @"primary": @YES};
    NSDictionary *v = @{@"files": @[secondary, primary]};
    MT_EQUAL([ModVersionSelector primaryFileOfVersion:v], primary);

    NSDictionary *a = @{@"filename": @"a.jar", @"primary": @NO};
    NSDictionary *b = @{@"filename": @"b.jar"};
    NSDictionary *noPrimary = @{@"files": @[a, b]};
    MT_EQUAL([ModVersionSelector primaryFileOfVersion:noPrimary], a);

    MT_EQUAL([ModVersionSelector primaryFileOfVersion:@{@"files": @[]}], nil);
    MT_EQUAL([ModVersionSelector primaryFileOfVersion:@{}], nil);
}

static void testCompatibleNewestFirst(void) {
    NSArray *versions = @[
        Version(@"mid", @"beta", @"2026-09-01T00:00:00.500Z", @[@"fabric"], @[@"1.21.1"]),
        Version(@"wrong", @"release", @"2026-12-01T00:00:00Z", @[@"forge"], @[@"1.21.1"]),
        Version(@"newest", @"alpha", @"2026-11-01T00:00:00.000000Z", @[@"fabric"], @[@"1.21.1"]),
        Version(@"oldest", @"release", @"2026-07-01T00:00:00Z", @[@"fabric"], @[@"1.21.1"])];
    NSArray *sorted = [ModVersionSelector compatibleVersionsNewestFirst:versions loaders:@[@"fabric"] gameVersion:@"1.21.1"];
    NSArray *ids = [sorted valueForKey:@"id"];
    MT_EQUAL(ids, (@[@"newest", @"mid", @"oldest"]));
}

void ModVersionSelectorTests(void) {
    MT_RUN(testPrefersNewestRelease);
    MT_RUN(testFallsBackToBetaThenAlpha);
    MT_RUN(testIgnoresWrongLoaderOrGame);
    MT_RUN(testNilWhenNothingFits);
    MT_RUN(testPrimaryFileWins);
    MT_RUN(testCompatibleNewestFirst);
}
