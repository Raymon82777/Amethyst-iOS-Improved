# Per-profile Resource Packs and Shader Packs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Resource Packs and Shader Packs screens to each profile. They browse Modrinth, install the version for the profile's Minecraft version, turn packs on and off, update them, change their version, and delete them, all by reusing the mod manager.

**Architecture:**
- A new Foundation-only `ModContentKind` describes each kind of content: mods, resource packs and shader packs. It records the folder, file extension, Modrinth project type and loaders, and whether dependencies, loaders and iOS warnings apply.
- `ModFolder` and `ModInstaller` take a kind instead of assuming `.jar`.
- `ModsViewController` takes a kind and exposes the loaders, game version and display names that the browse and detail pages use instead of reading `ModProfileInfo` directly.
- The profile editor gets two new rows, and all three content rows show item counts.
- The class names keep their `Mod` prefix, so the mod code doesn't need renaming.

**Tech Stack:** Objective-C (ARC), Foundation, UIKit, AFNetworking (already vendored), Modrinth API v2, host tests via `make test_mods`.

**Spec:** `docs/superpowers/specs/2026-10-29-resource-shader-packs-design.md`. It builds on `docs/superpowers/specs/2026-10-29-mod-manager-design.md` and `docs/superpowers/plans/2026-10-29-mod-manager.md`. Read the spec; this plan doesn't repeat its reasoning.

## Global Constraints

- Folders: `mods/` (`.jar`), `resourcepacks/` (`.zip`), `shaderpacks/` (`.zip`), all inside the profile's game folder.
- Disable means renaming `X.zip` to `X.zip.disabled`, and enable is the reverse. Folder packs are never renamed.
- Modrinth project types: `mod`, `resourcepack`, `shader`.
- Version loaders:
  - mods: the profile's accepted loaders (unchanged).
  - resource packs: `["minecraft"]`.
  - shader packs: `["iris","optifine"]`.
- Game versions matched: exactly `[mc]`.
- Search facets:
  - resource packs: `[["project_type:resourcepack"],["versions:<mc>"]]`.
  - shader packs: `[["project_type:shader"],["categories:iris","categories:optifine"],["versions:<mc>"]]`.
  - Packs have no `client_side` facet. Mod search is unchanged.
- Best version and file: the same rule as mods.
- An update takes Modrinth's file name, as for mods. The old name is not kept.
- Packs never resolve dependencies. Even when a pack's version lists a required dependency, the plan is that one version.
- Every profile, vanilla included, is moved to its own folder when a pack screen opens. The move only happens after the Minecraft version is known.
- `latest-release` / `latest-snapshot` resolve to `getPrefObject(@"internal.latest_version.release")` / `@"internal.latest_version.snapshot"`.
- The launcher never writes `options.txt`'s `resourcePacks` or any Iris/OptiFine config.
- The per-folder record is `.amethyst-mods.json` (`ModIndexFileName`) in each folder, including pack folders.
- The mod paths must behave exactly as before, and all existing `make test_mods` tests must still pass unchanged.
- Host-tested files import only Foundation/CommonCrypto: add `ModContentKind` to that list next to `ModFolder`, `ModInstaller`, `ModDependencyResolver`, etc.
- Every new `.m` that ships goes into `add_executable(AngelAuraAmethyst …)` in `Natives/CMakeLists.txt`. Every new host-tested `.m` also goes into the `test_mods` compile line in the `Makefile`.
- User-facing text goes through `localize(…)`, with English in `Natives/resources/en.lproj/Localizable.strings`. Existing `mods.*` keys and texts are unchanged.
- This Windows host has no iOS toolchain. Builds, `make test_mods` and device checks run on the user's Mac.

## Review Focus

1. **A Modrinth pack whose primary file isn't a `.zip`.** The install is refused before anything is downloaded, with a message naming the file (Task 3, test `testPackInstallRefusesNonZipFile`).
2. **Uppercase `.ZIP` names, from Modrinth or from Files.** They are saved with a lowercase `.zip`, so they are listed (Task 3, test `testPackInstallLowercasesZipExtension`; Task 5, check c).
3. **Stray items in `resourcepacks/`** (`README.txt`, `.DS_Store`, hidden folders, a leftover `*.part`). Text and hidden items aren't listed, and `*.part` files are removed. A visible folder is listed as a folder pack (Task 2, test `testPackScanListsZipsAndFoldersOnly`).
4. **A resource pack whose Modrinth version requires a mod.** It still installs as just the pack, with no "missing dependency" failure (Task 3, test `testSingleVersionPlanIgnoresDependencies`).
5. **A vanilla profile on the shared folder set to `latest-release` before the launcher has ever fetched the version list.** The screen shows the unknown-version message and does not move the profile (Task 5, check f).

