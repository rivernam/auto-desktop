#pragma once

#include "core/input.hpp"

#include <memory>

namespace desktop::windows {
// SendInput with the checks of docs/PHYSICAL-INPUT.md. Low-level hooks are installed only when the
// first input of the session is about to leave. Nothing is installed or sent by construction or status().
std::unique_ptr<InputDriver> makeInputDriver();
}
