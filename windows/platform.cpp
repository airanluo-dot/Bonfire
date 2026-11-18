#define NOMINMAX
#include <windows.h>
#include <commctrl.h>
#include <shlobj.h>
#include <tlhelp32.h>
#include <wrl/client.h>
#include <thread>
#include <algorithm>
#include "../app/runtime.hpp"
using Microsoft::WRL::ComPtr;
using namespace transfer;
Path known(REFKNOWNFOLDERID id) {
    PWSTR s=nullptr;
    if(FAILED(SHGetKnownFolderPath(id,KF_FLAG_DONT_VERIFY,nullptr,&s))) return {};
    Path path(s); CoTaskMemFree(s); return path;
}
void shortcuts(const Path& folder,std::vector<Path>& hints,int maxDepth,const Path& exeName,const std::atomic_bool& cancelScan) {
    std::error_code ec;
    fs::recursive_directory_iterator it(folder,fs::directory_options::skip_permission_denied,ec),end;
    for(;it!=end && !cancelScan;it.increment(ec)) {
        if(it.depth()>=maxDepth || (GetFileAttributesW(it->path().c_str()) & FILE_ATTRIBUTE_REPARSE_POINT))
            it.disable_recursion_pending();
        if(_wcsicmp(it->path().extension().c_str(),L".lnk")) continue;
        ComPtr<IShellLinkW> link; ComPtr<IPersistFile> file;
        if(FAILED(CoCreateInstance(CLSID_ShellLink,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&link))) ||
           FAILED(link.As(&file)) || FAILED(file->Load(it->path().c_str(),STGM_READ))) continue;
        wchar_t target[32768]{};
        if(SUCCEEDED(link->GetPath(target,32768,nullptr,SLGP_RAWPATH)) && target[0]) {
            Path p(target);
            if(!_wcsicmp(p.filename().c_str(),exeName.c_str())) hints.push_back(p);
        }
    }
}
static Path steamRegistryPath(HKEY hive,const wchar_t* field,DWORD view=0) {
    wchar_t value[32768]{};
    DWORD bytes=sizeof(value);
    if(RegGetValueW(hive,L"Software\\Valve\\Steam",field,RRF_RT_REG_SZ | view,
                    nullptr,value,&bytes)!=ERROR_SUCCESS) return {};
    Path result(value);
    return result.is_absolute() ? result : Path{};
}
#pragma comment(lib, "advapi32.lib")
std::vector<Path> transfer::locate(const GameAdapter& game,const std::atomic_bool& cancelScan) {
    std::vector<Path> hints,common,volumes;
    std::vector<Path> steamRoots;
    auto steamHints=[&](Path candidate) {
        if(cancelScan || candidate.empty()) return;
        candidate = candidate.lexically_normal().make_preferred();
        for(const auto& seen : steamRoots)
            if(!_wcsicmp(candidate.c_str(),seen.c_str())) return;
        steamRoots.push_back(candidate);
        std::error_code ec;
        if(fs::is_directory(candidate/L"steamapps",ec)) addSteamHints(game,candidate,hints,cancelScan);
    };
    steamHints(steamRegistryPath(HKEY_CURRENT_USER,L"SteamPath"));
    steamHints(steamRegistryPath(HKEY_LOCAL_MACHINE,L"InstallPath",RRF_SUBKEY_WOW6432KEY));
    steamHints(steamRegistryPath(HKEY_LOCAL_MACHINE,L"InstallPath",RRF_SUBKEY_WOW6464KEY));
    auto registered=discover(game,hints,{}, {},cancelScan);
    if(!registered.empty() || cancelScan) return registered;
    hints.clear();

    // A portable Steam client or a library left after moving Steam may have no
    // registry entry. Check its usual locations on each fixed disk directly.
    auto programs=known(FOLDERID_ProgramFilesX86);
    if(!programs.empty()) steamHints(programs/L"Steam");
    DWORD drives=GetLogicalDrives();
    for(unsigned i=0;i<26;++i) if(drives&(1u<<i)) {
        wchar_t letter[]=L"A:\\";letter[0]+=static_cast<wchar_t>(i);
        auto kind=GetDriveTypeW(letter);
        if(kind!=DRIVE_FIXED && kind!=DRIVE_REMOVABLE) continue;
        Path drive(letter);
        volumes.push_back(drive);
        if(kind==DRIVE_FIXED) {
            for(auto folder:{L"SteamLibrary",L"Steam",L"Program Files (x86)\\Steam",L"Program Files\\Steam",L"Games\\Steam"})
                steamHints(drive/folder);
        }
    }
    auto conventional=discover(game,hints,{}, {},cancelScan);
    if(!conventional.empty() || cancelScan) return conventional;
    hints.clear();

    auto hr=CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    struct Apartment {HRESULT hr; ~Apartment(){if(SUCCEEDED(hr))CoUninitialize();}} apartment{hr};
    {
        wchar_t exe[32768]{}; GetModuleFileNameW(nullptr,exe,32768);
        hints.push_back(Path(exe).parent_path());
        auto exeName=fs::u8path(game.info.windowsExe);
        shortcuts(known(FOLDERID_Desktop),hints,1,exeName,cancelScan);
        shortcuts(known(FOLDERID_PublicDesktop),hints,0,exeName,cancelScan);
        shortcuts(known(FOLDERID_Programs),hints,4,exeName,cancelScan);
        shortcuts(known(FOLDERID_CommonPrograms),hints,4,exeName,cancelScan);
        for(const auto& drive:volumes) {
            for(auto name:{L"Game",L"Games",L"游戏"}) {
                auto p=drive/name; common.push_back(p); hints.push_back(p);
                for(const auto& folder:game.info.folderNames) hints.push_back(p/fs::u8path(folder));
            }
            for(const auto& folder:game.info.folderNames) {
                auto p=drive/fs::u8path(folder);common.push_back(p);hints.push_back(p);
            }
        }
        for(auto p:{known(FOLDERID_Desktop),known(FOLDERID_Downloads),known(FOLDERID_Documents)}) if(!p.empty()) common.push_back(p);
        return discover(game,hints,common,volumes,cancelScan);
    }
}
bool transfer::gameIsRunning(const GameAdapter& game,const Path& root) {
    HANDLE snap=CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS,0);
    if(snap==INVALID_HANDLE_VALUE) throw Error("ProcessQuery");
    PROCESSENTRY32W p{};p.dwSize=sizeof p;bool running=false;
    auto exe=fs::u8path(game.info.windowsExe);
    if(!Process32FirstW(snap,&p)) { CloseHandle(snap); throw Error("ProcessQuery"); }
    do {
        bool gameName=!_wcsicmp(p.szExeFile,exe.c_str());
        bool python=game.sharesUserSaves() &&
            (!_wcsicmp(p.szExeFile,L"pythonw.exe") || !_wcsicmp(p.szExeFile,L"python.exe"));
        if(!gameName && !python) continue;
        HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,p.th32ProcessID);
        if(!process){if(gameName){running=true;break;} continue;}
        wchar_t path[32768];DWORD length=32768;
        bool queried=QueryFullProcessImageNameW(process,0,path,&length)!=0;
        CloseHandle(process);
        if(!queried){if(gameName){running=true;break;} continue;}
        Path executable(path);
        std::error_code ec;
        if(gameName && fs::equivalent(game.installation(root)/exe,executable,ec)) {running=true;break;}
        if(!game.sharesUserSaves()) continue;
        auto base=executable.parent_path();
        // Ren'Py runs either the launcher or an interpreter from lib/<arch>.
        if(!_wcsicmp(base.parent_path().filename().c_str(),L"lib")) base=base.parent_path().parent_path();
        else if(python) continue;
        auto identified=game.identify(base);
        if(!identified.empty() && fs::equivalent(base,identified,ec)) {running=true;break;}
    } while(Process32NextW(snap,&p));
    CloseHandle(snap);return running;
}
