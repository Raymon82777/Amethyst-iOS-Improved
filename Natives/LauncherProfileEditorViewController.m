#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherProfileEditorViewController.h"
#import "MinecraftResourceUtils.h"
#import "PickTextField.h"
#import "PLProfiles.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "mods/ModContentKind.h"
#import "mods/ModFolder.h"
#import "mods/ModsViewController.h"
#import "utils.h"

@interface LauncherProfileEditorViewController()<UIPickerViewDataSource, UIPickerViewDelegate>
@property(nonatomic) NSString* oldName;

@property(nonatomic) NSArray<NSDictionary *> *versionList;
@property(nonatomic) PickTextField* versionTextField;
@property(nonatomic) UISegmentedControl* versionTypeControl;
@property(nonatomic) UIPickerView* versionPickerView;
@property(nonatomic) UIToolbar* versionPickerToolbar;
@property(nonatomic) int versionSelectedAt;

/* Item counts shown on the Mods, Resource Packs and Shader Packs rows, by row key. A key is missing
   when its count is unknown: the profile is unsaved or shares the base game folder. */
@property(nonatomic, copy) NSDictionary<NSString *, NSString *> *contentCounts;
@property(nonatomic) NSUInteger contentCountsGeneration;
@end

/* The content kind a profile editor row opens, or nil if the key is not one of those rows. */
static ModContentKind * _Nullable ContentKindForKey(NSString *key) {
    if ([key isEqualToString:@"mods"]) return ModContentKind.mods;
    if ([key isEqualToString:@"resourcepacks"]) return ModContentKind.resourcePacks;
    if ([key isEqualToString:@"shaderpacks"]) return ModContentKind.shaderPacks;
    return nil;
}

/* The base folder the content screens use (see ModsViewController). */
static NSString *ContentGameRoot(void) {
    const char *gameDir = getenv("GAME_DIR");
    return gameDir ? @(gameDir) : @"";
}

@implementation LauncherProfileEditorViewController

