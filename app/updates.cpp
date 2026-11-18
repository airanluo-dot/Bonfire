#include "updates.hpp"
#include <algorithm>
#include <array>
#include <optional>
#include <regex>
#include <set>
#include <string_view>

namespace transfer {
namespace {
using Version = std::array<int,4>;
constexpr std::array<std::string_view,3> packages = {
    "Windows-x64-Setup.exe", "Windows-x64-Portable.zip", "macOS-arm64-Portable.zip"
};

std::optional<Version> version(const std::string& text) {
    static const std::regex pattern(R"(^v?(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})(?:-(?:beta|preview)\.([1-9][0-9]{0,3}))?$)");
    std::smatch fields;
    if(!std::regex_match(text,fields,pattern)) return {};
    int stage=fields[4].matched?std::stoi(fields[4]):9999;
    if(fields[4].matched && stage==9999) return {};
    return Version{std::stoi(fields[1]),std::stoi(fields[2]),std::stoi(fields[3]),stage};
}

struct UpdateRequest {
    Version current;
    bool stable;
    std::string kind;
};
UpdateRequest settings(const Json& input) {
    auto current=version(input.at("current"));
    auto channel=input.at("channel").get<std::string>();
    auto kind=input.at("kind").get<std::string>();
    // The updater replaces the Mac app with its portable distribution.
    if (!current || (channel!="Stable" && channel!="Beta") ||
        std::find(packages.begin(),packages.end(),kind)==packages.end())
        throw Error("InvalidRequest");
    return {*current,channel=="Stable",kind};
}

struct ReleaseAsset {
    std::string tag, normalized, name, directory;
    ReleaseAsset(const std::string& tagName,const std::string& kind) :
        tag(tagName), normalized(tag[0]=='v'?tag.substr(1):tag), name("Bonfire-"+normalized+"-"+kind),
        directory("https://github.com/airanluo-dot/Bonfire/releases/download/"+tag+"/") {}

