#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreServices/CoreServices.h>
#include "../app/runtime.hpp"
#include <algorithm>
#include <memory>
#include <libproc.h>
#include <unistd.h>

using namespace transfer;
static NSString *str(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }
static Path path(NSURL *url) { return url.fileSystemRepresentation ? Path(url.fileSystemRepresentation) : Path{}; }
static Path special(NSSearchPathDirectory key) {
    return path([[NSFileManager defaultManager] URLsForDirectory:key inDomains:NSUserDomainMask].firstObject);
}
static bool runningRenpyProcess(const GameAdapter& game) {
    int size=proc_listpids(PROC_UID_ONLY,getuid(),nullptr,0);
    if(size<=0) throw Error("ProcessQuery");
    std::vector<pid_t> processes(size/sizeof(pid_t)+32);
    size=proc_listpids(PROC_UID_ONLY,getuid(),processes.data(),int(processes.size()*sizeof(pid_t)));
    if(size<=0) throw Error("ProcessQuery");
    processes.resize(size/sizeof(pid_t));
    auto launcher=fs::u8path(game.info.windowsExe).stem();
    for(pid_t pid : processes) {
        char name[PROC_PIDPATHINFO_MAXSIZE];
        if(pid<=0 || proc_pidpath(pid,name,sizeof(name))<=0) continue;
        Path executable(name);
        auto file=executable.filename();
        if(file!=launcher && file!="python" && file!="pythonw" && file!="python3") continue;
        auto base=executable.parent_path();
        if(base.parent_path().filename()=="lib") base=base.parent_path().parent_path();
        else if(file!=launcher) continue;
        // A packaged interpreter can live under Contents/MacOS, under
        // Resources/autorun, or in the Steam game folder beside the bundle.
        if(base.filename()=="autorun" && base.parent_path().filename()=="Resources")
            base=base.parent_path().parent_path();
        if(base.filename()=="MacOS") base=base.parent_path();
        if(base.filename()=="Contents") base=base.parent_path();
        if(base.extension()==".app") {
            if(!game.identify(base).empty()) return true;
        } else {
            for(const auto& app : game.info.macAppNames)
                if(!game.identify(base/fs::u8path(app)).empty()) return true;
        }
    }
    return false;
}
bool transfer::gameIsRunning(const GameAdapter& game,const Path& root) {
    for(NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        auto p=path(app.bundleURL);std::error_code ec;
        if(!p.empty() && fs::equivalent(p,game.installation(root),ec)) return true;
        // The same game can be launched by Gatekeeper from a translocated copy.
        if(!p.empty() && (game.sharesUserSaves() || p.string().find("/AppTranslocation/")!=std::string::npos)
           && !game.identify(p).empty()) return true;
    }
    if(root.string().find("/AppTranslocation/")!=std::string::npos)
        throw Error("Translocation");
    return game.sharesUserSaves() && runningRenpyProcess(game);
}
std::vector<Path> transfer::locate(const GameAdapter& game,const std::atomic_bool& stop) {
    Path home=NSHomeDirectory().fileSystemRepresentation;
    std::vector<Path> hints{path(NSBundle.mainBundle.bundleURL).parent_path()};
    addSteamHints(game,special(NSApplicationSupportDirectory)/"Steam",hints,stop);
    for(const auto& identifier:game.info.macBundleIds)
        for(NSURL *u in [NSWorkspace.sharedWorkspace URLsForApplicationsWithBundleIdentifier:str(identifier)])
            hints.push_back(path(u));
    for(const Path& parent : std::vector<Path>{"/Applications",home/"Applications",home/"Games"}) {
        for(const auto& name : game.info.macAppNames) hints.push_back(parent/fs::u8path(name));
    }
    auto installed=discover(game,hints,{},{},stop);
    if(stop || !installed.empty()) return installed;
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