- (void)viewDidLoad {
    // Setup navigation bar & appearance
    self.title = localize(@"Edit profile", nil);
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(actionDone)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose target:self action:@selector(actionClose)];
    self.navigationController.modalInPresentation = YES;
    self.prefSectionsVisible = YES;

    // Setup preference getter and setter
    __weak LauncherProfileEditorViewController *weakSelf = self;
    self.getPreference = ^id(NSString *section, NSString *key){
        if (ContentKindForKey(key)) {
            // A missing count shows an empty detail
            return weakSelf.contentCounts[key];
        }
        NSString *value = weakSelf.profile[key];
        if (value.length > 0 || ![weakSelf isPickFieldAtSection:section key:key]) {
            return value;
        } else {
            return @"(default)";
        }
    };
    self.setPreference = ^(NSString *section, NSString *key, NSString *value){
        if ([value isEqualToString:@"(default)"] && [weakSelf isPickFieldAtSection:section key:key]) {
            [weakSelf.profile removeObjectForKey:key];
        } else if (value) {
            weakSelf.profile[key] = value;
        }
    };

    // Obtain all the lists
    self.oldName = self.getPreference(nil, @"name");
    if ([self.oldName length] == 0) {
        self.setPreference(nil, @"name", @"New Profile");
    }
    NSArray *rendererKeys = getRendererKeys(YES);
    NSArray *rendererList = getRendererNames(YES);
    NSArray *touchControlList = [self listFilesAtPath:[NSString stringWithFormat:@"%s/controlmap", getenv("AME_HOME")]];
    NSArray *gamepadControlList = [self listFilesAtPath:[NSString stringWithFormat:@"%s/controlmap/gamepads", getenv("AME_HOME")]];
    NSMutableArray *javaList = [getPrefObject(@"java.java_homes") allKeys].mutableCopy;
    [javaList sortUsingSelector:@selector(compare:)];
    javaList[0] = @"(default)";

    // Setup version picker
    [self setupVersionPicker];
    id typeVersionPicker = ^void(UITableViewCell *cell, NSString *section, NSString *key, NSDictionary *item){
        self.typeTextField(cell, section, key, item);
        PickTextField *textField = (id)cell.accessoryView;
        weakSelf.versionTextField = textField;
        textField.inputAccessoryView = weakSelf.versionPickerToolbar;
        textField.inputView = weakSelf.versionPickerView;
        // Auto pick version type
        if (self.versionList) return;
        if ([MinecraftResourceUtils findVersion:textField.text inList:localVersionList]) {
            self.versionTypeControl.selectedSegmentIndex = 0;
        } else {
            NSDictionary *selected = (id)[MinecraftResourceUtils findVersion:textField.text inList:remoteVersionList];
            if (selected) {
                NSArray *types = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"];
                NSString *type = selected[@"type"];
                self.versionTypeControl.selectedSegmentIndex = [types indexOfObject:type];
            } else {
                // Version not found
                self.versionTypeControl.selectedSegmentIndex = 0;
            }
        }
        self.versionSelectedAt = -1;
        [self changeVersionType:nil];
    };

    BOOL(^enableContent)(void) = ^BOOL(){
        return weakSelf.oldName.length > 0 && PLProfiles.current.profiles[weakSelf.oldName] != nil;
    };

    self.prefContents = @[
        @[
            // General settings
            @{@"key": @"name",
              @"icon": @"tag",
              @"title": @"preference.profile.title.name",
              @"type": self.typeTextField,
              @"placeholder": self.oldName
            },
            @{@"key": @"lastVersionId",
              @"icon": @"archivebox",
              @"title": @"preference.profile.title.version",
              @"type": typeVersionPicker,
              @"placeholder": self.getPreference(nil, @"lastVersionId"),
              @"customClass": PickTextField.class
            },
            @{@"key": @"gameDir",
              @"icon": @"folder",
              @"title": @"preference.title.game_directory",
              @"type": self.typeTextField,
              @"placeholder": [NSString stringWithFormat:@". -> /Documents/instances/%@", getPrefObject(@"general.game_directory")]
            },
            // These work on the saved profile, so a profile that was never saved has none yet
            @{@"key": @"mods",
              @"icon": @"puzzlepiece",
              @"title": @"preference.profile.title.mods",
              @"type": self.typeChildPane,
              @"enableCondition": enableContent,
              @"action": ^void(){
                  [weakSelf actionOpenContent:ModContentKind.mods];
              }
            },
            @{@"key": @"resourcepacks",
              @"icon": @"photo.on.rectangle",
              @"title": @"preference.profile.title.resourcepacks",
              @"type": self.typeChildPane,
              @"enableCondition": enableContent,
              @"action": ^void(){
                  [weakSelf actionOpenContent:ModContentKind.resourcePacks];
              }
            },
            @{@"key": @"shaderpacks",
              @"icon": @"sparkles",
              @"title": @"preference.profile.title.shaderpacks",
              @"type": self.typeChildPane,
              @"enableCondition": enableContent,
              @"action": ^void(){
                  [weakSelf actionOpenContent:ModContentKind.shaderPacks];
              }
            },
            // Video and renderer settings
            @{@"key": @"renderer",
              @"icon": @"cpu",
              @"type": self.typePickField,
              @"pickKeys": rendererKeys,
              @"pickList": rendererList
            },
            // Control settings
            @{@"key": @"defaultTouchCtrl",
              @"icon": @"hand.tap",
              @"title": @"preference.profile.title.default_touch_control",
              @"type": self.typePickField,
              @"pickKeys": touchControlList,
              @"pickList": touchControlList
            },
            @{@"key": @"defaultGamepadCtrl",
              @"icon": @"gamecontroller",
              @"title": @"preference.profile.title.default_gamepad_control",
              @"type": self.typePickField,
              @"pickKeys": gamepadControlList,
              @"pickList": gamepadControlList
            },
            // Java tweaks
            @{@"key": @"javaVersion",
              @"icon": @"cube",
              @"title": @"preference.manage_runtime.header.default",
              @"type": self.typePickField,
              @"pickKeys": javaList,
              @"pickList": javaList
            },
            @{@"key": @"javaArgs",
              @"icon": @"slider.vertical.3",
              @"title": @"preference.title.java_args",
              @"type": self.typeTextField,
              @"placeholder": @"(default)"
            }
        ]
    ];

    [super viewDidLoad];
}

