#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreServices/CoreServices.h>
#include "../app/runtime.hpp"
#include <algorithm>
#include <memory>

using namespace transfer;
static NSString *str(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }
static Path path(NSURL *url) { return url.fileSystemRepresentation ? Path(url.fileSystemRepresentation) : Path{}; }
static Path special(NSSearchPathDirectory key) {
    return path([[NSFileManager defaultManager] URLsForDirectory:key inDomains:NSUserDomainMask].firstObject);
}
bool transfer::gameIsRunning(const GameAdapter& game,const Path& root) {
    for(NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        auto p=path(app.bundleURL);std::error_code ec;
        if(!p.empty() && fs::equivalent(p,game.installation(root),ec)) return true;
        // The same game can be launched by Gatekeeper from a translocated copy.
        if(p.string().find("/AppTranslocation/")!=std::string::npos && !game.identify(p).empty()) return true;
    }
    if(root.string().find("/AppTranslocation/")!=std::string::npos)
        throw Error("Translocation");
    return false;
}
std::vector<Path> transfer::locate(const GameAdapter& game,const std::atomic_bool& stop) {
    Path home=NSHomeDirectory().fileSystemRepresentation;
    std::vector<Path> hints{path(NSBundle.mainBundle.bundleURL).parent_path()};
    for(const auto& identifier:game.info.macBundleIds)
        for(NSURL *u in [NSWorkspace.sharedWorkspace URLsForApplicationsWithBundleIdentifier:str(identifier)])
            hints.push_back(path(u));
    NSMutableArray<NSString*> *predicates=[NSMutableArray array];
    for(const auto& name:game.info.macAppNames) {
        NSString *escaped=[str(name) stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        [predicates addObject:[NSString stringWithFormat:@"kMDItemFSName == '%@'cd",escaped]];
    }
    MDQueryRef q=predicates.count ? MDQueryCreate(nullptr,(__bridge CFStringRef)[predicates componentsJoinedByString:@" || "],nullptr,nullptr) : nullptr;
    if(q) {
        if(MDQueryExecute(q,kMDQuerySynchronous)) {
            for(CFIndex i=0;i<MDQueryGetResultCount(q) && !stop;++i) {
                MDItemRef item=(MDItemRef)MDQueryGetResultAtIndex(q,i);
                NSString *p=CFBridgingRelease(MDItemCopyAttribute(item,kMDItemPath));
                if(p.length) hints.emplace_back(p.fileSystemRepresentation);
            }
        }
        CFRelease(q);
    }
    std::vector<Path> common{"/Applications",home/"Applications",home/"Games",
        special(NSDesktopDirectory),special(NSDownloadsDirectory),special(NSDocumentDirectory)};
    std::vector<Path> volumes{home,"/Users/Shared","/opt","/usr/local","/"};
    for(NSURL *u in [NSFileManager.defaultManager mountedVolumeURLsIncludingResourceValuesForKeys:@[NSURLVolumeIsLocalKey]
                                      options:NSVolumeEnumerationSkipHiddenVolumes]) {
        NSNumber *local=nil;[u getResourceValue:&local forKey:NSURLVolumeIsLocalKey error:nil];
        auto p=path(u);
        if(local.boolValue && p.parent_path()=="/Volumes") {
            common.push_back(p/"Games");common.push_back(p/"Applications");volumes.insert(volumes.begin(),p);
        }
    }
    return discover(game,hints,common,volumes,stop);
}
