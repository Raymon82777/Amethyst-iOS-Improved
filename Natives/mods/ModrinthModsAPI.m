#import "ModrinthModsAPI.h"

static const NSUInteger kSearchPageSize = 50;
static const NSUInteger kProjectsPerRequest = 100;

/* A JSON string for `object` (built by NSJSONSerialization so quotes in values cannot break it). */
static NSString *JSONString(id object) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"[]";
}

/* `value` when it is a non-empty string; JSON null, numbers and the like count as missing. */
static NSString *StringOrNil(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0 ? value : nil;
}

static NSArray<NSString *> *UniqueStrings(NSArray<NSString *> *strings) {
    NSMutableArray *result = [NSMutableArray new];
    NSMutableSet *seen = [NSMutableSet new];
    for (NSString *string in strings) {
        if ([string isKindOfClass:NSString.class] && string.length > 0 && ![seen containsObject:string]) {
            [seen addObject:string];
            [result addObject:string];
        }
    }
    return result;
}

@implementation ModrinthModsAPI

- (instancetype)init {
    return [super initWithURL:@"https://api.modrinth.com/v2"];
}

/* Records an "unexpected response" error and returns nil. */
- (id)failWithBadResponse:(NSString *)endpoint {
    self.lastError = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCannotParseResponse userInfo:@{
        NSLocalizedDescriptionKey: [NSString stringWithFormat:@"Modrinth sent an unexpected answer for %@.", endpoint]
    }];
    return nil;
}

