#include "../../core/renpy.hpp"
#include "../../core/renpy_format.hpp"
#include "../../core/renpy_scripts.hpp"

namespace transfer {
namespace {
constexpr char metadata[] = "bonfire-nekojishi-content";
constexpr unsigned char adult = 1, sunnyDay = 2, both = adult | sunnyDay;

unsigned char installedContent(const Path& gameDir) {
    auto has = [&](const char* path) { return fs::is_regular_file(gameDir / path); };
    unsigned char installed = 0;
    if (has("adult-d.rpa") || has("adult.rpa") || has("adult/_adult.rpy") || has("adult/_adult.rpyc")) installed |= adult;
    if (has("extra.rpa") || has("extra/_init.rpy") || has("extra/_init.rpyc")) installed |= sunnyDay;
    return installed;
}

unsigned char scriptContent(std::string_view path) {
    auto ends = [&](std::string_view suffix) {
        return path.size() >= suffix.size() && path.substr(path.size() - suffix.size()) == suffix;
    };
    if (ends("/extra/script/script.rpy")) return sunnyDay;
    if (ends("/adult/script/14_r18.rpy") || ends("/adult/script/16_r18.rpy") ||
        ends("/adult/script/17_r18.rpy") || ends("/adult/script/18_r18.rpy")) return adult;
    return 0;
}

unsigned char requiredContent(const Bytes& log) {
    unsigned char required = 0;
    visitRenpyStatements(log, [&](std::string_view path){ required |= scriptContent(path); });
    return required;
}

// Version, optional content present on the source, content referenced by
// script nodes in the slots. This entry exists only in Bonfire packages.
const Bytes* manifest(const Files& files) {
    auto entry = files.find(metadata);
    if (entry == files.end()) return nullptr;
    const auto& value = entry->second;
    if (value.size()!=3 || value[0]!=1 || value[1]>both || value[2]>both)
        throw Error("Neko_ContentFormat");
    return &value;
}

const char* missingMessage(unsigned char missing) {
    if (missing == adult) return "Neko_NeedsAdult";
    if (missing == sunnyDay) return "Neko_NeedsSunny";
    return "Neko_NeedsBoth";
}

class NekojishiAdapter final : public RenpyAdapter {
public:
    NekojishiAdapter() : RenpyAdapter({
        "nekojishi", "nekosave", {'N','E','K','O','S','A','V','E'},
        "Nekojishi.exe", "Bonfire_Nekojishi",
        {"Nekojishi"}, {"Nekojishi.app"}, {}
    }, "Neko-171107s") {}

    bool acceptsEntry(const std::string& name) const override {
        return name == metadata || RenpyAdapter::acceptsEntry(name);
    }
    Files capture(const Path& root) const override {
        auto saves = RenpyAdapter::capture(root);
        if (!saves.empty()) {
            unsigned char required = 0;
            renpyProgress(saves, [&](const Bytes& log){ required |= requiredContent(log); });
            saves[metadata] = {1, installedContent(dataRoot(root)/"game"), required};
        }
        return saves;
    }
    Progress inventory(const Path& root) const override {
        return renpyProgress(RenpyAdapter::capture(root));
    }
    Progress validate(const Files& files) const override {
        const auto* source = manifest(files);
        if (!source) return RenpyAdapter::validate(files);
        if (files.size() == 1) throw Error("Renpy_Empty");
        unsigned char required = 0;
        auto progress = renpyProgress(files, [&](const Bytes& log){ required |= requiredContent(log); }, metadata);
        if (required != (*source)[2]) throw Error("Neko_ContentFormat");
        return progress;
    }
    std::string compatibilityNotice(const Path& root, const Files& files) const override {
        const auto* source = manifest(files);
        if (!source) return {};
        if (root.empty()) {
            switch ((*source)[2]) {
                case adult: return "Neko_PackageAdult";
                case sunnyDay: return "Neko_PackageSunny";
                case both: return "Neko_PackageBoth";
                default: return {};
            }
        }
        auto base = dataRoot(root);
        if (base.empty()) return {};
        auto installed = installedContent(base/"game");
        if ((*source)[2] & ~installed) return {};
        switch ((*source)[1] & ~installed) {
            case adult: return "Neko_SourceAdult";
            case sunnyDay: return "Neko_SourceSunny";
            case both: return "Neko_SourceBoth";
            default: return {};
        }
    }
    void checkCompatibility(const Path& root, const Files& files) const override {
        const auto* source = manifest(files);
        if (source && !root.empty()) {
        auto base = dataRoot(root);
        if (base.empty()) throw Error("MovedGame");
        if (auto missing = (*source)[2] & ~installedContent(base/"game"))
                throw Error(missingMessage(missing));
        }
    }
    void install(const Path& root, const Files& files) const override {
        if (!manifest(files)) return RenpyAdapter::install(root, files);
        Files saves;
        for (const auto& entry : files) if (entry.first != metadata) saves.insert(entry);
        RenpyAdapter::install(root, saves);
    }
};
}
const GameAdapter& nekojishi() {
    static const NekojishiAdapter game;
    return game;
}
}
