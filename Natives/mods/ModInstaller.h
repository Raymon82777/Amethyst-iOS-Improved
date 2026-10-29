#import <Foundation/Foundation.h>
#import "ModDependencyResolver.h"
#import "ModIndex.h"

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const ModInstallErrorDomain; // @"ModInstallErrorDomain"

typedef NS_ENUM(NSInteger, ModInstallError) {
    /* A file could not be downloaded (or the version has no usable file or URL). */
    ModInstallErrorDownload = 1,
    /* A downloaded file does not match the hash Modrinth lists for it. */
    ModInstallErrorHashMismatch = 2,
    /* The version's file lists neither a sha1 nor a sha512, so it cannot be verified. */
    ModInstallErrorNoHash = 3,
    /* A file name is not usable, or the mods folder or its record could not be changed. */
    ModInstallErrorFileSystem = 4
};
/* Every error carries userInfo[@"fileName"], the file that failed (when there is one). */

typedef void (^ModDownloadCompletion)(NSError * _Nullable error);
/* Downloads `url` to the file at `destPath` (replacing anything there), then calls `completion`
   exactly once, on any queue. */
typedef void (^ModDownloader)(NSURL *url, NSString *destPath, ModDownloadCompletion completion);

/* Makes a ModInstallPlan real in a profile's mods folder. Every file is downloaded beside its final
   name as `<name>.part` and verified before anything existing is touched; only then are files swapped
   in and the record updated. If anything fails on the way, the folder and the record are left as they
   were. Foundation-only so it can be tested on the host with a fake downloader (see `make test_mods`). */
@interface ModInstaller : NSObject

/* "Amethyst-iOS/<version> (github.com/Raymon82777/Amethyst-iOS-Improved)"; the version is the app's
   CFBundleShortVersionString, or "dev" without one. Sent as the User-Agent on Modrinth requests. */
+ (NSString *)userAgent;

/* An NSURLSession download task that sends `userAgent`, treats a non-2xx status as an error, and
   moves the downloaded file to `destPath`. */
+ (ModDownloader)defaultDownloader;

- (instancetype)initWithIndex:(ModIndex *)index downloader:(ModDownloader)downloader;

/* `projects` maps a project id to its Modrinth project object (for title, slug and icon); a missing
   project is fine. Installs every version in `plan.versionsToInstall` (its primary file), replacing the
   file already recorded for the same project, and switches `plan.projectIdsToEnable` back on.
   A replaced mod that was disabled stays disabled. A file that already has the downloaded name is
   treated as the file being replaced, whether or not it was recorded.
   Every file name must end in ".jar" (any case; it is saved and recorded with a lowercase ".jar") and
   must not be one of the folder's own names (the record, "*.part", "*.old", "*.disabled"); otherwise
   the install fails with ModInstallErrorFileSystem before anything is downloaded or touched.
   `completion` is called exactly once, on an arbitrary queue; nil error means the whole plan is in.
   If saving the record fails after the files are in place, the files stay installed and the error is
   ModInstallErrorFileSystem for the record file. */
- (void)installPlan:(ModInstallPlan *)plan
           projects:(NSDictionary<NSString *, NSDictionary *> *)projects
         completion:(void (^)(NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
