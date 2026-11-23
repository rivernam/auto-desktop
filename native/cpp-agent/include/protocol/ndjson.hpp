#pragma once

#include <nlohmann/json.hpp>
#include <istream>
#include <string_view>

namespace desktop {
using Json = nlohmann::json;
inline constexpr std::size_t frameLimit = 65536;

bool readFrame(std::istream& input, std::string& frame);
Json parseFrame(std::string_view frame);

// These helpers take UTF-8 already validated by the protocol parser.
std::size_t utf16Length(std::string_view text);
bool isBlank(std::string_view text);
}
