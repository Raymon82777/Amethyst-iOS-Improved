#import "ModProfileInfo.h"
#import "ModTest.h"

static void testFabricFromLibraries(void) {
    ModProfileInfo *i = [ModProfileInfo infoForVersionId:@"fabric-loader-0.16.5-1.21.1" json:@{
        @"inheritsFrom": @"1.21.1",
        @"libraries": @[@{@"name": @"net.fabricmc:fabric-loader:0.16.5"}]}];
    MT_EQUAL(i.loader, @"fabric");
    MT_EQUAL(i.minecraftVersion, @"1.21.1");
    MT_EQUAL(i.loaderVersion, @"0.16.5");
    MT_EQUAL(i.acceptedLoaders, (@[@"fabric"]));
    MT_ASSERT(i.isModded);
    MT_EQUAL(i.displayName, @"Fabric · 1.21.1");
}

static void testQuiltAcceptsFabric(void) {
    ModProfileInfo *i = [ModProfileInfo infoForVersionId:@"quilt-loader-0.26.0-1.20.4" json:@{
        @"inheritsFrom": @"1.20.4",
        @"libraries": @[@{@"name": @"org.quiltmc:quilt-loader:0.26.0"}]}];
    MT_EQUAL(i.loader, @"quilt");
    MT_EQUAL(i.minecraftVersion, @"1.20.4");
    MT_EQUAL(i.loaderVersion, @"0.26.0");
    MT_EQUAL(i.acceptedLoaders, (@[@"quilt", @"fabric"]));
    MT_EQUAL(i.displayName, @"Quilt · 1.20.4");
}

static void testForgeFromLibraries(void) {
    ModProfileInfo *i = [ModProfileInfo infoForVersionId:@"1.20.1-forge-47.2.0" json:@{
        @"inheritsFrom": @"1.20.1",
        @"libraries": @[@{@"name": @"net.minecraftforge:fmlloader:1.20.1-47.2.0"}]}];
    MT_EQUAL(i.loader, @"forge");
    MT_EQUAL(i.minecraftVersion, @"1.20.1");
    MT_EQUAL(i.loaderVersion, @"47.2.0");
    MT_EQUAL(i.acceptedLoaders, (@[@"forge"]));
}

static void testNeoForge1201AcceptsForge(void) {
    ModProfileInfo *i = [ModProfileInfo infoForVersionId:@"neoforge-47.1.106" json:@{
        @"inheritsFrom": @"1.20.1",
        @"libraries": @[@{@"name": @"net.neoforged:forge:1.20.1-47.1.106"}]}];
    MT_EQUAL(i.loader, @"neoforge");
    MT_EQUAL(i.minecraftVersion, @"1.20.1");
    MT_EQUAL(i.loaderVersion, @"47.1.106");
    MT_EQUAL(i.acceptedLoaders, (@[@"neoforge", @"forge"]));
    MT_EQUAL(i.displayName, @"NeoForge · 1.20.1");
}

static void testNeoForge121OnlyNeoForge(void) {
    ModProfileInfo *i = [ModProfileInfo infoForVersionId:@"neoforge-21.1.77" json:@{
        @"inheritsFrom": @"1.21.1",
        @"libraries": @[
            @{@"name": @"net.neoforged.fancymodloader:loader:4.0.30"},
            @{@"name": @"net.neoforged:neoforge:21.1.77"}]}];
    MT_EQUAL(i.loader, @"neoforge");
    MT_EQUAL(i.minecraftVersion, @"1.21.1");
    MT_EQUAL(i.loaderVersion, @"21.1.77");
    MT_EQUAL(i.acceptedLoaders, (@[@"neoforge"]));
}

static void testVanillaJson(void) {
    ModProfileInfo *i = [ModProfileInfo infoForVersionId:@"1.21.1" json:@{
        @"libraries": @[@{@"name": @"com.mojang:brigadier:1.3.10"}]}];
    MT_EQUAL(i.loader, nil);
    MT_EQUAL(i.loaderVersion, nil);
    MT_EQUAL(i.minecraftVersion, @"1.21.1");
    MT_EQUAL(i.acceptedLoaders, (@[]));
    MT_ASSERT(!i.isModded);
}