- (void)viewWillAppear:(BOOL)animated {
    // Also reloads the child pane rows, which show the counts known so far
    [super viewWillAppear:animated];
    [self refreshContentCounts];
}

- (void)actionClose {
    [self.navigationController dismissViewControllerAnimated:YES completion:nil];
}

- (void)actionDone {
    if (![self saveProfile]) {
        // Skip dismissing this view controller
        return;
    }
    [self actionClose];
    [self refreshProfileList];
}

- (void)refreshProfileList {
    // Call LauncherProfilesViewController's viewWillAppear
    UINavigationController *navVC = (id) ((UISplitViewController *)self.presentingViewController).viewControllers[1];
    [navVC.viewControllers[0] viewWillAppear:NO];
}

- (void)commitEditingTextField {
    // We might be saving without ending editing, so make sure textFieldDidEndEditing is always called
    UITextField *currentTextField = [self performSelector:@selector(_firstResponder)];
    if ([currentTextField isKindOfClass:UITextField.class] && [currentTextField isDescendantOfView:self.tableView]) {
        [self textFieldDidEndEditing:currentTextField];
    }
}

/* Writes the edited profile to PLProfiles and saves it. Returns NO (after telling the user) when the
   new name is already taken. */
- (BOOL)saveProfile {
    [self commitEditingTextField];

    if ([self.profile[@"name"] length] == 0 && self.oldName.length > 0) {
        // Return to its old name
        self.profile[@"name"] = self.oldName;
    }

    if ([self.oldName isEqualToString:self.profile[@"name"]]) {
        // Not a rename, directly create/replace
        // Store a copy: the editor stays open after saving from the Mods row, and its later edits
        // must not reach the saved profile until they are saved too
        PLProfiles.current.profiles[self.oldName] = self.profile.mutableCopy;
    } else if (!PLProfiles.current.profiles[self.profile[@"name"]]) {
        // A rename, remove then re-add to update its key name
        if (self.oldName.length > 0) {
            [PLProfiles.current.profiles removeObjectForKey:self.oldName];
        }
        PLProfiles.current.profiles[self.profile[@"name"]] = self.profile.mutableCopy;
        // Update selected name
        if ([PLProfiles.current.selectedProfileName isEqualToString:self.oldName]) {
            PLProfiles.current.selectedProfileName = self.profile[@"name"];
        }
    } else {
        // Cancel rename since a profile with the same name already exists
        showDialog(localize(@"Error", nil), localize(@"profile.error.name_exists", nil));
        return NO;
    }

    [PLProfiles.current save];
    self.oldName = self.profile[@"name"];
    return YES;
}

#pragma mark Mods, resource packs and shader packs

/* Counts each content folder of the saved profile off the main thread, then updates the rows. */
- (void)refreshContentCounts {
    NSUInteger generation = ++self.contentCountsGeneration;
    NSDictionary *saved = self.oldName.length > 0 ? PLProfiles.current.profiles[self.oldName] : nil;
    NSString *savedGameDir = saved[@"gameDir"];
    NSString *baseDir = ContentGameRoot();
    if (!saved || [ModFolder isSharedGameDir:savedGameDir baseDir:baseDir]) {
        // Nothing to count: the profile is unsaved, or its folders are shared with other profiles
        self.contentCounts = @{};
        [self reloadContentRows];
        return;
    }

    NSString *gameDirPath = [ModFolder gameDirPathForGameDir:savedGameDir baseDir:baseDir];
    NSArray<NSString *> *keys = @[@"mods", @"resourcepacks", @"shaderpacks"];
    __weak LauncherProfileEditorViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary<NSString *, NSString *> *counts = [NSMutableDictionary new];
        for (NSString *key in keys) {
            ModContentKind *kind = ContentKindForKey(key);
            NSString *dir = [gameDirPath stringByAppendingPathComponent:kind.folderName];
            counts[key] = [NSString stringWithFormat:@"%lu", (unsigned long)[ModFolder countItemsInDir:dir kind:kind]];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            LauncherProfileEditorViewController *strongSelf = weakSelf;
            // A newer refresh supersedes this one
            if (!strongSelf || strongSelf.contentCountsGeneration != generation) return;
            strongSelf.contentCounts = counts;
            [strongSelf reloadContentRows];
        });
    });
}

