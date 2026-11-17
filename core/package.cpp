#include "transfer.hpp"
#include "storage_internal.hpp"
#include <algorithm>
#include <chrono>
#ifdef _WIN32
#define NOMINMAX
#include <windows.h>
#include <bcrypt.h>
#else
#include <CommonCrypto/CommonDigest.h>
#endif
namespace transfer {
static Bytes signature(const GameAdapter& game) {
    Bytes header(game.info.packageTag.begin(),game.info.packageTag.end());
    header.insert(header.end(),{2,0,0,0});
    return header;
}
using Digest = std::array<unsigned char,32>;
static Digest digest(const Bytes& b, size_t n) {
    Digest out{};
#ifdef _WIN32
    BCRYPT_ALG_HANDLE algorithm{};
    if (BCryptOpenAlgorithmProvider(&algorithm,BCRYPT_SHA256_ALGORITHM,nullptr,0) < 0)
        throw Error("HashUnavailable");
    auto status = BCryptHash(algorithm,nullptr,0,const_cast<PUCHAR>(b.data()),static_cast<ULONG>(n),out.data(),32);
    BCryptCloseAlgorithmProvider(algorithm,0);
    if (status < 0) throw Error("HashFailed");
#else
    CC_SHA256(b.data(), static_cast<CC_LONG>(n), out.data());
#endif
    return out;
}

static void put(Bytes& b, uint32_t v) { for(int i=0;i<4;i++){ b.push_back(static_cast<unsigned char>(v)); v>>=8; } }
Bytes encodePackage(const GameAdapter& game,const Files& f) {
    Bytes b=signature(game);
    if (f.empty() || f.size()>countLimit) throw Error("InvalidCount");
    size_t total=0;
    auto now=std::chrono::duration_cast<std::chrono::milliseconds>(
        std::chrono::system_clock::now().time_since_epoch()).count();
    for(unsigned i=0;i<8;++i) b.push_back(static_cast<unsigned char>(uint64_t(now)>>(8*i)));
    put(b,static_cast<uint32_t>(f.size()));
    for(const auto& [name,data]:f) {
        if (!portableEntry(name) || !game.acceptsEntry(name) || data.size()>fileLimit || (total+=data.size())>totalLimit)
            throw Error("BadAdapter");
        put(b,static_cast<uint32_t>(name.size())); put(b,static_cast<uint32_t>(data.size()));
        b.insert(b.end(),name.begin(),name.end()); b.insert(b.end(),data.begin(),data.end());
    }
    auto hash=digest(b,b.size());
    b.insert(b.end(),hash.begin(),hash.end());
    return b;
}
Package readPackage(const GameAdapter& game,const Path& p) {
    auto b=readBounded(p,totalLimit+countLimit*136+56);
    auto header=signature(game);
    if (b.size()<48 || !std::equal(header.begin(),header.begin()+8,b.begin()) ||
        (b[8]!=1 && b[8]!=2) || b[9] || b[10] || b[11])
        throw Error("WrongFormat",{game.info.extension});
    size_t end=b.size()-32, pos=header.size();
    auto hash=digest(b,end);
    if (!std::equal(hash.begin(),hash.end(),b.begin()+end)) throw Error("BadHash");
    auto take=[&](){if(end-pos<4) throw Error("Truncated"); uint32_t v=0;
        for(unsigned i=0;i<4;++i) v|=uint32_t(b[pos++])<<(8*i); return v;};
    Package result;
    if(b[8]==2) {
        uint64_t timestamp=take();
        timestamp|=uint64_t(take())<<32;
        if(!timestamp || timestamp>253402300799999ULL) throw Error("BadLength");
        result.createdMs=static_cast<int64_t>(timestamp);
    }
    auto count=take();
    if (!count || count>countLimit) throw Error("InvalidCount");
    result.gameId=game.info.id;
    constexpr char hex[]="0123456789abcdef";
    for(auto byte:hash) { result.checksum+=hex[byte>>4]; result.checksum+=hex[byte&15]; }
    size_t total=0;
    for(unsigned i=0;i<count;++i) {
        auto nl=take(),len=take();
        if(nl>128 || nl>end-pos || len>fileLimit || len>end-pos-nl || (total+=len)>totalLimit)
            throw Error("BadLength");
        std::string name(b.begin()+pos,b.begin()+pos+nl); pos+=nl;
        if(!portableEntry(name) || !game.acceptsEntry(name) || result.files.count(name)) throw Error("BadName");
        result.files.emplace(name,Bytes(b.begin()+pos,b.begin()+pos+len)); pos+=len;
    }
    if(pos!=end) throw Error("Trailing");
    result.progress=game.validate(result.files);
    return result;
}

}
