# Per-profile Mod Manager Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Mods screen to each profile that browses Modrinth, installs the version matching the profile's Minecraft version and loader (with required dependencies), toggles/deletes/updates mods, and re-matches mods when the profile's version changes.

**Architecture:** Pure-Foundation model classes in `Natives/mods/` (loader detection, version choice, dependency resolution, the per-folder record, folder operations, the installer with an injectable downloader) are unit-tested on the Mac host with a tiny test runner. A Modrinth client extends the existing `ModpackAPI`. Three UIKit screens (installed list, browse, detail) sit on top and are verified on device. Entry is a new row in `LauncherProfileEditorViewController`.

**Tech Stack:** Objective-C (ARC), Foundation, UIKit, AFNetworking (already vendored, incl. `UIImageView+AFNetworking`), UnzipKit (bundled framework), CommonCrypto, Modrinth API v2.

**Spec:** `docs/superpowers/specs/2026-10-29-mod-manager-design.md` (read it; this plan does not repeat its reasoning).

## Global Constraints

- Modrinth base URL `https://api.modrinth.com/v2`. Every request (API and downloads) sends `User-Agent: Amethyst-iOS/<CFBundleShortVersionString> (github.com/Raymon82777/Amethyst-iOS-Improved)`.
- Accepted loaders: fabric→`fabric`; quilt→`quilt`,`fabric`; forge→`forge`; neoforge→`neoforge`, plus `forge` only when Minecraft is exactly `1.20.1`. Game versions matched: exactly `[mc]`.
- Best version: newest `date_published` among `release`; else `beta`; else `alpha`. File: `primary: true`, else first.
- Record file: `<profile game dir>/mods/.amethyst-mods.json`, `formatVersion` `1`, keyed by jar file name **without** `.disabled`. Entry keys: `projectId, versionId, slug, title, versionNumber, versionType, iconUrl, sha1, requires, gameVersions, loaders`. Top-level `unknownHashes` array.
- Disable = rename `X.jar` → `X.jar.disabled`; enable = reverse.
- Downloads go to `<name>.part`, are verified (`sha1`, else `sha512`; neither → refuse), then renamed. A failed set leaves the folder and record exactly as before.
- Per-profile folder: `./custom_gamedir/<safe profile name>`; any existing folder → append ` (2)`, ` (3)`… Only modded profiles are migrated. Copy `options.txt` from the instance root if the new folder has none. Profile game folder = `[NSString stringWithFormat:@"%s/%@", getenv("GAME_DIR"), gameDir].stringByStandardizingPath` (same folder `JavaLauncher.m` uses).
- Files in `Natives/mods/` whose names start with `Mod` and are listed under "Host-tested" below must import only Foundation/CommonCrypto (no `utils.h`, which pulls in UIKit). Host-tested: `ModProfileInfo`, `ModVersionSelector`, `ModIndex`, `ModFolder`, `ModDependencyResolver`, `ModInstaller`.
- Network calls never run on the main thread (`ModpackAPI getEndpoint:` blocks).
- All user-facing strings via `localize(@"mods.…", nil)`, English added to `Natives/resources/en.lproj/Localizable.strings`.
- Every new `.m` that ships in the app is added to `add_executable(AngelAuraAmethyst …)` in `Natives/CMakeLists.txt`.
- Building/device testing needs the user's Mac and an iOS device; this Windows host can only do static checks. Host tests run on macOS with `make test_mods`.

## Review Focus

1. **App killed mid-download leaves `*.part` files** → they are deleted next time the folder is scanned, never shown as mods (Task 4 test `testStrayPartFilesAreRemoved`).
2. **Profile names with `/`, `..`, `:` or leading dots** → folder name is sanitized and stays inside `custom_gamedir` (Task 4 test `testSafeFolderNameStripsPathCharacters`).
3. **Jars deleted or renamed outside the app (Files app)** → stale record entries are pruned on scan; renamed jars are re-identified by hash (Task 3 test `testPruneRemovesEntriesForMissingFiles`).
4. **A hand-added jar already has the exact file name Modrinth wants to download** → it is treated as the file being replaced, not a failure, and not left duplicated (Task 6 test `testDownloadOverExistingSameNameReplacesIt`).
5. **Tapping Install/Update/Switch twice, or switching a mod while an install runs** → only one operation runs; controls are disabled until it ends (Task 8 check h, Task 9 check e).

---

### Task 1: Host test runner and loader detection

**Files:**
- Create: `Natives/mods/ModProfileInfo.h`, `Natives/mods/ModProfileInfo.m`
- Create: `Natives/tests/mods/ModTest.h`, `Natives/tests/mods/ModTestMain.m`, `Natives/tests/mods/ModProfileInfoTests.m`
- Modify: `Makefile` (new `test_mods` target and a line in `help`), `Natives/CMakeLists.txt` (add `mods/ModProfileInfo.m`)

