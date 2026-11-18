#pragma once
#include "runtime.hpp"
namespace transfer {
// Both shells supply all published release pages. Return an empty object
// when current, or a verified asset plan for the newest usable release.
Json selectUpdate(const Json& input);
// Without a checksum manifest, return the official URLs to query. With the
// manifest and the exact asset size, return the same plan as selectUpdate.
Json webUpdate(const Json& input);
}
