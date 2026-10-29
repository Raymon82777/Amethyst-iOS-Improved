#import "ModProfileInfo.h"

static NSString *const kLoaderFabric = @"fabric";
static NSString *const kLoaderQuilt = @"quilt";
static NSString *const kLoaderForge = @"forge";
static NSString *const kLoaderNeoForge = @"neoforge";

#pragma mark - Helpers

static BOOL IsNumeric(NSString *string) {
    if (string.length == 0) return NO;
    NSCharacterSet *nonNumbers = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
    return [string rangeOfCharacterFromSet:nonNumbers].location == NSNotFound;
}

/* Same rule as -[ForgeInstallViewController extractMinecraftVersionFromNeoForgeVersion:]
   (kept separate because that class imports UIKit). Returns nil where it returns "Unknown".
   NeoForge versioning: [MC version without 1.].[NeoForge version][-beta/alpha]
   Example: "21.4.114-beta" for Minecraft 1.21.4
   Special case: "0.25w14craftmine.5-beta" contains snapshot "25w14craftmine" */
static NSString *MinecraftVersionFromNeoForgeVersion(NSString *version) {
    NSString *cleanVersion = version;
    NSRange hyphenRange = [version rangeOfString:@"-"];
    if (hyphenRange.location != NSNotFound) {
        cleanVersion = [version substringToIndex:hyphenRange.location];
    }

    NSRegularExpression *snapshotRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(\\d{2}w\\d{2}[a-z]*)"
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *snapshotMatch = [snapshotRegex firstMatchInString:cleanVersion options:0 range:NSMakeRange(0, cleanVersion.length)];
    if (snapshotMatch) {
        return [cleanVersion substringWithRange:snapshotMatch.range];
    }

    NSArray *components = [cleanVersion componentsSeparatedByString:@"."];
    if (components.count >= 2) {
        NSString *majorComponent = components[0];
        NSString *minorComponent = components[1];
        if (IsNumeric(majorComponent) && IsNumeric(minorComponent)) {
            return [NSString stringWithFormat:@"1.%@.%@", majorComponent, minorComponent];
        }
    }

    NSRegularExpression *versionRegex = [NSRegularExpression
        regularExpressionWithPattern:@"(\\d+\\.\\d+)"
        options:0 error:nil];
    NSTextCheckingResult *match = [versionRegex firstMatchInString:version options:0 range:NSMakeRange(0, version.length)];
    if (match) {
        NSString *extractedPart = [version substringWithRange:match.range];
        return [NSString stringWithFormat:@"1.%@", extractedPart];
    }

    return nil;
}

/* Returns the capture groups (1...n) of the first match, or nil if there is none. */
static NSArray<NSString *> *RegexCaptures(NSString *pattern, NSString *string) {
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern
        options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:string options:0 range:NSMakeRange(0, string.length)];
    if (!match) return nil;
    NSMutableArray<NSString *> *captures = [NSMutableArray arrayWithCapacity:match.numberOfRanges - 1];
    for (NSUInteger i = 1; i < match.numberOfRanges; i++) {
        NSRange range = [match rangeAtIndex:i];
        [captures addObject:range.location == NSNotFound ? @"" : [string substringWithRange:range]];
    }
    return captures;
}

/* Splits "group:artifact:version[:classifier][@ext]" into @[group, artifact, version]. */
static NSArray<NSString *> *ParseCoordinate(id name) {
    if (![name isKindOfClass:NSString.class]) return nil;
    NSArray<NSString *> *parts = [(NSString *)name componentsSeparatedByString:@":"];
    if (parts.count < 3) return nil;
    NSString *version = parts[2];
    NSRange at = [version rangeOfString:@"@"];
    if (at.location != NSNotFound) {
        version = [version substringToIndex:at.location];
    }
    return @[parts[0], parts[1], version];
}

/* Detects the loader from library coordinates. Checked in the order quilt, neoforge, forge,
   fabric. *outVersion is the coordinate's version, or nil when it cannot be trusted. */
static NSString *DetectLoaderFromLibraries(id libraries, NSString **outVersion) {
    *outVersion = nil;
    if (![libraries isKindOfClass:NSArray.class]) return nil;

    NSMutableArray<NSArray<NSString *> *> *coords = [NSMutableArray array];
    for (id library in libraries) {
        if (![library isKindOfClass:NSDictionary.class]) continue;
        NSArray<NSString *> *coord = ParseCoordinate(((NSDictionary *)library)[@"name"]);
        if (coord) [coords addObject:coord];
    }

    for (NSArray<NSString *> *c in coords) {
        if ([c[0] isEqualToString:@"org.quiltmc"] && [c[1] isEqualToString:@"quilt-loader"]) {
            *outVersion = c[2];
            return kLoaderQuilt;
        }
    }
    // The loader jar itself, as opposed to net.neoforged.* helper libraries
    for (NSArray<NSString *> *c in coords) {
        if ([c[0] isEqualToString:@"net.neoforged"] &&
            ([c[1] isEqualToString:@"neoforge"] || [c[1] isEqualToString:@"forge"])) {
            *outVersion = c[2];
            return kLoaderNeoForge;
        }
    }
    for (NSArray<NSString *> *c in coords) {
        if ([c[0] hasPrefix:@"net.neoforged"]) {
            return kLoaderNeoForge;
        }
    }
    for (NSArray<NSString *> *c in coords) {
        if ([c[0] isEqualToString:@"net.minecraftforge"] &&
            ([c[1] isEqualToString:@"forge"] || [c[1] isEqualToString:@"fmlloader"])) {
            *outVersion = c[2];
            return kLoaderForge;
        }
    }
    for (NSArray<NSString *> *c in coords) {
        if ([c[0] isEqualToString:@"net.fabricmc"] && [c[1] isEqualToString:@"fabric-loader"]) {
            *outVersion = c[2];
            return kLoaderFabric;
        }
    }
    return nil;
}

