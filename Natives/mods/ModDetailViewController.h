#import <UIKit/UIKit.h>
#import "ModsViewController.h"

NS_ASSUME_NONNULL_BEGIN

/* Why a mod is known to have trouble on iOS, or nil. Read from `ios_mod_warnings.plist` in the app bundle
   (a dictionary of Modrinth project id -> short reason) the first time it is needed, then cached.
   Safe on any thread. */
NSString * _Nullable ModIOSWarningForProject(NSString *projectId);

/* A short download count: "830", "4.2K", "52M", "1.3B". */
NSString *ModFormattedDownloads(NSNumber * _Nullable downloads);

/* A small rounded tag ("Installed", "iOS?", "Beta") in `color`. */
UIView *ModTagView(NSString *text, UIColor *color);

/* `tags` side by side, sized to fit, for use as a cell's accessoryView; nil when `tags` is empty. */
UIView * _Nullable ModTagsAccessoryView(NSArray<UIView *> *tags);

/* One Modrinth mod for one profile: description, the Install / Update button for the best version, what
   else the install brings in, every compatible version (tap one to install it instead), and a link to
   Modrinth. Installs run as an operation of `mods` (see ModsViewController runOperation:), so only one
   runs at a time; after a successful install the page closes back to the installed list. */
@interface ModDetailViewController : UITableViewController

/* `hit` is a search result from ModrinthModsAPI (shown at once); without it the project is loaded. */
- (instancetype)initWithModsController:(ModsViewController *)mods projectId:(NSString *)projectId hit:(nullable NSDictionary *)hit;

@end

NS_ASSUME_NONNULL_END