static void testLatestReleaseIsVanilla(void) {
    ModProfileInfo *i = [ModProfileInfo infoForVersionId:@"latest-release" json:nil];
    MT_ASSERT(!i.isModded);
    MT_EQUAL(i.loader, nil);
    MT_EQUAL(i.minecraftVersion, nil);
    MT_EQUAL(i.acceptedLoaders, (@[]));

    i = [ModProfileInfo infoForVersionId:@"latest-snapshot" json:nil];
    MT_ASSERT(!i.isModded);
    MT_EQUAL(i.minecraftVersion, nil);
}

static void testFallbackFromIdPatterns(void) {
    ModProfileInfo *i = [ModProfileInfo infoForVersionId:@"fabric-loader-0.16.5-1.21.1" json:nil];
    MT_EQUAL(i.loader, @"fabric");
    MT_EQUAL(i.minecraftVersion, @"1.21.1");
    MT_EQUAL(i.loaderVersion, @"0.16.5");

    i = [ModProfileInfo infoForVersionId:@"quilt-loader-0.26.0-1.20.4" json:nil];
    MT_EQUAL(i.loader, @"quilt");
    MT_EQUAL(i.minecraftVersion, @"1.20.4");
    MT_EQUAL(i.loaderVersion, @"0.26.0");
    MT_EQUAL(i.acceptedLoaders, (@[@"quilt", @"fabric"]));

    i = [ModProfileInfo infoForVersionId:@"1.20.1-forge-47.2.0" json:nil];
    MT_EQUAL(i.loader, @"forge");
    MT_EQUAL(i.minecraftVersion, @"1.20.1");
    MT_EQUAL(i.loaderVersion, @"47.2.0");

    i = [ModProfileInfo infoForVersionId:@"neoforge-21.4.114-beta" json:nil];
    MT_EQUAL(i.loader, @"neoforge");
    MT_EQUAL(i.minecraftVersion, @"1.21.4");
    MT_EQUAL(i.loaderVersion, @"21.4.114-beta");
    MT_EQUAL(i.acceptedLoaders, (@[@"neoforge"]));
}

static void testAcceptedLoadersHelper(void) {
    MT_EQUAL([ModProfileInfo acceptedLoadersForLoader:nil minecraftVersion:@"1.21.1"], (@[]));
    MT_EQUAL([ModProfileInfo acceptedLoadersForLoader:@"neoforge" minecraftVersion:@"1.20.1"], (@[@"neoforge", @"forge"]));
    MT_EQUAL([ModProfileInfo acceptedLoadersForLoader:@"neoforge" minecraftVersion:@"1.20.4"], (@[@"neoforge"]));
    MT_EQUAL([ModProfileInfo acceptedLoadersForLoader:@"neoforge" minecraftVersion:nil], (@[@"neoforge"]));
}

static void testReadsFromVersionsDir(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]];
    NSString *vdir = [tmp stringByAppendingPathComponent:@"fabric-x"];
    MT_ASSERT([fm createDirectoryAtPath:vdir withIntermediateDirectories:YES attributes:nil error:nil]);

    NSDictionary *json = @{
        @"inheritsFrom": @"1.21.1",
        @"libraries": @[@{@"name": @"net.fabricmc:fabric-loader:0.16.5"}]};
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    MT_ASSERT([data writeToFile:[vdir stringByAppendingPathComponent:@"fabric-x.json"] atomically:YES]);

    ModProfileInfo *i = [ModProfileInfo infoForVersionId:@"fabric-x" versionsDir:tmp];
    MT_EQUAL(i.loader, @"fabric");
    MT_EQUAL(i.minecraftVersion, @"1.21.1");
    MT_EQUAL(i.loaderVersion, @"0.16.5");

    // Missing json falls back to the id, which here is not a loader pattern.
    i = [ModProfileInfo infoForVersionId:@"1.21.1" versionsDir:tmp];
    MT_ASSERT(!i.isModded);
    MT_EQUAL(i.minecraftVersion, @"1.21.1");

    [fm removeItemAtPath:tmp error:nil];
}

void ModProfileInfoTests(void) {
    MT_RUN(testFabricFromLibraries);
    MT_RUN(testQuiltAcceptsFabric);
    MT_RUN(testForgeFromLibraries);
    MT_RUN(testNeoForge1201AcceptsForge);
    MT_RUN(testNeoForge121OnlyNeoForge);
    MT_RUN(testVanillaJson);
    MT_RUN(testLatestReleaseIsVanilla);
    MT_RUN(testFallbackFromIdPatterns);
    MT_RUN(testAcceptedLoadersHelper);
    MT_RUN(testReadsFromVersionsDir);
}
