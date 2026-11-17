#pragma once
#include "../core/save_files.hpp"

// Test-only adapter with an independent layout, format identifier and payload.
namespace fixture {
using namespace transfer;
inline Path directory(const Path& root) { return root/"Profiles"; }
inline bool accepts(const std::string& n) { return n=="slot.dat"; }
class Fixture final : public GameAdapter {
public:
    Fixture() : GameAdapter({
        "fixture","fixturesave",{'B','F','T','E','S','T','0','1'},
        "Fixture.exe","Bonfire_Fixture",{"Fixture"},{"Fixture.app"},{}
    }) {}
    Path identify(const Path& p) const override {
        std::error_code ec;
        auto root=fs::is_regular_file(p,ec)?p.parent_path():p;
        return fs::is_regular_file(root/"fixture.marker",ec)?root:Path{};
    }
    Path installation(const Path& p) const override { return p; }
    Path saveDirectory(const Path& p) const override { return directory(p); }
    bool acceptsEntry(const std::string& n) const override { return accepts(n); }
    Progress inventory(const Path& p) const override { return validate(capture(p)); }
    Progress validate(const Files& f) const override {
        if(f.size()!=1 || !f.count("slot.dat") || f.at("slot.dat").empty()) throw Error("Invalid fixture payload");
        return {1,"00:01:00",0};
    }
    Files capture(const Path& p) const override { return snapshot(directory(p),accepts); }
    void install(const Path& p,const Files& f) const override { replaceFiles(directory(p),f,accepts); }
};
inline const GameAdapter& adapter() {
    static const Fixture game;
    return game;
}
}