/* Reloads just the three content rows, so a text field being edited keeps focus. */
- (void)reloadContentRows {
    if (!self.isViewLoaded) return;
    NSMutableArray *indexPaths = [NSMutableArray new];
    for (NSInteger section = 0; section < self.prefContents.count; section++) {
        if (!self.prefSectionsVisibility[section].boolValue) {
            continue;
        }
        for (NSInteger row = 0; row < self.prefContents[section].count; row++) {
            if (ContentKindForKey(self.prefContents[section][row][@"key"])) {
                [indexPaths addObject:[NSIndexPath indexPathForRow:row inSection:section]];
            }
        }
    }
    [self.tableView reloadRowsAtIndexPaths:indexPaths withRowAnimation:UITableViewRowAnimationNone];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *item = self.prefContents[indexPath.section][indexPath.row];
    if (ContentKindForKey(item[@"key"])) {
        // Run the action directly: the generic button handling would also show a "done" alert
        [tableView deselectRowAtIndexPath:indexPath animated:YES];
        void(^invokeAction)(void) = item[@"action"];
        if (invokeAction) {
            invokeAction();
        }
        return;
    }
    [super tableView:tableView didSelectRowAtIndexPath:indexPath];
}

- (void)actionOpenContent:(ModContentKind *)kind {
    [self commitEditingTextField];
    NSDictionary *saved = PLProfiles.current.profiles[self.oldName];
    if (!saved) {
        return;
    }

    NSString *name = self.profile[@"name"];
    NSString *version = self.profile[@"lastVersionId"];
    BOOL nameChanged = name.length > 0 && ![name isEqualToString:self.oldName];
    BOOL versionChanged = !(version == saved[@"lastVersionId"] || [version isEqualToString:saved[@"lastVersionId"]]);
    // A missing Game directory and an empty one both mean the shared folder.
    NSString *gameDir = self.profile[@"gameDir"] ?: @"";
    NSString *savedGameDir = saved[@"gameDir"] ?: @"";
    BOOL gameDirChanged = ![gameDir isEqual:savedGameDir];
    if (!nameChanged && !versionChanged && !gameDirChanged) {
        [self pushContentViewController:kind];
        return;
    }

    NSString *titleKey = kind.isMods ? @"preference.profile.title.mods" : [kind stringKey:@"title"];
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(titleKey, nil)
        message:localize([kind stringKey:@"alert.save_first"], nil) preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Save", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        if (![self saveProfile]) {
            return;
        }
        [self refreshProfileList];
        [self.tableView reloadData];
        [self pushContentViewController:kind];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)pushContentViewController:(ModContentKind *)kind {
    NSString *profileName = self.oldName;
    ModsViewController *vc = [[ModsViewController alloc] initWithProfileName:profileName kind:kind];
    __weak LauncherProfileEditorViewController *weakSelf = self;
    vc.gameDirChanged = ^(NSString *newGameDir) {
        LauncherProfileEditorViewController *strongSelf = weakSelf;
        if (!strongSelf) return;
        // Keep the editor's copy in step with the saved profile, so a later Done does not undo the move
        strongSelf.profile[@"gameDir"] = newGameDir;
        [strongSelf.tableView reloadData];
    };
    [self.navigationController pushViewController:vc animated:YES];
}

