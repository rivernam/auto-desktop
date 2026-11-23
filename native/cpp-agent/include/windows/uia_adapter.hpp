#pragma once

#include "core/desktop_adapter.hpp"

#include <cstdint>
#include <memory>

namespace desktop::windows {
std::optional<std::uint64_t> processStart(int pid);
std::string sessionToken();
std::unique_ptr<DesktopAdapter> makeAdapter();
}
