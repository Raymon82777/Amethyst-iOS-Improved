#import "ModBrowseViewController.h"
#import "ModDetailViewController.h"
#import "UIKit+AFNetworking.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

NS_ASSUME_NONNULL_BEGIN

static void *kBrowseBusyContext = &kBrowseBusyContext;
static NSString *const kHitCellID = @"ModHitCell";
static const CGFloat kIconSize = 40;

/* `value` when it is a non-empty string. */
static NSString * _Nullable StringOrNil(id _Nullable value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

@interface ModBrowseViewController () <UISearchResultsUpdating>
@property(nonatomic) ModsViewController *mods;
@property(nonatomic) UISearchController *searchController;
@property(nonatomic) UIActivityIndicatorView *spinner;

@property(nonatomic, copy) NSArray<NSDictionary *> *hits;
@property(nonatomic, copy, nullable) NSString *loadedQuery; // the query `hits` belong to; nil until one loaded
@property(nonatomic) BOOL reachedEnd;
@property(nonatomic) BOOL pageFailed; // stops loading more pages until the next search
@property(nonatomic) BOOL loading;
@property(nonatomic) NSUInteger generation; // a new search makes older answers stale

@property(nonatomic, copy) NSSet<NSString *> *installedProjectIds;
@end

@implementation ModBrowseViewController

- (instancetype)initWithModsController:(ModsViewController *)mods {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    if (!self) return nil;
    _mods = mods;
    _hits = @[];
    _installedProjectIds = [NSSet set];
    [mods addObserver:self forKeyPath:@"busy" options:0 context:kBrowseBusyContext];
    return self;
}

- (void)dealloc {
    [_mods removeObserver:self forKeyPath:@"busy" context:kBrowseBusyContext];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = localize(@"mods.browse.title", nil);
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    self.tableView.estimatedRowHeight = 64;

    self.searchController = [[UISearchController alloc] initWithSearchResultsController:nil];
    self.searchController.searchResultsUpdater = self;
    self.searchController.obscuresBackgroundDuringPresentation = NO;
    self.searchController.searchBar.placeholder = localize(@"mods.browse.search", nil);
    self.navigationItem.searchController = self.searchController;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;

    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemClose
        target:self action:@selector(actionClose)];
    self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
    self.spinner.hidesWhenStopped = YES;
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:self.spinner];

    self.tableView.tableHeaderView = [self filterChipView];
    [self refreshInstalledProjects];
    [self loadQuery:@"" append:NO];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refreshInstalledProjects];
}

- (void)actionClose {
    [self.navigationController.presentingViewController dismissViewControllerAnimated:YES completion:nil];
}

/* The fixed filter, e.g. "Fabric · 1.21.1". Not a control: the profile decides it. */
- (UIView *)filterChipView {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = self.mods.info.displayName;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    label.textColor = UIColor.secondaryLabelColor;

    UIView *chip = [UIView new];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    chip.backgroundColor = UIColor.tertiarySystemFillColor;
    chip.layer.cornerRadius = 12;
    [chip addSubview:label];

    UIView *container = [[UIView alloc] initWithFrame:CGRectMake(0, 0, CGRectGetWidth(self.tableView.bounds), 40)];
    container.preservesSuperviewLayoutMargins = YES;
    [container addSubview:chip];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:10],
        [label.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-10],
        [label.topAnchor constraintEqualToAnchor:chip.topAnchor constant:4],
        [label.bottomAnchor constraintEqualToAnchor:chip.bottomAnchor constant:-4],
        [chip.leadingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.leadingAnchor],
        [chip.trailingAnchor constraintLessThanOrEqualToAnchor:container.layoutMarginsGuide.trailingAnchor],
        [chip.centerYAnchor constraintEqualToAnchor:container.centerYAnchor]
    ]];
    return container;
}

- (void)showMessage:(nullable NSString *)message {
    if (!message) {
        self.tableView.backgroundView = nil;
        return;
    }
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = message;
    label.numberOfLines = 0;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = UIColor.secondaryLabelColor;
    label.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    label.adjustsFontForContentSizeCategory = YES;

    UIView *container = [UIView new];
    [container addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerYAnchor constraintEqualToAnchor:container.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.leadingAnchor constant:16],
        [label.trailingAnchor constraintEqualToAnchor:container.layoutMarginsGuide.trailingAnchor constant:-16]
    ]];
    self.tableView.backgroundView = container;
}

#pragma mark Installed tags

