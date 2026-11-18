#pragma once
#include <array>
#include <cstdint>
#include <filesystem>
#include <map>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace transfer {
namespace fs = std::filesystem;
using Path = fs::path;
using Bytes = std::vector<unsigned char>;
using Files = std::map<std::string, Bytes>;
struct Error : std::runtime_error {
    std::vector<std::string> arguments;
    explicit Error(const std::string& key,std::vector<std::string> args={})
        : std::runtime_error(key),arguments(std::move(args)) {}
};
struct Progress {
    size_t count=0;
    std::string playtime;
    size_t slot=0;
    bool persistent=false;
    std::string slotName;
};

struct GameInfo {
    std::string id, extension;
    std::array<unsigned char, 8> packageTag;
    std::string windowsExe, windowsLock;
    std::vector<std::string> folderNames, macAppNames, macBundleIds;
};
struct SaveLimits {
    size_t fileBytes=16*1024*1024;
    size_t totalBytes=64*1024*1024;
};

// One immutable instance per supported game. Discovery can call identify on a worker.
class GameAdapter {
public:
    const GameInfo info;
    explicit GameAdapter(GameInfo metadata) : info(std::move(metadata)) {}
    virtual ~GameAdapter() = default;
    virtual SaveLimits limits() const { return {}; }
    virtual bool sharesUserSaves() const { return false; }
    virtual std::string compatibilityNotice(const Path&, const Files&) const { return {}; }
    virtual void checkCompatibility(const Path&, const Files&) const {}
    virtual Path identify(const Path& selection) const = 0;
    virtual Path installation(const Path& root) const = 0;
    virtual Path saveDirectory(const Path& root) const = 0;
    virtual bool acceptsEntry(const std::string& name) const = 0;
    virtual Progress inventory(const Path& root) const = 0;
    virtual Progress validate(const Files& files) const = 0;
    virtual Files capture(const Path& root) const = 0;
    virtual void install(const Path& root, const Files& files) const = 0;
};
const std::vector<const GameAdapter*>& catalog();
}
