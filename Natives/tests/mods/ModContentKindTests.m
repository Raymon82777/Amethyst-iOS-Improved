#import "ModContentKind.h"
#import "ModTest.h"

static void testModsKindKeepsProfileLoaders(void) {
    ModContentKind *kind = ModContentKind.mods;
    MT_EQUAL([kind loadersForProfileLoaders:(@[@"quilt", @"fabric"])], (@[@"quilt", @"fabric"]));
    MT_EQUAL([kind searchCategoriesForProfileLoaders:(@[@"quilt", @"fabric"])], (@[@"quilt", @"fabric"]));
    MT_ASSERT(kind.type == ModContentTypeMods);
    MT_EQUAL(kind.folderName, @"mods");
    MT_EQUAL(kind.fileExtension, @"jar");
    MT_EQUAL(kind.projectType, @"mod");
    MT_ASSERT(kind.isMods);
    MT_ASSERT(!kind.listsFolders);
    MT_EQUAL([kind stringKey:@"title"], @"mods.title");
}

static void testResourcePackKindUsesMinecraftLoader(void) {
    ModContentKind *kind = ModContentKind.resourcePacks;
    MT_EQUAL([kind loadersForProfileLoaders:@[@"fabric"]], (@[@"minecraft"]));
    MT_EQUAL([kind loadersForProfileLoaders:@[]], (@[@"minecraft"]));
    MT_EQUAL([kind searchCategoriesForProfileLoaders:@[@"fabric"]], (@[]));
    MT_ASSERT(kind.type == ModContentTypeResourcePacks);
    MT_EQUAL(kind.projectType, @"resourcepack");
    MT_EQUAL(kind.folderName, @"resourcepacks");
    MT_EQUAL(kind.fileExtension, @"zip");
    MT_ASSERT(kind.listsFolders);
    MT_ASSERT(!kind.isMods);
    MT_EQUAL([kind stringKey:@"title"], @"resourcepacks.title");
}

static void testShaderKindUsesIrisAndOptifine(void) {
    ModContentKind *kind = ModContentKind.shaderPacks;
    NSArray *expected = @[@"iris", @"optifine"];
    MT_EQUAL([kind loadersForProfileLoaders:@[@"fabric"]], expected);
    MT_EQUAL([kind loadersForProfileLoaders:@[]], expected);
    MT_EQUAL([kind searchCategoriesForProfileLoaders:@[@"forge"]], expected);
    MT_EQUAL([kind searchCategoriesForProfileLoaders:@[]], expected);
    MT_ASSERT(kind.type == ModContentTypeShaderPacks);
    MT_EQUAL(kind.projectType, @"shader");
    MT_EQUAL(kind.folderName, @"shaderpacks");
    MT_EQUAL(kind.fileExtension, @"zip");
    MT_ASSERT(kind.listsFolders);
    MT_ASSERT(!kind.isMods);
    MT_EQUAL([kind stringKey:@"title"], @"shaderpacks.title");
}

static void testKindsAreSharedInstances(void) {
    MT_ASSERT(ModContentKind.mods == ModContentKind.mods);
    MT_ASSERT(ModContentKind.resourcePacks == ModContentKind.resourcePacks);
    MT_ASSERT(ModContentKind.shaderPacks == ModContentKind.shaderPacks);
    MT_ASSERT(ModContentKind.mods != ModContentKind.resourcePacks);
}

void ModContentKindTests(void) {
    MT_RUN(testModsKindKeepsProfileLoaders);
    MT_RUN(testResourcePackKindUsesMinecraftLoader);
    MT_RUN(testShaderKindUsesIrisAndOptifine);
    MT_RUN(testKindsAreSharedInstances);
}
