#import "ModVersionSelector.h"

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Helpers

/* Modrinth timestamps look like 2026-10-01T12:34:56.123456Z (sometimes without fractions).
   Unparseable or missing dates sort as the oldest. */
static NSDate *PublishedDate(NSDictionary *version) {
    static NSISO8601DateFormatter *fractional;
    static NSISO8601DateFormatter *plain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fractional = [NSISO8601DateFormatter new];
        fractional.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        plain = [NSISO8601DateFormatter new];
        plain.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });

    id value = version[@"date_published"];
    if (![value isKindOfClass:NSString.class]) return [NSDate distantPast];
    NSDate *date;
    @synchronized (fractional) {
        date = [fractional dateFromString:value] ?: [plain dateFromString:value];
    }
    return date ?: [NSDate distantPast];
}

/* release (0) beats beta (1) beats alpha (2); anything unknown ranks last. */
static NSInteger ChannelRank(NSDictionary *version) {
    id type = version[@"version_type"];
    if ([type isEqual:@"release"]) return 0;
    if ([type isEqual:@"beta"]) return 1;
    return 2;
}

static NSComparisonResult CompareNewestFirst(NSDictionary *a, NSDictionary *b) {
    return [PublishedDate(b) compare:PublishedDate(a)];
}

@implementation ModVersionSelector

+ (BOOL)version:(NSDictionary *)version fitsLoaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc {
    id versionLoaders = version[@"loaders"];
    id gameVersions = version[@"game_versions"];
    if (![versionLoaders isKindOfClass:NSArray.class] || ![gameVersions isKindOfClass:NSArray.class]) return NO;
    if (![gameVersions containsObject:mc]) return NO;
    for (NSString *loader in loaders) {
        if ([versionLoaders containsObject:loader]) return YES;
    }
    return NO;
}

+ (NSArray<NSDictionary *> *)compatibleVersionsNewestFirst:(NSArray<NSDictionary *> *)versions loaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc {
    NSMutableArray<NSDictionary *> *fitting = [NSMutableArray new];
    for (NSDictionary *version in versions) {
        if ([self version:version fitsLoaders:loaders gameVersion:mc]) {
            [fitting addObject:version];
        }
    }
    return [fitting sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return CompareNewestFirst(a, b);
    }];
}

+ (nullable NSDictionary *)bestVersionIn:(NSArray<NSDictionary *> *)versions loaders:(NSArray<NSString *> *)loaders gameVersion:(NSString *)mc {
    NSDictionary *best = nil;
    for (NSDictionary *version in [self compatibleVersionsNewestFirst:versions loaders:loaders gameVersion:mc]) {
        // Sorted newest first, so the first of each channel is its newest.
        if (!best || ChannelRank(version) < ChannelRank(best)) {
            best = version;
        }
    }
    return best;
}

+ (nullable NSDictionary *)primaryFileOfVersion:(NSDictionary *)version {
    id files = version[@"files"];
    if (![files isKindOfClass:NSArray.class]) return nil;
    NSDictionary *first = nil;
    for (id file in files) {
        if (![file isKindOfClass:NSDictionary.class]) continue;
        if ([file[@"primary"] boolValue]) return file;
        if (!first) first = file;
    }
    return first;
}

@end

NS_ASSUME_NONNULL_END