**Interfaces:**
- Produces:
  ```objc
  @interface ModProfileInfo : NSObject
  @property(nonatomic, readonly, nullable) NSString *minecraftVersion;
  @property(nonatomic, readonly, nullable) NSString *loader;        // @"fabric" @"quilt" @"forge" @"neoforge", nil = vanilla
  @property(nonatomic, readonly, nullable) NSString *loaderVersion;
  @property(nonatomic, readonly) NSArray<NSString *> *acceptedLoaders; // empty when vanilla
  @property(nonatomic, readonly) BOOL isModded;
  @property(nonatomic, readonly) NSString *displayName;             // e.g. @"Fabric · 1.21.1"
  + (instancetype)infoForVersionId:(NSString *)versionId versionsDir:(NSString *)versionsDir;
  + (instancetype)infoForVersionId:(NSString *)versionId json:(nullable NSDictionary *)json;
  + (NSArray<NSString *> *)acceptedLoadersForLoader:(nullable NSString *)loader minecraftVersion:(nullable NSString *)mc;
  @end
  ```
- Test runner: `ModTest.h` defines `MT_ASSERT(cond)` and `MT_EQUAL(a, b)` (uses `isEqual:`; prints file:line and increments a global failure count) and `MT_RUN(fn)`. Each test file exposes `void ModXxxTests(void)` that calls its `test…` functions; `ModTestMain.m` calls each and exits non-zero on any failure.

- [ ] **Step 1: Write the runner and failing tests** in `ModProfileInfoTests.m`:

```objc
static void testFabricFromLibraries(void) {
    ModProfileInfo *i = [ModProfileInfo infoForVersionId:@"fabric-loader-0.16.5-1.21.1" json:@{
        @"inheritsFrom": @"1.21.1",
        @"libraries": @[@{@"name": @"net.fabricmc:fabric-loader:0.16.5"}]}];
    MT_EQUAL(i.loader, @"fabric"); MT_EQUAL(i.minecraftVersion, @"1.21.1");
    MT_EQUAL(i.loaderVersion, @"0.16.5"); MT_EQUAL(i.acceptedLoaders, (@[@"fabric"]));
}
static void testQuiltAcceptsFabric(void)        // org.quiltmc:quilt-loader → @[@"quilt", @"fabric"]
static void testForgeFromLibraries(void)        // net.minecraftforge:fmlloader:1.20.1-47.2.0, inheritsFrom 1.20.1 → forge, @[@"forge"]
static void testNeoForge1201AcceptsForge(void)  // net.neoforged:forge:1.20.1-47.1.106, inheritsFrom 1.20.1 → neoforge, @[@"neoforge", @"forge"]
static void testNeoForge121OnlyNeoForge(void)   // net.neoforged:neoforge:21.1.77, inheritsFrom 1.21.1 → @[@"neoforge"]
static void testVanillaJson(void)               // no inheritsFrom, no loader libs, id 1.21.1 → loader nil, mc 1.21.1, isModded NO
static void testLatestReleaseIsVanilla(void)    // id latest-release, json nil → isModded NO
static void testFallbackFromIdPatterns(void)    // json nil: "fabric-loader-0.16.5-1.21.1" → fabric/1.21.1; "quilt-loader-0.26.0-1.20.4" → quilt/1.20.4; "1.20.1-forge-47.2.0" → forge/1.20.1; "neoforge-21.4.114-beta" → neoforge/1.21.4
static void testReadsFromVersionsDir(void)      // write <tmp>/fabric-x/fabric-x.json, infoForVersionId:versionsDir: reads it
```

Spell out each listed test with `MT_EQUAL`s on `loader`, `minecraftVersion`, `acceptedLoaders` as in the first one.

- [ ] **Step 2: Add the `test_mods` Makefile target**

```make
test_mods:
	mkdir -p $(WORKINGDIR)/tests
	xcrun --sdk macosx clang -fobjc-arc -fmodules -framework Foundation \
		-I$(SOURCEDIR)/Natives/mods -I$(SOURCEDIR)/Natives/tests/mods \
		$(SOURCEDIR)/Natives/mods/ModProfileInfo.m \
		$(SOURCEDIR)/Natives/tests/mods/*.m \
		-o $(WORKINGDIR)/tests/mods_tests
	$(WORKINGDIR)/tests/mods_tests
```

Later tasks append their host-tested `.m` to this source list.

- [ ] **Step 3: Run, expect failure**

Run: `make test_mods` → link errors / FAIL lines (class not implemented).

- [ ] **Step 4: Implement `ModProfileInfo`**

Loader from `libraries[].name`, checked in this order: group `org.quiltmc` artifact `quilt-loader` → quilt; group starting `net.neoforged` → neoforge; `net.minecraftforge:forge` or `net.minecraftforge:fmlloader` → forge; `net.fabricmc:fabric-loader` → fabric. `loaderVersion` = the coordinate's version, with a leading `<mc>-` stripped for forge. `minecraftVersion` = `inheritsFrom` ?: id. If json is nil, use the id patterns from the test; NeoForge id → Minecraft via the same rule as `-[ForgeInstallViewController extractMinecraftVersionFromNeoForgeVersion:]` (copy the logic into a static function; do not import the view controller). `latest-release`/`latest-snapshot` → vanilla with nil mc. `displayName`: capitalized loader (`NeoForge` for neoforge) + ` · ` + mc.

- [ ] **Step 5: Run, expect pass**

Run: `make test_mods` → all tests pass, exit 0.

