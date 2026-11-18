#import "../macos/BundleUpdate.h"
#include "../core/adapter.hpp"
#include <cstdio>

int main(int argc, const char **argv) { @autoreleasepool {
    if (argc != 4) return 2;
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *archive = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
    NSURL *current = [NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
    NSString *version = [NSString stringWithUTF8String:argv[3]];
    NSString *identity = BFApplicationIdentity(current);
    NSURL *binary = [current URLByAppendingPathComponent:@"Contents/MacOS/Bonfire"];
    NSData *before = [NSData dataWithContentsOfURL:binary];
    NSData *expected = [NSData dataWithContentsOfURL:archive];
    if (!identity || !before || !expected) return 3;
    BOOL (^verify)(NSURL*) = ^BOOL(NSURL *copied) {
        return ![archive isEqual:copied] && [expected isEqual:[NSData dataWithContentsOfURL:copied]];
    };
    auto rejects = [&](NSString *v, NSString *idValue, BOOL (^matcher)(NSURL*), const char *key) {
        try { BFReplaceApplication(archive, current, v, idValue, matcher); }
        catch (const transfer::Error& e) { return std::string(e.what()) == key; }
        return false;
    };
    if (!rejects(version, @"stale target", verify, "UpdateTargetChanged") ||
        !rejects(version, identity, ^BOOL(NSURL*) { return NO; }, "UpdateIntegrity") ||
        !rejects(@"999.0.0", identity, verify, "UpdateIntegrity")) return 4;
    if (![before isEqual:[NSData dataWithContentsOfURL:binary]]) return 5;
    try { BFReplaceApplication(archive, current, version, identity, verify); }
    catch (const std::exception& e) { std::fprintf(stderr,"%s\n", e.what()); return 6; }
    if (![before isEqual:[NSData dataWithContentsOfURL:binary]] ||
        !rejects(version, identity, verify, "UpdateTargetChanged")) return 7;
    for (NSString *name in [files contentsOfDirectoryAtPath:current.URLByDeletingLastPathComponent.path error:nil])
        if ([name hasPrefix:@".bonfire-update-"]) return 8;
    std::puts("Native installer verifies its private copy, rejects changed targets and atomically swaps the bundle.");
    return 0;
}}
