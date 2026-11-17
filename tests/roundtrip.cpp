#include "../core/transfer.hpp"
#include "../app/runtime.hpp"
#include "fixture.hpp"
#include <algorithm>
#include <fstream>
#include <functional>
#include <iostream>
#ifdef _WIN32
#include <windows.h>
#endif
using namespace transfer;
static bool running=false;
bool transfer::gameIsRunning(const GameAdapter&,const Path&) { return running; }
std::vector<Path> transfer::locate(const GameAdapter&,const std::atomic_bool&) { return {}; }
static void require(bool ok,const char* text){if(!ok)throw std::runtime_error(text);}
static Bytes bytes(const Path& p){std::ifstream f(p,std::ios::binary);return {std::istreambuf_iterator<char>(f),{}};}
static void put(const Path& p,const std::string& v){std::ofstream f(p,std::ios::binary);f<<v;require(f.good(),"fixture write");}
static void mustFail(const std::function<void()>& action){try{action();}catch(const std::exception&){return;}throw std::runtime_error("operation should fail");}

// The second argument must be a new empty directory; only fixtures are modified.
static int test(const Path& original,const Path& tmp){
    const auto& games=catalog();
    auto it=std::find_if(games.begin(),games.end(),[](auto g){return g->info.id=="jurodo";});
    require(it!=games.end(),"registered Jurodo adapter");
    const auto& game=**it;
    require(!game.identify(original).empty(),"real game identity");require(fs::is_empty(tmp),"test directory must be empty");
    auto incoming=extract(game,original,tmp);
    auto p=readPackage(game,incoming);
    require(p.progress.count==game.inventory(original).count && p.progress.playtime==game.inventory(original).playtime,"package preview matches the saved progress count and playtime");
    for(auto& [n,b]:p.files)require(b==bytes(original/"save"/n),"original bytes");
    std::cout<<"Extract + parse: "<<p.progress.count<<" / "<<p.progress.playtime<<"\n";
#ifdef _WIN32
    auto target=tmp/"game";
#else
    auto target=tmp/"game.app"/"Contents"/"Resources"/"app.nw";
#endif
    fs::create_directories(target/"data");fs::create_directories(target/"js");
    fs::copy_file(original/"data"/"System.json",target/"data"/"System.json");
    put(target/"js"/"rmmz_managers.js","");
#ifdef _WIN32
    put(target/"Jurodo.exe","");
#else
    put(target.parent_path().parent_path()/"Info.plist","");
#endif
    std::atomic_bool stop{false};
    auto found=discover(game,{}, {tmp}, {}, stop);require(found.size()==1 && fs::equivalent(found.front(),target),"scan from nondefault path");
    require(!fs::exists(target/"save"),"clean install fixture");
    receive(game,target,p);
    auto dir=target/"save";
    for(auto& [n,b]:p.files)require(b==bytes(dir/n),"replace empty install");
    std::cout<<"Create missing save directory and verify all files: OK\n";
    put(dir/"file999.rmmzsave","stale");put(dir/"notes.txt","keep");
    put(dir/"file1.rmmzsave","old progress");put(dir/"config.rmmzsave","old settings");
#ifdef _WIN32
    HANDLE locked=CreateFileW((dir/"file1.rmmzsave").c_str(),GENERIC_READ,FILE_SHARE_READ,nullptr,OPEN_EXISTING,0,nullptr);
    require(locked!=INVALID_HANDLE_VALUE,"hold exclusive writer off");
    mustFail([&]{receive(game,target,p);});CloseHandle(locked);
    auto config=bytes(dir/"config.rmmzsave");require(std::string(config.begin(),config.end())=="old settings","rollback previous file");
    require(fs::exists(dir/"file999.rmmzsave"),"rollback keeps stale slot");
    std::cout<<"Partial write failure and in-memory rollback: OK\n";
#endif
    running=true;mustFail([&]{receive(game,target,p);});running=false;
    receive(game,target,p);receive(game,target,p);
    require(!fs::exists(dir/"file999.rmmzsave"),"remove stale slot");require(bytes(dir/"notes.txt")==Bytes{'k','e','e','p'},"preserve unmanaged file");
    for(auto& [n,b]:p.files)require(b==bytes(dir/n),"verify replacement and retry");
    require(static_cast<size_t>(std::distance(fs::directory_iterator(dir),fs::directory_iterator{}))==p.files.size()+1,"no other files");
    require(readPackage(game,extract(game,target,tmp)).files==p.files,"re-export after import is byte-identical");
    auto bad=bytes(incoming);bad[bad.size()/2]^=1;
    auto corrupt=tmp/"corrupt.jurosave";std::ofstream(corrupt,std::ios::binary).write((const char*)bad.data(),bad.size());
    mustFail([&]{readPackage(game,corrupt);});
    auto broken=p;broken.files["file1.rmmzsave"]=Bytes{42};mustFail([&]{receive(game,target,broken);});
    for(auto& [n,b]:p.files)require(b==bytes(dir/n),"invalid input leaves target intact");
    const auto& other=fixture::adapter();
    auto second=tmp/"fixture";
    fs::create_directories(other.saveDirectory(second));
    put(second/"fixture.marker","test");
    auto slot=other.saveDirectory(second)/"slot.dat";
    put(slot,"original fixture progress");
    auto secondFile=extract(other,second,tmp);
    auto secondPackage=readPackage(other,secondFile);
    mustFail([&]{readPackage(other,incoming);});mustFail([&]{readPackage(game,secondFile);});
    mustFail([&]{receive(other,second,p);});mustFail([&]{receive(game,target,secondPackage);});
    require(bytes(slot)==secondPackage.files.at("slot.dat"),"wrong game cannot replace fixture data");
    put(slot,"stale");receive(other,second,secondPackage);
    require(bytes(slot)==secondPackage.files.at("slot.dat"),"independent adapter layout and replacement");
    std::cout<<"Replace, stale slots, unrelated files, repeat, byte-identical re-export, invalid input: OK\n";
    return 0;
}
#ifdef _WIN32
int wmain(int argc,wchar_t** argv)
#else
int main(int argc,char** argv)
#endif
{
    if(argc==1){
        Json input;
        try {std::cin>>input;std::cout<<request(input,std::atomic_bool{false}).dump();}
        catch(const Error& error){std::cout<<Json{{"error",error.what()}}.dump();}
        return 0;
    }
    if(argc!=3)return 2;
    try{return test(argv[1],argv[2]);}catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;}
}
