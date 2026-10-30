# Per-profile resource packs and shader packs

Date: 2026-10-29
Status: Approved design, pending implementation plan

## Goal

Bring the launcher closer to its desktop counterparts (Prism Launcher, Modrinth
App): from a profile, you can browse Modrinth for **resource packs** and
**shader packs**, install one with one tap, turn packs on and off, update them,
change their version, and remove them. Everything is scoped to the profile.

The user has not used packs on iPhone yet. The point is parity with desktop
launchers, so success means a desktop launcher user finds packs where they
expect them and they behave the way they expect.

This builds on the per-profile mod manager
(`docs/superpowers/specs/2026-10-29-mod-manager-design.md`, code in
`Natives/mods/`). Read that design first. Unless this document says otherwise,
packs behave exactly like mods there.

### Non-goals (for this version)

- Data packs. They belong to individual worlds, so they need a world list first.
- CurseForge. Modrinth only, as for mods.
- Choosing which packs are active in the game. The player still picks packs in
  Minecraft's Resource Packs menu, or in Iris's / OptiFine's Shader Packs menu.
- Checking whether a shader pack can run. **Decided by the user:** no check for
  Iris, OptiFine or a capable renderer, and no warning. Shader packs can be
  added to any profile, vanilla included, just as Prism allows.
- Dependencies between packs. Packs almost never declare them, so packs skip
  the dependency step. *(My call.)*

### Anti-goals (would be a failure even if it "works")

- Editing the game's own settings. The launcher must not write `options.txt`'s
  `resourcePacks` list or Iris's / OptiFine's shader settings.
- Installing a pack version made for a different Minecraft version than the
  profile's.
- Leaving a half-installed state, such as a partial `.zip`, or a replaced pack
  whose old file is gone before the new one is verified.
- Packs from one profile showing up in another profile.
- Silently changing or losing the user's existing files.
- Blocking the main thread on network or disk work.
- Breaking the existing Mods screen or the records it already keeps.

## Background

- Minecraft reads resource packs from `<game folder>/resourcepacks/`. It loads
  `*.zip` files and folders that contain `pack.mcmeta`. A file whose name does
  not end in `.zip` is ignored, so `X.zip.disabled` is hidden from the game.
- Iris and OptiFine read shader packs from `<game folder>/shaderpacks/`. They
  load `*.zip` files and folders. As with resource packs, `X.zip.disabled` is
  ignored.
- Each Minecraft version expects a particular resource pack format. A pack made
  for another version is flagged in the game and may partly fail, so packs are
  version-specific, like mods.
- Modrinth calls these project types `resourcepack` and `shader`.
  - Resource pack versions list the loader `minecraft`.
  - Shader versions list `iris`, `optifine`, `canvas` or `vanilla`. Only
    `iris` and `optifine` shaders go in `shaderpacks/`. `vanilla` (core
    shader) and `canvas` shaders are installed differently (as resource packs,
    and Canvas needs its own mod). **My call:** they are not offered on either
    screen in this version.
