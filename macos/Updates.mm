#import "Updates.h"
#import "BundleUpdate.h"
#import <CommonCrypto/CommonDigest.h>
#import <sys/stat.h>
#include "../app/runtime.hpp"
#include "../app/updates.hpp"
#include <algorithm>
#include <charconv>
#include <cmath>
#include <memory>

using namespace transfer;
using Cancellation = std::shared_ptr<std::atomic_bool>;
namespace {
enum class Endpoint { api, page, asset };
BOOL trustedURL(NSURL *url, Endpoint endpoint) {
    NSString *host = url.host.lowercaseString;
    if (![url.scheme.lowercaseString isEqual:@"https"] || url.user || url.password ||
        (url.port && url.port.integerValue != 443)) return NO;
    if (endpoint == Endpoint::api) return [host isEqual:@"api.github.com"] &&
        [url.path isEqual:@"/repos/airanluo-dot/Bonfire/releases"];
    if (endpoint == Endpoint::asset && [host hasSuffix:@".githubusercontent.com"]) return YES;
    if (![host isEqual:@"github.com"]) return NO;
    if (endpoint == Endpoint::asset) return [url.path hasPrefix:@"/airanluo-dot/Bonfire/releases/download/"];
    return [url.path isEqual:@"/airanluo-dot/Bonfire/releases"] || [url.path isEqual:@"/airanluo-dot/Bonfire/releases.atom"] ||
           [url.path hasPrefix:@"/airanluo-dot/Bonfire/releases/"];
}
NSString *string(const std::string& value) { return [NSString stringWithUTF8String:value.c_str()]; }
NSDictionary *object(const Json& value) {
    auto text = value.dump();
    return [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:text.data() length:text.size()] options:0 error:nil];
}
void active(Cancellation stop) { if (*stop) throw Error("UpdateFailed"); }
BOOL matches(NSURL *file, NSDictionary *plan) {
    NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:file.path error:nil];
    if (![attributes[NSFileType] isEqual:NSFileTypeRegular] ||
        [attributes[NSFileSize] unsignedLongLongValue] != [plan[@"size"] unsignedLongLongValue]) return NO;
    NSFileHandle *stream = [NSFileHandle fileHandleForReadingFromURL:file error:nil];
    if (!stream) return NO;
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    for (;;) {
        NSError *error = nil;
        NSData *chunk = [stream readDataUpToLength:1024 * 1024 error:&error];
        if (error) { [stream closeAndReturnError:nil]; return NO; }
        if (!chunk.length) break;
        CC_SHA256_Update(&context, chunk.bytes, (CC_LONG)chunk.length);
    }
    [stream closeAndReturnError:nil];
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &context);
    NSMutableString *hex = [NSMutableString new];
    for (auto c : digest) [hex appendFormat:@"%02x", c];
    return [hex isEqual:plan[@"hash"]];
}
void fileFailure(NSError *error) {
    if ([error.domain isEqual:NSCocoaErrorDomain]) {
        if (error.code == NSFileWriteOutOfSpaceError) throw Error("UpdateDiskFull");
        if (error.code == NSFileReadNoPermissionError || error.code == NSFileWriteNoPermissionError ||
            error.code == NSFileWriteVolumeReadOnlyError) throw Error("UpdatePermission");
    }
    throw Error("UpdateDownloadFailed");
}
NSDate *rateReset(NSHTTPURLResponse *response) {
    NSString *after = [response valueForHTTPHeaderField:@"Retry-After"];
    NSDate *when = nil;
    if (after.length) {
        NSScanner *scanner = [NSScanner scannerWithString:after];
        long long seconds = 0;
        if ([scanner scanLongLong:&seconds] && scanner.isAtEnd && seconds >= 0)
            when = [NSDate dateWithTimeIntervalSinceNow:seconds];
        else {
            NSDateFormatter *http = [NSDateFormatter new];
            http.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
            http.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
            http.dateFormat = @"EEE',' dd MMM yyyy HH':'mm':'ss z";
            when = [http dateFromString:after];
        }
    }
    if (!when) {
        double epoch = [[response valueForHTTPHeaderField:@"X-RateLimit-Reset"] doubleValue];
        if (epoch > 0) when = [NSDate dateWithTimeIntervalSince1970:epoch];
    }
    return when.timeIntervalSinceNow > 0 && when.timeIntervalSince1970 < 253402300799.0 ? when : nil;
}
void responseFailure(NSHTTPURLResponse *response, NSError *error, Endpoint endpoint) {
    if (error || ![response isKindOfClass:NSHTTPURLResponse.class]) {
        if ([error.domain isEqual:NSURLErrorDomain]) {
            if (error.code == NSURLErrorTimedOut) throw Error("UpdateTimeout");
            if (error.code == NSURLErrorHTTPTooManyRedirects) throw Error("UpdateIntegrity");
            if (error.code <= NSURLErrorSecureConnectionFailed && error.code >= NSURLErrorClientCertificateRequired)
                throw Error("UpdateTls");
        }
        if ([error.domain isEqual:NSCocoaErrorDomain]) fileFailure(error);
        throw Error("UpdateNetwork");
    }
    if (!trustedURL(response.URL, endpoint)) throw Error("UpdateIntegrity");
    NSInteger status = response.statusCode;
    if (status >= 300 && status < 400) throw Error("UpdateIntegrity");
    if (status == 429 || (status == 403 &&
        ([[response valueForHTTPHeaderField:@"X-RateLimit-Remaining"] isEqual:@"0"] ||
         [response valueForHTTPHeaderField:@"Retry-After"] != nil))) {
        NSDate *when = rateReset(response);
        if (when) throw Error("UpdateRateLimited", {std::to_string((int64_t)when.timeIntervalSince1970)});
        throw Error("UpdateRateLimited");
    }
    if (status != 200) throw Error("UpdateHttp", {std::to_string(status)});
}
BOOL canTryReleasePage(const Error& error) {
    std::string key = error.what();
    if (key == "UpdateNetwork" || key == "UpdateTimeout" || key == "UpdateRateLimited") return YES;
    return key == "UpdateHttp" && !error.arguments.empty() && error.arguments[0].size() == 3 && error.arguments[0][0] == '5';
}
NSString *releaseTag(NSString *href) {
    NSString *prefix = @"https://github.com/airanluo-dot/Bonfire/releases/tag/";
    if (![href hasPrefix:prefix]) return nil;
    NSString *tag = [href substringFromIndex:prefix.length];
    if (!tag.length || [tag rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"/?#%"]].location != NSNotFound) return nil;
    return tag;
}

}