/* A path component for an id or slug: "/" and other characters special in a path are escaped. */
- (NSString *)pathComponent:(NSString *)value {
    NSMutableCharacterSet *allowed = NSCharacterSet.URLPathAllowedCharacterSet.mutableCopy;
    [allowed removeCharactersInString:@"/"];
    return [value stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: value;
}

#pragma mark Search

- (NSMutableArray<NSDictionary *> *)searchMods:(NSString *)query
                                       loaders:(NSArray<NSString *> *)loaders
                                   gameVersion:(NSString *)mc
                                      previous:(NSMutableArray *)previous {
    return [self searchProjects:query kind:ModContentKind.mods profileLoaders:loaders gameVersion:mc previous:previous];
}

- (NSMutableArray<NSDictionary *> *)searchProjects:(NSString *)query
                                              kind:(ModContentKind *)kind
                                    profileLoaders:(NSArray<NSString *> *)profileLoaders
                                       gameVersion:(NSString *)mc
                                          previous:(NSMutableArray *)previous {
    NSMutableArray *facets = [NSMutableArray arrayWithObject:@[[@"project_type:" stringByAppendingString:kind.projectType]]];
    NSArray<NSString *> *loaders = [kind searchCategoriesForProfileLoaders:profileLoaders];
    if (loaders.count > 0) {
        NSMutableArray *categories = [NSMutableArray new];
        for (NSString *loader in loaders) {
            [categories addObject:[@"categories:" stringByAppendingString:loader]];
        }
        [facets addObject:categories];
    }
    if (mc.length > 0) {
        [facets addObject:@[[@"versions:" stringByAppendingString:mc]]];
    }
    if (kind.isMods) {
        [facets addObject:@[@"client_side:required", @"client_side:optional"]];
    }

    BOOL hasQuery = query.length > 0;
    NSMutableDictionary *params = [@{
        @"facets": JSONString(facets),
        @"limit": @(kSearchPageSize),
        @"index": hasQuery ? @"relevance" : @"downloads",
        @"offset": @(previous.count)
    } mutableCopy];
    if (hasQuery) {
        params[@"query"] = query;
    }

    NSDictionary *response = [self getEndpoint:@"search" params:params];
    if (!response) {
        return nil;
    }
    if (![response isKindOfClass:NSDictionary.class] || ![response[@"hits"] isKindOfClass:NSArray.class]) {
        return [self failWithBadResponse:@"search"];
    }

    NSMutableArray *result = previous ?: [NSMutableArray new];
    NSDictionary *mapping = @{
        @"slug": @"slug", @"title": @"title", @"description": @"description",
        @"author": @"author", @"imageUrl": @"icon_url"
    };
    for (NSDictionary *hit in response[@"hits"]) {
        if (![hit isKindOfClass:NSDictionary.class] || !StringOrNil(hit[@"project_id"])) {
            continue;
        }
        NSMutableDictionary *item = [NSMutableDictionary new];
        item[@"id"] = hit[@"project_id"];
        for (NSString *key in mapping) {
            NSString *value = StringOrNil(hit[mapping[key]]);
            if (value) {
                item[key] = value;
            }
        }
        if ([hit[@"downloads"] isKindOfClass:NSNumber.class]) {
            item[@"downloads"] = hit[@"downloads"];
        }
        [result addObject:item];
    }
    NSNumber *total = [response[@"total_hits"] isKindOfClass:NSNumber.class] ? response[@"total_hits"] : @0;
    self.reachedLastPage = result.count >= total.unsignedLongValue;
    return result;
}

#pragma mark Versions and projects

- (NSArray<NSDictionary *> *)versionsOfProject:(NSString *)projectId
                                       loaders:(NSArray<NSString *> *)loaders
                                   gameVersion:(NSString *)mc {
    NSMutableDictionary *params = [NSMutableDictionary new];
    if (loaders.count > 0) {
        params[@"loaders"] = JSONString(loaders);
    }
    if (mc.length > 0) {
        params[@"game_versions"] = JSONString(@[mc]);
    }
    NSString *endpoint = [NSString stringWithFormat:@"project/%@/version", [self pathComponent:projectId]];
    id response = [self getEndpoint:endpoint params:params];
    if (!response) {
        return nil;
    }
    if (![response isKindOfClass:NSArray.class]) {
        return [self failWithBadResponse:endpoint];
    }
    return response;
}

- (NSDictionary *)versionWithId:(NSString *)versionId {
    NSString *endpoint = [NSString stringWithFormat:@"version/%@", [self pathComponent:versionId]];
    id response = [self getEndpoint:endpoint params:nil];
    if (!response) {
        return nil;
    }
    if (![response isKindOfClass:NSDictionary.class]) {
        return [self failWithBadResponse:endpoint];
    }
    return response;
}

- (NSDictionary<NSString *, NSDictionary *> *)projectsWithIds:(NSArray<NSString *> *)ids {
    NSArray<NSString *> *unique = UniqueStrings(ids);
    NSMutableDictionary *result = [NSMutableDictionary new];
    // Ids go in the URL, so a long list is asked for in several requests.
    for (NSUInteger start = 0; start < unique.count; start += kProjectsPerRequest) {
        NSRange range = NSMakeRange(start, MIN(kProjectsPerRequest, unique.count - start));
        id response = [self getEndpoint:@"projects" params:@{@"ids": JSONString([unique subarrayWithRange:range])}];
        if (!response) {
            return nil;
        }
        if (![response isKindOfClass:NSArray.class]) {
            return [self failWithBadResponse:@"projects"];
        }
        for (NSDictionary *project in response) {
            if ([project isKindOfClass:NSDictionary.class] && StringOrNil(project[@"id"])) {
                result[project[@"id"]] = project;
            }
        }
    }
    return result;
}

#pragma mark Hash lookups

- (NSDictionary<NSString *, NSDictionary *> *)postHashes:(NSDictionary *)body endpoint:(NSString *)endpoint {
    id response = [self postEndpoint:endpoint body:body];
    if (!response) {
        return nil;
    }
    if (![response isKindOfClass:NSDictionary.class]) {
        return [self failWithBadResponse:endpoint];
    }
    return response;
}

- (NSDictionary<NSString *, NSDictionary *> *)versionsForHashes:(NSArray<NSString *> *)sha1s {
    NSArray<NSString *> *hashes = UniqueStrings(sha1s);
    if (hashes.count == 0) {
        return @{};
    }
    return [self postHashes:@{@"hashes": hashes, @"algorithm": @"sha1"} endpoint:@"version_files"];
}

- (NSDictionary<NSString *, NSDictionary *> *)latestVersionsForHashes:(NSArray<NSString *> *)sha1s
                                                              loaders:(NSArray<NSString *> *)loaders
                                                          gameVersion:(NSString *)mc
                                                         versionTypes:(NSArray<NSString *> *)types {
    NSArray<NSString *> *hashes = UniqueStrings(sha1s);
    if (hashes.count == 0) {
        return @{};
    }
    NSMutableDictionary *body = [@{
        @"hashes": hashes,
        @"algorithm": @"sha1",
        @"loaders": loaders ?: @[],
        @"game_versions": mc.length > 0 ? @[mc] : @[]
    } mutableCopy];
    if (types) {
        body[@"version_types"] = types;
    }
    return [self postHashes:body endpoint:@"version_files/update"];
}

@end
