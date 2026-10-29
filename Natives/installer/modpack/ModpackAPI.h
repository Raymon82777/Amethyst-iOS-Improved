#import <Foundation/Foundation.h>
#import "ModpackUtils.h"
#import "UnzipKit.h"

@class MinecraftResourceDownloadTask;

@interface ModpackAPI : NSObject
@property(nonatomic) NSString *baseURL;
@property(nonatomic) NSError *lastError;
@property(nonatomic) BOOL reachedLastPage;

- (instancetype)initWithURL:(NSString *)url;
- (NSMutableArray *)searchModWithFilters:(NSDictionary *)filters previousPageResult:(NSMutableArray *)prevResult;
- (void)loadDetailsOfMod:(NSMutableDictionary *)item;

- (void)installModpackFromDetail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;
- (void)downloader:(MinecraftResourceDownloadTask *)downloader submitDownloadTasksFromPackage:(NSString *)packagePath toPath:(NSString *)destPath;

/* The User-Agent sent with every request (GET and POST): [ModInstaller userAgent]. */
+ (NSString *)userAgent;

/* Synchronous (blocks until the request finishes): never call on the main thread. */
- (id)getEndpoint:(NSString *)endpoint params:(NSDictionary *)params;
/* Synchronous like getEndpoint:, but POSTs `body` as JSON and parses the JSON response. Returns nil on
   failure with lastError set. */
- (id)postEndpoint:(NSString *)endpoint body:(NSDictionary *)body;

@end
