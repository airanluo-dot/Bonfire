#include "renpy_scripts.hpp"
#include "inflate.hpp"
#include <charconv>
#include <fstream>
#include <string_view>

namespace transfer {
namespace {
constexpr size_t MiB = 1024 * 1024;

std::optional<Bytes> archiveIndex(const Path& path) {
    std::ifstream stream(path, std::ios::binary | std::ios::ate);
    const auto size = stream.tellg();
    char header[34];
    if (size < 34 || !stream.seekg(0).read(header, sizeof header) ||
        std::string_view(header, 8) != "RPA-3.0 " || header[24] != ' ' || header[33] != '\n') return {};
    uint64_t offset = 0;
    auto parsed = std::from_chars(header + 8, header + 24, offset, 16);
    const auto end = static_cast<uint64_t>(size);
    if (parsed.ec != std::errc{} || parsed.ptr != header + 24 || offset < sizeof header ||
        offset > end || end - offset < 8 || end - offset > 4 * MiB) return {};
    Bytes packed(static_cast<size_t>(end - offset));
    if (!stream.seekg(static_cast<std::streamoff>(offset)).read(reinterpret_cast<char*>(packed.data()),
                                                                 static_cast<std::streamsize>(packed.size()))) return {};
    if ((packed[0] & 15) != 8 || (packed[0] >> 4) > 7 || (packed[1] & 32) ||
        ((unsigned(packed[0]) << 8) + packed[1]) % 31) return {};

    Bytes index(64 * 1024);
    for (;;) {
        unsigned long length = static_cast<unsigned long>(index.size());
        unsigned long used = static_cast<unsigned long>(packed.size() - 6);
        int status = inflateRaw(index.data(), &length, packed.data() + 2, &used);
        if (status == 0) {
            if (used != packed.size() - 6) return {};
            index.resize(length);
            break;
        }
        if (status != 1 || index.size() >= 8 * MiB) return {};
        index.resize(index.size() * 2);
    }
    // Both distributions use Python protocol 5 indexes with short literal path keys.
    if (index.size() < 4 || index[0] != 0x80 || index[1] != 5 || index.back() != '.') return {};
    uint32_t a = 1, b = 0, checksum = 0;
    for (auto c : index) { a = (a + c) % 65521; b = (b + a) % 65521; }
    for (size_t i = packed.size() - 4; i < packed.size(); ++i) checksum = (checksum << 8) | packed[i];
    if (checksum != ((b << 16) | a)) return {};
    return index;
}
}

std::optional<bool> renpyHasScript(const Path& directory, const std::string& sourceName) {
    std::error_code ec;
    for (const auto& name : {sourceName, sourceName + "c"})
        if (fs::is_regular_file(directory / fs::u8path(name), ec)) return true;
    std::vector<std::string> keys;
    for (const auto& name : {sourceName, sourceName + "c"}) {
        if (name.size() > 255) return {};
        keys.push_back(std::string{char(0x8c), static_cast<char>(name.size())} + name);
        keys.push_back(std::string{'C', static_cast<char>(name.size())} + name);
    }
    bool unknownArchive = false;
    for (fs::directory_iterator it(directory, ec), end; !ec && it != end; it.increment(ec)) {
        const auto path = it->path();
        if (path.extension() != ".rpa") continue;
        if (!it->is_regular_file(ec)) { unknownArchive = true; continue; }
        auto index = archiveIndex(path);
        if (!index) { unknownArchive = true; continue; }
        std::string_view bytes(reinterpret_cast<const char*>(index->data()), index->size());
        for (const auto& key : keys) if (bytes.find(key) != bytes.npos) return true;
    }
    if (ec || unknownArchive) return {};
    return false;
}
}