@interface BFUpdateRedirect : NSObject <NSURLSessionTaskDelegate>
@end
@implementation BFUpdateRedirect
- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task willPerformHTTPRedirection:(NSHTTPURLResponse*)response
        newRequest:(NSURLRequest*)request completionHandler:(void(^)(NSURLRequest*))completion {
    NSURL *original = task.originalRequest.URL;
    Endpoint scope = [original.host.lowercaseString isEqual:@"api.github.com"] ? Endpoint::api :
        ([original.path hasPrefix:@"/airanluo-dot/Bonfire/releases/download/"] ? Endpoint::asset : Endpoint::page);
    completion(trustedURL(request.URL,scope) ? request : nil);
}
@end

@interface BFReleaseFeed : NSObject <NSXMLParserDelegate>
@property(nonatomic) NSUInteger depth;
@property(nonatomic) BOOL feed, entry, linked, invalid;
@property(nonatomic,strong) NSMutableArray<NSString*> *tags;
@end
@implementation BFReleaseFeed
- (void)parser:(NSXMLParser*)parser didStartElement:(NSString*)name namespaceURI:(NSString*)ns
 qualifiedName:(NSString*)qualified attributes:(NSDictionary<NSString*,NSString*>*)attributes {
    ++_depth;
    BOOL atom = [ns isEqual:@"http://www.w3.org/2005/Atom"];
    if (_depth == 1) _feed = atom && [name isEqual:@"feed"];
    if (_depth == 2) {
        _entry = _feed && atom && [name isEqual:@"entry"];
        _linked = NO;
    }
    if (_entry && _depth == 3 && atom && [name isEqual:@"link"] &&
        (!attributes[@"rel"] || [attributes[@"rel"] isEqual:@"alternate"])) {
        NSString *tag = releaseTag(attributes[@"href"]);
        if (tag) { [_tags addObject:tag]; _linked = YES; }
        else _invalid = YES;
    }
}
- (void)parser:(NSXMLParser*)parser didEndElement:(NSString*)name namespaceURI:(NSString*)ns qualifiedName:(NSString*)qualified {
    if (_depth == 2) {
        if (_entry && !_linked) _invalid = YES;
        _entry = NO;
    }
    --_depth;
}
@end
// Preserve unrelated downloads and reuse previously verified copies, including after restarting Bonfire.
namespace {
NSURL *destination(NSURL *directory, NSDictionary *plan, BOOL& exists, Cancellation stop) {
    if (!directory) throw Error("UpdatePermission");
    NSString *name = plan[@"name"];
    for (NSUInteger index = 1;; ++index) {
        active(stop);
        NSString *file = index == 1 ? name : [NSString stringWithFormat:@"%@ (%lu).%@",
            name.stringByDeletingPathExtension, (unsigned long)index, name.pathExtension];
        NSURL *path = [directory URLByAppendingPathComponent:file];
        struct stat info{};
        if (lstat(path.fileSystemRepresentation, &info) != 0) {
            if (errno != ENOENT) throw Error("UpdatePermission");
            exists = NO; return path;
        }
        if (S_ISREG(info.st_mode) && matches(path, plan)) { exists = YES; return path; }
    }
}
}
@implementation BFUpdates {
    BFPrefs *_prefs;
    Cancellation _stop;
    NSURLSession *_session;
    NSString *_originalIdentity;
    BOOL _pendingManual, _pendingAutomatic, _automaticDownload;
}
+ (NSString*)version { return [NSBundle.mainBundle objectForInfoDictionaryKey:@"BonfireVersion"]; }
- (NSString*)currentVersion { return BFUpdates.version; }
- (NSURL*)downloadsDirectory {
    return [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
}
- (instancetype)initWithPreferences:(BFPrefs*)prefs {
    if ((self = [super init])) {
        _prefs = prefs;
        _stop = std::make_shared<std::atomic_bool>(false);
        _status = @"UpdateIdle";
        _statusArguments = @[];
        _originalIdentity = BFApplicationIdentity(NSBundle.mainBundle.bundleURL);
        NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
        config.URLCache = nil;
        config.HTTPCookieStorage = nil;
        config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        config.timeoutIntervalForRequest = 60;
        config.timeoutIntervalForResource = 480;
        config.HTTPAdditionalHeaders = @{@"User-Agent":[@"Bonfire/" stringByAppendingString:[self currentVersion] ?: @"test"]};
        _session = [NSURLSession sessionWithConfiguration:config delegate:[BFUpdateRedirect new] delegateQueue:nil];
    }
    return self;
}
- (void)dealloc { [_session invalidateAndCancel]; }
- (BOOL)installed {
    NSString *parent = NSBundle.mainBundle.bundleURL.URLByDeletingLastPathComponent.path;
    return [parent isEqual:@"/Applications"] || [parent isEqual:[NSHomeDirectory() stringByAppendingPathComponent:@"Applications"]];
}
- (BOOL)canCancel { return _busy && !_installing; }
- (void)emit:(NSString*)status {
    _status = status;
    _statusArguments = @[];
    _retryAfter = nil;
    if (_changed) _changed();
}
- (void)cancel {
    if (_installing) return;
    *_stop = true;
    _stop = std::make_shared<std::atomic_bool>(false);
    _busy = NO;
    _retryAction = nil;
    _pendingManual = _pendingAutomatic = _automaticDownload = NO;
    [self emit:@"UpdateCancelled"];
}
- (void)perform:(NSString*)action status:(NSString*)phase work:(id(^)(Cancellation))work finish:(void(^)(id))finish {
    if (_busy || _needsReopen) return;
    _busy = YES;
    _retryAction = nil;
    Cancellation stop = _stop;
    [self emit:phase];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{@autoreleasepool {
        id value = nil;
        NSString *error = nil;
        NSMutableArray *arguments = [NSMutableArray new];
        try { active(stop); value = work(stop); }
        catch (const Error& e) {
            error = string(e.what());
            for (const auto& arg : e.arguments) [arguments addObject:string(arg)];
        } catch (...) { error = @"UpdateFailed"; }
        dispatch_async(dispatch_get_main_queue(), ^{
            if (*stop) return;
            self->_busy = NO;
            if (!error) { finish(value); return; }
            self->_installing = self->_automaticDownload = NO;
            self->_retryAction = action;
            if ([action isEqual:@"check"] && ([error isEqual:@"UpdateIntegrity"] || [error isEqual:@"UpdateInvalidFeed"] ||
                                               [error isEqual:@"UpdateMissing"])) {
                self->_candidate = nil;
                self->_download = nil;
            }
            if ([action isEqual:@"install"] && ([error isEqual:@"UpdateIntegrity"] || [error isEqual:@"UpdateDownloadedMissing"])) {
                self->_download = nil;
                self->_retryAction = @"download";
            }
            if ([error isEqual:@"UpdateTargetChanged"]) self->_needsReopen = YES;
            self->_status = error;
            self->_statusArguments = arguments;
            if ([error isEqual:@"UpdateRateLimited"] && arguments.count)
                self->_retryAfter = [NSDate dateWithTimeIntervalSince1970:[arguments.firstObject doubleValue]];
            if (self.changed) self.changed();
        });
    }});
}

