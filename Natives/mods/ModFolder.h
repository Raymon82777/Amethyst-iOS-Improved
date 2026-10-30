#import <Foundation/Foundation.h>
#import "ModContentKind.h"

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const ModFolderErrorDomain; // @"ModFolderErrorDomain"

typedef NS_ENUM(NSInteger, ModFolderError) {
    /* The target file name is already taken (enabled or disabled). */
    ModFolderErrorExists = 1
};

/* One entry in a content folder: a mod file, a pack file or (packs only) an unzipped pack folder. */
@interface ModJar : NSObject
@property(nonatomic, copy) NSString *fileName; // without ".disabled"; the folder name for a folder pack
@property(nonatomic, copy) NSString *path;     // actual path on disk
@property(nonatomic) BOOL enabled;
@property(nonatomic) BOOL isDirectory;         // a folder pack: never switched, never hashed
@end

/* Every file operation on one of a profile's content folders (`mods/`, `resourcepacks/` or
   `shaderpacks/`: scan, enable/disable by rename, delete, import, hashing), plus giving a profile its
   own game folder. A disabled item is the same file with ".disabled" appended to its name.
   Folder packs (kinds with `listsFolders`) are listed but never renamed.
   Foundation + CommonCrypto only so it can be tested on the host (see `make test_mods`). */
@interface ModFolder : NSObject

/* Creates the folder if it is missing. */
- (instancetype)initWithModsDir:(NSString *)modsDir kind:(ModContentKind *)kind;

/* The mods kind (`ModContentKind.mods`). Creates the folder if it is missing. */
- (instancetype)initWithModsDir:(NSString *)modsDir;

@property(nonatomic, readonly) NSString *modsDir;
@property(nonatomic, readonly) ModContentKind *kind;

/* Number of items `scanJars` would list, without creating the folder or deleting anything;
   0 if the folder is missing. */
+ (NSUInteger)countItemsInDir:(NSString *)dir kind:(ModContentKind *)kind;

/* Lists *.<ext> and *.<ext>.disabled files (the kind's extension; nothing else, the record file is
   ignored), sorted by file name. For kinds with `listsFolders` it also lists visible folders (names not
   starting with "."), as enabled items with `isDirectory` set. Deletes stray *.part files left by
   interrupted downloads first. */
- (NSArray<ModJar *> *)scanJars;

/* Renames the file to add or drop ".disabled" and updates jar.path and jar.enabled.
   Fails with ModFolderErrorExists if the target name is taken, or if the item is a folder pack. */
- (BOOL)setJar:(ModJar *)jar enabled:(BOOL)enabled error:(NSError **)error;

/* Removes the file, or the whole folder for a folder pack. */
- (BOOL)deleteJar:(ModJar *)jar error:(NSError **)error;

/* Copies the file at `url` into the folder as `fileName` (nil = the URL's last path component) and
   returns the file name written. A ".disabled" twin of the name counts as a clash. Without `replace`
   a clash fails with ModFolderErrorExists; with it the existing file (and twin) is removed first.
   For kinds other than mods the name must end in ".<kind.fileExtension>", else the import fails. */
- (nullable NSString *)importJarFromURL:(NSURL *)url asFileName:(nullable NSString *)fileName replaceExisting:(BOOL)replace error:(NSError **)error;

/* The first free name of "X.<ext>", "X (2).<ext>", "X (3).<ext>"... (the name's own extension is kept).
   A ".disabled" twin counts as taken. */
- (NSString *)uniqueFileNameFor:(NSString *)fileName;

/* Lowercase hex digest, or nil if the file cannot be read. Streamed in 1 MB chunks. */
+ (nullable NSString *)sha1OfFileAtPath:(NSString *)path;
+ (nullable NSString *)sha512OfFileAtPath:(NSString *)path;

/* The standardized game folder for a profile's gameDir value (nil or empty means the base folder).
   Always `baseDir` + "/" + gameDir, like the launcher: an absolute value is not honored as such, so
   "/foo" means "<baseDir>/foo". */
+ (NSString *)gameDirPathForGameDir:(nullable NSString *)gameDir baseDir:(NSString *)baseDir;

/* YES when the profile uses the base folder itself, so its mods would be shared with other profiles. */
+ (BOOL)isSharedGameDir:(nullable NSString *)gameDir baseDir:(NSString *)baseDir;

/* A profile name made safe to use as a folder name; "Profile" if nothing is left. */
+ (NSString *)safeFolderName:(NSString *)profileName;

/* Gives a profile its own game folder under `<baseDir>/custom_gamedir/`. Creates the folder and its
   mods/ subfolder and copies options.txt from `baseDir` if it has one. Nothing else in `baseDir` is
   touched. Returns the new gameDir value ("./custom_gamedir/<name>"), or nil with `error` set. */
+ (nullable NSString *)migrateProfileNamed:(NSString *)profileName baseDir:(NSString *)baseDir error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
