#include "transfer.hpp"
#include <algorithm>
#include <set>
#ifdef _WIN32
#include <windows.h>
#endif

namespace transfer {
static bool skip(const fs::directory_entry& entry) {
    std::error_code ec;
    if (entry.is_symlink(ec)) return true;
#ifdef _WIN32
    auto attr = GetFileAttributesW(entry.path().c_str());
    if (attr == INVALID_FILE_ATTRIBUTES || (attr & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_OFFLINE))) return true;
#else
    if (entry.path().parent_path()=="/") {
        static const std::set<Path> systemDirs={"System","Volumes","Network","private","dev","cores","bin","sbin"};
        if(systemDirs.count(entry.path().filename())) return true;
    }
#endif
    auto name = entry.path().filename().u8string();
    for (char& c : name) if (c >= 'A' && c <= 'Z') c += 'a' - 'A';
    static const std::set<std::string> ignored = {"node_modules","__macosx","$recycle.bin",
        "system volume information","windowsapps","winsxs","system32","syswow64","driverstore","caches",
        "deriveddata","apptranslocation","proc","dev"};
    return name.empty() || name[0] == '.' || ignored.count(name);
}

static void add(std::vector<Path>& found, const Path& root) {
    if (root.empty()) return;
    for (const auto& other : found) {
        std::error_code ec;
        if (fs::equivalent(other, root, ec)) return;
    }
    found.push_back(root);
}

static void scan(const GameAdapter& game, const Path& start, int depth, std::vector<Path>& found, const std::atomic_bool& stop) {
    std::error_code ec;
    if (stop || !fs::is_directory(start, ec)) return;
#ifdef _WIN32
    const auto exe=fs::u8path(game.info.windowsExe);
#endif
    fs::recursive_directory_iterator it(start,fs::directory_options::skip_permission_denied,ec), end;
    for (; it != end && !stop; it.increment(ec)) {
        if (ec) { ec.clear(); continue; }
        if (it->is_directory(ec)) {
            if (skip(*it) || it.depth() >= depth) it.disable_recursion_pending();
#ifndef _WIN32
            if (it->path().extension() == ".app") {
                add(found, game.identify(it->path()));
                it.disable_recursion_pending();
            }
#endif
        }
#ifdef _WIN32
        else if (!_wcsicmp(it->path().filename().c_str(), exe.c_str())) add(found, game.identify(it->path()));
#endif
    }
}

std::vector<Path> discover(const GameAdapter& game, const std::vector<Path>& hints, const std::vector<Path>& common,
                           const std::vector<Path>& volumes, const std::atomic_bool& stop) {
    std::vector<Path> found;
    for (const auto& p : hints) { if (stop) return found; add(found, game.identify(p)); }
    if (found.empty()) for (const auto& p : common) scan(game,p, 7, found, stop);
    if (found.empty()) for (const auto& p : volumes) scan(game,p, 128, found, stop);
    std::sort(found.begin(), found.end());
    return found;
}
}