- (NSHTTPURLResponse*)get:(NSURL*)url limit:(NSUInteger)limit endpoint:(Endpoint)endpoint progress:(BOOL)showProgress stop:(Cancellation)stop
       read:(void(^)(NSURL*, NSError**))read {
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block NSError *network = nil, *fileError = nil;
    __block NSHTTPURLResponse *response = nil;
    __block BOOL oversized = NO;
    NSURLSessionDownloadTask *task = [_session downloadTaskWithURL:url completionHandler:^(NSURL *file, NSURLResponse *raw, NSError *error) {
        response = (NSHTTPURLResponse*)raw;
        network = error;
        if (!*stop && !error && [raw isKindOfClass:NSHTTPURLResponse.class] && response.statusCode == 200 && file) {
            NSNumber *size = nil;
            NSError *local = nil;
            if ([file getResourceValue:&size forKey:NSURLFileSizeKey error:&local]) {
                oversized = !size || size.unsignedLongLongValue > limit;
                if (!oversized) read(file, &local);
            }
            fileError = local;
        }
        dispatch_semaphore_signal(ready);
    }];
    [task resume];
    double last = -1;
    BOOL exceeded = NO;
    while (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5))) {
        int64_t received = task.countOfBytesReceived;
        if (received > (int64_t)limit) exceeded = YES;
        if (*stop || exceeded) { [task cancel]; continue; }
        if (showProgress && received >= 0) {
            double percent = std::floor(100.0 * received / limit);
            if (percent != last) {
                last = percent;
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!*stop && [self.status isEqual:@"UpdateDownloading"]) {
                        self->_progress = percent;
                        if (self.progressChanged) self.progressChanged();
                    }
                });
            }
        }
    }
    active(stop);
    if (exceeded || oversized) throw Error(endpoint == Endpoint::asset ? "UpdateIntegrity" : "UpdateInvalidFeed");
    responseFailure(response, network, endpoint);
    if (fileError) fileFailure(fileError);
    return response;
}
- (NSData*)body:(NSURL*)url limit:(NSUInteger)limit endpoint:(Endpoint)endpoint stop:(Cancellation)stop {
    __block NSData *body = nil;
    NSHTTPURLResponse *response = [self get:url limit:limit endpoint:endpoint progress:NO stop:stop read:^(NSURL *file,NSError **error) {
        body = [NSData dataWithContentsOfURL:file options:NSDataReadingMappedIfSafe error:error];
    }];
    if (endpoint != Endpoint::asset && ![response.URL isEqual:url]) throw Error("UpdateIntegrity");
    if (!body.length) throw Error(endpoint == Endpoint::asset ? "UpdateIntegrity" : "UpdateInvalidFeed");
    return body;
}
- (NSHTTPURLResponse*)head:(NSURL*)url endpoint:(Endpoint)endpoint stop:(Cancellation)stop {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"HEAD";
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block NSHTTPURLResponse *response = nil;
    __block NSError *failure = nil;
    NSURLSessionDataTask *task = [_session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *raw,NSError *error) {
        response = (NSHTTPURLResponse*)raw; failure = error; dispatch_semaphore_signal(ready);
    }];
    [task resume];
    while (dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 5))) if (*stop) [task cancel];
    active(stop);
    responseFailure(response, failure, endpoint);
    return response;
}
- (NSDictionary*)releasePlan:(NSString*)channel stop:(Cancellation)stop {
    try {
        Json releases = Json::array();
        auto feed = request({{"op","updateFeed"}}, *stop).get<std::string>();
        for (size_t page = 1;; ++page) {
            NSString *address = [NSString stringWithFormat:@"%@?per_page=100&page=%zu", string(feed), page];
            NSData *body = [self body:[NSURL URLWithString:address] limit:16 * 1024 * 1024 endpoint:Endpoint::api stop:stop];
            const char *p = (const char*)body.bytes;
            auto items = Json::parse(p, p + body.length, nullptr, false);
            if (!items.is_array()) throw Error("UpdateInvalidFeed");
            for (auto& item : items) releases.push_back(std::move(item));
            if (items.size() < 100) break;
        }
        return object(selectUpdate({{"current", [self currentVersion].UTF8String}, {"channel", channel.UTF8String},
            {"kind","macOS-arm64-Portable.zip"}, {"releases",std::move(releases)}}));
    } catch (const Error& e) {
        active(stop);
        if (!canTryReleasePage(e)) throw;
        try { return [self webPlan:channel stop:stop]; }
        catch (const Error& fallback) {
            if (std::string(e.what()) == "UpdateRateLimited" && !e.arguments.empty() && canTryReleasePage(fallback))
                throw e;
            throw;
        }
    }
}
- (NSDictionary*)webPlan:(NSString*)channel stop:(Cancellation)stop {
    Json query = {{"op","webUpdate"}, {"current", [self currentVersion].UTF8String}, {"channel", channel.UTF8String},
                  {"kind","macOS-arm64-Portable.zip"}, {"tags",Json::array()}};
    if ([channel isEqual:@"Stable"]) {
        NSURL *url = [NSURL URLWithString:@"https://github.com/airanluo-dot/Bonfire/releases/latest"];
        NSString *finalURL = [self head:url endpoint:Endpoint::page stop:stop].URL.absoluteString;
        NSString *tag = releaseTag(finalURL);
        if (tag) query["tags"].push_back(tag.UTF8String);
        else if (![finalURL isEqual:@"https://github.com/airanluo-dot/Bonfire/releases"]) throw Error("UpdateInvalidFeed");
    } else {
        NSURL *url = [NSURL URLWithString:@"https://github.com/airanluo-dot/Bonfire/releases.atom"];
        NSData *body = [self body:url limit:2 * 1024 * 1024 endpoint:Endpoint::page stop:stop];
        NSString *xml = [[NSString alloc] initWithData:body encoding:NSUTF8StringEncoding];
        const char zero = 0;
        if (!xml || [xml rangeOfString:@"<!DOCTYPE" options:NSCaseInsensitiveSearch].location != NSNotFound ||
            [body rangeOfData:[NSData dataWithBytes:&zero length:1] options:0 range:NSMakeRange(0,body.length)].location != NSNotFound)
            throw Error("UpdateInvalidFeed");
        NSXMLParser *parser = [[NSXMLParser alloc] initWithData:body];
        BFReleaseFeed *feed = [BFReleaseFeed new]; feed.tags = [NSMutableArray new];
        parser.delegate = feed;
        parser.shouldProcessNamespaces = YES;
        parser.shouldResolveExternalEntities = NO;
        parser.externalEntityResolvingPolicy = NSXMLParserResolveExternalEntitiesNever;
        if (![parser parse] || !feed.feed || feed.invalid) throw Error("UpdateInvalidFeed");
        for (NSString *tag in feed.tags) query["tags"].push_back(tag.UTF8String);
    }
    bool missing = false;
    for (;;) {
        active(stop);
        auto stub = request(query, *stop);
        if (stub.empty()) {
            if (missing) throw Error("UpdateMissing");
            return @{};
        }
        try {
            Json verified = query;
            NSURL *manifest = [NSURL URLWithString:string(stub.at("checksumsUrl").get<std::string>())];
            NSData *data = [self body:manifest limit:64 * 1024 endpoint:Endpoint::asset stop:stop];
            NSString *checksums = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (!checksums) throw Error("UpdateIntegrity");
            verified["checksums"] = std::string((const char*)data.bytes, data.length);
            NSURL *asset = [NSURL URLWithString:string(stub.at("url").get<std::string>())];
            NSHTTPURLResponse *head = [self head:asset endpoint:Endpoint::asset stop:stop];
            std::string length = [head valueForHTTPHeaderField:@"Content-Length"].UTF8String ?: "";
            int64_t size = 0;
            auto parsed = std::from_chars(length.data(), length.data() + length.size(), size);
            if (parsed.ec != std::errc{} || parsed.ptr != length.data() + length.size() || size <= 0) throw Error("UpdateIntegrity");
            verified["size"] = size;
            return object(request(verified,*stop));
        } catch (const Error& error) {
            const std::string key = error.what();
            if (key != "UpdateMissing" && !(key == "UpdateHttp" && error.arguments == std::vector<std::string>{"404"})) throw;
            missing = true;
            auto& tags = query["tags"];
            tags.erase(std::remove(tags.begin(), tags.end(), stub.at("tag")), tags.end());
        }
    }
}
- (void)check {
    if (_busy || _needsReopen) return;
    NSString *channel = [_prefs.channel copy];
    _pendingAutomatic = _pendingManual = NO;
    [self perform:@"check" status:@"UpdateChecking" work:^id(Cancellation stop) {
        NSDictionary *plan = [self releasePlan:channel stop:stop];
        if (!plan[@"url"]) return @[];
        BOOL exists = NO;
        NSURL *file = destination([self downloadsDirectory], plan, exists, stop);
        return exists ? @[plan, file] : @[plan];
    } finish:^(NSArray *result) {
        self->_prefs.lastCheck = NSDate.date;
        [self->_prefs save];
        self->_candidate = result.firstObject;
        self->_download = result.count == 2 ? result.lastObject : nil;
        if (!self->_candidate) { [self emit:@"UpdateCurrent"]; return; }
        if (self->_download) { [self ready]; return; }
        [self emit:@"UpdateAvailable"];
        if (self->_prefs.autoDownload) [self downloadAutomatic:YES];
    }];
}
- (void)ready {
    _pendingAutomatic = _prefs.autoInstall;
    [self emit:@"UpdateReady"];
    [self applyAutomaticIfReady];
}
- (void)downloadUpdate { [self downloadAutomatic:NO]; }
- (void)downloadAutomatic:(BOOL)automatic {
    if (_busy || !_candidate || _needsReopen) return;
    _automaticDownload = automatic;
    _progress = 0;
    NSDictionary *plan = _candidate;
    [self perform:@"download" status:@"UpdateDownloading" work:^id(Cancellation stop) {
        NSFileManager *fm = NSFileManager.defaultManager;
        BOOL exists = NO;
        NSURL *directory = [self downloadsDirectory];
        NSURL *final = destination(directory, plan, exists, stop);
        if (exists) return final;
        NSURL *partial = [final.URLByDeletingLastPathComponent URLByAppendingPathComponent:
            [NSString stringWithFormat:@".bonfire-%@.partial", NSUUID.UUID.UUIDString]];
        @try {
            [self get:[NSURL URLWithString:plan[@"url"]] limit:[plan[@"size"] unsignedIntegerValue] endpoint:Endpoint::asset progress:YES stop:stop
                 read:^(NSURL *file, NSError **error) { [fm moveItemAtURL:file toURL:partial error:error]; }];
            dispatch_async(dispatch_get_main_queue(), ^{ if (!*stop) [self emit:@"UpdateVerifying"]; });
            if (!matches(partial,plan)) throw Error("UpdateIntegrity");
            for (;;) {
                active(stop);
                NSError *error = nil;
                if ([fm moveItemAtURL:partial toURL:final error:&error]) return final;
                if (![error.domain isEqual:NSCocoaErrorDomain] || error.code != NSFileWriteFileExistsError) fileFailure(error);
                final = destination(directory, plan, exists, stop);
                if (exists) return final;
            }
        } @finally { [fm removeItemAtURL:partial error:nil]; }
    } finish:^(NSURL *file) {
        self->_automaticDownload = NO;
        self->_download = file;
        [self ready];
    }];
}
- (void)install {
    if (_busy || !_download || _needsReopen) return;
    _pendingManual = YES;
    [self applyAutomaticIfReady];
}
- (void)applyAutomaticIfReady {
    if (_busy || !_download || _needsReopen || !(_pendingManual || (_pendingAutomatic && _prefs.autoInstall))) return;
    if (_canInstall && !_canInstall()) { [self emit:@"UpdateWait"]; return; }
    _pendingManual = _pendingAutomatic = NO;
    NSURL *current = NSBundle.mainBundle.bundleURL;
    if ([current.path containsString:@"/AppTranslocation/"] ||
        ![NSFileManager.defaultManager isWritableFileAtPath:current.URLByDeletingLastPathComponent.path]) {
        [self emit:@"UpdateManualMac"]; return;
    }
    NSURL *archive = _download;
    NSDictionary *plan = _candidate;
    _installing = YES;
    [self perform:@"install" status:@"UpdateInstalling" work:^id(Cancellation stop) {
        BFReplaceApplication(archive, current, plan[@"version"], self->_originalIdentity,
                             ^BOOL(NSURL *file) { return matches(file,plan); });
        return @YES;
    } finish:^(id result) {
        self->_needsReopen = YES;
        NSWorkspaceOpenConfiguration *config = NSWorkspaceOpenConfiguration.configuration;
        config.createsNewApplicationInstance = YES;
        [NSWorkspace.sharedWorkspace openApplicationAtURL:current configuration:config completionHandler:^(NSRunningApplication *app,NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_installing = NO;
                if (app) [NSApp terminate:nil]; else [self emit:@"UpdateRelaunch"];
            });
        }];
    }];
}
- (void)preferencesChanged:(NSString*)key {
    if ([key isEqual:@"channel"]) {
        if (_installing || _needsReopen) return;
        _download = nil;
        _candidate = nil;
        _prefs.lastCheck = nil;
        [_prefs save];
        if (_busy) [self cancel];
        _pendingAutomatic = _pendingManual = NO;
        _retryAction = nil;
        if (_prefs.autoCheck) [self check];
        else [self emit:@"UpdateIdle"];
    } else if ([key isEqual:@"autoInstall"]) {
        _pendingAutomatic = _prefs.autoInstall && _download;
        if (_pendingAutomatic) [self applyAutomaticIfReady];
        else if (!_pendingManual && [_status isEqual:@"UpdateWait"]) [self emit:@"UpdateReady"];
    } else if ([key isEqual:@"autoDownload"]) {
        if (!_prefs.autoDownload && _automaticDownload) [self cancel];
        else if (_prefs.autoDownload && _candidate && !_download && !_busy) [self downloadAutomatic:YES];
    }
}
- (void)reveal {
    if (!_download) return;
    if (![NSFileManager.defaultManager fileExistsAtPath:_download.path]) {
        _download = nil;
        _retryAction = @"download";
        [self emit:@"UpdateDownloadedMissing"]; return;
    }
    [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[_download]];
}
@end
