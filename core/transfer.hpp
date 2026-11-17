#pragma once
#include "adapter.hpp"
#include <atomic>
#include <optional>

namespace transfer {
struct Package {
    std::string gameId;
    Files files;
    Progress progress;
    int64_t createdMs=0;
    std::string checksum;
};
std::vector<Path> discover(const GameAdapter&, const std::vector<Path>& hints,
                           const std::vector<Path>& common, const std::vector<Path>& volumes,
                           const std::atomic_bool& cancelled);
Package readPackage(const GameAdapter&, const Path& path);
Path extract(const GameAdapter&, const Path& root, const Path& destination, const std::string& localizedName = {});
void receive(const GameAdapter&, const Path& root, const Package& package);
bool gameIsRunning(const GameAdapter&, const Path& root);
}