---

### Task 1: Content kinds

**Files:**
- Create: `Natives/mods/ModContentKind.h`, `Natives/mods/ModContentKind.m`
- Create: `Natives/tests/mods/ModContentKindTests.m`
- Modify: `Natives/tests/mods/ModTestMain.m` (call `ModContentKindTests()`), `Makefile` (`test_mods` compiles `ModContentKind.m`), `Natives/CMakeLists.txt` (add `mods/ModContentKind.m`)

**Interfaces:**
- Produces:
  ```objc
  typedef NS_ENUM(NSInteger, ModContentType) { ModContentTypeMods, ModContentTypeResourcePacks, ModContentTypeShaderPacks };
  @interface ModContentKind : NSObject
  + (instancetype)mods;
  + (instancetype)resourcePacks;
  + (instancetype)shaderPacks;
  @property(nonatomic, readonly) ModContentType type;
  @property(nonatomic, readonly) NSString *folderName;      // @"mods" @"resourcepacks" @"shaderpacks"
  @property(nonatomic, readonly) NSString *fileExtension;   // @"jar" @"zip" @"zip" (lowercase, no dot)
  @property(nonatomic, readonly) NSString *projectType;     // @"mod" @"resourcepack" @"shader"
  @property(nonatomic, readonly) NSString *stringPrefix;    // @"mods" @"resourcepacks" @"shaderpacks"
  @property(nonatomic, readonly) BOOL listsFolders;         // NO YES YES
  @property(nonatomic, readonly) BOOL isMods;               // YES NO NO: needs a loader, resolves dependencies,
                                                            // uses the client_side facet, iOS warnings, jar metadata
  /* Loaders for version requests and matching: mods → `profileLoaders`; packs → their fixed list. */
  - (NSArray<NSString *> *)loadersForProfileLoaders:(NSArray<NSString *> *)profileLoaders;
  /* Loaders for search's `categories:` facet: mods → `profileLoaders`; resource packs → @[]; shaders → @[@"iris", @"optifine"]. */
  - (NSArray<NSString *> *)searchCategoriesForProfileLoaders:(NSArray<NSString *> *)profileLoaders;
  /* "<stringPrefix>.<suffix>", e.g. [ModContentKind.resourcePacks stringKey:@"title"] → @"resourcepacks.title". */
  - (NSString *)stringKey:(NSString *)suffix;
  @end
  ```
  The three class methods return shared instances.

- [ ] **Step 1: Write the failing tests** in `ModContentKindTests.m`, exposing `void ModContentKindTests(void)`:
  - `testModsKindKeepsProfileLoaders`: `[ModContentKind.mods loadersForProfileLoaders:@[@"quilt",@"fabric"]]` equals `@[@"quilt",@"fabric"]`; `folderName` `@"mods"`; `fileExtension` `@"jar"`; `isMods` YES; `listsFolders` NO; `[ModContentKind.mods stringKey:@"title"]` equals `@"mods.title"`.
  - `testResourcePackKindUsesMinecraftLoader`: loaders for `@[@"fabric"]` and for `@[]` both equal `@[@"minecraft"]`; search categories `@[]`; `projectType` `@"resourcepack"`; `folderName` `@"resourcepacks"`; `fileExtension` `@"zip"`; `listsFolders` YES; `isMods` NO.
  - `testShaderKindUsesIrisAndOptifine`: loaders and search categories both equal `@[@"iris",@"optifine"]` for any input; `projectType` `@"shader"`; `folderName` `@"shaderpacks"`; `stringKey:@"title"` equals `@"shaderpacks.title"`.
