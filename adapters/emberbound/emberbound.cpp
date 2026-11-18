#include "../../core/renpy.hpp"
#include "../../core/renpy_format.hpp"
#include "../../core/renpy_scripts.hpp"

namespace transfer {
namespace {
class EmberboundAdapter final : public RenpyAdapter {
public:
    using RenpyAdapter::RenpyAdapter;

    Progress summarize(const Files& files) const override {
        nlohmann::json latest;
        auto progress = renpyProgress(files, {}, {}, {}, &latest);
        auto chapter = latest.find("emberbound_chapter");
        if (chapter == latest.end()) return progress;
        if (*chapter == "part1") progress.chapterKey = "Emberbound_Part1";
        if (*chapter == "part2") progress.chapterKey = "Emberbound_Part2";
        if (*chapter == "extra_shengyang_day") progress.chapterKey = "Emberbound_ShengyangDay";
        return progress;
    }

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
