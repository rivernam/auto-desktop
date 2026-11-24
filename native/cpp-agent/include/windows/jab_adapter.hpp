#pragma once

#include "core/desktop_adapter.hpp"

#include <memory>
#include <string>

namespace desktop::windows {
// Java Access Bridge for AWT and Swing windows. An empty path selects the Windows system directory,
// then the Java installation registered under HKLM. A failure to load is reported as a capability.
std::unique_ptr<DesktopAdapter> makeJabAdapter(const std::wstring& library);

// True once the bridge library stayed loaded because unloading it would wait on a silent JVM.
// The process must then end without library detach.
bool jabDetachWouldBlock();
}
