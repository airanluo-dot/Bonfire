#include "../../core/renpy.hpp"
#include "../../core/renpy_format.hpp"
#include <set>

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

// A Ren'Py 7 statement ID in the saved execution/rollback state is a tuple
// (script filename, script timestamp, serial). Only recognize that literal
// encoding in the protocol-2 log. A gallery flag or dialogue string alone
// does not establish a script dependency. Never load Python objects.
uint32_t little32(const Bytes& bytes, size_t pos) {
    return bytes[pos] | (unsigned(bytes[pos+1])<<8) |
        (unsigned(bytes[pos+2])<<16) | (uint32_t(bytes[pos+3])<<24);
}
unsigned char requiredContent(const Bytes& log) {
    if (log.size() < 8 || log[0] != 0x80 || log[1] != 2) return 0;
    std::set<uint32_t> currentFields;
    const std::string_view view(reinterpret_cast<const char*>(log.data()), log.size());
    unsigned char required = 0;
    for (size_t i = 2; i + 5 < log.size() && required != both; ++i) {
        // The execution context stores the statement ID under "current".
        // Later contexts often refer to that field by its pickle memo index.
        size_t pos = i;
        bool direct = false;
        if (log[i]=='U' && log[i+1]==7 && view.substr(i+2,7)=="current") {
            pos=i+9; direct=true;
        } else if (log[i]=='X' && little32(log,i+1)==7 && view.substr(i+5,7)=="current") {
            pos=i+12; direct=true;
        } else if (log[i]=='h' && currentFields.count(log[i+1])) pos=i+2;
        else if (log[i]=='j' && currentFields.count(little32(log,i+1))) pos=i+5;
        else continue;
        if (direct && pos+2 <= log.size() && log[pos]=='q') {
            currentFields.insert(log[pos+1]); pos+=2;
        } else if (direct && pos+5 <= log.size() && log[pos]=='r') {
            currentFields.insert(little32(log,pos+1)); pos+=5;
        }
        if (pos+5 >= log.size() || log[pos]!='X') continue; // BINUNICODE filename
        auto length=little32(log,pos+1);
        pos+=5;
        if (length < 16 || length > 4096 || length >= log.size() - pos) continue;
        std::string_view path(reinterpret_cast<const char*>(log.data()+pos), length);
        auto content = scriptContent(path);
        if (!content) continue;
        pos += length;
        if (log[pos] == 'q') pos += 2;       // BINPUT
        else if (log[pos] == 'r') pos += 5;  // LONG_BINPUT
        for (int n = 0; n < 2 && pos < log.size(); ++n) {
            if (log[pos] == 'J') pos += 5;       // BININT
            else if (log[pos] == 'M') pos += 3;  // BININT2
            else if (log[pos] == 'K') pos += 2;  // BININT1
            else { pos = log.size(); break; }
        }
        if (pos < log.size() && log[pos] == 0x87) required |= content; // TUPLE3
    }
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
        auto installed = installedContent(dataRoot(root)/"game");
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
            if (auto missing = (*source)[2] & ~installedContent(dataRoot(root)/"game"))
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