- [ ] **Step 2: Run the tests and confirm they fail to build.** Run `make test_mods` on the Mac. Expected: a compile error, because `ModContentKind.h` isn't found yet.
- [ ] **Step 3: Implement `ModContentKind`.** Write it as an immutable value object, Foundation only.
- [ ] **Step 4: Run the tests and confirm they pass.** Run `make test_mods`. Expected: all tests pass, old and new, and the exit code is 0.
- [ ] **Step 5: Commit** with the message `feat(packs): describe mods, resource packs and shader packs as content kinds`.

### Task 2: Kind-aware folder scan and counts

**Files:**
- Modify: `Natives/mods/ModFolder.h`, `Natives/mods/ModFolder.m`
- Test: `Natives/tests/mods/ModFolderTests.m`

**Interfaces:**
- Consumes: `ModContentKind` (Task 1).
- Produces:
  ```objc
  @interface ModJar (unchanged fields) …
  @property(nonatomic) BOOL isDirectory;   // a folder pack: never switched, never hashed
  @end
  @interface ModFolder
  - (instancetype)initWithModsDir:(NSString *)modsDir kind:(ModContentKind *)kind;  // creates the folder
  - (instancetype)initWithModsDir:(NSString *)modsDir;   // = kind ModContentKind.mods (unchanged behaviour)
  @property(nonatomic, readonly) ModContentKind *kind;
  /* Number of items scanJars would list, without creating the folder or deleting anything; 0 if missing. */
  + (NSUInteger)countItemsInDir:(NSString *)dir kind:(ModContentKind *)kind;
  @end
  ```
- Behaviour changes, for kinds other than mods only:
  - `scanJars` lists `*.<ext>` / `*.<ext>.disabled` regular files.
  - When `kind.listsFolders` is set, it also lists visible folders whose names don't start with `.`, with `isDirectory = YES`, `enabled = YES`, and `fileName` set to the folder name.
  - The suffix match on file names stays case-sensitive, as it is today. Uppercase names are lowercased on the way in, during install and import.
  - `setJar:enabled:error:` on a directory fails with `ModFolderErrorExists`. That never happens in the UI, because folder rows have no switch.
  - `deleteJar:` removes folders too.
  - `importJarFromURL:…` refuses a name that doesn't end in `.<kind.fileExtension>`.
  - `uniqueFileNameFor:` keeps the kind's extension.

- [ ] **Step 1: Write the failing tests:**
  - `testPackScanListsZipsAndFoldersOnly`:
    - Setup: a dir with `a.zip`, `b.zip.disabled`, `c.jar`, `README.txt`, `.DS_Store`, `x.zip.part`, folder `Faithful`, folder `.hidden`, and `ModIndexFileName`.
    - With the `resourcePacks` kind, the scan gives 3 items in this order: `a.zip` (enabled), `b.zip` (disabled), `Faithful` (`isDirectory` YES).
    - `x.zip.part` is deleted.
  - `testModScanUnchangedIgnoresFoldersAndZips`: the same dir scanned with `initWithModsDir:` lists only `c.jar`.
  - `testCountItemsDoesNotCreateOrDelete`:
    - `countItemsInDir:` on a missing dir returns 0, and the dir still doesn't exist afterwards.
    - On the dir above (re-created, with `x.zip.part`) it returns 3, and `x.zip.part` still exists.
  - `testPackImportRequiresZip`:
    - Importing `pack.jar` into a resource-pack folder fails, and nothing is written.
    - `pack.zip` succeeds and returns `@"pack.zip"`.
  - `testDeleteFolderPack`: `deleteJar:` on the `Faithful` item removes the folder.
- [ ] **Step 2: Run the tests and confirm they fail.** Run `make test_mods`. Expected: the new tests fail, either on the missing selector `initWithModsDir:kind:` or on their assertions.
- [ ] **Step 3: Implement the interface above in `ModFolder.m`.** Replace the hard-coded `@".jar"` with `kind.fileExtension` (adding the dot), and add the folder branch gated on `kind.listsFolders`.
- [ ] **Step 4: Run the tests and confirm they pass.** Run `make test_mods`. Expected: all tests pass.
- [ ] **Step 5: Commit** with the message `feat(packs): scan, import and count zip and folder packs`.

### Task 3: Installing packs (zip names, no dependencies)

