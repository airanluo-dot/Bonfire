#import "BundleUpdate.h"
#import <sys/stdio.h>
#include "../core/adapter.hpp"
using transfer::Error;

namespace {
void command(NSString *program,NSArray<NSString*> *arguments){
    NSTask *task=[NSTask new];task.executableURL=[NSURL fileURLWithPath:program];task.arguments=arguments;
    task.standardOutput=NSFileHandle.fileHandleWithNullDevice;task.standardError=NSFileHandle.fileHandleWithNullDevice;
    if(![task launchAndReturnError:nil])throw Error("UpdateFailed");
    [task waitUntilExit];if(task.terminationStatus!=0)throw Error("UpdateIntegrity");
}
}
void BFReplaceApplication(NSURL *archive,NSURL *current,NSString *expectedVersion){
    NSFileManager *files=NSFileManager.defaultManager;
    NSURL *stage=[current.URLByDeletingLastPathComponent URLByAppendingPathComponent:[@".bonfire-update-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    if(![files createDirectoryAtURL:stage withIntermediateDirectories:NO attributes:nil error:nil])throw Error("UpdateManualMac");
    @try{
        command(@"/usr/bin/ditto",@[@"-x",@"-k",archive.path,stage.path]);
        NSURL *fresh=[stage URLByAppendingPathComponent:@"Bonfire.app"];
        NSDictionary *info=[NSDictionary dictionaryWithContentsOfURL:[fresh URLByAppendingPathComponent:@"Contents/Info.plist"]];
        if(![info[@"CFBundleIdentifier"] isEqual:@"app.bonfire.savetransfer"]||![info[@"BonfireVersion"] isEqual:expectedVersion])throw Error("UpdateIntegrity");
        command(@"/usr/bin/codesign",@[@"--verify",@"--strict",fresh.path]);
        // A read-only existing bundle would prevent cleanup of the displaced app.
        for(NSURL *url in [files enumeratorAtURL:current includingPropertiesForKeys:@[NSURLIsDirectoryKey] options:0 errorHandler:nil]){
            NSNumber *directory=nil;[url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:nil];
            if(directory.boolValue && ![files isWritableFileAtPath:url.path])throw Error("UpdateManualMac");
        }
        if(![files isWritableFileAtPath:current.path])throw Error("UpdateManualMac");
        if(renamex_np(current.fileSystemRepresentation,fresh.fileSystemRepresentation,RENAME_SWAP)!=0)throw Error("UpdateManualMac");
    }@finally{
        [files removeItemAtURL:stage error:nil];
    }
}

