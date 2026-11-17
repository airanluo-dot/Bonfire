#pragma once
#include "../core/transfer.hpp"
#include "../vendor/json.hpp"
namespace transfer {
using Json = nlohmann::json;
std::vector<Path> locate(const GameAdapter& game,const std::atomic_bool& stop);
Json request(const Json& input,const std::atomic_bool& stop);
}
