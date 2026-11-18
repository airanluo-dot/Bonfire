#pragma once
#include "adapter.hpp"

namespace transfer {
using NameFilter = bool (*)(const std::string&);
std::vector<Path> members(const Path& dir, NameFilter filter);
Bytes readSaveFile(const Path& path);
Files snapshot(const Path& dir, NameFilter filter, SaveLimits limits = {});
// Finalize lastFile after the other payloads when the game has a separate index.
void replaceFiles(const Path& dir, const Files& incoming, NameFilter filter,
                  const std::string& lastFile = {});
void replaceMirrors(const std::vector<Path>& dirs, const Files& incoming, NameFilter filter,
                    const std::string& lastFile, SaveLimits limits);
}
