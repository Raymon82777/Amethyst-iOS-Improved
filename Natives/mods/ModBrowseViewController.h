#import <UIKit/UIKit.h>
#import "ModsViewController.h"

NS_ASSUME_NONNULL_BEGIN

/* Search Modrinth for mods that fit a profile's loader and Minecraft version (shown as a fixed chip).
   Meant to be the root of a navigation controller presented from the Mods screen; tapping a result
   opens its detail page. */
@interface ModBrowseViewController : UITableViewController

- (instancetype)initWithModsController:(ModsViewController *)mods;

@end

NS_ASSUME_NONNULL_END