**Files:**
- Modify: `Natives/mods/ModInstaller.h`, `Natives/mods/ModInstaller.m`, `Natives/mods/ModDependencyResolver.h`, `Natives/mods/ModDependencyResolver.m`
- Test: `Natives/tests/mods/ModInstallerTests.m`, `Natives/tests/mods/ModDependencyResolverTests.m`

**Interfaces:**
- Consumes: `ModContentKind` (Task 1).
- Produces:
  ```objc
  // ModInstaller
  - (instancetype)initWithIndex:(ModIndex *)index downloader:(ModDownloader)downloader kind:(ModContentKind *)kind;
  - (instancetype)initWithIndex:(ModIndex *)index downloader:(ModDownloader)downloader; // kind = mods
  // ModDependencyResolver.h
  @interface ModInstallPlan (Single)
  /* versionsToInstall = @[version]; every other list empty. For kinds that don't resolve dependencies. */
  + (instancetype)planForSingleVersion:(NSDictionary *)version;
  @end
  ```
- Rules:
  - `InstallFileName` takes the extension. A name must end in `.<ext>` (in any case) and is saved with a lowercase `.<ext>`. The reserved names are unchanged.
  - When the name doesn't end in `.<ext>`, the error is `ModInstallErrorFileSystem` with `userInfo[@"fileName"]` set and the description `"<name> is not a .<ext> file."`. This happens before anything is downloaded.

- [ ] **Step 1: Write the failing tests**, using the existing fake downloader in `ModInstallerTests.m`:
  - `testPackInstallLowercasesZipExtension`: the version file name is `Faithful-32x.ZIP`, with the `resourcePacks` kind. After install, `Faithful-32x.zip` exists, and the record has the key `@"Faithful-32x.zip"`.
  - `testPackInstallRefusesNonZipFile`: the file is `pack.jar`, with the `resourcePacks` kind.
    - The error domain is `ModInstallErrorDomain` and the code is `ModInstallErrorFileSystem`.
    - The fake downloader was called 0 times.
    - The folder is unchanged.
  - `testPackUpdateTakesNewFileName`:
    - Setup: `old-v1.zip` is installed and recorded for project `P`.
    - Installing a plan with `new-v2.zip` for `P` leaves `new-v2.zip` in the folder and no `old-v1.zip`.
    - The record key is `new-v2.zip`.
    - If `old-v1.zip` had been `.disabled`, the result is `new-v2.zip.disabled`.
  - `testSingleVersionPlanIgnoresDependencies` (in `ModDependencyResolverTests.m`):
    - Input: a version with `dependencies` `@[@{@"project_id": @"MOD", @"dependency_type": @"required"}]`.
    - `[ModInstallPlan planForSingleVersion:v]` has `versionsToInstall` equal to `@[v]`.
    - `projectIdsToEnable`, `incompatibleInstalledProjectIds` and `optionalProjectIds` are all empty.
- [ ] **Step 2: Run the tests and confirm they fail.** Run `make test_mods`. Expected: the new tests fail, while the existing installer and resolver tests still pass.
- [ ] **Step 3: Implement the two interfaces above.** Keep the old `initWithIndex:downloader:` as a wrapper that passes the mods kind.
- [ ] **Step 4: Run the tests and confirm they pass.** Run `make test_mods`. Expected: all tests pass.
- [ ] **Step 5: Commit** with the message `feat(packs): install zip packs as single versions`.

### Task 4: Modrinth search and install flow by kind

**Files:**
- Modify: `Natives/mods/ModrinthModsAPI.h`, `Natives/mods/ModrinthModsAPI.m`, `Natives/mods/ModInstallFlow.h`, `Natives/mods/ModInstallFlow.m`

