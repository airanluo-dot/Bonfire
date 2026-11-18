#import "../macos/Updates.mm"
#include <stdexcept>
#include <cstdio>

// Same service entry points used by the app. The test substitutes transport
// responses and a disposable Downloads folder, leaving the native state machine intact.
transfer::Json transfer::request(const Json& input, const std::atomic_bool&) {
    if (input.at("op") == "updateFeed") return "https://api.github.com/repos/airanluo-dot/Bonfire/releases";
    if (input.at("op") == "webUpdate") return webUpdate(input);
    throw std::runtime_error("unexpected operation");
}
@interface BFTestPreferences : BFPrefs
@end
@implementation BFTestPreferences
- (void)save {}
@end
@interface BFTestUpdates : BFUpdates
@property(nonatomic,strong) NSURL *directory;
@property(nonatomic,copy) NSString *mode;
@property(atomic) NSUInteger pageRequests;
@property(nonatomic,strong) dispatch_semaphore_t gate;
@end
@implementation BFTestUpdates
- (NSString*)currentVersion { return @"0.1.0"; }
- (NSURL*)downloadsDirectory { return _directory; }
- (NSHTTPURLResponse*)head:(NSURL*)url endpoint:(Endpoint)endpoint stop:(Cancellation)stop {
    if (endpoint == Endpoint::page) {
        self.pageRequests++;
        url = [NSURL URLWithString:@"https://github.com/airanluo-dot/Bonfire/releases"];
    }
    return [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1"
                                     headerFields:@{@"Content-Length":@"3"}];
}
- (NSHTTPURLResponse*)get:(NSURL*)url limit:(NSUInteger)limit endpoint:(Endpoint)endpoint progress:(BOOL)progress
                     stop:(Cancellation)stop read:(void(^)(NSURL*, NSError**))read {
    NSString *text = nil;
    if (endpoint == Endpoint::api) {
        if ([_mode isEqual:@"hold"]) {
            dispatch_semaphore_wait(_gate, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC));
            active(stop);
        }
        if ([_mode isEqual:@"bad-feed"]) text = @"{}";
        else {
            NSHTTPURLResponse *denied = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:403 HTTPVersion:@"HTTP/1.1"
                headerFields:@{@"x-ratelimit-remaining":@"0"}];
            responseFailure(denied,nil,endpoint);
        }
    } else if (endpoint == Endpoint::page) {
        self.pageRequests++;
        text = @"<feed xmlns='http://www.w3.org/2005/Atom'>"
                "<entry><link rel='alternate' href='https://github.com/airanluo-dot/Bonfire/releases/tag/v0.3.0'/></entry>"
                "<entry><link rel='alternate' href='https://github.com/airanluo-dot/Bonfire/releases/tag/v0.2.0'/></entry></feed>";
    } else if ([url.lastPathComponent isEqual:@"SHA256SUMS.txt"]) {
        if ([url.path containsString:@"/v0.3.0/"]) {
            if (![_mode isEqual:@"bad-manifest"]) throw Error("UpdateHttp", {"404"});
            text = @"bad  Bonfire-0.3.0-macOS-arm64-Portable.zip\n";
        } else text = @"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad  Bonfire-0.2.0-macOS-arm64-Portable.zip\n";
    } else text = [_mode isEqual:@"bad-download"] ? @"bad" : @"abc";
    NSURL *temp = [_directory URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    [text writeToURL:temp atomically:YES encoding:NSUTF8StringEncoding error:nil];
    NSError *error = nil;
    read(temp,&error);
    [NSFileManager.defaultManager removeItemAtURL:temp error:nil];
    if (error) fileFailure(error);
    return [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1" headerFields:@{}];
}
@end

static void check(BOOL value, const char *what) { if (!value) throw std::runtime_error(what); }
static void waitFor(BFUpdates *u, NSString *phase) {
    NSDate *until = [NSDate dateWithTimeIntervalSinceNow:6];
    while ((u.busy || ![phase isEqual:u.status]) && until.timeIntervalSinceNow > 0)
        [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    if (u.busy || ![phase isEqual:u.status])
        throw std::runtime_error(std::string("Expected ") + phase.UTF8String + ", got " + u.status.UTF8String);
}
int main(int argc, const char** argv) { @autoreleasepool { try {
    if (argc != 2) return 2;
    NSURL *api = [NSURL URLWithString:@"https://api.github.com/repos/airanluo-dot/Bonfire/releases"];
    NSHTTPURLResponse *limited = [[NSHTTPURLResponse alloc] initWithURL:api statusCode:429 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Retry-After":@"60"}];
    check(rateReset(limited).timeIntervalSinceNow > 50, "rate-limit retry time");
    check(!trustedURL([NSURL URLWithString:@"http://github.com/airanluo-dot/Bonfire/releases/download/v1/file"], Endpoint::asset) &&
          !trustedURL([NSURL URLWithString:@"https://github.com/other/project/releases/download/v1/file"], Endpoint::asset) &&
          trustedURL([NSURL URLWithString:@"https://release-assets.githubusercontent.com/assets/test"], Endpoint::asset),
          "redirect boundaries");
    BFTestPreferences *prefs = [BFTestPreferences new];
    prefs.autoCheck = prefs.autoDownload = prefs.autoInstall = NO;
    prefs.channel = @"Beta";
    BFTestUpdates *u = [[BFTestUpdates alloc] initWithPreferences:prefs];
    u.directory = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]] isDirectory:YES];
    u.canInstall = ^BOOL { return NO; };
    u.mode = @"bad-feed";
    [u check]; waitFor(u,@"UpdateInvalidFeed");
    check(u.pageRequests == 0 && [u.retryAction isEqual:@"check"], "malformed API should not fall back");
    u.mode = @"hold";
    u.gate = dispatch_semaphore_create(0);
    [u check]; [u cancel];
    dispatch_semaphore_signal(u.gate);
    waitFor(u,@"UpdateCancelled");
    u.mode = @"bad-manifest";
    [u check]; waitFor(u,@"UpdateIntegrity");
    check(!u.candidate, "bad digest must stop selection");
    u.mode = @"normal";
    [u check]; waitFor(u,@"UpdateAvailable");
    check([u.candidate[@"version"] isEqual:@"0.2.0"] && u.pageRequests == 2, "Atom fallback skips only missing assets");
    NSURL *conflict = [u.directory URLByAppendingPathComponent:u.candidate[@"name"]];
    [@"keep" writeToURL:conflict atomically:YES encoding:NSUTF8StringEncoding error:nil];
    u.mode = @"bad-download";
    [u downloadUpdate]; waitFor(u,@"UpdateIntegrity");
    check(!u.download && [u.retryAction isEqual:@"download"], "damaged download must be retryable");
    u.mode = @"normal";
    [u downloadUpdate]; waitFor(u,@"UpdateReady");
    check([@"abc" isEqual:[NSString stringWithContentsOfURL:u.download encoding:NSUTF8StringEncoding error:nil]], "verified payload");
    check([@"keep" isEqual:[NSString stringWithContentsOfURL:conflict encoding:NSUTF8StringEncoding error:nil]], "existing file retained");
    [u check]; waitFor(u,@"UpdateReady");
    prefs.autoInstall = YES; [u preferencesChanged:@"autoInstall"]; waitFor(u,@"UpdateWait");
    prefs.autoInstall = NO; [u preferencesChanged:@"autoInstall"]; waitFor(u,@"UpdateReady");
    [NSFileManager.defaultManager removeItemAtURL:u.download error:nil]; [u reveal];
    check(!u.download && [u.status isEqual:@"UpdateDownloadedMissing"], "removed download");
    prefs.channel = @"Stable"; [u preferencesChanged:@"channel"]; waitFor(u,@"UpdateIdle");
    check(!u.download && !u.candidate && !prefs.lastCheck, "channel change discarded the old state without an automatic check");
    [u check]; waitFor(u,@"UpdateCurrent");
    prefs.autoCheck = YES; prefs.channel = @"Beta"; [u preferencesChanged:@"channel"]; waitFor(u,@"UpdateAvailable");
    std::puts("Mac check, official fallbacks, cancel, verify, retry, recovery, channel and deferred install: OK");
    return 0;
} catch (const std::exception& e) { std::fprintf(stderr,"%s\n",e.what()); return 1; } }}
