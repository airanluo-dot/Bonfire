#include "renpy.hpp"
#include "renpy_format.hpp"
#include "save_files.hpp"
#include "storage_internal.hpp"
#include <cstdlib>
#include <fstream>
#include <string_view>

namespace transfer {
namespace {
Path environmentPath(const char* name) {
#ifdef _WIN32
    const auto* value = _wgetenv(fs::u8path(name).c_str());
#else
    const auto* value = std::getenv(name);
#endif
    return value && *value ? Path(value) : Path{};
}

bool matchesProfile(const Path& options, const std::string& profile) {
    std::error_code ec;
    if (!fs::is_regular_file(options, ec) || fs::file_size(options, ec) > 512 * 1024) return true;
    std::ifstream stream(options);
    std::string line;
    constexpr std::string_view field = "define config.save_directory";
    while (std::getline(stream, line)) {
        auto start = line.find_first_not_of(" \t");
        if (start == line.npos || line.compare(start, field.size(), field) != 0) continue;
        auto equals = line.find_first_not_of(" \t", start + field.size());
        if (equals == line.npos || line[equals] != '=') continue;
        auto quote = line.find_first_not_of(" \t", equals + 1);
        if (quote == line.npos || (line[quote] != '"' && line[quote] != '\'')) continue;
        auto end = line.find(line[quote], quote + 1);
        if (end != line.npos) return line.substr(quote + 1, end - quote - 1) == profile;
    }
    return true;
}

bool hasGameData(const Path& base, const Path& launcher, const std::string& profile) {
    std::error_code ec;
    auto game = base / "game";
    return fs::is_regular_file(base / launcher, ec) &&
        (fs::is_regular_file(game / "script.rpyc", ec) || fs::is_regular_file(game / "archive.rpa", ec) ||
         fs::is_regular_file(game / "data.rpa", ec)) && matchesProfile(game / "options.rpy", profile);
}

bool diskEntry(const std::string& name) {
    // Ren'Py checks the recovery copy before persistent after an interrupted save.
    return name == "persistent.new" || renpyEntry(name);
}
}

RenpyAdapter::RenpyAdapter(GameInfo metadata, std::string profileName, bool overrideSupported)
    : GameAdapter(std::move(metadata)), profile(std::move(profileName)), supportsSaveOverride(overrideSupported) {}

Path RenpyAdapter::dataRoot(const Path& install) const {
    std::error_code ec;
    auto executable = fs::u8path(info.windowsExe);
    auto launcher = executable.stem();
    launcher += ".py";
#ifdef _WIN32
    if (fs::is_regular_file(install / executable, ec) && hasGameData(install, launcher, profile)) return install;
#else
    auto contents = install / "Contents";
    if (install.extension() != ".app" || !fs::is_regular_file(contents / "Info.plist", ec) ||
        !fs::is_regular_file(contents / "MacOS" / executable.stem(), ec)) return {};
    for (const auto& base : {contents / "MacOS", contents / "Resources" / "autorun", install.parent_path()})
        if (hasGameData(base, launcher, profile)) return base;
#endif
    return {};
}

Path RenpyAdapter::identify(const Path& selection) const {
    std::error_code ec;
    if (selection.empty() || !fs::exists(selection, ec)) return {};
    auto path = fs::canonical(selection, ec);
    if (ec) return {};
    if (fs::is_regular_file(path, ec)) path = path.parent_path();
    if (path.filename() == "saves") path = path.parent_path();
    if (path.filename() == "game") path = path.parent_path();
    if (!dataRoot(path).empty()) return path;
    // An unpacked distribution may wrap the executable or .app in one folder.
    // A parent containing two versions requires an explicit selection.
    Path single;
    for (fs::directory_iterator it(path, fs::directory_options::skip_permission_denied, ec), end;
         !ec && it != end; it.increment(ec)) {
        if (!it->is_directory(ec) || it->is_symlink(ec) || dataRoot(it->path()).empty()) continue;
        if (!single.empty()) return {};
        single = it->path();
    }
    return single;
}

Path RenpyAdapter::saveDirectory(const Path& root) const {
    if (supportsSaveOverride) {
        auto overridePath = environmentPath("RENPY_PATH_TO_SAVES");
        if (overridePath.is_absolute()) return overridePath / profile;
    }
    auto base = dataRoot(root);
    if (base.empty()) throw Error("MovedGame");
    for (auto parent = base;; parent = parent.parent_path()) {
        auto portable = parent / "Ren'Py Data";
        if (fs::is_directory(portable)) return portable / profile;
        if (parent == parent.root_path()) break;
    }
#ifdef _WIN32
    auto appData = environmentPath("APPDATA");
    if (appData.is_absolute()) return appData / "RenPy" / profile;
    auto home = environmentPath("USERPROFILE");
    if (home.is_absolute()) return home / "RenPy" / profile;
#else
    auto home = environmentPath("HOME");
    if (home.is_absolute()) return home / "Library" / "RenPy" / profile;
#endif
    throw Error("Renpy_Profile");
}

std::vector<Path> RenpyAdapter::saveDirectories(const Path& root) const {
    const auto base = dataRoot(root);
    if (base.empty()) throw Error("MovedGame");
    auto primary = saveDirectory(root);
    std::vector<Path> dirs{primary};
    // A standalone Mac app only uses the user profile. The Steam distribution
    // with game/ beside the bundle uses the second location on both platforms.
#ifndef _WIN32
    if (base == root / "Contents" / "Resources" / "autorun") return dirs;
#endif
    const auto mirror = base / "game" / "saves";
    std::error_code ec;
    if (fs::symlink_status(mirror).type() != fs::file_type::not_found && !fs::equivalent(mirror, primary, ec))
        dirs.push_back(mirror);
    return dirs;
}

bool RenpyAdapter::acceptsEntry(const std::string& name) const { return renpyEntry(name); }

Files RenpyAdapter::capture(const Path& root) const {
    std::map<std::string, std::pair<fs::file_time_type, Path>> newest;
    for (const auto& dir : saveDirectories(root)) {
        for (const auto& file : members(dir, diskEntry)) {
            auto name = file.filename().u8string();
            if (name == "persistent" && fs::exists(dir / "persistent.new")) continue;
            if (name == "persistent.new") name = "persistent";
            auto time = fs::last_write_time(file);
            auto it = newest.find(name);
            if (it == newest.end() || time > it->second.first) newest[name] = {time, file};
            if (newest.size() > countLimit) throw Error("PackageLimit");
        }
    }
    Files result;
    size_t total = 0;
    for (const auto& [name, entry] : newest) {
        auto data = readBounded(entry.second, limits().fileBytes);
        total += data.size();
        if (total > limits().totalBytes) throw Error("PackageLimit");
        result.emplace(name, std::move(data));
    }
    return result;
}

Progress RenpyAdapter::summarize(const Files& files) const { return renpyProgress(files); }
Progress RenpyAdapter::inventory(const Path& root) const { return summarize(capture(root)); }
Progress RenpyAdapter::validate(const Files& files) const {
    if (files.empty()) throw Error("Renpy_Empty");
    return summarize(files);
}
void RenpyAdapter::install(const Path& root, const Files& files) const {
    auto dirs = saveDirectories(root);
    fs::create_directories(dirs.front().parent_path());
    replaceMirrors(dirs, files, diskEntry, "persistent", limits());
}
}
