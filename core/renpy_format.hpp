#pragma once
#include "adapter.hpp"
#include "../vendor/json.hpp"
#include <functional>
#include <string_view>

namespace transfer {
bool renpyEntry(const std::string& name);
using RenpyLogVisitor = std::function<void(const Bytes&)>;
using RenpyMetadataVisitor = std::function<void(const nlohmann::json&)>;
Progress renpyProgress(const Files& files, const RenpyLogVisitor& visitLog = {},
                       std::string_view packageMetadata = {}, const RenpyMetadataVisitor& visitMetadata = {},
                       nlohmann::json* latestMetadata = nullptr);
bool renpySignedPersistent(const Files& files);
}