**Interfaces:**
- Consumes: `ModContentKind`, `+[ModInstallPlan planForSingleVersion:]`, `-[ModInstaller initWithIndex:downloader:kind:]`.
- Produces:
  ```objc
  // ModrinthModsAPI — the old searchMods:loaders:gameVersion:previous: becomes a wrapper passing the mods kind
  - (nullable NSMutableArray<NSDictionary *> *)searchProjects:(NSString *)query
                                                         kind:(ModContentKind *)kind
                                               profileLoaders:(NSArray<NSString *> *)profileLoaders
                                                  gameVersion:(NSString *)mc
                                                     previous:(nullable NSMutableArray *)previous;
  // ModInstallFlow — the old initializer becomes a wrapper passing the mods kind
  - (instancetype)initWithKind:(ModContentKind *)kind loaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc
                   profileName:(NSString *)profileName fetchCache:(ModFetchCache *)fetchCache;
  @property(nonatomic, readonly) ModContentKind *kind;
  /* kind.isMods → the resolver's plan (unchanged behaviour); otherwise +planForSingleVersion: (never fails).
     Blocking. Replaces direct resolverWithInstalledProjects:/planForVersion: calls in the UI. */
  - (nullable ModInstallPlan *)planForVersion:(NSDictionary *)version
                            installedProjects:(NSDictionary<NSString *, NSNumber *> *)installed
                                          api:(ModrinthModsAPI *)api error:(NSError **)error;
  ```
- Search builds facets as described in Global Constraints:
  - `project_type:<kind.projectType>`.
  - A `categories:` group from `searchCategoriesForProfileLoaders:`, only when that list isn't empty.
  - `versions:<mc>`.
  - The `client_side` group only when `kind.isMods`.
- `installVersion:…` uses `planForVersion:installedProjects:api:error:` and creates its `ModInstaller` with `self.kind`.

- [ ] **Step 1: Implement both interfaces.** These classes aren't host-tested, because they depend on AFNetworking and `localize`.
- [ ] **Step 2: Check that the mod paths call the same code as before.** Run `git diff` and confirm that, for `ModContentKind.mods`, the facets, the resolver call and `installVersion:` behave exactly as before.
- [ ] **Step 3: Commit** with the message `feat(packs): search and install by content kind`.

### Task 5: Pack screens (installed list, browse, detail)

**Files:**
- Modify: `Natives/mods/ModsViewController.h`, `Natives/mods/ModsViewController.m`, `Natives/mods/ModBrowseViewController.m`, `Natives/mods/ModDetailViewController.m`, `Natives/resources/en.lproj/Localizable.strings`

**Interfaces:**
- Consumes: Tasks 1–4.
- Produces (on `ModsViewController`):
  ```objc
  - (instancetype)initWithProfileName:(NSString *)profileName kind:(ModContentKind *)kind;
  - (instancetype)initWithProfileName:(NSString *)profileName;   // kind = mods
  @property(nonatomic, readonly) ModContentKind *kind;
  @property(nonatomic, readonly) NSArray<NSString *> *loaders;       // [kind loadersForProfileLoaders:info.acceptedLoaders]
  @property(nonatomic, readonly) NSString *gameVersion;              // resolved Minecraft version, @"" if unknown
  @property(nonatomic, readonly) NSString *profileDisplayName;       // mods: info.displayName; packs: "Minecraft 1.21.1"
  @property(nonatomic, readonly) NSString *filterChipText;           // mods: info.displayName; packs: "Resource packs · 1.21.1"
  ```
- Every `info.acceptedLoaders`, `info.minecraftVersion` and `info.displayName` read in these three files becomes `loaders`, `gameVersion` or `profileDisplayName`. The browse chip uses `filterChipText`. Every `ModInstallFlow` is made with `initWithKind:…`, and every dry-run or install plan comes from `planForVersion:installedProjects:api:error:`.
- Browse calls `searchProjects:kind:profileLoaders:gameVersion:previous:` with `kind:self.mods.kind` and `profileLoaders:self.mods.loaders`. For packs, the kind ignores the loaders it's given, so this is the same as passing the profile's own loaders.
- `gameVersion`:
  - If `info.minecraftVersion` is set, use it.
  - Otherwise, when `lastVersionId` is `latest-release` or `latest-snapshot`, use the matching `internal.latest_version.*` pref, if it is a non-empty string.
  - Otherwise use `@""`.
- `prepareFolder`, in this order:
  1. `kind.isMods` and not modded: the vanilla message (unchanged).
  2. `gameVersion` is empty: `[kind stringKey:@"empty.unknown_version"]`, with no move.
  3. Shared folder: migrate (unchanged code).
  4. Folder `<game dir>/<kind.folderName>`, opened with `initWithModsDir:kind:`.
