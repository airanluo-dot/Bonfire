#pragma once
#include "adapter.hpp"
#include <optional>

namespace transfer {
// Ren'Py loads loose scripts and the game directory's resource archives. An unknown
// archive layout cannot establish that a chapter is missing.
std::optional<bool> renpyHasScript(const Path& gameDirectory, const std::string& sourceName);
}
