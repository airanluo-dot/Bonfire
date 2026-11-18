#pragma once
#include "adapter.hpp"
#include <functional>
#include <optional>
#include <string_view>

namespace transfer {
void visitRenpyStatements(const Bytes& log, const std::function<void(std::string_view)>& visit);
// Ren'Py loads loose scripts and the game directory's resource archives. An unknown
// archive layout cannot establish that a chapter is missing.
std::optional<bool> renpyHasScript(const Path& gameDirectory, const std::string& sourceName);
}