- Strings: every place that has a key in the table below uses `localize([self.kind stringKey:@"<suffix>"], nil)`. All other strings keep their `mods.*` keys.
- Behaviour that applies only to packs (`!kind.isMods`):
  - **Row titles:** the record title; otherwise the file name without `.zip`. Jar metadata is never read.
  - **Folder rows** (`jar.isDirectory`): subtitle `localize(@"packs.row.folder", nil)`, no switch, not tappable, swipe offers only Delete. They are never hashed, identified or update-checked.
  - **Import:** the picker type is `[UTType typeWithFilenameExtension:@"zip"]` (fallback `UTTypeData`). The extension check and the lowercasing use `kind.fileExtension`.
  - **Not shown for packs:** the iOS tag in Browse, the iOS warning note and alert on Detail, and the "needed by" delete confirmation.
- Strings to add to `Localizable.strings`. Mods keep their existing keys.
  ```
  "packs.row.folder" = "Folder";
  "packs.profile_name" = "Minecraft %@";
  "resourcepacks.chip" = "Resource packs · %@";          "shaderpacks.chip" = "Shaders · %@";
  "resourcepacks.title" = "Resource Packs";               "shaderpacks.title" = "Shader Packs";
  "resourcepacks.header.count.one" = "1 resource pack";   "shaderpacks.header.count.one" = "1 shader pack";
  "resourcepacks.header.count.other" = "%d resource packs"; "shaderpacks.header.count.other" = "%d shader packs";
  "resourcepacks.empty.none" = "No resource packs in this profile yet. Add some with + or import .zip files with the folder button.";
  "shaderpacks.empty.none" = "No shader packs in this profile yet. Add some with + or import .zip files with the folder button.";
  "resourcepacks.empty.unknown_version" = "Couldn't tell which Minecraft version this profile uses. Set a specific version for it in Edit profile.";
  "shaderpacks.empty.unknown_version" = (same text);
  "resourcepacks.alert.own_folder" = "This profile now has its own game folder, so its resource packs are kept apart from other profiles. Worlds, resource packs and mods in the shared folder stay where they are.";
  "shaderpacks.alert.own_folder" = (same, "shader packs" for the first "resource packs");
  "resourcepacks.alert.save_first" = "Save your changes to this profile before managing its resource packs?";  (shader: "shader packs")
  "resourcepacks.import.exists" = "A resource pack with this file name is already in this profile.";      (shader: "shader pack")
  "resourcepacks.import.not_jar" = "Only .zip files can be added as resource packs.";                     (shader: "shader packs")
  "resourcepacks.action.add" = "Add resource packs";       "shaderpacks.action.add" = "Add shader packs";
  "resourcepacks.browse.title" = "Add Resource Packs";     "shaderpacks.browse.title" = "Add Shader Packs";
  "resourcepacks.browse.empty" = "No resource packs found for %@.";   (shader: "shader packs")
  "resourcepacks.detail.no_version" = "No version of this resource pack works with %@.";   (shader: "shader pack")
  "resourcepacks.banner.mismatch.one" = "1 resource pack doesn't match Minecraft %@";      (shader: "shader pack")
  "resourcepacks.banner.mismatch.other" = "%1$d resource packs don't match Minecraft %2$@"; (shader: "shader packs")
  "resourcepacks.error.update_failed" = "Not every resource pack could be updated:\n\n%@"; (shader: "shader pack")
  "resourcepacks.error.switch_failed" = "Not every resource pack could be switched:\n\n%@"; (shader: "shader pack")
  ```
  Mods use their existing `mods.<suffix>` keys for the same suffixes. Write each `(shader: …)` line out in full as its own `shaderpacks.<suffix>` entry.
  - `mods.alert.save_first` is used by the profile editor (Task 6).
  - The suffix `import.not_jar` is kept for all kinds, so the existing mods key doesn't change.

