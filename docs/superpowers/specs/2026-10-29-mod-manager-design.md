# Per-profile mod manager

Date: 2026-10-29
Status: Approved design, pending implementation plan

## Goal

Make adding and managing mods on iOS feel like a desktop launcher (Prism,
Modrinth App): from a profile, you can browse Modrinth, install a mod with one
tap, turn mods on and off, update them, and remove them, all scoped to that
profile. The most important property is that **it always installs a version
that matches the profile's Minecraft version and mod loader**, including the
mods it depends on.

Today the only way to get mods is a full modpack install
(`Natives/installer/ModpackInstallViewController.m`) or copying jars in with
the Files app, with no help picking versions.

### Non-goals (for this version)

- CurseForge. Modrinth only. (`CurseForgeAPI.m` is a stub; CurseForge needs an
  API key.)
- Resource packs, shader packs, data packs, worlds. Planned later; the design
  should not make them harder (same Modrinth API, different `project_type`),
  but nothing is built for them now.
- Profile export/import, profile duplication.
- Installing or changing the mod loader itself. The existing Fabric/Quilt and
  Forge/NeoForge installers stay as they are.

### Anti-goals (would be a failure even if it "works")

- Installing a mod version built for another loader or Minecraft version.
- Leaving a half-installed state: a partial jar, or a mod installed without a
  required dependency.
- Silently changing or losing the user's existing files (worlds, mods already in
  a folder).
- Blocking the main thread on network calls.

## Background: how profiles work today

- Profiles live in `launcher_profiles.json` (`Natives/PLProfiles.m`). Relevant
  keys: `name`, `lastVersionId`, `gameDir`.
- `GAME_DIR` (env var) is a symlink to `AME_HOME/instances/<general.game_directory>`;
  version JSONs live in `GAME_DIR/versions/<id>/<id>.json`.
- A profile's game folder is `GAME_DIR/<gameDir>` standardized
  (`Natives/JavaLauncher.m` ~line 181). `gameDir` defaults to `.`, so **all
  profiles share one game folder and one `mods/` folder by default**. Modpack
  installs already set `gameDir` to `./custom_gamedir/<name>`.
- Modrinth access already exists: `ModpackAPI` / `ModrinthAPI`
  (`Natives/installer/modpack/`), using AFNetworking, with a synchronous
  `getEndpoint:params:` that must be called off the main thread.
- UI is UIKit/Objective-C, grouped `UITableView` screens with SF Symbols.
  Profile settings are edited in `LauncherProfileEditorViewController`.
  Strings go through `localize(@"key", nil)` with
  `Natives/resources/<lang>.lproj/Localizable.strings` (English is the source;
  other languages come from Crowdin).

## Design

### 1. Entry point

