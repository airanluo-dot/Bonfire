#pragma once
#include "adapter.hpp"

namespace transfer {
constexpr size_t countLimit=256;
Bytes readBounded(const Path& file,size_t limit);
bool writeNewFile(const Path& file,const Bytes& contents);
bool portableEntry(const std::string& name);
Bytes encodePackage(const GameAdapter& game,const Files& files);
}
