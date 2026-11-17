#import "Updates.h"
#import "BundleUpdate.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/stdio.h>
#include "../app/runtime.hpp"
#include "../app/updates.hpp"
#include <memory>

using namespace transfer;
using Cancellation=std::shared_ptr<std::atomic_bool>;
namespace {
NSString *string(const std::string& value){return [NSString stringWithUTF8String:value.c_str()];}
Json json(id object){
    NSData *data=[NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    return Json::parse((const char*)data.bytes,(const char*)data.bytes+data.length);
}
NSDictionary *object(const Json& value){
    auto text=value.dump();NSData *data=[NSData dataWithBytes:text.data() length:text.size()];
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}
void require(BOOL value,const char* key){if(!value)throw Error(key);}
BOOL matches(NSURL *file,NSDictionary *candidate){
    NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
    if(![attributes[NSFileType] isEqual:NSFileTypeRegular] || [attributes[NSFileSize] unsignedLongLongValue]!=[candidate[@"size"] unsignedLongLongValue])return NO;
    NSFileHandle *stream=[NSFileHandle fileHandleForReadingFromURL:file error:nil];if(!stream)return NO;
    CC_SHA256_CTX context;CC_SHA256_Init(&context);
    for(;;){
        NSError *error=nil;NSData *chunk=[stream readDataUpToLength:1024*1024 error:&error];
        if(error){[stream closeFile];return NO;}if(!chunk.length)break;CC_SHA256_Update(&context,chunk.bytes,(CC_LONG)chunk.length);
    }
    [stream closeFile];unsigned char digest[32];CC_SHA256_Final(digest,&context);
    NSMutableString *hex=[NSMutableString new];for(auto c:digest)[hex appendFormat:@"%02x",c];
    return [hex isEqual:candidate[@"hash"]];
}
}
@implementation BFUpdates{
    BFPrefs *_prefs;
    Cancellation _stop;
    NSURLSession *_session;
}
+ (NSString*)version{return [NSBundle.mainBundle objectForInfoDictionaryKey:@"BonfireVersion"];}
- (instancetype)initWithPreferences:(BFPrefs*)prefs{
    if((self=[super init])){
        _prefs=prefs;_stop=std::make_shared<std::atomic_bool>(false);_status=@"UpdateIdle";
        NSURLSessionConfiguration *config=NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.URLCache=nil;config.HTTPCookieStorage=nil;config.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
        config.timeoutIntervalForRequest=60;config.timeoutIntervalForResource=480;
        config.HTTPAdditionalHeaders=@{@"User-Agent":[@"Bonfire/" stringByAppendingString:BFUpdates.version]};
        _session=[NSURLSession sessionWithConfiguration:config];
    }return self;
}
- (BOOL)installed{return [NSBundle.mainBundle.bundleURL.path.stringByDeletingLastPathComponent isEqual:@"/Applications"];}
- (void)emit:(NSString*)status{_status=status;if(_changed)_changed();}
- (void)cancel{
    if(_installing)return;
    *_stop=true;_stop=std::make_shared<std::atomic_bool>(false);
    _busy=NO;_candidate=nil;_download=nil;[self emit:@"UpdateIdle"];
}
- (void)perform:(id(^)(Cancellation))operation finish:(void(^)(id))finish{
    if(_busy)return;_busy=YES;Cancellation stop=_stop;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0),^{@autoreleasepool{
        id value=nil;NSString *error=nil;
        try{value=operation(stop);}catch(const Error& e){error=string(e.what());}catch(...){error=@"UpdateFailed";}
        dispatch_async(dispatch_get_main_queue(),^{
            if(*stop)return;self->_busy=NO;
            if(error){self->_installing=NO;[self emit:error];}else finish(value);
        });
    }});
}
- (NSData*)fetch:(NSURL*)url stop:(Cancellation)stop{
    dispatch_semaphore_t ready=dispatch_semaphore_create(0);__block NSData *body=nil;__block NSHTTPURLResponse *response=nil;
    NSURLSessionDataTask *task=[_session dataTaskWithURL:url completionHandler:^(NSData *data,NSURLResponse *r,NSError *error){
        body=data;response=(NSHTTPURLResponse*)r;dispatch_semaphore_signal(ready);
    }];
    [task resume];
    while(dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC))){
        if(*stop){[task cancel];throw Error("UpdateFailed");}
    }
    require(!*stop && response.statusCode==200 && body.length<=16*1024*1024,"UpdateFailed");return body;
}
- (void)check{
    if(_busy)return;_candidate=nil;_download=nil;[self emit:@"UpdateChecking"];
    NSString *channel=[_prefs.channel copy];
    [self perform:^id(Cancellation stop){
        Json releases=Json::array();
        std::string feed=request({{"op","updateFeed"}},*stop).get<std::string>();
        for(int page=1;;++page){
            NSString *address=[NSString stringWithFormat:@"%@?per_page=100&page=%d",string(feed),page];
            NSData *data=[self fetch:[NSURL URLWithString:address] stop:stop];
            NSArray *items=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];require([items isKindOfClass:NSArray.class],"UpdateFailed");
            for(id item:items)releases.push_back(json(item));
            if(items.count<100)break;
        }
        return object(selectUpdate({{"current",BFUpdates.version.UTF8String},{"channel",channel.UTF8String},
            {"kind","macOS-arm64-Portable.zip"},{"releases",releases}}));
    } finish:^(NSDictionary *plan){
        self->_prefs.lastCheck=NSDate.date;[self->_prefs save];
        if(!plan[@"url"]){[self emit:@"UpdateCurrent"];return;}
        self->_candidate=plan;[self emit:@"UpdateAvailable"];
        if(self->_prefs.autoDownload)[self downloadAutomatic:YES];
    }];
}
- (NSURL*)downloadFile:(NSDictionary*)plan stop:(Cancellation)stop{
    NSFileManager *fm=NSFileManager.defaultManager;
    NSURL *directory=[fm URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *destination=[directory URLByAppendingPathComponent:plan[@"name"]];
    if([fm fileExistsAtPath:destination.path]){require(matches(destination,plan),"UpdateCollision");return destination;}
    NSURL *partial=[directory URLByAppendingPathComponent:[NSString stringWithFormat:@".bonfire-%@.partial",NSUUID.UUID.UUIDString]];
    dispatch_semaphore_t ready=dispatch_semaphore_create(0);
    __block BOOL valid=NO;
    NSURLSessionDownloadTask *task=[_session downloadTaskWithURL:[NSURL URLWithString:plan[@"url"]]
        completionHandler:^(NSURL *temporary,NSURLResponse *response,NSError *error){
            NSString *host=response.URL.host;
            BOOL allowed=[response.URL.scheme isEqual:@"https"] && ([host isEqual:@"github.com"]||[host hasSuffix:@".githubusercontent.com"]);
            if(!*stop && !error && allowed && ((NSHTTPURLResponse*)response).statusCode==200 &&
               matches(temporary,plan))valid=[fm moveItemAtURL:temporary toURL:partial error:nil];
            dispatch_semaphore_signal(ready);
        }];
    [task resume];
    while(dispatch_semaphore_wait(ready,dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC)))if(*stop)[task cancel];
    @try{
        require(valid && !*stop,"UpdateIntegrity");require([fm moveItemAtURL:partial toURL:destination error:nil],"UpdateFailed");
    }@finally{[fm removeItemAtURL:partial error:nil];}
    return destination;
}
- (void)downloadUpdate{[self downloadAutomatic:NO];}
- (void)downloadAutomatic:(BOOL)automatic{
    if(_busy||!_candidate)return;[self emit:@"UpdateDownloading"];NSDictionary *plan=_candidate;
    [self perform:^id(Cancellation stop){return [self downloadFile:plan stop:stop];} finish:^(NSURL *file){
        self->_download=file;[self emit:@"UpdateReady"];
        if(automatic && self->_prefs.autoInstall && (!self.canInstall||self.canInstall()))[self install];
    }];
}
- (void)install{
    if(_busy||!_download||!_candidate)return;
    if(_canInstall&&!_canInstall()){[self emit:@"UpdateWait"];return;}
    NSURL *current=NSBundle.mainBundle.bundleURL;NSFileManager *fm=NSFileManager.defaultManager;
    // Gatekeeper translocated apps and read-only disk images require relocation first.
    if([current.path containsString:@"/AppTranslocation/"]||![fm isWritableFileAtPath:current.URLByDeletingLastPathComponent.path]){
        [self emit:@"UpdateManualMac"];return;
    }
    NSURL *archive=_download;NSDictionary *plan=_candidate;
    _installing=YES;[self emit:@"UpdateInstalling"];
    [self perform:^id(Cancellation stop){
        require(matches(archive,plan),"UpdateIntegrity");
        BFReplaceApplication(archive,current,plan[@"version"]);return @YES;
    } finish:^(id result){
        self->_installing=NO;
        if(!result){[self emit:@"UpdateFailed"];return;}
        NSWorkspaceOpenConfiguration *configuration=[NSWorkspaceOpenConfiguration configuration];configuration.createsNewApplicationInstance=YES;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:current configuration:configuration completionHandler:^(NSRunningApplication *app,NSError *error){
            dispatch_async(dispatch_get_main_queue(),^{if(app)[NSApp terminate:nil];else [self emit:@"UpdateRelaunch"];});
        }];
    }];
}
- (void)reveal{if(_download)[NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[_download]];}
@end