/* Detects loader, loader version and Minecraft version from the version id alone, e.g.
   "fabric-loader-0.16.5-1.21.1", "1.20.1-forge-47.2.0", "neoforge-21.4.114-beta". */
static BOOL DetectFromVersionId(NSString *versionId, NSString **outLoader, NSString **outLoaderVersion, NSString **outMinecraft) {
    NSArray<NSString *> *m = RegexCaptures(@"^(fabric|quilt)-loader-(\\d+(?:\\.\\d+)*(?:-[A-Za-z][A-Za-z0-9.]*)?)-(.+)$", versionId);
    if (m) {
        *outLoader = m[0].lowercaseString;
        *outLoaderVersion = m[1];
        *outMinecraft = m[2];
        return YES;
    }
    // "1.20.1-forge-47.2.0", legacy "1.12.2-forge1.12.2-14.23.5.2860"
    m = RegexCaptures(@"^(\\d[0-9A-Za-z.]*)-forge-?(.+)$", versionId);
    if (m) {
        *outLoader = kLoaderForge;
        *outLoaderVersion = m[1];
        *outMinecraft = m[0];
        return YES;
    }
    m = RegexCaptures(@"^neoforge-(.+)$", versionId);
    if (m) {
        *outLoader = kLoaderNeoForge;
        *outLoaderVersion = m[0];
        *outMinecraft = MinecraftVersionFromNeoForgeVersion(m[0]);
        return YES;
    }
    return NO;
}

static NSString *DisplayNameForLoader(NSString *loader) {
    if ([loader isEqualToString:kLoaderFabric]) return @"Fabric";
    if ([loader isEqualToString:kLoaderQuilt]) return @"Quilt";
    if ([loader isEqualToString:kLoaderForge]) return @"Forge";
    if ([loader isEqualToString:kLoaderNeoForge]) return @"NeoForge";
    return @"Vanilla";
}

#pragma mark - ModProfileInfo

NS_ASSUME_NONNULL_BEGIN

@interface ModProfileInfo ()
@property(nonatomic, nullable) NSString *minecraftVersion;
@property(nonatomic, nullable) NSString *loader;
@property(nonatomic, nullable) NSString *loaderVersion;
@property(nonatomic) NSArray<NSString *> *acceptedLoaders;
@property(nonatomic) NSString *displayName;
@end

NS_ASSUME_NONNULL_END

@implementation ModProfileInfo

+ (instancetype)infoForVersionId:(NSString *)versionId versionsDir:(NSString *)versionsDir {
    NSString *path = [[versionsDir stringByAppendingPathComponent:versionId]
        stringByAppendingPathComponent:[versionId stringByAppendingString:@".json"]];
    NSDictionary *json = nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:NSDictionary.class]) {
            json = parsed;
        }
    }
    return [self infoForVersionId:versionId json:json];
}

+ (instancetype)infoForVersionId:(NSString *)versionId json:(NSDictionary *)json {
    ModProfileInfo *info = [[self alloc] init];

    // Launcher aliases that resolve to vanilla at launch time
    if ([versionId isEqualToString:@"latest-release"] || [versionId isEqualToString:@"latest-snapshot"]) {
        info.acceptedLoaders = @[];
        info.displayName = DisplayNameForLoader(nil);
        return info;
    }

    NSString *loaderVersion = nil;
    NSString *loader = DetectLoaderFromLibraries(json[@"libraries"], &loaderVersion);

    NSString *idLoader = nil, *idLoaderVersion = nil, *idMinecraft = nil;
    DetectFromVersionId(versionId, &idLoader, &idLoaderVersion, &idMinecraft);
    if (!loader) {
        loader = idLoader;
        loaderVersion = idLoaderVersion;
    }

    id inherits = json[@"inheritsFrom"];
    NSString *minecraft = nil;
    if ([inherits isKindOfClass:NSString.class] && [inherits length] > 0) {
        minecraft = inherits;
    } else if (idMinecraft.length > 0) {
        minecraft = idMinecraft;
    } else if (!loader) {
        minecraft = versionId;
    }

    // Forge and NeoForge 1.20.1 coordinates carry the Minecraft version: "1.20.1-47.2.0"
    if (minecraft && ([loader isEqualToString:kLoaderForge] || [loader isEqualToString:kLoaderNeoForge])) {
        NSString *prefix = [minecraft stringByAppendingString:@"-"];
        if ([loaderVersion hasPrefix:prefix]) {
            loaderVersion = [loaderVersion substringFromIndex:prefix.length];
        }
    }

    info.loader = loader;
    info.loaderVersion = loaderVersion;
    info.minecraftVersion = minecraft;
    info.acceptedLoaders = [self acceptedLoadersForLoader:loader minecraftVersion:minecraft];
    NSString *name = DisplayNameForLoader(loader);
    info.displayName = minecraft ? [NSString stringWithFormat:@"%@ · %@", name, minecraft] : name;
    return info;
}

+ (NSArray<NSString *> *)acceptedLoadersForLoader:(NSString *)loader minecraftVersion:(NSString *)mc {
    if (!loader) return @[];
    if ([loader isEqualToString:kLoaderQuilt]) {
        return @[kLoaderQuilt, kLoaderFabric];
    }
    // NeoForge 1.20.1 is still Forge-compatible
    if ([loader isEqualToString:kLoaderNeoForge] && [mc isEqualToString:@"1.20.1"]) {
        return @[kLoaderNeoForge, kLoaderForge];
    }
    return @[loader];
}

- (BOOL)isModded {
    return self.loader != nil;
}

@end
