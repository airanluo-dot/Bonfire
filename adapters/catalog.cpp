#include "../core/adapter.hpp"
#include <set>

namespace transfer {
#define BONFIRE_GAME(id) const GameAdapter& id();
#include "catalog.def"
#undef BONFIRE_GAME

const std::vector<const GameAdapter*>& catalog() {
    static const auto games = [] {
        std::vector<const GameAdapter*> entries{
#define BONFIRE_GAME(id) &id(),
#include "catalog.def"
#undef BONFIRE_GAME
        };
        std::set<std::string> ids;
        std::set<std::array<unsigned char,8>> tags;
        for (auto game : entries) {
            if (!ids.insert(game->info.id).second || !tags.insert(game->info.packageTag).second)
                throw Error("DuplicateGame");
        }
        return entries;
    }();
    return games;
}
}
