// Queries the Windows input driver without sending input, installing hooks or touching any window.
#include "windows/input_driver.hpp"
#include "../src/windows/input_observation.hpp"

#include <iostream>

using namespace desktop;

void checkObservations() {
    using namespace windows;
    InputObservations observations;
    observations.start(123);
    if (observations.missing({2, 4}) != (mouseObservation | keyboardObservation))
        throw std::runtime_error("total hook loss");
    if (!observations.record(InputDevice::mouse, 123) || !observations.record(InputDevice::mouse, 123))
        throw std::runtime_error("current mouse events");
    if (!observations.record(InputDevice::keyboard, 123) || !observations.record(InputDevice::keyboard, 123))
        throw std::runtime_error("current keyboard events");
    if (observations.missing({2, 4}) != keyboardObservation || observations.missing({4, 2}) != mouseObservation)
        throw std::runtime_error("partial or individual hook loss was masked by the other counter");
    if (observations.missing({2, 2}))
        throw std::runtime_error("complete observations");
    observations.start(124);
    if (observations.record(InputDevice::mouse, 123) || observations.record(InputDevice::keyboard, 123))
        throw std::runtime_error("late events credited to a new request");
    if (observations.missing({1, 1}) != (mouseObservation | keyboardObservation))
        throw std::runtime_error("stale counters after restart");
}

int main() {
    try {
        checkObservations();
        const auto driver = windows::makeInputDriver();
        const auto status = driver->status();
        const Json report{{"available", status.available}, {"reason", status.reason},
                          {"dpiAwareness", status.dpiAwareness}, {"integrity", status.integrity},
                          {"inputDesktop", status.inputDesktop}, {"monitors", status.monitors},
                          {"buttonsSwapped", status.buttonsSwapped},
                          {"virtualScreen", {{"x", status.virtualScreen.x}, {"y", status.virtualScreen.y},
                                             {"width", status.virtualScreen.width},
                                             {"height", status.virtualScreen.height}}}};
        std::cout << report.dump() << '\n';
        // The test executable has the agent's manifest, so its thread gets per-monitor v2 where Windows has it.
        if (status.dpiAwareness != "perMonitorV2" && status.dpiAwareness != "perMonitor" && status.dpiAwareness != "system"
            && status.dpiAwareness != "unaware") throw std::runtime_error("unknown DPI awareness");
        if (status.virtualScreen.width <= 0 || status.virtualScreen.height <= 0 || status.monitors < 1)
            throw std::runtime_error("no virtual screen");
        if (!driver->held().empty()) throw std::runtime_error("a new session holds keys");
        for (const std::uint32_t window : {0u, 0xFFFFFFF0u}) {
            try {
                driver->windowRect(window, 4);
                throw std::runtime_error("a missing window has a rectangle");
            } catch (const Error& error) {
                if (std::string_view(error.code) != "WINDOW_NOT_FOUND" || error.inputSent != false)
                    throw std::runtime_error("missing window code");
            }
        }
    } catch (const std::exception& ex) {
        std::cerr << ex.what() << '\n';
        return 1;
    }
}
