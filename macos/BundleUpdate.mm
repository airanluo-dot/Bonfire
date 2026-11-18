#import "BundleUpdate.h"
#import <sys/file.h>
#import <sys/stat.h>
#import <sys/stdio.h>
#import <fcntl.h>
#import <unistd.h>
#include "../core/adapter.hpp"
using transfer::Error;

namespace {
void command(NSString *program, NSArray<NSString*> *arguments, const char *failure) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:program];
    task.arguments = arguments;
    task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) throw Error("UpdateInstallFailed");
    [task waitUntilExit];
    if (task.terminationStatus != 0) throw Error(failure);
}
NSDictionary *bundleInfo(NSURL *url) {
    return [NSDictionary dictionaryWithContentsOfURL:[url URLByAppendingPathComponent:@"Contents/Info.plist"]];
}
}
NSString *BFApplicationIdentity(NSURL *bundle) {
    struct stat st{};
    NSDictionary *info = bundleInfo(bundle);
    NSString *version = info[@"BonfireVersion"];
    if (lstat(bundle.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) ||
        ![info[@"CFBundleIdentifier"] isEqual:@"app.bonfire.savetransfer"] || !version.length) return nil;
    return [NSString stringWithFormat:@"%llu/%llu/%@", (unsigned long long)st.st_dev,
            (unsigned long long)st.st_ino, version];
}

void BFReplaceApplication(NSURL *archive, NSURL *current, NSString *version,
                          NSString *expectedIdentity, BOOL (^verifyArchive)(NSURL *)) {
    if (!expectedIdentity || ![expectedIdentity isEqual:BFApplicationIdentity(current)]) throw Error("UpdateTargetChanged");
    int lock = open(current.fileSystemRepresentation, O_DIRECTORY | O_RDONLY | O_NOFOLLOW);
    if (lock < 0) throw Error("UpdateManualMac");
    NSFileManager *files = NSFileManager.defaultManager;
    NSURL *stage = [current.URLByDeletingLastPathComponent URLByAppendingPathComponent:
        [@".bonfire-update-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    BOOL madeStage = NO;
    @try {
        if (flock(lock, LOCK_EX | LOCK_NB)) throw Error("UpdateFileBusy");
        if (![files createDirectoryAtURL:stage withIntermediateDirectories:NO
                              attributes:@{NSFilePosixPermissions:@0700} error:nil]) throw Error("UpdateManualMac");
        madeStage = YES;
        NSURL *copy = [stage URLByAppendingPathComponent:@"download.zip"];
        NSError *failure = nil;
        if (![files copyItemAtURL:archive toURL:copy error:&failure]) {
            if (failure.code == NSFileReadNoSuchFileError || failure.code == NSFileNoSuchFileError) throw Error("UpdateDownloadedMissing");
            if (failure.code == NSFileWriteOutOfSpaceError) throw Error("UpdateDiskFull");
            throw Error("UpdateInstallFailed");
        }
        // The extractor opens its own file handle. Verify the private copy it will read.
        struct stat copied{};
        if (lstat(copy.fileSystemRepresentation, &copied) || !S_ISREG(copied.st_mode) || !verifyArchive(copy))
            throw Error("UpdateIntegrity");
        command(@"/usr/bin/ditto", @[@"-x", @"-k", copy.path, stage.path], "UpdateInstallFailed");
        NSURL *fresh = [stage URLByAppendingPathComponent:@"Bonfire.app"];
        NSDictionary *info = bundleInfo(fresh);
        if (![info[@"CFBundleIdentifier"] isEqual:@"app.bonfire.savetransfer"] ||
            ![info[@"BonfireVersion"] isEqual:version]) throw Error("UpdateIntegrity");
        command(@"/usr/bin/codesign", @[@"--verify", @"--strict", fresh.path], "UpdateIntegrity");
        for (NSURL *url in [files enumeratorAtURL:current includingPropertiesForKeys:@[NSURLIsDirectoryKey]
                                         options:0 errorHandler:nil]) {
            NSNumber *directory = nil;
            [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
            if (directory.boolValue && ![files isWritableFileAtPath:url.path]) throw Error("UpdateManualMac");
        }
        if (![expectedIdentity isEqual:BFApplicationIdentity(current)]) throw Error("UpdateTargetChanged");
        if (![files isWritableFileAtPath:current.path] ||
            renamex_np(current.fileSystemRepresentation, fresh.fileSystemRepresentation, RENAME_SWAP) != 0)
            throw Error("UpdateManualMac");
    } @finally {
        if (madeStage) [files removeItemAtURL:stage error:nil];
        close(lock);
    }
}