- (void)observeValueForKeyPath:(nullable NSString *)keyPath ofObject:(nullable id)object
                        change:(nullable NSDictionary<NSKeyValueChangeKey, id> *)change context:(nullable void *)context {
    if (context != kBrowseBusyContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    __weak ModBrowseViewController *weakSelf = self;
    void (^update)(void) = ^{
        ModBrowseViewController *strongSelf = weakSelf;
        if (strongSelf.isViewLoaded) [strongSelf refreshInstalledProjects];
    };
    // `busy` changes on the main queue; hop there in case that ever changes.
    if (NSThread.isMainThread) {
        update();
    } else {
        dispatch_async(dispatch_get_main_queue(), update);
    }
}

/* Re-reads which projects the profile has, but only while the Mods screen is idle (it runs again when
   the Mods screen goes idle, e.g. after an install). */
- (void)refreshInstalledProjects {
    ModIndex *modIndex = self.mods.index;
    if (self.mods.busy || !modIndex) {
        return;
    }
    NSMutableSet<NSString *> *projectIds = [NSMutableSet new];
    for (NSDictionary *entry in modIndex.entries.allValues) {
        NSString *projectId = StringOrNil(entry[@"projectId"]);
        if (projectId) [projectIds addObject:projectId];
    }
    if (![projectIds isEqualToSet:self.installedProjectIds]) {
        self.installedProjectIds = projectIds;
        [self.tableView reloadData];
    }
}

#pragma mark Search

- (NSString *)currentQuery {
    return [self.searchController.searchBar.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
}

- (void)updateSearchResults {
    NSString *query = [self currentQuery];
    if ([query isEqualToString:self.loadedQuery]) {
        return;
    }
    [self loadQuery:query append:NO];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(updateSearchResults) object:nil];
    [self performSelector:@selector(updateSearchResults) withObject:nil afterDelay:0.5];
}

/* Loads the first page of `query`, or (append) the next page of the current results. */
- (void)loadQuery:(NSString *)query append:(BOOL)append {
    NSUInteger generation = ++self.generation;
    self.loading = YES;
    if (!append) {
        self.pageFailed = NO;
    }
    [self.spinner startAnimating];

    // The search appends to the array it is given: hand it a copy so the list on screen never changes
    // under the table view.
    NSMutableArray *previous = append ? [self.hits mutableCopy] : nil;
    NSArray<NSString *> *loaders = self.mods.info.acceptedLoaders;
    NSString *mc = self.mods.info.minecraftVersion ?: @"";
    __weak ModBrowseViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Its own client: `reachedLastPage` and `lastError` belong to this request only.
        ModrinthModsAPI *api = [ModrinthModsAPI new];
        NSMutableArray<NSDictionary *> *result = [api searchMods:query loaders:loaders gameVersion:mc previous:previous];
        BOOL reachedEnd = api.reachedLastPage;
        NSString *failure = result ? nil : (api.lastError.localizedDescription ?: @"");
        dispatch_async(dispatch_get_main_queue(), ^{
            ModBrowseViewController *strongSelf = weakSelf;
            if (!strongSelf || generation != strongSelf.generation) return;
            strongSelf.loading = NO;
            [strongSelf.spinner stopAnimating];
            NSString *message = [NSString stringWithFormat:localize(@"mods.browse.error", nil), failure ?: @""];
            if (!result) {
                if (append) {
                    strongSelf.pageFailed = YES;
                    showDialog(localize(@"Error", nil), message);
                } else {
                    strongSelf.hits = @[];
                    strongSelf.loadedQuery = nil; // so the same search is tried again
                    [strongSelf showMessage:message];
                    [strongSelf.tableView reloadData];
                }
                return;
            }
            strongSelf.hits = result;
            strongSelf.loadedQuery = query;
            strongSelf.reachedEnd = reachedEnd;
            [strongSelf showMessage:result.count == 0
                ? [NSString stringWithFormat:localize(@"mods.browse.empty", nil), strongSelf.mods.info.displayName] : nil];
            [strongSelf.tableView reloadData];
        });
    });
}

#pragma mark UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.hits.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:kHitCellID];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:kHitCellID];
        cell.imageView.frame = CGRectMake(0, 0, kIconSize, kIconSize);
        cell.imageView.isSizeFixed = YES;
        cell.imageView.layer.cornerRadius = 8;
        cell.imageView.clipsToBounds = YES;
        cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
        cell.detailTextLabel.numberOfLines = 2;
    }

    NSDictionary *hit = self.hits[indexPath.row];
    NSString *projectId = StringOrNil(hit[@"id"]) ?: @"";
    cell.textLabel.text = StringOrNil(hit[@"title"]) ?: StringOrNil(hit[@"slug"]) ?: projectId;
    NSMutableArray<NSString *> *details = [NSMutableArray new];
    NSString *description = StringOrNil(hit[@"description"]);
    if (description) [details addObject:description];
    if ([hit[@"downloads"] isKindOfClass:NSNumber.class]) [details addObject:ModFormattedDownloads(hit[@"downloads"])];
    cell.detailTextLabel.text = [details componentsJoinedByString:@" · "];

    UIImage *placeholder = [[UIImage imageNamed:@"DefaultProfile"] _imageWithSize:CGSizeMake(kIconSize, kIconSize)];
    NSString *iconUrl = StringOrNil(hit[@"imageUrl"]);
    NSURL *url = iconUrl ? [NSURL URLWithString:iconUrl] : nil;
    if (url) {
        [cell.imageView setImageWithURL:url placeholderImage:placeholder];
    } else {
        // A reused cell may still be loading another mod's icon.
        [cell.imageView cancelImageDownloadTask];
        cell.imageView.image = placeholder;
    }

    NSMutableArray<UIView *> *tags = [NSMutableArray new];
    if ([self.installedProjectIds containsObject:projectId]) {
        [tags addObject:ModTagView(localize(@"mods.tag.installed", nil), UIColor.secondaryLabelColor)];
    }
    if (ModIOSWarningForProject(projectId)) {
        [tags addObject:ModTagView(localize(@"mods.tag.ios", nil), UIColor.systemOrangeColor)];
    }
    cell.accessoryView = ModTagsAccessoryView(tags);

    // Infinite scroll: the last row asks for the next page.
    if (indexPath.row == (NSInteger)self.hits.count - 1 && !self.loading && !self.reachedEnd && !self.pageFailed && self.loadedQuery) {
        [self loadQuery:self.loadedQuery append:YES];
    }
    return cell;
}

#pragma mark UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.row >= (NSInteger)self.hits.count) {
        return;
    }
    NSDictionary *hit = self.hits[indexPath.row];
    NSString *projectId = StringOrNil(hit[@"id"]);
    if (!projectId) {
        return;
    }
    ModDetailViewController *detail = [[ModDetailViewController alloc] initWithModsController:self.mods projectId:projectId hit:hit];
    [self.navigationController pushViewController:detail animated:YES];
}

@end

NS_ASSUME_NONNULL_END
