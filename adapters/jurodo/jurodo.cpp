#include "../../core/save_files.hpp"
#include "../../core/inflate.hpp"
#include "../../vendor/json.hpp"
#include <algorithm>
#include <fstream>
#include <set>

namespace transfer {
namespace {
using Json = nlohmann::json;
constexpr size_t MiB = 1024 * 1024;
class JurodoAdapter final : public GameAdapter {
public:
    JurodoAdapter() : GameAdapter({
        "jurodo","jurosave",{'J','U','R','O','S','A','V','E'},
        "Jurodo.exe","JurodoSaveTransfer_v1_97475763",
        {"Jurodo","兽劳动"},{"Jurodo.app","兽劳动.app","獣労働.app"},{"io.nwjs.nwjs"}
    }) {}
    Path identify(const Path&) const override;
    Path installation(const Path&) const override;
    Path saveDirectory(const Path&) const override;
    bool acceptsEntry(const std::string&) const override;
    Progress inventory(const Path&) const override;
    Progress validate(const Files&) const override;
    Files capture(const Path&) const override;
    void install(const Path&,const Files&) const override;
};
Path JurodoAdapter::saveDirectory(const Path& root) const { return root/"save"; }
Path JurodoAdapter::installation(const Path& root) const {
#ifdef _WIN32
    return root;
#else
    return root.parent_path().parent_path().parent_path();
#endif
}
bool isGame(const Path& root) {
    try {
#ifdef _WIN32
        if (!fs::is_regular_file(root / "Jurodo.exe")) return false;
#else
        if (root.filename() != "app.nw" || root.parent_path().filename() != "Resources" ||
            root.parent_path().parent_path().filename() != "Contents" ||
            root.parent_path().parent_path().parent_path().extension() != ".app" ||
            !fs::is_regular_file(root.parent_path().parent_path() / "Info.plist")) return false;
#endif
        auto system = root / "data" / "System.json";
        if (!fs::is_regular_file(root / "js" / "rmmz_managers.js") ||
            fs::file_size(system) > 4 * 1024 * 1024) return false;
        std::ifstream stream(system, std::ios::binary);
        auto data = Json::parse(stream);
        return data.at("advanced").at("gameId") == 97475763 && data.at("gameTitle") == "獣労働";
    } catch (const std::exception&) { return false; }
}

Path JurodoAdapter::identify(const Path& selected) const {
    if (selected.empty()) return {};
    std::error_code ec;
    auto p = fs::weakly_canonical(selected, ec);
    if (ec) return {};
    if (fs::is_regular_file(p, ec)) p = p.parent_path();
    if (p.filename() == "save") p = p.parent_path();
#ifdef _WIN32
    const Path paths[] = {p, p/"Jurodo_win", p/"Jurodo"/"Jurodo_win"};
#else
    const auto content = Path("Contents")/"Resources"/"app.nw";
    const Path paths[] = {p/content, p, p/"Jurodo.app"/content, p/"Jurodo_mac"/"Jurodo.app"/content,
                          p/"Jurodo"/"Jurodo_mac"/"Jurodo.app"/content};
#endif
    for (const auto& root : paths) if (isGame(root)) return root;
    return {};
}

static bool managed(const std::string& n) {
    if (n == "global.rmmzsave" || n == "config.rmmzsave") return true;
    if (n.size() < 14 || n.size() > 16 || n.compare(0,4,"file") || n.substr(n.size()-9) != ".rmmzsave") return false;
    auto id = n.substr(4,n.size()-13);
    return !(id.size()>1 && id[0]=='0') && std::all_of(id.begin(),id.end(),[](char c){return c>='0' && c<='9';});
}
// RPG Maker MZ writes pako's binary string through Node's UTF-8 file API.
bool JurodoAdapter::acceptsEntry(const std::string& n) const { return managed(n); }
static Json decodeSave(const Bytes& bytes) {
    auto invalid = []{throw Error("Jurodo_Format");};
    Bytes z;
    for (size_t i=0; i<bytes.size(); ++i) {
        unsigned v=bytes[i];
        if (v>=128) {
            if ((v!=194 && v!=195) || ++i>=bytes.size() || (bytes[i]&192)!=128) invalid();
            v=((v&3)<<6)|(bytes[i]&63);
        }
        z.push_back(static_cast<unsigned char>(v));
    }
    if (z.size()<7 || (z[0]&15)!=8 || (z[0]>>4)>7 || ((z[0]<<8)+z[1])%31 || (z[1]&32)) invalid();
    Bytes plain(64*1024);
    while (true) {
        unsigned long len=static_cast<unsigned long>(plain.size()), in=static_cast<unsigned long>(z.size()-6);
        int result=inflateRaw(plain.data(),&len,z.data()+2,&in);
        if (result==0) { if (in!=z.size()-6) invalid(); plain.resize(len); break; }
        if (result!=1 || plain.size()>=32*MiB) invalid();
        plain.resize(plain.size()*2);
    }
    uint32_t a=1,b=0;
    for (auto c : plain) { a=(a+c)%65521; b=(b+a)%65521; }
    uint32_t expected=0;
    for (size_t i=z.size()-4;i<z.size();++i) expected=(expected<<8)|z[i];
    if (((b<<16)|a)!=expected) invalid();
    auto data = Json::parse(plain.begin(),plain.end(),nullptr,false);
    if (data.is_discarded()) invalid();
    return data;
}
static Json readIndex(const Bytes& bytes) {
    auto index=decodeSave(bytes);
    if (!index.is_array() || index.size()>1000) throw Error("Jurodo_Index");
    for (const auto& entry : index) {
        if (!entry.is_null() && (!entry.is_object() || entry.value("title",std::string())!="獣労働"))
            throw Error("Jurodo_Title");
    }
    return index;
}
static std::string playtimeOf(const Json& entry) {
    auto value=entry.find("playtime");
    return value!=entry.end() && value->is_string() ? value->get<std::string>() : std::string{};
}
static Progress progressSummary(const Json& index, std::set<std::string> names) {
    size_t slots=0, displaySlot=0;
    int64_t latest=-1;
    for (size_t i=0; i<index.size(); ++i) {
        const auto& entry=index[i];
        if (entry.is_null()) continue;
        if (!names.erase("file"+std::to_string(i)+".rmmzsave"))
            throw Error("Jurodo_Missing");
        auto timestamp=entry.find("timestamp");
        auto time=timestamp!=entry.end() && timestamp->is_number_integer() ? timestamp->get<int64_t>() : -1;
        if (!slots || time>latest) { displaySlot=i; latest=time; }
        ++slots;
    }
    if (!names.empty()) throw Error("Jurodo_Mismatch");
    if (!slots) return {};
    return {slots,playtimeOf(index[displaySlot]),displaySlot};
}
Progress JurodoAdapter::inventory(const Path& root) const {
    auto dir=saveDirectory(root);
    std::set<std::string> names;
    for (const auto& p : members(dir,managed)) names.insert(p.filename().u8string());
    names.erase("config.rmmzsave");
    if (!names.erase("global.rmmzsave")) {
        if (names.empty()) return {};
        throw Error("Jurodo_NoIndex");
    }
    auto summary=progressSummary(readIndex(readSaveFile(dir/"global.rmmzsave")),std::move(names));
    return summary;
}
Progress JurodoAdapter::validate(const Files& files) const {
    if (!files.count("global.rmmzsave")) throw Error("Jurodo_NoIndex");
    auto index=readIndex(files.at("global.rmmzsave"));
    std::set<std::string> names;
    for (const auto& [n,b] : files) {
        if (n=="global.rmmzsave") continue;
        auto data=decodeSave(b);
        if (!data.is_object()) throw Error("Jurodo_Data");
        if (n=="config.rmmzsave") continue;
        if (!managed(n) || !data.contains("system") || !data.contains("party") || !data.contains("map"))
            throw Error("Jurodo_NoData");
        names.insert(n);
    }
    auto summary=progressSummary(index,std::move(names));
    if (!summary.count) throw Error("Jurodo_Empty");
    return summary;
}


Files JurodoAdapter::capture(const Path& root) const { return snapshot(saveDirectory(root),managed); }
void JurodoAdapter::install(const Path& root,const Files& files) const {
    replaceFiles(saveDirectory(root),files,managed,"global.rmmzsave");
}
}
const GameAdapter& jurodo() {
    static const JurodoAdapter game;
    return game;
}
}