- [ ] **Step 6: Commit**

```bash
git add Natives/mods/ModProfileInfo.* Natives/tests/mods Makefile Natives/CMakeLists.txt
git commit -m "feat(mods): detect profile loader and Minecraft version"
```

---

### Task 2: Version selection

**Files:**
- Create: `Natives/mods/ModVersionSelector.h/.m`, `Natives/tests/mods/ModVersionSelectorTests.m`
- Modify: `Makefile` (`test_mods` sources), `Natives/CMakeLists.txt`, `Natives/tests/mods/ModTestMain.m`

**Interfaces:**
- Produces (class methods on `ModVersionSelector`; versions are Modrinth version objects):
  ```objc
  + (BOOL)version:(NSDictionary *)version fitsLoaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc;
  + (nullable NSDictionary *)bestVersionIn:(NSArray<NSDictionary *> *)versions loaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc;
  + (NSArray<NSDictionary *> *)compatibleVersionsNewestFirst:(NSArray<NSDictionary *> *)versions loaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc;
  + (nullable NSDictionary *)primaryFileOfVersion:(NSDictionary *)version;
  ```

- [ ] **Step 1: Write failing tests**

```objc
testPrefersNewestRelease        // release 2026-08 + release 2026-10 + beta 2026-11 → versionId of release 2026-10
testFallsBackToBetaThenAlpha    // only beta+alpha → beta; only alpha → alpha
testIgnoresWrongLoaderOrGame    // newest release is forge-only for a fabric query → older fabric release chosen
testNilWhenNothingFits          // → nil
testPrimaryFileWins             // files [secondary, primary:true] → primary; none primary → first
testCompatibleNewestFirst       // mixed list → only fitting, sorted by date_published descending
```

`date_published` values are ISO-8601 UTC strings; compare with `NSISO8601DateFormatter` (`NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds`, falling back to without fractional seconds).

- [ ] **Step 2: Run** `make test_mods` → FAIL.
- [ ] **Step 3: Implement** `ModVersionSelector`. A version fits when its `loaders` intersect `loaders` and its `game_versions` contain `mc`.
- [ ] **Step 4: Run** `make test_mods` → PASS.
- [ ] **Step 5: Commit** `feat(mods): choose the best compatible Modrinth version`.

---

### Task 3: The per-folder record (`ModIndex`)

**Files:**
- Create: `Natives/mods/ModIndex.h/.m`, `Natives/tests/mods/ModIndexTests.m`
- Modify: `Makefile`, `Natives/CMakeLists.txt`, `ModTestMain.m`

**Interfaces:**
- Produces:
  ```objc
  extern NSString *const ModIndexFileName; // @".amethyst-mods.json"
  @interface ModIndex : NSObject
  - (instancetype)initWithModsDir:(NSString *)modsDir; // missing/corrupt file → empty index
  @property(nonatomic, readonly) NSString *modsDir;
  @property(nonatomic, readonly) NSMutableDictionary<NSString *, NSMutableDictionary *> *entries;
  @property(nonatomic, readonly) NSMutableSet<NSString *> *unknownHashes;
  - (nullable NSString *)fileNameForProjectId:(NSString *)projectId;
  - (NSArray<NSString *> *)fileNamesRequiringProject:(NSString *)projectId;
  - (void)pruneEntriesNotIn:(NSSet<NSString *> *)existingFileNames;
  - (BOOL)save:(NSError **)error; // atomic write, pretty-printed
  + (BOOL)entry:(NSDictionary *)entry matchesLoaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc;
  + (NSMutableDictionary *)entryForVersion:(NSDictionary *)version file:(NSDictionary *)file project:(nullable NSDictionary *)project;
  @end
  ```
  `entryForVersion:` fills keys from Global Constraints: `requires` = `project_id`s of `dependency_type == "required"` dependencies; `title`/`slug`/`iconUrl` from `project` (`title`, `slug`, `icon_url`), falling back to `version[@"name"]`; `sha1` from `file[@"hashes"][@"sha1"]`.

- [ ] **Step 1: Write failing tests**