- (BOOL)isPickFieldAtSection:(NSString *)section key:(NSString *)key {
    NSDictionary *pref = [self.prefContents[0] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(key == %@)", key]].firstObject;
    return pref[@"type"] == self.typePickField;
}

- (NSArray *)listFilesAtPath:(NSString *)path {
    NSMutableArray *files = [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:nil].mutableCopy;
    for (int i = 0; i < files.count;) {
        if ([files[i] hasSuffix:@".json"]) {
            i++;
        } else {
            [files removeObjectAtIndex:i];
        }
    }
    [files insertObject:@"(default)" atIndex:0];
    return files;
}

#pragma mark Version picker

- (void)setupVersionPicker {
    self.versionPickerView = [[UIPickerView alloc] init];
    self.versionPickerView.delegate = self;
    self.versionPickerView.dataSource = self;
    self.versionPickerToolbar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 390, 44.0)];
    self.versionTypeControl = [[UISegmentedControl alloc] initWithItems:@[
        localize(@"Installed", nil),
        localize(@"Releases", nil),
        localize(@"Snapshot", nil),
        localize(@"Old-beta", nil),
        localize(@"Old-alpha", nil)
    ]];
    self.versionTypeControl.frame = CGRectMake(0, 0, 390, 44.0);
    self.versionTypeControl.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self.versionTypeControl addTarget:self action:@selector(changeVersionType:) forControlEvents:UIControlEventValueChanged];
    // here we go some random private apis I found
    [[self.versionTypeControl _uiktest_labelsWithState:0] makeObjectsPerformSelector:@selector(setNumberOfLines:) withObject:nil];
    [self.versionPickerToolbar addSubview:self.versionTypeControl];
}

- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    if (self.versionList.count == 0) {
        self.versionTextField.text = @"";
        return;
    }
    self.versionSelectedAt = row;
    self.versionTextField.text = [self pickerView:pickerView titleForRow:row forComponent:component];
}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)thePickerView {
    return 1;
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return self.versionList.count;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    if (self.versionList.count <= row) return nil;
    NSObject *object = self.versionList[row];
    if ([object isKindOfClass:[NSString class]]) {
        return (NSString*) object;
    } else {
        return [object valueForKey:@"id"];
    }
}

- (void)versionClosePicker {
    [self.versionTextField endEditing:YES];
    [self pickerView:self.versionPickerView didSelectRow:[self.versionPickerView selectedRowInComponent:0] inComponent:0];
}

- (void)changeVersionType:(UISegmentedControl *)sender {
    NSArray *newVersionList = self.versionList;
    if (sender || !self.versionList) {
        if (self.versionTypeControl.selectedSegmentIndex == 0) {
            // installed
            newVersionList = localVersionList;
        } else {
            NSString *type = @[@"installed", @"release", @"snapshot", @"old_beta", @"old_alpha"][self.versionTypeControl.selectedSegmentIndex];
            newVersionList = [remoteVersionList filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"(type == %@)", type]];
        }
    }

    if (self.versionSelectedAt == -1) {
        NSDictionary *selected = (id)[MinecraftResourceUtils findVersion:self.versionTextField.text inList:newVersionList];
        self.versionSelectedAt = [newVersionList indexOfObject:selected];
    } else {
        // Find the most matching version for this type
        NSObject *lastSelected = nil; 
        if (self.versionList.count > self.versionSelectedAt) {
            lastSelected = self.versionList[self.versionSelectedAt];
        }
        if (lastSelected != nil) {
            NSObject *nearest = [MinecraftResourceUtils findNearestVersion:lastSelected expectedType:self.versionTypeControl.selectedSegmentIndex];
            if (nearest != nil) {
                self.versionSelectedAt = [newVersionList indexOfObject:(id)nearest];
            }
        }
        lastSelected = nil;
        // Get back the currently selected in case none matching version found
        self.versionSelectedAt = MIN(abs(self.versionSelectedAt), newVersionList.count - 1);
    }

    self.versionList = newVersionList;
    [self.versionPickerView reloadAllComponents];
    if (self.versionSelectedAt != -1) {
        [self.versionPickerView selectRow:self.versionSelectedAt inComponent:0 animated:NO];
        [self pickerView:self.versionPickerView didSelectRow:self.versionSelectedAt inComponent:0];
    }
}

@end