- [ ] **Step 1: Implement the interface and behaviour above** in the four source files, and add the strings.
- [ ] **Step 2: Statically check for leftover direct reads.** Run `grep -n "info\.acceptedLoaders\|info\.minecraftVersion\|info\.displayName\|resolverWithInstalledProjects\|initWithLoaders" Natives/mods/ModsViewController.m Natives/mods/ModBrowseViewController.m Natives/mods/ModDetailViewController.m`. Expected matches: only the definitions of `loaders`, `gameVersion` and `profileDisplayName` in `ModsViewController.m`, plus the `info.displayName`/`isModded` uses in `prepareFolder` and `headerText`.
- [ ] **Step 3: Device checks.** These run on the Mac and device after Task 6 adds the entry rows. Until then, a temporary push from the Mods screen can stand in, as long as it isn't committed.
  - a. On a Fabric 1.21.1 profile with Iris, install a resource pack and a shader pack. Both appear in the game's menus.
  - b. Turn a pack off. It disappears from the game's menu, and the row is dimmed.
  - c. Import `Test.ZIP` from Files. It's listed as `Test`.
  - d. Update a pack, and change a pack's version. The new file name is used, and a disabled pack stays disabled.
  - e. Change the profile's Minecraft version. The mismatch banner appears, and **Switch all** re-matches.
  - f. Use a vanilla profile on the shared folder set to `latest-release`. First, with the `internal.latest_version` pref removed, the unknown-version message appears and there is no move. Then, after the launcher has fetched versions, the folder-move alert appears and packs work.
  - g. Put an unzipped folder in `resourcepacks/` through Files. It's listed as "Folder", with no switch, and swipe-to-delete removes it.
  - h. The Mods screen, Browse and Detail on a modded profile behave exactly as before. The iOS tags, dependencies and the "needed by" alert are still there.
- [ ] **Step 4: Commit** with the message `feat(packs): resource and shader pack screens`.

### Task 6: Profile editor rows and counts

**Files:**
- Modify: `Natives/LauncherProfileEditorViewController.m`, `Natives/resources/en.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `-[ModsViewController initWithProfileName:kind:]`, `+[ModFolder countItemsInDir:kind:]`, `+[ModFolder gameDirPathForGameDir:baseDir:]`, `+[ModFolder isSharedGameDir:baseDir:]`, `ModContentKind`.
- Changes:
  - **Rows:** right after the `mods` row, add the keys `resourcepacks` (icon `photo.on.rectangle`, title `preference.profile.title.resourcepacks`) and `shaderpacks` (icon `sparkles`, title `preference.profile.title.shaderpacks`). All three rows use `self.typeChildPane`, so each gets a value cell with a chevron, and keep the Mods row's `enableCondition`.
  - **Counts:** `getPreference` returns a count string for these three keys from a `contentCounts` dictionary.
    - It's filled off the main thread in `viewWillAppear:` with `countItemsInDir:` on the **saved** profile's game folder: `GAME_DIR` plus `gameDir`, then `kind.folderName`.
    - A key is left out when the profile is unsaved or uses the shared folder (`isSharedGameDir`).
    - After filling, reload the table on the main queue. A missing key shows an empty detail.
  - **Opening:** `didSelectRowAtIndexPath:` handles all three keys the way it handles `mods` today. `actionOpenMods` becomes `actionOpenContent:(ModContentKind *)kind`.
    - The save-first alert uses `[kind stringKey:@"title"]` as its title (mods keeps `preference.profile.title.mods`) and `[kind stringKey:@"alert.save_first"]` as its message.
    - `pushModsViewController` becomes `pushContentViewController:(ModContentKind *)kind` and keeps the `gameDirChanged` handling.
  - **Strings:** `"preference.profile.title.resourcepacks" = "Resource Packs";` and `"preference.profile.title.shaderpacks" = "Shader Packs";`.

- [ ] **Step 1: Implement the changes above.**
- [ ] **Step 2: Device checks:**
  - a. On a saved profile with its own folder, the three rows show counts that match each screen. Returning from a screen after installing updates the count.
  - b. On a new, unsaved profile, all three rows are disabled.
  - c. On a profile still on the shared folder, the rows show no count. Opening Resource Packs moves the profile to its own folder (alert), and the Game directory field shows the new value.
  - d. With an unsaved version change in the editor, tapping Shader Packs asks to save first ("Save your changes to this profile before managing its shader packs?").
- [ ] **Step 3: Commit** with the message `feat(packs): resource and shader pack rows in the profile editor`.
- [ ] **Step 4: Run the full check on the Mac.** Run `make test_mods`. Expected: all tests pass. Then build the app with the usual `make` and repeat Task 5 checks a–h on the device.