```objc
testRoundTrip                   // set entry + unknown hash, save, reload → equal entries & hashes, formatVersion 1 on disk
testCorruptFileGivesEmptyIndex  // write "{not json" → entries.count == 0, no crash
testFileNameForProjectId        // two entries → correct key
testFileNamesRequiringProject   // A requires P, B requires P, C none → {A,B}
testPruneRemovesEntriesForMissingFiles // entries a.jar,b.jar; prune with {a.jar} → only a.jar
testEntryMatches                // gameVersions [1.21.1], loaders [fabric]: (fabric,1.21.1) YES; (fabric,1.21.4) NO; (quilt+fabric accepted,1.21.1) YES
testEntryForVersionMapsFields   // sample version with required+optional deps → requires == [requiredId]
```

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(mods): add per-folder mod record`.

---

### Task 4: Folder operations and per-profile folder migration (`ModFolder`)

**Files:**
- Create: `Natives/mods/ModFolder.h/.m`, `Natives/tests/mods/ModFolderTests.m`
- Modify: `Makefile`, `Natives/CMakeLists.txt`, `ModTestMain.m`

**Interfaces:**
- Produces:
  ```objc
  extern NSErrorDomain const ModFolderErrorDomain;
  typedef NS_ENUM(NSInteger, ModFolderError) { ModFolderErrorExists = 1 };
  @interface ModJar : NSObject
  @property(nonatomic) NSString *fileName; // without ".disabled"
  @property(nonatomic) NSString *path;     // actual path on disk
  @property(nonatomic) BOOL enabled;
  @end
  @interface ModFolder : NSObject
  - (instancetype)initWithModsDir:(NSString *)modsDir; // creates the dir if missing
  @property(nonatomic, readonly) NSString *modsDir;
  - (NSArray<ModJar *> *)scanJars;   // *.jar and *.jar.disabled only; deletes stray *.part first; sorted by fileName
  - (BOOL)setJar:(ModJar *)jar enabled:(BOOL)enabled error:(NSError **)error; // updates jar.path/enabled
  - (BOOL)deleteJar:(ModJar *)jar error:(NSError **)error;
  - (nullable NSString *)importJarFromURL:(NSURL *)url replaceExisting:(BOOL)replace error:(NSError **)error; // returns fileName; NO-replace + clash → error code ModFolderErrorExists
  + (nullable NSString *)sha1OfFileAtPath:(NSString *)path;
  + (nullable NSString *)sha512OfFileAtPath:(NSString *)path;
  + (NSString *)gameDirPathForGameDir:(nullable NSString *)gameDir baseDir:(NSString *)baseDir; // standardized
  + (BOOL)isSharedGameDir:(nullable NSString *)gameDir baseDir:(NSString *)baseDir;
  + (NSString *)safeFolderName:(NSString *)profileName;
  // Returns the new gameDir value ("./custom_gamedir/<name>"), or nil + error. Creates folder and mods/, copies options.txt.
  + (nullable NSString *)migrateProfileNamed:(NSString *)profileName baseDir:(NSString *)baseDir error:(NSError **)error;
  @end
  ```
  `baseDir` is `@(getenv("GAME_DIR"))` in the app and a temp dir in tests.

- [ ] **Step 1: Write failing tests**

```objc
testScanFindsEnabledAndDisabled     // a.jar, b.jar.disabled, notes.txt, .amethyst-mods.json → [a(enabled), b(disabled)]
testStrayPartFilesAreRemoved        // c.jar.part present → scan deletes it, not listed
testToggleRenames                   // disable a → a.jar.disabled exists, a.jar gone; enable → back
testDelete                          // disabled jar deleted from disk
testImportClash                     // import over existing name without replace → ModFolderErrorExists; with replace → overwritten
testSha1KnownValue                  // file "abc" → @"a9993e364706816aba3e25717850c26c9cd0d89d"
testIsSharedGameDir                 // nil, @"", @".", @"./", @"./foo/.." → YES; @"./custom_gamedir/x" → NO
testSafeFolderNameStripsPathCharacters // @"../a/b:c" → no '/', ':' and no leading '.'; @"" or @"..." → @"Profile"
testMigrateCreatesFolderAndCopiesOptions // base has options.txt → returns @"./custom_gamedir/Fab", folder+mods exist, options.txt copied
testMigrateSuffixesExistingFolder   // custom_gamedir/Fab exists (any content) → @"./custom_gamedir/Fab (2)"; Fab (2) exists too → "(3)"
testMigrateDoesNotOverwriteOptions  // no options.txt in base → none created; nothing in base modified
```

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement** (CommonCrypto `CC_SHA1`/`CC_SHA512`, streamed in 1 MB chunks). **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(mods): mod folder operations and per-profile folder`.

---

### Task 5: Dependency resolution

**Files:**
- Create: `Natives/mods/ModDependencyResolver.h/.m`, `Natives/tests/mods/ModDependencyResolverTests.m`
- Modify: `Makefile`, `Natives/CMakeLists.txt`, `ModTestMain.m`

**Interfaces:**
- Consumes: `ModVersionSelector` (Task 2).
- Produces:
  ```objc
  typedef NSArray<NSDictionary *> * _Nullable (^ModFetchProjectVersions)(NSString *projectId); // nil = network error
  typedef NSDictionary * _Nullable (^ModFetchVersion)(NSString *versionId);                  // nil = network error / not found
  extern NSErrorDomain const ModResolveErrorDomain;
  typedef NS_ENUM(NSInteger, ModResolveError) { ModResolveErrorNetwork = 1, ModResolveErrorMissingDependency = 2 };
  // userInfo[@"projectId"] on MissingDependency

  @interface ModInstallPlan : NSObject
  @property(nonatomic) NSArray<NSDictionary *> *versionsToInstall;          // root first
  @property(nonatomic) NSArray<NSString *> *projectIdsToEnable;             // installed but disabled required deps
  @property(nonatomic) NSArray<NSString *> *incompatibleInstalledProjectIds;
  @property(nonatomic) NSArray<NSString *> *optionalProjectIds;             // root's optional deps
  @end

  @interface ModDependencyResolver : NSObject
  - (instancetype)initWithLoaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc
                installedProjects:(NSDictionary<NSString *, NSNumber *> *)installed // projectId → @(enabled)
             fetchProjectVersions:(ModFetchProjectVersions)fetchProjectVersions
                     fetchVersion:(ModFetchVersion)fetchVersion;
  - (nullable ModInstallPlan *)planForVersion:(NSDictionary *)rootVersion error:(NSError **)error; // synchronous
  @end
  ```

