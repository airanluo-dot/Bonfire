#include "renpy_format.hpp"
#include "inflate.hpp"
#include "../vendor/json.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <set>
#include <string_view>

namespace transfer {
namespace {
constexpr size_t MiB = 1024 * 1024;
constexpr size_t expandedMemberLimit = 64 * MiB;
constexpr std::string_view suffix = "-LT1.save";

[[noreturn]] void invalid() { throw Error("Renpy_Format"); }

bool digits(std::string_view text) {
    return !text.empty() && std::all_of(text.begin(), text.end(), [](char c) {
        return c >= '0' && c <= '9';
    });
}

void extent(size_t offset, size_t length, size_t end) {
    if (offset > end || length > end - offset) invalid();
}

// All fields in ZIP headers are little endian. Callers bound the header first.
unsigned u16(const Bytes& bytes, size_t at) {
    return bytes[at] | (unsigned(bytes[at + 1]) << 8);
}
uint32_t u32(const Bytes& bytes, size_t at) {
    return u16(bytes, at) | (uint32_t(u16(bytes, at + 2)) << 16);
}

uint32_t crc32(const Bytes& bytes) {
    static constexpr auto table = [] {
        std::array<uint32_t, 256> values{};
        for (uint32_t i = 0; i < values.size(); ++i) {
            auto v = i;
            for (int bit = 0; bit < 8; ++bit) v = (v >> 1) ^ ((v & 1) ? 0xedb88320u : 0u);
            values[i] = v;
        }
        return values;
    }();
    uint32_t value = 0xffffffffu;
    for (auto c : bytes) value = table[(value ^ c) & 255] ^ (value >> 8);
    return ~value;
}

// Check only the framing of binary pickle data. The engine owns deserialization.
void checkPickle(const Bytes& bytes) {
    if (bytes.size() < 4 || bytes[0] != 0x80 || bytes[1] < 2 ||
        bytes[1] > 5 || bytes.back() != '.') invalid();
}

bool base64Field(std::string_view field) {
    if (field.empty() || field.size() % 4) return false;
    if (field.back() == '=') field.remove_suffix(1);
    if (field.back() == '=') field.remove_suffix(1);
    return std::all_of(field.begin(), field.end(), [](char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
               (c >= '0' && c <= '9') || c == '+' || c == '/';
    });
}

bool checkPersistent(const Bytes& bytes) {
    if (bytes.size() < 8 || (bytes[0] & 15) != 8 || (bytes[0] >> 4) > 7 ||
        ((bytes[0] << 8) + bytes[1]) % 31 || (bytes[1] & 32)) invalid();

    Bytes plain(64 * 1024);
    size_t tail;
    for (;;) {
        auto used = static_cast<unsigned long>(bytes.size() - 2);
        auto length = static_cast<unsigned long>(plain.size());
        int result = inflateRaw(plain.data(), &length, bytes.data() + 2, &used);
        if (result == 0) {
            plain.resize(length);
            tail = 2 + used;
            break;
        }
        if (result != 1 || plain.size() == expandedMemberLimit) invalid();
        plain.resize(plain.size() * 2);
    }
    extent(tail, 4, bytes.size());
    uint32_t a = 1, b = 0;
    for (auto c : plain) {
        a = (a + c) % 65521;
        b = (b + a) % 65521;
    }
    uint32_t checksum = 0;
    for (int i = 0; i < 4; ++i) checksum = (checksum << 8) | bytes[tail++];
    if (checksum != ((b << 16) | a)) invalid();
    checkPickle(plain);

    // Ren'Py 8 appends text signatures after the zlib stream. Leave the
    // signatures intact for the engine's own verification on the destination.
    std::string_view signatures(reinterpret_cast<const char*>(bytes.data() + tail), bytes.size() - tail);
    const bool signedPersistent = !signatures.empty();
    while (!signatures.empty()) {
        auto newline = signatures.find('\n');
        if (newline == std::string_view::npos || signatures.substr(0, 10) != "signature ") invalid();
        auto fields = signatures.substr(10, newline - 10);
        if (!fields.empty() && fields.back() == '\r') fields.remove_suffix(1);
        auto separator = fields.find(' ');
        if (separator == fields.npos || !base64Field(fields.substr(0, separator)) ||
            !base64Field(fields.substr(separator + 1))) invalid();
        signatures.remove_prefix(newline + 1);
    }
    return signedPersistent;
}

struct Slot {
    uint32_t dosTime = 0;
    double created = -1;
    double seconds = -1;
};

double number(const nlohmann::json& object, const char* key) {
    auto field = object.find(key);
    return field != object.end() && field->is_number() ? field->get<double>() : -1;
}

Slot readSlot(const Bytes& bytes, size_t& budget, const RenpyLogVisitor& visitLog,
              const RenpyMetadataVisitor& visitMetadata, nlohmann::json* slotMetadata) {
    // Python's ZipFile writer creates seekable, single-disk archives with no
    // archive comment. Each directory record points to a matching local header.
    extent(0, 22, bytes.size());
    const auto end = bytes.size() - 22;
    if (u32(bytes, end) != 0x06054b50 || u32(bytes, end + 4) || u16(bytes, end + 20)) invalid();
    const auto count = u16(bytes, end + 10);
    const size_t central = u32(bytes, end + 16);
    if (!count || count > 64 || count != u16(bytes, end + 8) ||
        central > end || end - central != u32(bytes, end + 12)) invalid();

    Slot slot;
    std::set<std::string> names;
    size_t pos = central;
    for (unsigned i = 0; i < count; ++i) {
        extent(pos, 46, end);
        if (u32(bytes, pos) != 0x02014b50 || u16(bytes, pos + 34)) invalid();
        const auto flags = u16(bytes, pos + 8);
        const auto method = u16(bytes, pos + 10);
        const auto crc = u32(bytes, pos + 16);
        const size_t packed = u32(bytes, pos + 20), length = u32(bytes, pos + 24);
        const size_t nameSize = u16(bytes, pos + 28);
        const auto recordSize = 46 + nameSize + u16(bytes, pos + 30) + u16(bytes, pos + 32);
        extent(pos, recordSize, end);
        if ((flags & ~0x0806u) || (method != 0 && method != 8) ||
            length > expandedMemberLimit || length > budget) invalid();
        budget -= length;
        std::string name(bytes.begin() + pos + 46, bytes.begin() + pos + 46 + nameSize);
        if (!names.insert(name).second) invalid();
        const size_t local = u32(bytes, pos + 42);
        extent(local, 30, central);
        if (u32(bytes, local) != 0x04034b50 || u16(bytes, local + 6) != flags ||
            u16(bytes, local + 8) != method || u32(bytes, local + 14) != crc ||
            u32(bytes, local + 18) != packed || u32(bytes, local + 22) != length ||
            u16(bytes, local + 26) != nameSize) invalid();
        const auto payload = local + 30 + nameSize + u16(bytes, local + 28);
        extent(payload, packed, central);
        if (!std::equal(name.begin(), name.end(), bytes.begin() + local + 30)) invalid();

        Bytes plain(std::max<size_t>(1, length));
        if (method == 8) {
            auto output = static_cast<unsigned long>(length);
            auto input = static_cast<unsigned long>(packed);
            if (inflateRaw(plain.data(), &output, bytes.data() + payload, &input) ||
                input != packed || output != length) invalid();
        } else {
            if (packed != length) invalid();
            std::copy_n(bytes.begin() + payload, length, plain.begin());
        }
        plain.resize(length);
        if (crc32(plain) != crc) invalid();
        if (name == "log") {
            checkPickle(plain);
            if (visitLog) visitLog(plain);
            slot.dosTime = u32(bytes, pos + 12);
        } else if (name == "json") {
            if (plain.size() > MiB) invalid();
            auto metadata = nlohmann::json::parse(plain.begin(), plain.end(), nullptr, false);
            if (!metadata.is_object()) invalid();
            if (visitMetadata) visitMetadata(metadata);
            slot.created = number(metadata, "_ctime");
            slot.seconds = number(metadata, "_game_runtime");
            if (slotMetadata) *slotMetadata = std::move(metadata);
        } else if (name == "renpy_version") {
            if (std::string_view(reinterpret_cast<const char*>(plain.data()), plain.size()).substr(0, 7) != "Ren'Py ") invalid();
        }
        pos += recordSize;
    }
    if (pos != end || !names.count("log") || !names.count("json") || !names.count("renpy_version")) invalid();
    return slot;
}

std::string duration(double value) {
    // Ren'Py records fractional seconds. Limit the conversion to a sensible,
    // exactly representable integer range even for hand-edited JSON metadata.
    if (!std::isfinite(value) || value < 0 || value >= 1e12) return {};
    const auto seconds = static_cast<unsigned long long>(value);
    char text[32];
    std::snprintf(text, sizeof(text), "%02llu:%02llu:%02llu", seconds / 3600, (seconds / 60) % 60, seconds % 60);
    return text;
}

// Older Ren'Py releases only timestamp ZIP members, using the source device's local clock.
std::string localSaveTime(uint32_t stamp) {
    const unsigned year = 1980 + (stamp >> 25), month = (stamp >> 21) & 15, day = (stamp >> 16) & 31;
    const unsigned hour = (stamp >> 11) & 31, minute = (stamp >> 5) & 63;
    const bool leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0);
    const unsigned days[] = {0,31,leap ? 29u : 28u,31,30,31,30,31,31,30,31,30,31};
    if (month == 0 || month > 12 || day == 0 || day > days[month] || hour > 23 || minute > 59) return {};
    // ZIP writers also use the DOS epoch for entries without a creation time.
    if (year == 1980 && month == 1 && day == 1 && hour == 0 && minute == 0) return {};
    char text[24];
    std::snprintf(text, sizeof(text), "%04u-%02u-%02u %02u:%02u", year, month, day, hour, minute);
    return text;
}
}

