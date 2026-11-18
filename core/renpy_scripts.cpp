#include "renpy_scripts.hpp"
#include "inflate.hpp"
#include <charconv>
#include <fstream>
#include <set>

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

// A Ren'Py statement ID in the saved execution/rollback state is a tuple
// (script filename, script timestamp, serial). Only recognize that literal
// encoding in the protocol-2 log. A gallery flag or dialogue string alone
// does not establish a script dependency. Never load Python objects.
static uint32_t little32(const Bytes& bytes, size_t pos) {
    return bytes[pos] | (unsigned(bytes[pos+1])<<8) |
        (unsigned(bytes[pos+2])<<16) | (uint32_t(bytes[pos+3])<<24);
}
void visitRenpyStatements(const Bytes& log, const std::function<void(std::string_view)>& visit) {
    if (log.size() < 8 || log[0] != 0x80 || log[1] != 2) return;
    std::set<uint32_t> currentFields;
    const std::string_view view(reinterpret_cast<const char*>(log.data()), log.size());
    for (size_t i = 2; i + 5 < log.size(); ++i) {
        // The execution context stores the statement ID under "current".
        // Later contexts often refer to that field by its pickle memo index.
        size_t pos = i;
        bool direct = false;
        if (log[i]=='U' && log[i+1]==7 && view.substr(i+2,7)=="current") {
            pos=i+9; direct=true;
        } else if (log[i]=='X' && little32(log,i+1)==7 && view.substr(i+5,7)=="current") {
            pos=i+12; direct=true;
        } else if (log[i]=='h' && currentFields.count(log[i+1])) pos=i+2;
        else if (log[i]=='j' && currentFields.count(little32(log,i+1))) pos=i+5;
        else continue;
        if (direct && pos+2 <= log.size() && log[pos]=='q') {
            currentFields.insert(log[pos+1]); pos+=2;
        } else if (direct && pos+5 <= log.size() && log[pos]=='r') {
            currentFields.insert(little32(log,pos+1)); pos+=5;
        }
        if (pos+5 >= log.size() || log[pos]!='X') continue; // BINUNICODE filename
        auto length=little32(log,pos+1);
        pos+=5;
        if (length < 16 || length > 4096 || length >= log.size() - pos) continue;
        std::string_view path(reinterpret_cast<const char*>(log.data()+pos), length);
        pos += length;
        if (log[pos] == 'q') pos += 2;       // BINPUT
        else if (log[pos] == 'r') pos += 5;  // LONG_BINPUT
        for (int n = 0; n < 2 && pos < log.size(); ++n) {
            if (log[pos] == 'J') pos += 5;       // BININT
            else if (log[pos] == 'M') pos += 3;  // BININT2
            else if (log[pos] == 'K') pos += 2;  // BININT1
            else { pos = log.size(); break; }
        }
        if (pos < log.size() && log[pos] == 0x87) visit(path); // TUPLE3
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
