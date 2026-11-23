#include "protocol/ndjson.hpp"

#include <cstdint>
#include <unordered_set>
#include <vector>

namespace desktop {
bool readFrame(std::istream& input, std::string& frame) {
    frame.clear();
    bool oversized = false;
    int byte;
    while ((byte = input.get()) != std::char_traits<char>::eof() && byte != '\n') {
        if (frame.size() < frameLimit) frame.push_back(static_cast<char>(byte));
        else oversized = true;
    }
    if (oversized) frame.clear();
    return byte == '\n' || oversized || !frame.empty();
}

Json parseFrame(std::string_view frame) {
    if (frame.empty() || frame.size() > frameLimit || frame.substr(0, 3) == "\xEF\xBB\xBF"
        || frame.find('\0') != std::string_view::npos) return nullptr;
    struct InvalidFrame {};
    std::vector<std::unordered_set<std::string>> keys;
    const auto validate = [&](int depth, Json::parse_event_t event, const Json& node) {
        using Event = Json::parse_event_t;
        if (depth > 128) throw InvalidFrame{};
        if (event == Event::object_start) keys.emplace_back();
        if (event == Event::key && !keys.back().insert(node.get_ref<const std::string&>()).second)
            throw InvalidFrame{};
        if (event == Event::object_end) keys.pop_back();
        return true;
    };
    try {
        auto request = Json::parse(frame.begin(), frame.end(), validate);
        if (request.is_object()) return request;
    } catch (const Json::exception&) {
        // Parser diagnostics can contain request data.
    } catch (const InvalidFrame&) {}
    return nullptr;
}

std::size_t utf16Length(std::string_view text) {
    std::size_t units = 0;
    for (unsigned char byte : text) {
        if ((byte & 0xc0) != 0x80) units += byte >= 0xf0 ? 2 : 1;
    }
    return units;
}

bool isBlank(std::string_view text) {
    std::uint32_t point = 0;
    int remaining = 0;
    for (unsigned char byte : text) {
        if (remaining) {
            point = (point << 6) | (byte & 0x3f);
            if (--remaining) continue;
        } else if (byte >= 0x80) {
            remaining = byte >= 0xf0 ? 3 : byte >= 0xe0 ? 2 : 1;
            point = byte & (0x3f >> remaining);
            continue;
        } else {
            point = byte;
        }
        if (!(point == 0x20 || (point >= 9 && point <= 13) || (point >= 0x1c && point <= 0x1f)
              || point == 0x1680 || (point >= 0x2000 && point <= 0x2006)
              || (point >= 0x2008 && point <= 0x200a) || point == 0x2028 || point == 0x2029
              || point == 0x205f || point == 0x3000)) return false;
    }
    return true;
}
} // namespace desktop