A new **Mods** row in the profile editor (`LauncherProfileEditorViewController`),
which pushes the Installed Mods screen for that profile. If the profile has not
been saved yet (brand-new profile), the row is disabled until it is saved.
*(Builder's call: icon, exact placement in the list.)*

The editor edits a copy of the profile and only writes it back on Done. The
Mods screen always works from the **saved** profile. If the editor has unsaved
changes to the name or version, tapping Mods asks the user to save first
(Save / Cancel); Save runs the editor's normal Done-save path, then opens Mods.
Any `gameDir` change made by §2 is written to both the saved profile and the
editor's copy, so a later Close in the editor cannot undo it. *(My call.)*

### 2. Giving the profile its own folder (automatic)

**Decided by the user:** mods are per profile, and a profile that still uses the
shared default folder is moved to its own folder automatically.

When the Mods screen opens for a **modded** profile (not vanilla, see §3) whose
resolved `gameDir` is `.` (or empty, or any value that standardizes to the
instance root):

1. Set `gameDir` to `./custom_gamedir/<profile name>` (file-system-safe version
   of the name; if that folder already exists for any reason, including
   leftovers from a deleted profile or a modpack, append ` (2)`, ` (3)`, … so
   unrelated files are never mixed in). Save the profile. *(My call.)*
2. Create the folder and its `mods/` subfolder.
3. Copy `options.txt` from the instance root into the new folder if the new
   folder has none, so controls and video settings carry over. *(My call.)*
4. Show a one-time alert: the profile now has its own folder; worlds, resource
   packs and mods in the shared folder stay where they are. *(My call.)*

Nothing in the shared folder is moved or deleted. Profiles that already have a
non-default `gameDir` are never touched, even if two profiles happen to share
one. If the profile editor is open, its Game directory field must show the new
value after returning.

### 3. Working out the profile's Minecraft version and loader

Given `lastVersionId`:

- `latest-release` / `latest-snapshot`, or a version with no loader → **vanilla**.
- Otherwise read `GAME_DIR/versions/<id>/<id>.json`:
  - Minecraft version = `inheritsFrom` if present, else `id`.
  - Loader from the `libraries` names:
    `net.fabricmc:fabric-loader` → `fabric`;
    `org.quiltmc:quilt-loader` → `quilt`;
    `net.neoforged:*` (e.g. `neoforge`, `fancymodloader`) → `neoforge`;
    `net.minecraftforge:forge` / `fmlloader` → `forge`.
- If the JSON is missing (version not downloaded yet), fall back to the id
  patterns this launcher creates: `fabric-loader-<loader>-<mc>`,
  `quilt-loader-<loader>-<mc>`, `<mc>-forge-<forge>`, `neoforge-<ver>`
  (NeoForge's Minecraft version is derived from its version number, as
  `ForgeInstallViewController` already does). If still unknown, treat as vanilla.

**Loaders Modrinth should match** for each profile loader (same rules Prism uses):

| Profile loader | Modrinth `loaders` accepted |
|---|---|
| fabric | `fabric` |
| quilt | `quilt`, `fabric` |
| forge | `forge` |
| neoforge | `neoforge`, plus `forge` only when Minecraft is `1.20.1` |

Game versions matched: exactly the profile's Minecraft version.

**Vanilla profiles:** the Mods screen shows an empty state explaining that mods
need Fabric, Quilt, Forge or NeoForge, and that a loader is installed from the
Profiles screen's install menu, after which this profile's Version can be set
to it. No buttons that launch the installers from here: both installers assume
they were presented from the main screen (`ForgeInstallViewController` casts
`presentingViewController` to a split view; the Fabric one opens its own
profile editor). No browsing, and no folder move (§2). *(My call.)*

### 4. Installed Mods screen

**Decided by the user: layout A** — one row per mod with a switch.

- Navigation title "Mods", **+** button opens Browse, plus an import button that
  opens the Files picker for `.jar` files.
- Search field filtering the installed list by name.
- Header line: mod count, loader and loader version, Minecraft version.
- Banner "N updates available — Update all" when updates exist.
- Each row: icon, mod name, installed version (or "old → new" when an update
  exists), an **Update** tag when one exists, and a `UISwitch`.
  - Switch off: rename `<file>.jar` → `<file>.jar.disabled`. Switch on: the
    reverse. Disabled rows are dimmed. (Same convention as Prism; loaders ignore
    `.disabled` files.)
  - Swipe left: **Delete** (no confirmation) and, for Modrinth mods,
    **Change version** (opens the mod's detail page with the installed version
    marked).
  - Tapping a Modrinth mod's row opens its detail page.
- Mods not found on Modrinth show as "Added manually"; they can be switched and
  deleted but get no updates or version changes.
- Sort: alphabetical by display name. *(My call.)*

Mockup: `.superpowers/brainstorm/962-1793253987/content/mods-screens.html`
(option A, plus Browse and Mod detail).

### 5. Browse screen

- Presented from **+**. Search field (debounced, like the modpack screen) over
  Modrinth `search` with facets:
  `[["project_type:mod"], [<"categories:<loader>"> for each accepted loader],
  ["versions:<mc>"], ["client_side:required","client_side:optional"]]`.
  Default order: relevance; empty query shows the most-downloaded matches.
- A fixed, non-editable chip shows the filter, e.g. "Fabric · 1.21.1".
- Rows: icon, title, short description, download count. Already-installed
  projects show an **Installed** tag. Mods on the iOS warning list (§9) show an
  **iOS?** tag.
- Infinite scroll as in the existing modpack list.

### 6. Mod detail page

- Icon, title, author, download count, description.
- Big **Install <version>** button for the best version (§7). If the project is
  already installed, the button reads **Installed** (disabled) or **Update to
  <version>**.
- A line listing required mods: each shown as "already installed ✓" or "will
  also be installed".
- "Other versions for <Loader> <mc>": every compatible version, newest first,
  tagged Release / Beta / Alpha. Tapping one installs that version (replacing
  the installed one if present).
- "View on Modrinth" link.

### 7. Picking the right version

- Fetch `GET /project/{id}/version` with `loaders` = accepted loaders (§3) and
  `game_versions` = `[mc]`.
- Best version = newest `date_published` with `version_type` `release`; if none,
  newest `beta`; if none, newest `alpha` (labelled as such on the button).
- File = the version's file with `primary: true`, else the first file.
- If no compatible version exists, the detail page says so and offers no
  install.

### 8. Dependencies

Resolved before anything is downloaded, as one install "set":

- `required`: if it names a `version_id` and that version supports one of the
  accepted loaders and the profile's Minecraft version, use it; otherwise
  (no pin, or the pin doesn't fit) pick the best version of `project_id` by §7.
  Recurse (track visited projects to avoid cycles). Skip projects already
  installed and enabled in this profile. If a required project is installed
  but **disabled**, the install re-enables it as part of the set and says so.
  *(My call.)*
- If any required dependency has no compatible version: abort the whole set,
  install nothing, and say which dependency is missing.
- `incompatible`: if a listed project is installed, warn before installing
  (user may continue). *(My call: warn, don't block.)*
- `optional`: shown on the detail page as "Works with", not installed.
- `embedded`: ignored.

**Turning off or deleting a mod that others need:** if any other enabled mod's
record lists this project as a required dependency, show a confirmation naming
those mods before disabling or deleting (this overrides "no confirmation" in
§4 for that case only). The record (§11) therefore stores each mod's required
dependency project ids. *(My call.)*

### 9. iOS warnings

A bundled list (e.g. a plist in `Natives/resources`) mapping Modrinth project id
→ short reason. Matching mods get the **iOS?** tag in Browse and a one-line
warning on the detail page / before install. It never blocks installing. The
initial list can be small or empty; it exists so known problem mods (e.g. ones
that bundle native libraries) can be flagged as they're reported. *(My call.)*

### 10. Downloads and file safety

- Download to `mods/<filename>.part`, verify the file's `sha1` (or `sha512`)
  from Modrinth, then rename to `mods/<filename>`. On any failure in a set,
  delete that set's `.part` files and anything already renamed in that set, so
  the folder ends up as it was before.
- Replacing a version (update / change version): new file is fully downloaded
  and verified first; then the old file is removed. A disabled mod stays
  disabled (new file gets `.disabled`).
- One install/update operation at a time per screen; show progress (spinner in
  the nav bar, per-row progress or status). Screen stays usable for viewing.
- Set a Modrinth-friendly `User-Agent` (app name, version, repo URL) on all
  requests. *(My call.)*

### 11. Remembering where mods came from

A small JSON file in the profile's `mods/` folder, e.g.
`mods/.amethyst-mods.json` *(name is the builder's call)*, keyed by jar file
name without `.disabled`:

```json
{
  "formatVersion": 1,
  "mods": {
    "sodium-fabric-0.6.0+mc1.21.1.jar": {
      "projectId": "AANobbMI", "versionId": "...", "slug": "sodium",
      "title": "Sodium", "versionNumber": "0.6.0", "versionType": "release",
      "iconUrl": "https://...", "sha1": "...",
      "requires": ["P7dR8mSH"],
      "gameVersions": ["1.21.1"], "loaders": ["fabric", "quilt"]
    }
  },
  "unknownHashes": ["<sha1 of jars not on Modrinth>"]
}
```

- Written on every install, update, change version, delete and enable/disable
  rename.
- On opening the screen, any jar not in the record (copied in via Files or
  imported) is hashed and looked up in one `POST /version_files` call; matches
  are added to the record, non-matches go in `unknownHashes` so they aren't
  looked up again. *(My call.)*
- For "Added manually" jars, the display name and version come from the jar's
  own `fabric.mod.json` / `quilt.mod.json` / `META-INF/mods.toml` /
  `META-INF/neoforge.mods.toml` (UnzipKit is already bundled), falling back to
  the file name. *(My call; nice to have.)*
- If the record is missing or corrupt, rebuild it from the hash lookup.
- The record lets the list show names/icons offline.

Prism's `.index/*.pw.toml` format was considered; a single JSON file is simpler
in Objective-C and nothing needs Prism compatibility yet.

### 12. Update checks

- Every time the Installed Mods screen opens (and after imports), when online.
- `POST /version_files/update` with all Modrinth mods' `sha1` hashes, the
  accepted `loaders` and `game_versions` `[mc]`. Send two requests: mods whose
  installed version is a release use `version_types: ["release"]`; others use
  all types. This avoids offering betas to people on stable releases.
  *(My call.)*
- A result whose version id differs from the installed one is an update.
- **Update all** runs each update as its own set (§8, §10), resolving any newly
  required dependencies. Failures are reported per mod; successful ones stay.
- Offline: no tags, no banner, no error beyond a quiet note.

### 12b. When the profile's version or loader changes

**Decided by the user:** flag mods that don't match, and offer one tap to switch
them all.

- The record (§11) stores, per mod, the `gameVersions` and `loaders` of the
  installed Modrinth version (add both fields to each entry at install/update).
- On opening the Installed Mods screen, a Modrinth mod is **mismatched** if its
  stored `gameVersions` doesn't include the profile's Minecraft version, or its
  stored `loaders` share nothing with the accepted loaders (§3). Mismatched rows
  show a warning line such as "Built for 1.21.1".
- When any mods are mismatched, a banner reads "N mods don't match Minecraft
  <mc> — Switch all" (shown instead of the updates banner; the update check
  only runs for mods that match).
- **Switch all** asks `POST /version_files/update` for the mismatched mods'
  hashes with the profile's current loaders and Minecraft version, first with
  `version_types: ["release"]`, then with all types for any hash that got no
  result (so releases win, as in §7). It then replaces each mod that has a
  match exactly like an
  update (§8, §10), including any newly required dependencies. Mods with no
  matching version stay flagged with "No <mc> version yet"; they are left
  enabled. *(My call: leave enabled; the user can switch them off.)*
- A single mismatched row can also be switched from its swipe **Change
  version** action.
- "Added manually" jars aren't flagged; there's nothing reliable to compare.
- Records written before these fields existed are filled in by one lookup
  (`POST /version_files` by hash) the next time the screen opens.

### 13. Import from Files

`UIDocumentPickerViewController` for `.jar` files; copy into `mods/`
(replace-or-rename prompt on name clash), then identify as in §11.

## Error handling summary

- No network: Browse and detail show an error with retry; Installed list still
  works from the record.
- Modrinth errors / bad hashes: the set is rolled back and the message shows
  which file failed.
- Vanilla profile: empty state (§3).

## What's left to the builder

- Class and file names, where Modrinth calls live (extend `ModrinthAPI` or a
  new mods-focused class), and whether to reuse `MinecraftResourceDownloadTask`
  or write a lighter downloader.
- Exact icons, spacing, string keys and wording (English strings added to
  `en.lproj/Localizable.strings`).
- How progress is shown during installs/updates.
- Testing approach. This repo is built and tested on a Mac/device by the user;
  the parts worth isolating for testing are loader detection (§3), version
  picking (§7) and dependency resolution (§8).

## Calls I made (not discussed with the user)

Marked *(My call.)* above: copying `options.txt` on folder migration; the
one-time alert; alphabetical sort; warn-not-block on incompatible mods; the iOS
warning list format; User-Agent; the single JSON record and its
`unknownHashes` cache; reading names from jar metadata; the two-request update
check that keeps release users on releases; Mods works from the saved profile
and asks to save unsaved edits first; only modded profiles get moved, and an
existing folder always gets a suffix; the vanilla empty state explains instead
of launching installers; pinned dependency versions are used only if they fit;
disabled required mods are re-enabled on install; confirmation before
disabling or deleting a mod other mods need.
