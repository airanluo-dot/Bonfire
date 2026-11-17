#include "transfer.hpp"
#include "storage_internal.hpp"
#include <ctime>
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#else
#include <fcntl.h>
#include <unistd.h>
#include <sys/file.h>
#endif
namespace transfer {
class GameLock {
#ifdef _WIN32
    HANDLE handle{};
#else
    int fd = -1;
#endif
public:
    GameLock(const GameAdapter& game,const Path& root) {
        std::error_code ec;
        auto identified=game.identify(root);
        if (identified.empty() || !fs::equivalent(root,identified,ec)) throw Error("MovedGame");
#ifdef _WIN32
        handle = CreateMutexW(nullptr,FALSE,(L"Local\\"+fs::u8path(game.info.windowsLock).wstring()).c_str());
        DWORD result = handle ? WaitForSingleObject(handle,0) : WAIT_FAILED;
        if (result != WAIT_OBJECT_0 && result != WAIT_ABANDONED) {
            if(handle) CloseHandle(handle);
            throw Error("Locked");
        }
#else
        fd = open(root.c_str(), O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (fd < 0 || flock(fd, LOCK_EX | LOCK_NB)) {
            if (fd >= 0) close(fd);
            throw Error("LockFailed");
        }
#endif
    }
    ~GameLock() {
#ifdef _WIN32
        ReleaseMutex(handle); CloseHandle(handle);
#else
        close(fd);
#endif
    }
};

static void requireClosed(const GameAdapter& game,const Path& root) {
    if(gameIsRunning(game,root)) throw Error("Running");
}
Path extract(const GameAdapter& game,const Path& root,const Path& dest,const std::string& localizedName) {
    GameLock lock(game,root); requireClosed(game,root);
    const auto data=game.capture(root);
    game.validate(data);
    if(data!=game.capture(root)) throw Error("SaveChanged");
    auto b=encodePackage(game,data);
    std::time_t t=std::time(nullptr); std::tm tm{};
#ifdef _WIN32
    localtime_s(&tm,&t);
#else
    localtime_r(&t,&tm);
#endif
    char stamp[32]; std::strftime(stamp,sizeof stamp,"%Y%m%d-%H%M%S",&tm);
    const auto& title=!localizedName.empty() && localizedName.find_first_of("<>:\"/\\|?*")==std::string::npos ? localizedName : game.info.id;
    for(unsigned i=0;i<10000;++i) {
        std::string name=title+"-"+stamp+(i?"-"+std::to_string(i):"")+"."+game.info.extension;
        auto p=dest/fs::u8path(name);
        if(writeNewFile(p,b)) return p;
    }
    throw Error("NameLimit");
}
void receive(const GameAdapter& game,const Path& root,const Package& package) {
    if (package.gameId!=game.info.id) throw Error("WrongGame");
    game.validate(package.files);
    GameLock lock(game,root); requireClosed(game,root);
    game.install(root,package.files);
}
}
