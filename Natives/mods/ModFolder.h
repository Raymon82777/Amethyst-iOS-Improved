#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const ModFolderErrorDomain; // @"ModFolderErrorDomain"

typedef NS_ENUM(NSInteger, ModFolderError) {
    /* The target file name is already taken (enabled or disabled). */
    ModFolderErrorExists = 1
};

/* One mod file in a mods folder. */
@interface ModJar : NSObject
@property(nonatomic, copy) NSString *fileName; // without ".disabled"
@property(nonatomic, copy) NSString *path;     // actual path on disk
@property(nonatomic) BOOL enabled;
@end

/* Every file operation on a profile's `mods/` folder (scan, enable/disable by rename, delete,
   import, hashing), plus giving a profile its own game folder.
   A disabled mod is the same file with ".disabled" appended to its name.
   Foundation + CommonCrypto only so it can be tested on the host (see `make test_mods`). */
@interface ModFolder : NSObject

/* Creates the folder if it is missing. */
- (instancetype)initWithModsDir:(NSString *)modsDir;

@property(nonatomic, readonly) NSString *modsDir;

/* Lists *.jar and *.jar.disabled (nothing else; the record file is ignored), sorted by file name.
   Deletes stray *.part files left by interrupted downloads first. */
- (NSArray<ModJar *> *)scanJars;

/* Renames the file to add or drop ".disabled" and updates jar.path and jar.enabled.
   Fails with ModFolderErrorExists if the target name is taken. */
- (BOOL)setJar:(ModJar *)jar enabled:(BOOL)enabled error:(NSError **)error;

- (BOOL)deleteJar:(ModJar *)jar error:(NSError **)error;

/* Copies the file at `url` into the folder as `fileName` (nil = the URL's last path component) and
   returns the file name written. A ".disabled" twin of the name counts as a clash. Without `replace`
   a clash fails with ModFolderErrorExists; with it the existing file (and twin) is removed first. */
- (nullable NSString *)importJarFromURL:(NSURL *)url asFileName:(nullable NSString *)fileName replaceExisting:(BOOL)replace error:(NSError **)error;

/* The first free name of "X.jar", "X (2).jar", "X (3).jar"... A ".disabled" twin counts as taken. */
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
