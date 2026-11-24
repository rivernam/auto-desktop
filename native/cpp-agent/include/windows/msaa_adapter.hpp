#pragma once

#include "core/desktop_adapter.hpp"

#include <memory>

namespace desktop::windows {
std::unique_ptr<DesktopAdapter> makeMsaaAdapter(AllowedProcess trustedProvider);
}
