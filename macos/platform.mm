#import <AppKit/AppKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <CoreServices/CoreServices.h>
#include "../app/runtime.hpp"
#include <algorithm>
#include <chrono>
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
static void addMacAppHints(const GameAdapter& game, const Path& parent, std::vector<Path>& hints) {
    for (const auto& name : game.info.macAppNames) hints.push_back(parent / fs::u8path(name));
}

static void addMacDownloadHints(const GameAdapter& game, const Path& parent, std::vector<Path>& hints,
                                const std::atomic_bool& stop) {
    // Distribution directories often include a version, e.g. Interea-0.4-mac/Interea.app.
    std::error_code ec;
    for (fs::directory_iterator it(parent, fs::directory_options::skip_permission_denied, ec), end;
         !ec && !stop && it != end; it.increment(ec)) {
        if (it->path().extension() == ".app") continue;
        NSString *name = str(it->path().filename().u8string());
        for (const auto& prefix : game.info.folderNames) {
            if ([name rangeOfString:str(prefix) options:(NSAnchoredSearch | NSCaseInsensitiveSearch)].location == NSNotFound)
                continue;
            if (it->is_directory(ec)) addMacAppHints(game, it->path(), hints);
            break;
        }
    }
}

static void addSpotlightHints(const GameAdapter& game, std::vector<Path>& hints, const std::atomic_bool& stop) {
    NSMutableArray<NSString*> *predicates=[NSMutableArray array];
    for(const auto& name:game.info.macAppNames) {
        NSString *escaped=[str(name) stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        [predicates addObject:[NSString stringWithFormat:@"kMDItemFSName == '%@'cd",escaped]];
    }
    MDQueryRef q=predicates.count ? MDQueryCreate(nullptr,(__bridge CFStringRef)[predicates componentsJoinedByString:@" || "],nullptr,nullptr) : nullptr;
    if (!q) return;
    if (!stop && MDQueryExecute(q,0)) {
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        while (!stop && !MDQueryIsGatheringComplete(q) && std::chrono::steady_clock::now() < deadline)
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        MDQueryStop(q);
        for(CFIndex i=0;i<MDQueryGetResultCount(q) && !stop;++i) {
            MDItemRef item=(MDItemRef)MDQueryGetResultAtIndex(q,i);
            NSString *p=CFBridgingRelease(MDItemCopyAttribute(item,kMDItemPath));
            if(p.length) hints.emplace_back(p.fileSystemRepresentation);
        }
    }
    CFRelease(q);
}

std::vector<Path> transfer::locate(const GameAdapter& game,const std::atomic_bool& stop) {
    std::vector<Path> hints;
    addSteamHints(game,special(NSApplicationSupportDirectory)/"Steam",hints,stop);
    auto installed=discover(game,hints,{},{},stop);
    if(stop || !installed.empty()) return installed;
    hints.clear();

    Path home=NSHomeDirectory().fileSystemRepresentation;
    std::vector<Path> common{"/Applications",home/"Applications",home/"Games",
        special(NSDesktopDirectory),special(NSDownloadsDirectory),special(NSDocumentDirectory)};
    for (const auto& parent : common) addMacAppHints(game, parent, hints);
    for(const auto& identifier:game.info.macBundleIds) {
        if(stop) return {};
        for(NSURL *u in [NSWorkspace.sharedWorkspace URLsForApplicationsWithBundleIdentifier:str(identifier)])
            hints.push_back(path(u));
    }
    installed=discover(game,hints,{},{},stop);
    if(stop || !installed.empty()) return installed;
    hints.clear();

    std::vector<Path> volumes{home,"/Users/Shared","/opt","/usr/local","/"};
    for(NSURL *u in [NSFileManager.defaultManager mountedVolumeURLsIncludingResourceValuesForKeys:@[NSURLVolumeIsLocalKey]
                                      options:NSVolumeEnumerationSkipHiddenVolumes]) {
        if(stop) return {};
        NSNumber *local=nil;[u getResourceValue:&local forKey:NSURLVolumeIsLocalKey error:nil];
        auto p=path(u);
        if(local.boolValue && p.parent_path()=="/Volumes") {
            for (const auto& folder : {"SteamLibrary", "Steam"}) addSteamHints(game,p/folder,hints,stop);
            for (const auto& folder : {"Games", "Applications"}) {
                common.push_back(p/folder);
                addMacAppHints(game,p/folder,hints);
            }
            addMacAppHints(game,p,hints);
            volumes.insert(volumes.begin(),p);
        }
    }
    installed=discover(game,hints,{},{},stop);
    if(stop || !installed.empty()) return installed;
    hints.clear();

    for(const auto& parent : common) {
        if(stop) return {};
        addMacDownloadHints(game,parent,hints,stop);
    }
    hints.push_back(path(NSBundle.mainBundle.bundleURL).parent_path());
    installed=discover(game,hints,{},{},stop);
    if(stop || !installed.empty()) return installed;
    hints.clear();

    addSpotlightHints(game,hints,stop);
    return discover(game,hints,common,volumes,stop);
}