- [ ] **Step 1: Write failing tests** (fetch blocks return canned version dicts and count calls):

```objc
testRootOnly                         // no deps → [root]
testInstallsMissingRequired          // root requires A (not installed) → [root, bestOf(A)]
testRecursesAndAvoidsCycles          // root→A→B→A → [root, A, B], A fetched once
testSkipsInstalledEnabled            // A installed @YES → [root]
testReenablesInstalledDisabled       // A installed @NO → [root], projectIdsToEnable == [A]
testPinnedVersionUsedWhenItFits      // dep has version_id that fits → that version, fetchProjectVersions not called
testPinnedVersionReplacedWhenNotFit  // pinned version is for 1.20.1 on a 1.21.1 query → bestOf(A)
testMissingDependencyAborts          // A has no compatible versions → nil, ModResolveErrorMissingDependency, projectId A
testNetworkErrorAborts               // fetch returns nil → ModResolveErrorNetwork
testIncompatibleAndOptional          // root incompatible with installed X, optional Y → incompatible [X], optional [Y]; X not installed → []
testEmbeddedIgnored                  // embedded dep → not in plan
```

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(mods): resolve required dependencies`.

---

### Task 6: Installer (download, verify, replace, roll back)

**Files:**
- Create: `Natives/mods/ModInstaller.h/.m`, `Natives/tests/mods/ModInstallerTests.m`
- Modify: `Makefile`, `Natives/CMakeLists.txt`, `ModTestMain.m`

**Interfaces:**
- Consumes: `ModInstallPlan` (Task 5), `ModIndex` (Task 3), `ModFolder` hashing (Task 4), `ModVersionSelector primaryFileOfVersion:` (Task 2).
- Produces:
  ```objc
  typedef void (^ModDownloadCompletion)(NSError * _Nullable error);
  typedef void (^ModDownloader)(NSURL *url, NSString *destPath, ModDownloadCompletion completion);
  extern NSErrorDomain const ModInstallErrorDomain;
  typedef NS_ENUM(NSInteger, ModInstallError) { ModInstallErrorDownload = 1, ModInstallErrorHashMismatch = 2, ModInstallErrorNoHash = 3, ModInstallErrorFileSystem = 4 };
  // userInfo[@"fileName"] names the file that failed

  @interface ModInstaller : NSObject
  + (ModDownloader)defaultDownloader; // NSURLSession download task with the Global User-Agent; moves the temp file to destPath
  - (instancetype)initWithIndex:(ModIndex *)index downloader:(ModDownloader)downloader;
  // projects: projectId → Modrinth project dict (for title/slug/icon). Completion on an arbitrary queue.
  - (void)installPlan:(ModInstallPlan *)plan projects:(NSDictionary<NSString *, NSDictionary *> *)projects
           completion:(void (^)(NSError * _Nullable error))completion;
  @end
  ```
  Order: download every version's primary file to `<fileName>.part` sequentially and verify; then, for each, if the index has a file for that project (or a jar with the same name exists), remember whether it was disabled and delete it; rename `.part` to `<fileName>` or `<fileName>.disabled` (kept disabled if the replaced one was); rename `projectIdsToEnable` files to enabled; set index entries via `entryForVersion:file:project:` (removing the replaced entry's key if the file name changed); `save:`. Any failure before the rename phase deletes all `.part` files and leaves the index untouched.

- [ ] **Step 1: Write failing tests** (fake downloader writes given bytes to `destPath` or fails; versions carry real sha1s of those bytes):

```objc
testInstallsAndRecords                  // 2-version plan → both jars exist, index has both entries, no .part left
testHashMismatchRollsBack               // 2nd file bytes don't match → error HashMismatch, fileName set, folder & index unchanged, no .part
testDownloadFailureRollsBack            // downloader error on 2nd → ModInstallErrorDownload, nothing changed
testReplaceKeepsDisabledState           // old sodium-0.5.jar.disabled recorded for project S; install S 0.6 → sodium-0.6.jar.disabled exists, old gone, index key updated
testDownloadOverExistingSameNameReplacesIt // unrecorded foo.jar on disk, plan downloads foo.jar → one foo.jar with new content, recorded
testEnablesRequestedProjects            // projectIdsToEnable [A], A's jar disabled → enabled after install
testSha512FallbackAndNoHash             // file with only sha512 → verified; with no hashes → ModInstallErrorNoHash, rolled back
```

- [ ] **Step 2: Run** → FAIL. **Step 3: Implement.** **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `feat(mods): install mod sets with verification and rollback`.

---

### Task 7: Modrinth client for mods

**Files:**
- Create: `Natives/mods/ModrinthModsAPI.h/.m`
- Modify: `Natives/installer/modpack/ModpackAPI.h/.m` (User-Agent on every request; new `postEndpoint:body:`), `Natives/CMakeLists.txt`

**Interfaces:**
- Produces (all synchronous, call off the main thread; return nil on failure with `lastError` set):
  ```objc
  // ModpackAPI additions
  - (nullable id)postEndpoint:(NSString *)endpoint body:(NSDictionary *)body; // JSON request & response
  + (NSString *)userAgent;                                                    // Global Constraints value

  @interface ModrinthModsAPI : ModpackAPI
  - (nullable NSMutableArray<NSDictionary *> *)searchMods:(NSString *)query loaders:(NSArray<NSString *> *)loaders
      gameVersion:(NSString *)mc previous:(nullable NSMutableArray *)previous; // sets reachedLastPage; 50 per page
  - (nullable NSArray<NSDictionary *> *)versionsOfProject:(NSString *)projectId loaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc;
  - (nullable NSDictionary *)versionWithId:(NSString *)versionId;
  - (nullable NSDictionary<NSString *, NSDictionary *> *)projectsWithIds:(NSArray<NSString *> *)ids;   // GET /projects?ids=[…], keyed by id
  - (nullable NSDictionary<NSString *, NSDictionary *> *)versionsForHashes:(NSArray<NSString *> *)sha1s; // POST /version_files
  - (nullable NSDictionary<NSString *, NSDictionary *> *)latestVersionsForHashes:(NSArray<NSString *> *)sha1s
      loaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc versionTypes:(nullable NSArray<NSString *> *)types; // POST /version_files/update
  @end
  ```
  Search hit dict keys: `id`, `slug`, `title`, `description`, `author`, `downloads`, `imageUrl` (from `project_id`, `slug`, `title`, `description`, `author`, `downloads`, `icon_url`). Search facets per spec §5: `[["project_type:mod"],["categories:<l>",…],["versions:<mc>"],["client_side:required","client_side:optional"]]`; `index` = `relevance` when query non-empty, `downloads` when empty. JSON-array query params (`loaders`, `game_versions`, `ids`) are passed as JSON strings, e.g. `@"[\"fabric\",\"quilt\"]"`. `version_types` is omitted when `types` is nil.

- [ ] **Step 1: Implement** the additions and the class.
- [ ] **Step 2: Check the requests against the live API from the Mac**

Run each and confirm a non-empty JSON result:
```bash
curl -s -A "Amethyst-iOS/test" 'https://api.modrinth.com/v2/search?limit=3&facets=[["project_type:mod"],["categories:fabric"],["versions:1.21.1"],["client_side:required","client_side:optional"]]' | head -c 300
```
```bash
curl -s -A "Amethyst-iOS/test" 'https://api.modrinth.com/v2/project/sodium/version?loaders=["fabric"]&game_versions=["1.21.1"]' | head -c 300
```
Expected: `{"hits":[…` and `[{"game_versions":…` respectively.
- [ ] **Step 3: Build the app** (`make` on the Mac) → compiles with no new warnings in the touched files.
- [ ] **Step 4: Commit** `feat(mods): Modrinth client for mods`.

---

### Task 8: Installed Mods screen and profile editor entry

**Files:**
- Create: `Natives/mods/ModsViewController.h/.m`, `Natives/mods/ModJarMetadata.h/.m`
- Modify: `Natives/LauncherProfileEditorViewController.m` (Mods row, save-first, extract save), `Natives/CMakeLists.txt`, `Natives/resources/en.lproj/Localizable.strings`

**Interfaces:**
- Consumes: Tasks 1, 3, 4, 7.
- Produces:
  ```objc
  @interface ModsViewController : UITableViewController
  - (instancetype)initWithProfileName:(NSString *)profileName;
  @property(nonatomic, copy, nullable) void (^gameDirChanged)(NSString *newGameDir); // editor updates its copy
  // Shared state later tasks use:
  @property(nonatomic, readonly) ModProfileInfo *info;
  @property(nonatomic, readonly) ModIndex *index;
  @property(nonatomic, readonly) ModFolder *folder;
  @property(nonatomic, readonly) ModrinthModsAPI *api;
  @property(nonatomic, readonly) BOOL busy;                 // an operation is running
  - (void)runOperation:(void (^)(void (^done)(NSError * _Nullable error)))operation; // sets busy, spinner, disables controls; done reloads list and shows error
  - (void)reloadFromDisk;                                   // scan, prune, identify, then (Task 10) checks
  @end

  @interface ModJarMetadata : NSObject
  + (nullable NSDictionary *)metadataForJarAtPath:(NSString *)path; // @{@"name":…, @"version":…} from fabric.mod.json / quilt.mod.json / META-INF/mods.toml / META-INF/neoforge.mods.toml
  @end
  ```
  In `LauncherProfileEditorViewController`: extract `- (BOOL)saveProfile` from `actionDone` (everything up to and including `[PLProfiles.current save]`, returning NO on the name clash); after saving set `self.oldName = self.profile[@"name"]`. `actionDone` = `if ([self saveProfile]) { close + refresh as today }`. New row `@{@"key": @"mods", @"icon": @"puzzlepiece", @"title": @"preference.profile.title.mods", @"type": self.typeButton, @"enableCondition": …saved profile exists…, @"action": …}`. Action: if `self.profile` differs from `PLProfiles.current.profiles[self.oldName]` in `name` or `lastVersionId`, alert `mods.alert.save_first` (Save / Cancel); Save → `saveProfile` then push. Push `ModsViewController initWithProfileName:self.oldName` on `self.navigationController`, `gameDirChanged` sets `self.profile[@"gameDir"]` and reloads the table.

- [ ] **Step 1: Implement the editor changes.**
- [ ] **Step 2: Implement `ModsViewController`** per spec §2–§4, §11, §13:
  - `viewDidLoad`: read saved profile; `info = [ModProfileInfo infoForVersionId:… versionsDir:GAME_DIR/versions]`. Vanilla → empty-state background view with `mods.empty.vanilla` text, no buttons, no migration, no `+`.
  - Modded + `isSharedGameDir` → `migrateProfileNamed:`; write `gameDir` to `PLProfiles.current.profiles[name]`, `[PLProfiles.current save]`, call `gameDirChanged`; show `mods.alert.own_folder` once per profile (store `@"modsFolderNotice": @"1"` in the profile dict).
  - Header text: `"<count> mods · <info.displayName>"`. Rows: `UITableViewCellStyleSubtitle`, icon via `setImageWithURL:placeholderImage:` (placeholder `DefaultProfile`), title = record `title` ?: jar metadata `name` ?: file name, subtitle = `versionNumber` ?: metadata `version`; non-record jars add `mods.row.manual`. `UISwitch` accessory → `setJar:enabled:` (with dependents check below). Disabled rows: `contentView.alpha = 0.45`.
  - Dependents check before disable/delete: `fileNamesRequiringProject:` filtered to enabled jars; if non-empty, confirm `mods.alert.needed_by` listing their titles.
  - Swipe: Delete (no confirmation unless dependents); for record jars also `mods.action.change_version` (Task 9 provides the detail screen; until then omit).
  - Search controller filters rows by title.
  - Toolbar/nav: `+` (Task 9), Files import button → `UIDocumentPickerViewController` for `@[@"public.java-archive", @"com.sun.java-archive"]` falling back to `public.data`; clash → alert Replace / Keep both (Keep both appends ` (2)` before `.jar`).
  - `reloadFromDisk` (background queue): `scanJars`, `pruneEntriesNotIn:`, then for jars with no entry and whose sha1 isn't in `unknownHashes`: one `versionsForHashes:`, `projectsWithIds:` for matches, `entryForVersion:file:project:`; non-matches → `unknownHashes`; `save:`. Offline → skip silently.
- [ ] **Step 3: Implement `ModJarMetadata`** with UnzipKit (`UZKArchive extractDataFromFile:`); parse JSON for fabric/quilt (`name`, `version`; quilt under `quilt_loader.metadata.name` / `quilt_loader.version`); for TOML read the first `displayName = "…"` and `version = "…"` with a regex (a `${file.jarVersion}` version → nil).
- [ ] **Step 4: Add strings** (`preference.profile.title.mods`, `mods.title`, `mods.empty.vanilla`, `mods.alert.save_first`, `mods.alert.own_folder`, `mods.alert.needed_by`, `mods.row.manual`, `mods.action.delete`, `mods.action.import`, `mods.import.replace`, `mods.import.keep_both`).
- [ ] **Step 5: Build and check on device**
  - a. Vanilla profile → Mods shows the explanation; profile's Game directory unchanged.
  - b. Fabric profile on `.` → one-time notice; editor's Game directory now `./custom_gamedir/<name>`; Close the editor and reopen → still set; `options.txt` present in the new folder; worlds remain in the instance root.
  - c. Second profile with the same name folder existing → `(2)` suffix.
  - d. Copy a known Modrinth jar (e.g. Sodium) and a random jar into the folder via Files → list shows Sodium with title/icon and the other as "Added manually" with its `fabric.mod.json` name.
  - e. Switch off → file becomes `.jar.disabled`, row dims; switch on → back.
  - f. Disable Fabric API while Sodium is recorded as requiring it → confirmation naming Sodium.
  - g. Unsaved version change in the editor then tap Mods → save prompt; Save → Mods opens for the new version.
  - h. While `busy`, switches and swipe actions are disabled (trigger with a slow identification over a throttled network).
  - i. Launch the game → enabled mods load, disabled ones don't.
- [ ] **Step 6: Commit** `feat(mods): installed mods screen and profile entry`.

---

### Task 9: Browse, mod detail, install flow, iOS warnings

**Files:**
- Create: `Natives/mods/ModBrowseViewController.h/.m`, `Natives/mods/ModDetailViewController.h/.m`, `Natives/resources/ios_mod_warnings.plist`
- Modify: `Natives/mods/ModsViewController.m` (`+` button, row tap and Change version → detail), `Natives/CMakeLists.txt`, `Localizable.strings`

**Interfaces:**
- Consumes: Tasks 2, 5, 6, 7, 8 (`runOperation:`, `info`, `index`, `api`).
- Produces:
  ```objc
  @interface ModBrowseViewController : UITableViewController
  - (instancetype)initWithModsController:(ModsViewController *)mods;
  @end
  @interface ModDetailViewController : UITableViewController
  - (instancetype)initWithModsController:(ModsViewController *)mods projectId:(NSString *)projectId hit:(nullable NSDictionary *)hit;
  @end
  NSString * _Nullable ModIOSWarningForProject(NSString *projectId); // reads ios_mod_warnings.plist (dict projectId → reason) from the main bundle, cached
  ```
  `ios_mod_warnings.plist` starts as an empty `<dict/>`.

- [ ] **Step 1: Implement Browse** (spec §5): presented in a nav controller from `+`; `UISearchController` debounced 0.5 s like `ModpackInstallViewController`; non-editable chip label = `info.displayName` in the table header; infinite scroll; tags `mods.tag.installed` (project id in `index`) and `mods.tag.ios` (warning exists). Tap → push detail.
- [ ] **Step 2: Implement Detail** (spec §6–§8): load `projectsWithIds:@[id]` (if no hit) and `versionsOfProject:`; hero (icon, title, author when known, downloads, description); button `mods.detail.install` / `mods.detail.installed` / `mods.detail.update` using `bestVersionIn:`; "no compatible version" message when nil; required-deps line (`mods.detail.also_installs` / `mods.detail.already_installed`) from a dry-run plan; optional deps as `mods.detail.works_with`; iOS warning line; versions section from `compatibleVersionsNewestFirst:` with Release/Beta/Alpha tags — tapping installs that version; "View on Modrinth" opens `https://modrinth.com/mod/<slug>`.
- [ ] **Step 3: Install flow** inside `mods runOperation:`: build `ModDependencyResolver` with `info.acceptedLoaders`, `info.minecraftVersion`, installed map from `index` + scanned jars' enabled state, and `api` fetch blocks; `planForVersion:`; if `incompatibleInstalledProjectIds` non-empty → confirm `mods.alert.incompatible`; if warning → confirm `mods.alert.ios_warning`; `projectsWithIds:` for all plan project ids; `ModInstaller` with `defaultDownloader`; on MissingDependency show `mods.error.missing_dependency` with the project title; on install error show `mods.error.install` with `fileName`.
- [ ] **Step 4: Add strings** for every key named above.
- [ ] **Step 5: Build and check on device**
  - a. Browse on a Fabric 1.21.1 profile shows chip "Fabric · 1.21.1" and only Fabric mods; on a Quilt profile Fabric mods appear too.
  - b. Install Sodium Extra with nothing installed → Sodium Extra, Sodium and any other required mods installed; detail line said "will also be installed".
  - c. Disable Sodium, install Sodium Extra → Sodium re-enabled.
  - d. Pick an older version from the list → replaces the installed one.
  - e. Double-tap Install → only one install runs.
  - f. Airplane mode during download → error, mods folder unchanged (no `.part`, no partial set).
- [ ] **Step 6: Commit** `feat(mods): browse and install mods from Modrinth`.

---

### Task 10: Update checks and version-change re-matching

**Files:**
- Modify: `Natives/mods/ModsViewController.m`, `Localizable.strings`

**Interfaces:**
- Consumes: Tasks 3, 5, 6, 7, 8, 9.
- Produces (in `ModsViewController`): `@property NSDictionary<NSString *, NSDictionary *> *availableUpdates;` (fileName → newer version), `@property NSArray<NSString *> *mismatchedFileNames;`.

- [ ] **Step 1: Mismatch detection** (spec §12b): after `reloadFromDisk`, record entries failing `entry:matchesLoaders:gameVersion:` → `mismatchedFileNames`; entries missing `gameVersions`/`loaders` are backfilled via `versionsForHashes:` first. Mismatched rows show `mods.row.built_for` (with the entry's newest game version) and, after a failed switch, `mods.row.no_version`.
- [ ] **Step 2: Update check** (spec §12): for matching record entries only, two `latestVersionsForHashes:` calls (release-installed with `@[@"release"]`, the rest with nil); result whose `id` ≠ entry `versionId` → `availableUpdates`. Row subtitle `"old → new"` and an Update tag (tap = update that mod).
- [ ] **Step 3: Banners** in the table header: mismatched non-empty → `mods.banner.mismatch` ("%d mods don't match Minecraft %@") + `mods.banner.switch_all`; else updates non-empty → `mods.banner.updates` + `mods.banner.update_all`.
- [ ] **Step 4: Update all / Switch all** inside `runOperation:`: each mod is its own resolver plan + install (one failure doesn't stop the others; collect failures and show one summary). Switch all asks `latestVersionsForHashes:` with `@[@"release"]` then nil for the leftovers, per spec; mods with no result keep their flag.
- [ ] **Step 5: Add strings.**
- [ ] **Step 6: Build and check on device**
  - a. Install an older Sodium via the version list → Update tag and banner appear; Update all → newest release installed, banner gone.
  - b. A mod installed as beta gets beta updates; a release-installed mod is never offered a beta.
  - c. Change the profile from Fabric 1.21.1 to Fabric 1.21.4 (version installed) → mismatch banner; Switch all → matching versions installed; a mod without a 1.21.4 build stays flagged "No 1.21.4 version yet" and enabled.
  - d. Offline → no banner, no tags, list still shows names/icons.
- [ ] **Step 7: Commit** `feat(mods): update checks and version-change re-matching`.