bool renpyEntry(const std::string& name) {
    if (name == "persistent") return true;
    std::string_view slot(name);
    if (slot.size() <= suffix.size() || slot.size() > 128 ||
        slot.substr(slot.size() - suffix.size()) != suffix) return false;
    slot.remove_suffix(suffix.size());
    if (slot == "quit" || digits(slot)) return true;
    auto hyphen = slot.find('-');
    if (hyphen == slot.npos || !digits(slot.substr(hyphen + 1))) return false;
    auto page = slot.substr(0, hyphen);
    return page == "auto" || page == "quick" || digits(page);
}

bool renpySignedPersistent(const Files& files) {
    auto persistent = files.find("persistent");
    return persistent != files.end() && checkPersistent(persistent->second);
}

Progress renpyProgress(const Files& files, const RenpyLogVisitor& visitLog, std::string_view packageMetadata,
                       const RenpyMetadataVisitor& visitMetadata, nlohmann::json* latestMetadata) {
    Progress result;
    Slot latest;
    // Bound total work as well as individual allocations for compressed saves.
    size_t budget = 1024 * MiB;
    for (const auto& [name, bytes] : files) {
        if (!packageMetadata.empty() && name == packageMetadata) continue;
        if (!renpyEntry(name)) invalid();
        if (name == "persistent") {
            checkPersistent(bytes);
            result.persistent = true;
            continue;
        }
        nlohmann::json metadata;
        auto slot = readSlot(bytes, budget, visitLog, visitMetadata, latestMetadata ? &metadata : nullptr);
        const bool newer = slot.created >= 0 && latest.created >= 0
            ? slot.created > latest.created : slot.dosTime > latest.dosTime;
        if (!result.count || newer) {
            latest = slot;
            if (latestMetadata) *latestMetadata = std::move(metadata);
            result.slotName = name.substr(0, name.size() - suffix.size());
        }
        ++result.count;
    }
    result.playtime = duration(latest.seconds);
    result.savedLocalTime = localSaveTime(latest.dosTime);
    return result;
}
}
