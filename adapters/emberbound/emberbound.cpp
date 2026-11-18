#include "../../core/renpy.hpp"
#include "../../core/renpy_format.hpp"
#include "../../core/renpy_scripts.hpp"

namespace transfer {
namespace {
class EmberboundAdapter final : public RenpyAdapter {
public:
    using RenpyAdapter::RenpyAdapter;

    void checkCompatibility(const Path& root, const Files& files) const override {
        bool needsSideStory = false;
        renpyProgress(files, {}, {}, [&](const nlohmann::json& metadata) {
            auto chapter = metadata.find("emberbound_chapter");
            if (chapter != metadata.end() && *chapter == "extra_shengyang_day") needsSideStory = true;
        });
        if (!needsSideStory) return;
        auto base = dataRoot(root);
        if (base.empty()) throw Error("MovedGame");
        if (renpyHasScript(base / "game", "side_stories/shengyang_day/story.rpy") == false)
            throw Error("Emberbound_SideStoryMissing");
    }
};
}
const GameAdapter& emberbound() {
    static const EmberboundAdapter game({
        "emberbound", "embersave", {'E','M','B','E','R','B','N','D'},
        "Emberbound.exe", "Bonfire_Emberbound",
        {"Emberbound", "未烬之约", "Emberbound-preview-1.8-win"}, {"Emberbound.app"}, {}
    }, "newgame-1773923380", true);
    return game;
}
}