    Json verified(const Json& size,const Json& url,const Json& digest) const {
        static const std::regex sha256("sha256:[a-f0-9]{64}");
        if (!size.is_number_integer() || size<=0 || size>512LL*1024*1024 || url!=directory+name ||
            !digest.is_string() || !std::regex_match(digest.get_ref<const std::string&>(),sha256))
            throw Error("UpdateIntegrity");
        return {{"version",normalized},{"name",name},{"url",url},{"size",size},{"hash",digest.get<std::string>().substr(7)}};
    }
};

// Inspect only assets for the requested distribution. Any integrity failure
// on a matching uploaded asset stops the check, even if an older release exists.
std::optional<Json> targetAsset(const Json& release,const std::string& kind) {
    const ReleaseAsset target(release.at("tag_name").get_ref<const std::string&>(),kind);
    const auto assets=release.find("assets");
    if(assets==release.end() || !assets->is_array()) throw Error("UpdateInvalidFeed");

    std::optional<Json> match;
    for(const auto& asset:*assets) {
        if(!asset.is_object() || !asset.contains("name") || !asset["name"].is_string())
            throw Error("UpdateInvalidFeed");
        if(asset["name"]!=target.name) continue;
        if(!asset.contains("state") || !asset["state"].is_string()) throw Error("UpdateInvalidFeed");
        if(asset["state"]!="uploaded") continue;
        if(match) throw Error("UpdateIntegrity");
        match=target.verified(asset.value("size",Json{}),asset.value("browser_download_url",Json{}),asset.value("digest",Json{}));
    }
    return match;
}

std::string checksum(const ReleaseAsset& target,std::string_view text) {
    if (text.empty() || text.size()>64*1024) throw Error("UpdateIntegrity");
    const auto prefix="Bonfire-"+target.normalized+"-";
    std::set<std::string> seen;
    std::string result;
    while (!text.empty()) {
        const auto newline=text.find('\n');
        auto line=text.substr(0,newline);
        if (newline==text.npos) text={}; else text.remove_prefix(newline+1);
        if (!line.empty() && line.back()=='\r') line.remove_suffix(1);
        if (line.size()<=66 || line.substr(0,64).find_first_not_of("0123456789abcdef")!=line.npos ||
            (line.substr(64,2)!="  " && line.substr(64,2)!=" *"))
            throw Error("UpdateIntegrity");
        const auto file=line.substr(66);
        if (file.substr(0,prefix.size())!=prefix) throw Error("UpdateIntegrity");
        const auto kind=file.substr(prefix.size());
        // Other architectures and supplemental release files are valid. Only
        // a portable basename in this exact release can appear in its manifest.
        if (kind.empty() || file.size()>255 || kind.front()=='.' || kind.front()==' ' ||
            kind.back()=='.' || kind.back()==' ' || kind.find_first_of("/\\:<>\"|?*%")!=kind.npos ||
            std::any_of(kind.begin(),kind.end(),[](unsigned char c){return c<32 || c==127;}))
            throw Error("UpdateIntegrity");
        // A prerelease filename also starts with its stable version's prefix.
        static const std::regex prereleasePrefix(R"(^(beta|preview)\.[0-9]{1,4}-)");
        if (target.normalized.find('-')==target.normalized.npos &&
            std::regex_search(kind.begin(),kind.end(),prereleasePrefix)) throw Error("UpdateIntegrity");
        std::string folded(kind);
        for (char& c:folded) if (c>='A' && c<='Z') c+='a'-'A';
        if (!seen.insert(std::move(folded)).second) throw Error("UpdateIntegrity");
        if (file==target.name) result=std::string(line.substr(0,64));
    }
    if (result.empty()) throw Error("UpdateMissing");
    return result;
}
}

Json selectUpdate(const Json& input) {
    const auto request=settings(input);
    const auto& releases=input.at("releases");
    if(!releases.is_array()) throw Error("UpdateInvalidFeed");
    std::vector<std::pair<Version,const Json*>> candidates;
    for(const auto& item:releases) {
        if(!item.is_object() || !item.contains("draft") || !item["draft"].is_boolean())
            throw Error("UpdateInvalidFeed");
        if(item["draft"]==true) continue;
        if(!item.contains("tag_name") || !item["tag_name"].is_string()
           || !item.contains("prerelease") || !item["prerelease"].is_boolean())
            throw Error("UpdateInvalidFeed");
        auto parsed=version(item["tag_name"].get_ref<const std::string&>());
        if(!parsed || *parsed<=request.current) continue;
        if(request.stable && ((*parsed)[3]!=9999 || item["prerelease"]==true)) continue;
        candidates.emplace_back(*parsed,&item);
    }
    if(candidates.empty()) return Json::object();
    std::stable_sort(candidates.begin(),candidates.end(),[](const auto& a,const auto& b){return a.first>b.first;});
    for(const auto& entry:candidates)
        if(auto asset=targetAsset(*entry.second,request.kind)) return *asset;
    throw Error("UpdateMissing");
}

Json webUpdate(const Json& input) {
    const auto request=settings(input);
    auto tags=input.find("tags");
    if (tags==input.end() || !tags->is_array()) throw Error("UpdateInvalidFeed");
    auto highest=request.current;
    std::string selected;
    for (const auto& value:*tags) {
        if (!value.is_string()) throw Error("UpdateInvalidFeed");
        const auto& tag=value.get_ref<const std::string&>();
        auto parsed=version(tag);
        if (parsed && *parsed>highest && (!request.stable || (*parsed)[3]==9999)) {
            highest=*parsed;
            selected=tag;
        }
    }
    if (selected.empty()) return Json::object();
    const ReleaseAsset target(selected,request.kind);
    const auto url=target.directory+target.name;
    if (!input.contains("checksums") && !input.contains("size"))
        return {{"tag",selected},{"version",target.normalized},{"name",target.name},{"url",url},
                {"checksumsUrl",target.directory+"SHA256SUMS.txt"}};
    if (!input.contains("checksums") || !input["checksums"].is_string() || !input.contains("size"))
        throw Error("UpdateIntegrity");
    const auto hash=checksum(target,input["checksums"].get_ref<const std::string&>());
    return target.verified(input["size"],url,"sha256:"+hash);
}
}
