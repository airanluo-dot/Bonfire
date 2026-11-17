#pragma once
#include "adapter.hpp"

namespace transfer {
constexpr size_t fileLimit=16*1024*1024, totalLimit=64*1024*1024, countLimit=256;
Bytes readBounded(const Path& file,size_t limit);
bool writeNewFile(const Path& file,const Bytes& contents);
bool portableEntry(const std::string& name);
Bytes encodePackage(const GameAdapter& game,const Files& files);
}
