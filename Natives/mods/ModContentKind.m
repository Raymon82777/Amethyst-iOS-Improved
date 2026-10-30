#import "ModContentKind.h"

NS_ASSUME_NONNULL_BEGIN

@interface ModContentKind ()
- (instancetype)initWithType:(ModContentType)type
                  folderName:(NSString *)folderName
               fileExtension:(NSString *)fileExtension
                 projectType:(NSString *)projectType
                stringPrefix:(NSString *)stringPrefix
                listsFolders:(BOOL)listsFolders NS_DESIGNATED_INITIALIZER;
@end

@implementation ModContentKind

+ (instancetype)mods {
    static ModContentKind *kind;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kind = [[ModContentKind alloc] initWithType:ModContentTypeMods folderName:@"mods"
                                      fileExtension:@"jar" projectType:@"mod"
                                       stringPrefix:@"mods" listsFolders:NO];
    });
    return kind;
}

+ (instancetype)resourcePacks {
    static ModContentKind *kind;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kind = [[ModContentKind alloc] initWithType:ModContentTypeResourcePacks folderName:@"resourcepacks"
                                      fileExtension:@"zip" projectType:@"resourcepack"
                                       stringPrefix:@"resourcepacks" listsFolders:YES];
    });
    return kind;
}

+ (instancetype)shaderPacks {
    static ModContentKind *kind;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kind = [[ModContentKind alloc] initWithType:ModContentTypeShaderPacks folderName:@"shaderpacks"
                                      fileExtension:@"zip" projectType:@"shader"
                                       stringPrefix:@"shaderpacks" listsFolders:YES];
    });
    return kind;
}

- (instancetype)initWithType:(ModContentType)type
                  folderName:(NSString *)folderName
               fileExtension:(NSString *)fileExtension
                 projectType:(NSString *)projectType
                stringPrefix:(NSString *)stringPrefix
                listsFolders:(BOOL)listsFolders {
    self = [super init];
    if (self) {
        _type = type;
        _folderName = [folderName copy];
        _fileExtension = [fileExtension copy];
        _projectType = [projectType copy];
        _stringPrefix = [stringPrefix copy];
        _listsFolders = listsFolders;
    }
    return self;
}

- (BOOL)isMods {
    return self.type == ModContentTypeMods;
}

- (NSArray<NSString *> *)loadersForProfileLoaders:(NSArray<NSString *> *)profileLoaders {
    if (self.type == ModContentTypeResourcePacks) return @[@"minecraft"];
    if (self.type == ModContentTypeShaderPacks) return @[@"iris", @"optifine"];
    return profileLoaders;
}

- (NSArray<NSString *> *)searchCategoriesForProfileLoaders:(NSArray<NSString *> *)profileLoaders {
    if (self.type == ModContentTypeResourcePacks) return @[];
    if (self.type == ModContentTypeShaderPacks) return @[@"iris", @"optifine"];
    return profileLoaders;
}

- (NSString *)stringKey:(NSString *)suffix {
    return [NSString stringWithFormat:@"%@.%@", self.stringPrefix, suffix];
}

@end

NS_ASSUME_NONNULL_END
