#import "ModJarMetadata.h"
#import "UnzipKit.h"

NS_ASSUME_NONNULL_BEGIN

/* `value` when it is a usable string: not empty and not an unexpanded build placeholder like "${version}". */
static NSString * _Nullable CleanString(id _Nullable value) {
    if (![value isKindOfClass:NSString.class]) return nil;
    NSString *string = [(NSString *)value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (string.length == 0 || [string containsString:@"${"]) return nil;
    return string;
}

static NSDictionary * _Nullable Metadata(NSString * _Nullable name, NSString * _Nullable version) {
    if (!name && !version) return nil;
    NSMutableDictionary *result = [NSMutableDictionary new];
    if (name) result[@"name"] = name;
    if (version) result[@"version"] = version;
    return result;
}

static NSDictionary * _Nullable JSONObject(NSData *data) {
    id object = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    return [object isKindOfClass:NSDictionary.class] ? object : nil;
}

/* The first `key = "value"` (or 'value') at the start of a line in a TOML file. */
static NSString * _Nullable TOMLValue(NSString *toml, NSString *key) {
    NSString *pattern = [NSString stringWithFormat:@"^[ \\t]*%@[ \\t]*=[ \\t]*(?:\"([^\"\\n]*)\"|'([^'\\n]*)')", key];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:toml options:0 range:NSMakeRange(0, toml.length)];
    if (!match) return nil;
    for (NSUInteger group = 1; group <= 2; group++) {
        NSRange range = [match rangeAtIndex:group];
        if (range.location != NSNotFound) {
            return CleanString([toml substringWithRange:range]);
        }
    }
    return nil;
}

@implementation ModJarMetadata

+ (nullable NSDictionary<NSString *, NSString *> *)metadataForJarAtPath:(NSString *)path {
    NSError *error;
    UZKArchive *archive = [[UZKArchive alloc] initWithPath:path error:&error];
    if (!archive) return nil;

    NSData *data = [archive extractDataFromFile:@"fabric.mod.json" error:nil];
    if (data) {
        NSDictionary *json = JSONObject(data);
        NSDictionary *result = Metadata(CleanString(json[@"name"]), CleanString(json[@"version"]));
        if (result) return result;
    }

    data = [archive extractDataFromFile:@"quilt.mod.json" error:nil];
    if (data) {
        id loader = JSONObject(data)[@"quilt_loader"];
        if ([loader isKindOfClass:NSDictionary.class]) {
            id metadata = loader[@"metadata"];
            NSString *name = [metadata isKindOfClass:NSDictionary.class] ? CleanString(metadata[@"name"]) : nil;
            NSDictionary *result = Metadata(name, CleanString(loader[@"version"]));
            if (result) return result;
        }
    }

    for (NSString *tomlPath in @[@"META-INF/mods.toml", @"META-INF/neoforge.mods.toml"]) {
        data = [archive extractDataFromFile:tomlPath error:nil];
        if (!data) continue;
        NSString *toml = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (!toml) continue;
        // A version of "${file.jarVersion}" is filled in from the jar's manifest at runtime: treated as unknown.
        NSDictionary *result = Metadata(TOMLValue(toml, @"displayName"), TOMLValue(toml, @"version"));
        if (result) return result;
    }
    return nil;
}

@end

NS_ASSUME_NONNULL_END