- The mod manager already has every piece this needs, but written for jars in
  `mods/`:
  - `ModFolder`: scan, enable or disable by adding `.disabled`, delete, import,
    hashing, and giving a profile its own folder.
  - `ModIndex`: the per-folder record, `.amethyst-mods.json`.
  - `ModVersionSelector`, `ModInstaller` (download as `.part`, verify the hash,
    then swap in), `ModrinthModsAPI`, `ModFetchCache`.
  - `ModsViewController`, `ModBrowseViewController`, `ModDetailViewController`.
  - Host tests run with `make test_mods`.

  `ModInstaller` and `ModFolder` currently require `.jar` names, and the
  screens assume mods. The builder decides how to generalise them (see "Left to
  the builder"). The mod paths must keep working exactly as they do today.

## Design

### 1. Entry points (decided by the user: one row per kind)

The profile editor (`LauncherProfileEditorViewController`) gets two new rows
directly below **Mods**:

- **Resource Packs**, which opens the Resource Packs screen.
- **Shader Packs**, which opens the Shader Packs screen.

They behave exactly like the Mods row:

- Disabled until a new profile has been saved.
- The same save-first prompt when the editor has unsaved name, version or
  Game directory changes.
- The same `gameDirChanged` handling, so the editor's Game directory field
  shows a folder move done by §2.

**My call:** all three rows (Mods, Resource Packs, Shader Packs) show how many
items are installed as the row's detail text (enabled and disabled together).
The count comes from scanning the folder off the main thread when the editor
appears. It shows nothing while unknown, or when the profile still uses the
shared folder.

### 2. Every profile gets its own folder (decided by the user)

Packs are version-specific, so they must not be shared between profiles. When
the Resource Packs or Shader Packs screen opens on a profile whose `gameDir`
is the shared folder, the profile is moved to its own folder exactly as the
Mods screen does today. This uses `ModFolder migrateProfileNamed:` with the
same naming, the same `options.txt` copy, the same alert, and nothing moved
out of the shared folder.

Unlike Mods, this happens for **every** profile, including vanilla ones. The
screen ensures its own subfolder (`resourcepacks/` or `shaderpacks/`) exists.
Whether the move also creates an empty `mods/` folder for a vanilla profile is
the builder's call; it is harmless either way.

### 3. Minecraft version

Use `ModProfileInfo`'s `minecraftVersion`. The loader does not matter for packs.

- `latest-release` / `latest-snapshot`: today `ModProfileInfo` gives no
  Minecraft version for these. **My call:** resolve them from
  `internal.latest_version.release` / `.snapshot`. The launcher saves these
  from the version manifest (`LauncherNavigationController.m`), and
  `MinecraftResourceDownloadTask` already reads them at launch.
- If the version is still unknown (no saved latest version yet, or a version
  JSON `ModProfileInfo` cannot read), the screen shows only an empty state
  asking the user to set a specific version for this profile, modelled on the
  Mods screen's `mods.empty.unknown_version`. **My call:** the version check
  comes **before** the folder move in §2, as it does on the Mods screen. A
  profile is never moved to its own folder unless it can then actually manage
  packs.

### 4. The two screens

Each screen is the Installed Mods screen
(`docs/superpowers/specs/2026-10-29-mod-manager-design.md` §4) applied to its
folder, with these differences:

- **Title:** "Resource Packs" or "Shader Packs".
- **Header line:** count and Minecraft version, e.g. "3 resource packs ·
  1.21.1". No loader.
- **Files listed:** `*.zip` and `*.zip.disabled`. The record file and `*.part`
  files are not listed, and stray `*.part` files are cleaned up as for mods.
- **Rows:** icon, name, installed version (or "old → new"), **Update** tag,
  and the on/off switch.
  - Off renames to `.zip.disabled`; on renames back. Disabled rows are dimmed.
    **Decided by the user:** the switch only hides or shows the file from the
    game, like Prism. It never selects the pack in the game.
- **Folder packs** (unzipped folders): listed with "Folder" as their subtitle.
  They have no switch, because renaming a folder does not hide it from the
  game. They can be deleted with the swipe action. They get no updates. *(My
  call.)*
- **Swipe actions:** **Delete**, and for Modrinth packs **Change version**,
  as for mods. There is no "required by" warning, because packs have no
  dependencies.
- **Identification:** packs added by hand are looked up on Modrinth by SHA-1,
  as mods are. Unrecognised ones show "Added manually" and can be switched and
  deleted. **My call:** they show the file name without `.zip`. Reading
  `pack.mcmeta` for a nicer name is optional.
- **Updates:** an "N updates available — Update all" banner and per-row
  **Update**, using the same release-type rule as mods.
- **Version change:** when the profile's Minecraft version no longer matches
  a pack's recorded game versions, the pack is flagged and a "Switch all"
  banner re-matches it, as the Mods screen does for mods.
- **Import:** the import button opens the Files picker for `.zip` files. It
  uses the same name-clash handling as mod import (replace, keep both, cancel).
- **No iOS warning list.** The mods' `ios_mod_warnings.plist` does not apply
  here.
- **One operation at a time**, and back navigation is locked while one runs,
  as on the Mods screen.

### 5. Browse

**+** opens Modrinth search for the screen's kind, filtered to the profile's
Minecraft version:

- Resource packs: facets `[["project_type:resourcepack"],
  ["versions:<mc>"]]`.
- Shader packs: facets `[["project_type:shader"],
  ["categories:iris","categories:optifine"], ["versions:<mc>"]]`.

Everything else is as in mod Browse:

- A fixed chip, "Resource packs · 1.21.1" or "Shaders · 1.21.1".
- Debounced search. An empty query lists the most downloaded.
- Infinite scroll.
- An **Installed** tag on rows already installed.

There is no **iOS?** tag.

### 6. Detail page

The mod detail page, without the "required mods" line. It shows:

- The **Install / Installed / Update to** button for the best version.
- "Other versions for <mc>": newest first, tagged Release / Beta / Alpha, and
  tap one to install it.
- "View on Modrinth".

### 7. Picking the version and file

- Resource packs: `GET /project/{id}/version` with `loaders=["minecraft"]` and
  `game_versions=[mc]`.
- Shader packs: the same request with `loaders=["iris","optifine"]`.
- The best version and the file are chosen as for mods (newest release, then
  beta, then alpha; the primary file, else the first). The file name must end
  in `.zip`, case-insensitive. Otherwise the install fails before anything is
  downloaded, with a message saying the pack's file is not a `.zip`.
- If no version fits, the detail page says so and offers no install.

### 8. Installing

Install exactly as `ModInstaller` does, for one version, without a dependency
plan:

- Download beside the final name as `.part`, verify the SHA-1 or SHA-512, then
  replace the file recorded for the same project.
- **Decided by the user:** the new file takes Modrinth's file name, as mods
  do and as Prism does. The old file name is not kept. Minecraft, Iris and
  OptiFine remember the selected pack by file name, so an updated or
  re-versioned pack is no longer selected in the game until the player picks
  it again. This is accepted. **My call:** no extra message about it.
- A replaced pack that was disabled stays disabled.
- Update the folder's record.
- On any failure, the folder and record are left as they were.

The record lives in the pack folder itself (one record per folder) and keeps
the same entry fields as mods (projectId, versionId, title, versionNumber,
versionType, iconUrl, sha1, gameVersions, loaders).

### 9. Strings

All new user-facing text goes through `localize(@"key", nil)`, with English
added to `Natives/resources/en.lproj/Localizable.strings`. Crowdin supplies the
other languages. Reuse the existing `mods.*` strings wherever the wording is
identical, and add new keys where it says "mod".

## Left to the builder

- How to generalise the mod code. For example, `ModFolder` and `ModInstaller`
  could take an allowed extension, and `ModsViewController` could take a
  content-kind description (title, folder name, project type, loaders,
  whether to resolve dependencies and show iOS warnings), or the shared parts
  could be split out. Constraints:
  - The Mods screen's behaviour and its existing `.amethyst-mods.json` records
    must keep working unchanged.
  - The pure, Foundation-only pieces stay host-testable.
  - New behaviour (`.zip` handling, folder packs being skipped by the switch,
    the shader loaders, the version-only matching) gets host tests under
    `Natives/tests/mods`, run with `make test_mods`.
- The record file's name inside pack folders. Reusing `.amethyst-mods.json` is
  fine. If it is renamed, the mods folder's existing file must still be read.
- Icons for the two new editor rows. Suggested SF Symbols:
  `photo.on.rectangle` for resource packs and `sparkles` for shader packs.
- The exact empty-state wording, and whether the count in the editor rows is
  fetched once or refreshed after returning from a screen. It should be
  refreshed if that is cheap.

## Verification

This Windows machine has no iOS toolchain. The user builds on a Mac and tests
on a device.

- `make test_mods` must pass on the Mac.
- Check by hand on a device:
  - Install a resource pack and a shader pack on a Fabric profile with Iris,
    and confirm both appear in the game's menus.
  - Install a resource pack on a vanilla profile that used the shared folder:
    the folder-move alert appears, and the pack shows only in that profile.
  - Turn a pack off and confirm it disappears from the game's menu.
  - Update a pack and change a pack's version.
  - Change a profile's Minecraft version, then use **Switch all**.
  - Import a `.zip` from Files.
  - Confirm the Mods screen still works as before.
