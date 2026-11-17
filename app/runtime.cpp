#include "runtime.hpp"
#include "updates.hpp"
#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <iomanip>
#include <set>
#include <sstream>

namespace transfer {
static Json progress(const Progress& p) {
    return {{"count",p.count},{"playtime",p.playtime},{"slot",p.slot}};
}
// v1 retained the local wall-clock timestamp only in its original generated name.
static int64_t legacyDate(const Path& path) {
    auto name=path.stem().u8string();
    auto last=name.rfind('-');
    if(last==std::string::npos) return 0;
    auto stamp=[&](size_t end)->int64_t {
        if(end<16 || name[end-16]!='-' || name[end-7]!='-') return 0;
        auto text=name.substr(end-15,15);
        for(size_t i=0;i<text.size();++i) if(i!=8 && (text[i]<'0' || text[i]>'9')) return 0;
        std::tm date{};std::istringstream in(text);
        in>>std::get_time(&date,"%Y%m%d-%H%M%S");
        if(in.fail()) return 0;
        date.tm_isdst=-1;auto time=std::mktime(&date);
        char check[32]{};
        return time>0 && std::strftime(check,sizeof check,"%Y%m%d-%H%M%S",&date) && text==check ? int64_t(time)*1000 : 0;
    };
    if(auto t=stamp(name.size())) return t;
    if(last+1==name.size() || name.find_first_not_of("0123456789",last+1)!=std::string::npos) return 0;
    return stamp(last);
}
static Json timeline(const GameAdapter& game,const Json& folders,const std::atomic_bool& stop) {
    std::vector<Json> rows;
    size_t skipped=0;
    std::set<Path> visited;
    for(const auto& value:folders) {
        std::error_code ec;
        auto dir=fs::weakly_canonical(fs::u8path(value.get<std::string>()),ec);
        if(ec || !visited.insert(dir).second) continue;
        fs::directory_iterator it(dir,ec),end;
        if(ec){++skipped;continue;}
        while(it!=end && !stop) {
            auto p=it->path();
            bool regular=it->symlink_status(ec).type()==fs::file_type::regular;
            if(regular) {
                auto ext=p.extension().u8string();
                std::transform(ext.begin(),ext.end(),ext.begin(),[](unsigned char c){return c>='A' && c<='Z'?char(c+32):char(c);});
                if(ext=="."+game.info.extension) try {
                    auto package=readPackage(game,p);
                    rows.push_back({{"name",p.filename().u8string()},{"path",p.u8string()},
                        {"created",package.createdMs?package.createdMs:legacyDate(p)},{"progress",progress(package.progress)}});
                } catch(const Error& e) {if(std::string(e.what())!="WrongFormat") ++skipped;}
                  catch(const std::exception&) {++skipped;}
            }
            it.increment(ec);if(ec){++skipped;break;}
        }
    }
    std::sort(rows.begin(),rows.end(),[](const Json& a,const Json& b) {
        if(a["created"]!=b["created"]) return a["created"]>b["created"];
        return a["path"]<b["path"];
    });
    return {{"rows",rows},{"skipped",skipped}};
}
Json request(const Json& in,const std::atomic_bool& stop) {
    auto op=in.at("op").get<std::string>();
    if(op=="updateFeed")return "https://api.github.com/repos/airanluo-dot/Bonfire/releases";
    if(op=="selectUpdate")return selectUpdate(in);
    if(op=="catalog") {
        Json list=Json::array();
        for(auto game:catalog()) list.push_back({{"id",game->info.id},{"ext",game->info.extension}});
        return list;
    }
    auto id=in.at("game").get<std::string>();
    auto found=std::find_if(catalog().begin(),catalog().end(),[&](auto g){return g->info.id==id;});
    if(found==catalog().end()) throw Error("UnknownGame");
    const auto& game=**found;
    auto path=[&](const char* key){return fs::u8path(in.at(key).get<std::string>());};
    if(op=="timeline") return timeline(game,in.at("folders"),stop);
    if(op=="locate" || op=="identify") {
        std::vector<Path> roots;
        if(op=="locate") roots=locate(game,stop);
        else {auto root=game.identify(path("path"));if(root.empty())throw Error("InvalidLocation");roots.push_back(root);}
        Json list=Json::array();
        for(auto& root:roots) list.push_back({{"root",root.u8string()},{"install",game.installation(root).u8string()},{"save",game.saveDirectory(root).u8string()}});
        return list;
    }
    if(op=="inventory") return progress(game.inventory(path("root")));
    if(op=="preview") {
        auto p=readPackage(game,path("path"));
        return {{"progress",progress(p.progress)},{"checksum",p.checksum}};
    }
    if(op=="export") return extract(game,path("root"),path("folder"),in.value("title",game.info.id)).u8string();
    if(op=="import") {
        auto p=readPackage(game,path("path"));
        if(in.at("checksum")!=p.checksum) throw Error("ChangedPackage");
        receive(game,path("root"),p);return true;
    }
    throw Error("InvalidRequest");
}
}
#ifdef _WIN32
#define BF_API extern "C" __declspec(dllexport)
#else
#define BF_API extern "C"
#endif
BF_API void* bf_token_new(){return new(std::nothrow) std::atomic_bool(false);}
BF_API void bf_cancel(void* p){if(p)*static_cast<std::atomic_bool*>(p)=true;}
BF_API void bf_token_free(void* p){delete static_cast<std::atomic_bool*>(p);}
BF_API void bf_free(void* p){std::free(p);}
BF_API char* bf_request(const char* input,void* token) {
    using namespace transfer;
    Json result;
    try {
        static const std::atomic_bool never{false};
        result={{"value",request(Json::parse(input),token?*static_cast<std::atomic_bool*>(token):never)}};
    } catch(const Error& e) {result={{"error",e.what()},{"args",e.arguments}};}
      catch(const std::exception& e) {result={{"error","Unexpected"},{"args",Json::array({e.what()})}};}
    auto text=result.dump(-1,' ',false,Json::error_handler_t::replace);
    auto copy=static_cast<char*>(std::malloc(text.size()+1));
    if(copy) std::memcpy(copy,text.c_str(),text.size()+1);
    return copy;
}
