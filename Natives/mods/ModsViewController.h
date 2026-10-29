#import <UIKit/UIKit.h>
#import "ModFolder.h"
#import "ModIndex.h"
#import "ModProfileInfo.h"
#import "ModrinthModsAPI.h"

NS_ASSUME_NONNULL_BEGIN

/* The Installed Mods screen of one saved profile: one row per jar in the profile's mods folder with an
   on/off switch, swipe to delete, search, and import from Files. Mods with a newer version get an Update
   tag and an "Update all" banner; mods made for another Minecraft version or loader are flagged with a
   "Switch all" banner instead. Gives a modded profile that still uses the shared game folder its own
   folder the first time it opens.

   Threading: every file and network job runs on one private serial queue; results are published on the
   main queue. Everything below is meant to be used from the main queue. */
@interface ModsViewController : UITableViewController

- (instancetype)initWithProfileName:(NSString *)profileName;

/* Called on the main queue after the profile was given its own game folder, so an open profile editor
   can update its copy of the profile. */
@property(nonatomic, copy, nullable) void (^gameDirChanged)(NSString *newGameDir);

@property(nonatomic, readonly) NSString *profileName;
@property(nonatomic, readonly) ModProfileInfo *info;
/* nil when the profile cannot have mods (vanilla, unknown Minecraft version, or no folder of its own). */
@property(nonatomic, readonly, nullable) ModIndex *index;
@property(nonatomic, readonly, nullable) ModFolder *folder;
@property(nonatomic, readonly) ModrinthModsAPI *api;
/* YES while an operation or a reload runs. Key-value observable. Never touch `index` or `folder` from
   another job while this is YES unless you are the running operation. */
@property(nonatomic, readonly) BOOL busy;

/* Runs `operation` on the main queue unless the screen is busy (then nothing happens). While it runs the
   screen is busy: spinner shown, switches, swipe actions and bar buttons disabled. The operation does its
   blocking work off the main queue and must call `done` exactly once, from any queue; `done` then shows
   the error (if any) and reloads the list. */
- (void)runOperation:(void (^)(void (^done)(NSError * _Nullable error)))operation;

/* Rescans the folder, prunes the record, identifies new jars on Modrinth, fills in which Minecraft
   versions and loaders recorded mods were made for, finds the mods that don't fit the profile and checks
   the others for updates (the network steps are skipped silently offline), then refreshes the list. The
   work runs on the background queue; asked for while busy, it runs once the current job ends. */
- (void)reloadFromDisk;

/* From the last reload (empty before it, and offline): Modrinth's newer version (a version object) for
   each installed mod that fits the profile and has one, keyed by jar file name without ".disabled". */
@property(nonatomic, readonly) NSDictionary<NSString *, NSDictionary *> *availableUpdates;
/* From the last reload: jar file names (without ".disabled") of Modrinth mods whose recorded Minecraft
   versions don't include the profile's, or whose loaders share none with it. Sorted. */
@property(nonatomic, readonly) NSArray<NSString *> *mismatchedFileNames;

@end

NS_ASSUME_NONNULL_END
