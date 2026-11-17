#import "../macos/BundleUpdate.h"
#include "../core/adapter.hpp"
#include <cstdio>

int main(int argc,const char **argv){@autoreleasepool{
    if(argc!=4)return 2;
    NSFileManager *files=NSFileManager.defaultManager;
    NSURL *archive=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[1]]];
    NSURL *current=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
    NSString *version=[NSString stringWithUTF8String:argv[3]];
    NSURL *binary=[current URLByAppendingPathComponent:@"Contents/MacOS/Bonfire"];
    NSData *before=[NSData dataWithContentsOfURL:binary];
    BOOL rejected=NO;
    try{BFReplaceApplication(archive,current,@"999.0.0");}catch(const transfer::Error&){rejected=YES;}
    if(!rejected || ![before isEqual:[NSData dataWithContentsOfURL:binary]])return 3;
    try{BFReplaceApplication(archive,current,version);}catch(const std::exception& e){std::fprintf(stderr,"%s\n",e.what());return 4;}
    if(![before isEqual:[NSData dataWithContentsOfURL:binary]])return 5;
    for(NSString *name in [files contentsOfDirectoryAtPath:current.URLByDeletingLastPathComponent.path error:nil])
        if([name hasPrefix:@".bonfire-update-"])return 6;
    std::puts("Native Mac updater rejects a mismatched bundle, swaps the verified app and cleans its staging directory.");
    return 0;
}}

