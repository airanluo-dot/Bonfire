#include "save_files.hpp"
#include "storage_internal.hpp"
#include <algorithm>
#include <cstdio>
#include <memory>
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#include <io.h>
#include <fcntl.h>
#else
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#endif
namespace transfer {
enum class Access { read, replace, create };
using Stream = std::unique_ptr<FILE, decltype(&std::fclose)>;
// Return an empty stream only for a collision while creating a new export.
static Stream openFile(const Path& p, Access access) {
    bool reading = access == Access::read;
    FILE* stream = nullptr;
#ifdef _WIN32
    HANDLE h = CreateFileW(p.c_str(),reading ? GENERIC_READ : GENERIC_WRITE,
        reading ? FILE_SHARE_READ : 0, nullptr,
        access == Access::create ? CREATE_NEW : reading ? OPEN_EXISTING : OPEN_ALWAYS,
        FILE_FLAG_OPEN_REPARSE_POINT | FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE && access == Access::create &&
        (GetLastError() == ERROR_FILE_EXISTS || GetLastError() == ERROR_ALREADY_EXISTS)) return {nullptr,&fclose};
    if (h != INVALID_HANDLE_VALUE) {
        BY_HANDLE_FILE_INFORMATION info{};
        bool safe = GetFileInformationByHandle(h,&info) && !(info.dwFileAttributes &
            (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) && (reading || info.nNumberOfLinks == 1);
        if (safe && (access != Access::replace || SetEndOfFile(h))) {
            int fd = _open_osfhandle(reinterpret_cast<intptr_t>(h), _O_BINARY | (reading ? _O_RDONLY : _O_WRONLY));
            if (fd >= 0) { stream = _fdopen(fd,reading ? "rb":"wb"); if (!stream) _close(fd); }
            else CloseHandle(h);
        } else CloseHandle(h);
    }
#else
    int flags = (reading ? O_RDONLY : O_WRONLY | O_CREAT) | O_NOFOLLOW | O_NONBLOCK;
    if (access == Access::create) flags |= O_EXCL;
    int fd = open(p.c_str(),flags,0600);
    if (fd < 0 && errno == EEXIST && access == Access::create) return {nullptr,&fclose};
    if (fd >= 0) {
        struct stat st{};
        if (fstat(fd,&st)==0 && S_ISREG(st.st_mode) && (reading || st.st_nlink == 1) &&
            (access != Access::replace || ftruncate(fd,0)==0)) stream = fdopen(fd,reading ? "rb":"wb");
        if (!stream) close(fd);
    }
#endif
    if (!stream) throw Error("OpenFile",{p.u8string()});
    return {stream,&fclose};
}
Bytes readBounded(const Path& p, size_t limit) {
    auto f = openFile(p, Access::read);
    auto size = fs::file_size(p);
    if (size > limit) throw Error("FileLimit",{p.u8string()});
    Bytes b(static_cast<size_t>(size));
    if (std::fread(b.data(),1,b.size(),f.get()) != b.size() || std::fgetc(f.get()) != EOF || std::ferror(f.get()))
        throw Error("FileChanged");
    return b;
}
static void write(Stream stream, const Bytes& b) {
    if (std::fwrite(b.data(),1,b.size(),stream.get()) != b.size() || std::fflush(stream.get()) != 0)
        throw Error("WriteFailed");
#ifdef _WIN32
    if (_commit(_fileno(stream.get())) != 0)
#else
    if (fsync(fileno(stream.get())) != 0)
#endif
        throw Error("FlushFailed");
    if (std::fclose(stream.release()) != 0) throw Error("CloseFailed");
}

bool portableEntry(const std::string& n) {
    if (n.empty() || n.size()>128 || n=="." || n==".." || n.back()=='.') return false;
    auto stem=n.substr(0,n.find('.'));
    for(char& c:stem) if(c>='a' && c<='z') c-=('a'-'A');
    if(stem=="CON" || stem=="PRN" || stem=="AUX" || stem=="NUL") return false;
    if(stem.size()==4 && (stem.compare(0,3,"COM")==0 || stem.compare(0,3,"LPT")==0)
       && stem[3]>='1' && stem[3]<='9') return false;
    return std::all_of(n.begin(),n.end(),[](unsigned char c) {
        return (c>='a' && c<='z') || (c>='A' && c<='Z') || (c>='0' && c<='9') || c=='_' || c=='-' || c=='.';
    });
}
Bytes readSaveFile(const Path& p) { return readBounded(p,SaveLimits{}.fileBytes); }
static void checkReal(const Path& p, bool directory) {
    auto st = fs::symlink_status(p);
    bool ok = directory ? fs::is_directory(st) : fs::is_regular_file(st);
#ifdef _WIN32
    ok = ok && !(GetFileAttributesW(p.c_str()) & FILE_ATTRIBUTE_REPARSE_POINT);
#endif
    if (!ok || (!directory && fs::hard_link_count(p) != 1))
        throw Error("SpecialFile",{p.u8string()});
}
std::vector<Path> members(const Path& dir,NameFilter filter) {
    if (fs::symlink_status(dir).type()==fs::file_type::not_found) return {};
    checkReal(dir,true);
    std::vector<Path> paths;
    for (const auto& item : fs::directory_iterator(dir)) {
        auto n = item.path().filename().u8string();
        if (filter(n)) { checkReal(item.path(),false); paths.push_back(item.path()); }
    }
    return paths;
}
Files snapshot(const Path& dir,NameFilter filter,SaveLimits limits) {
    Files files;
    size_t total = 0;
    for (const auto& p : members(dir,filter)) {
        auto b = readBounded(p,limits.fileBytes);
        total += b.size();
        if (total>limits.totalBytes || files.size()>=countLimit) throw Error("PackageLimit");
        files.emplace(p.filename().u8string(),std::move(b));
    }
    return files;
}
void replaceFiles(const Path& dir,const Files& incoming,NameFilter filter,const std::string& lastFile) {
    replaceMirrors({dir},incoming,filter,lastFile,{});
}
void replaceMirrors(const std::vector<Path>& dirs,const Files& incoming,NameFilter filter,const std::string& lastFile,SaveLimits limits) {
    for (const auto& entry : incoming)
        if (!portableEntry(entry.first) || !filter(entry.first)) throw Error("InvalidName");
    struct Destination {
        Path dir;
        Files before;
        std::map<std::string,fs::file_time_type> times;
        std::vector<std::string> touched;
        bool made=false;
    };
    std::vector<Destination> copies;
    for(const auto& dir:dirs) {
        Destination copy{dir,snapshot(dir,filter,limits)};
        for(const auto& [name,data]:copy.before) copy.times[name]=fs::last_write_time(dir/name);
        copies.push_back(std::move(copy));
    }
    try {
      for(auto& copy:copies) {
        const auto& dir=copy.dir;
        const auto& before=copy.before;
        auto& touched=copy.touched;
        copy.made=fs::create_directory(dir);
        checkReal(dir,true);
        auto install=[&](const std::string& name,const Bytes& data) {
            auto previous=before.find(name);
            if(previous==before.end()) {
                if(!writeNewFile(dir/name,data)) throw Error("Collision");
                touched.push_back(name);
                return;
            }
            if(previous->second==data) return;
            touched.push_back(name);
            write(openFile(dir/name,Access::replace),data);
        };
        for(const auto& [n,b]:incoming) if(n!=lastFile) install(n,b);
        if (incoming.count(lastFile)) install(lastFile,incoming.at(lastFile));
        for(const auto& [n,b]:before) if(!incoming.count(n)) {
            if(fs::remove(dir/n)) touched.push_back(n);
        }
        if(snapshot(dir,filter,limits)!=incoming) throw Error("VerifyFailed");
      }
    } catch(...) {
        bool ok=true;
        for(auto copy=copies.rbegin();copy!=copies.rend();++copy) {
            for(auto it=copy->touched.rbegin();it!=copy->touched.rend();++it) try {
                auto p=copy->dir/ *it;
                if(copy->before.count(*it)) {
                    const auto& original=copy->before.at(*it);
                    bool intact=false;
                    try { intact=readBounded(p,limits.fileBytes)==original; } catch(...) {}
                    if(!intact) write(openFile(p,Access::replace),original);
                    auto time=copy->times.at(*it);
                    if(fs::last_write_time(p)!=time) fs::last_write_time(p,time);
                } else fs::remove(p);
            } catch(...) { ok=false; }
            if(copy->made) {std::error_code ec; fs::remove(copy->dir,ec);}
        }
        if(!ok) throw Error("RollbackFailed");
        throw;
    }
}

bool writeNewFile(const Path& p,const Bytes& bytes) {
    auto file=openFile(p,Access::create);
    if (!file) return false;
    try { write(std::move(file),bytes); }
    catch (...) { std::error_code ec; fs::remove(p,ec); throw; }
    return true;
}
}
