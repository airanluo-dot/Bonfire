#include "updates.hpp"
#include <algorithm>
#include <array>
#include <optional>
#include <regex>

namespace transfer {
namespace {
using Version = std::array<int,4>;

std::optional<Version> version(const std::string& text) {
    static const std::regex pattern(R"(^v?(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})\.(0|[1-9][0-9]{0,3})(?:-(?:beta|preview)\.([1-9][0-9]{0,3}))?$)");
    std::smatch fields;
    if(!std::regex_match(text,fields,pattern)) return {};
    int stage=fields[4].matched?std::stoi(fields[4]):9999;
    if(fields[4].matched && stage==9999) return {};
    return Version{std::stoi(fields[1]),std::stoi(fields[2]),std::stoi(fields[3]),stage};
}
}

Json selectUpdate(const Json& input) {
    auto current=version(input.at("current"));
    auto channel=input.at("channel").get<std::string>();
    auto kind=input.at("kind").get<std::string>();
    if(!current || (channel!="Stable" && channel!="Beta")
       || (kind!="Windows-x64-Setup.exe" && kind!="Windows-x64-Portable.zip" && kind!="macOS-arm64-Portable.zip"))
        throw Error("InvalidRequest");
    auto highest=*current;
    const Json* candidate=nullptr;
    for(const auto& item:input.at("releases")) {
        if(!item.is_object() || item.value("draft",true)) continue;
        auto tag=item.value("tag_name",std::string{});
        auto parsed=version(tag);
        if(!parsed || *parsed<=highest) continue;
        if(channel=="Stable" && ((*parsed)[3]!=9999 || item.value("prerelease",false))) continue;
        highest=*parsed;
        candidate=&item;
    }
    if(!candidate)return Json::object();
    auto tag=candidate->at("tag_name").get<std::string>();
    auto normalized=tag[0]=='v'?tag.substr(1):tag;
    auto name="Bonfire-"+normalized+"-"+kind;
    auto url="https://github.com/airanluo-dot/Bonfire/releases/download/"+tag+"/"+name;
    for(const auto& asset:candidate->at("assets")) {
        if(asset.value("name",std::string{})!=name || asset.value("state",std::string{})!="uploaded")continue;
        auto digest=asset.value("digest",Json{});
        auto size=asset.value("size",int64_t(0));
        if(!digest.is_string() || !std::regex_match(digest.get<std::string>(),std::regex("sha256:[a-f0-9]{64}")) ||
           asset.value("browser_download_url",std::string{})!=url || size<=0 || size>512LL*1024*1024)
            throw Error("UpdateIntegrity");
        return {{"version",normalized},{"name",name},{"url",url},{"size",size},{"hash",digest.get<std::string>().substr(7)}};
    }
    throw Error("UpdateMissing");
}
}
