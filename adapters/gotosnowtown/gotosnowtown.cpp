#include "../../core/renpy.hpp"
#include "../../core/renpy_format.hpp"
#include "../../core/renpy_scripts.hpp"
#include <set>

namespace transfer {
namespace {
class SnowTownAdapter final : public RenpyAdapter {
public:
    using RenpyAdapter::RenpyAdapter;

    void checkCompatibility(const Path& root, const Files& files) const override {
        // The Public edition shares the profile ID with the main release, but
        // its story_ep*.rpy locations do not exist in the latter's scripts.
        std::set<std::string> chapters;
        renpyProgress(files, [&](const Bytes& log) {
            visitRenpyStatements(log, [&](std::string_view path) {
                for (const auto* chapter : {"game/scripts/story/story_ep0.rpy", "game/scripts/story/story_ep1.rpy",
                                            "game/scripts/story/story_ep2.rpy"})
                    if (path == chapter) chapters.emplace(path.substr(5));
            });
        });
        if (chapters.empty()) return;
        auto base = dataRoot(root);
        if (base.empty()) throw Error("MovedGame");
        for (const auto& chapter : chapters)
            if (renpyHasScript(base / "game", chapter) == false) throw Error("Snowtown_PublicMissing");
    }
};
}
const GameAdapter& gotosnowtown() {
    static const SnowTownAdapter game({
        "gotosnowtown", "snowtownsave", {'S','N','O','W','T','O','W','N'},
        "GoToSnowTown.exe", "Bonfire_GoToSnowTown",
        {"GoToSnowTown", "GoToSnowTown-0.5.0.2-pc", "出发！去落雪镇"}, {"GoToSnowTown.app"}, {}
    }, "GoToSnowTown-VERSION260901", true);
    return game;
}
}
