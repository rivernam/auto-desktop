#pragma once

#include <atomic>
#include <cstdint>

namespace desktop::windows {

enum class InputDevice { mouse, keyboard };
enum : unsigned { mouseObservation = 1, keyboardObservation = 2 };

struct InputEventCounts {
    std::uint32_t mouse = 0;
    std::uint32_t keyboard = 0;

    void add(InputDevice device) {
        ++(device == InputDevice::mouse ? mouse : keyboard);
    }
};

// Each atomic holds the request tag and the count together. A callback delayed from an
// earlier request cannot increment the new count after the requesting thread resets it.
class InputObservations {
public:
    void start(std::uint32_t tag) {
        const auto initial = static_cast<std::uint64_t>(tag) << 32;
        mouse_.store(initial, std::memory_order_release);
        keyboard_.store(initial, std::memory_order_release);
    }

    bool record(InputDevice device, std::uint32_t tag) {
        auto& counter = device == InputDevice::mouse ? mouse_ : keyboard_;
        auto current = counter.load(std::memory_order_acquire);
        while (current >> 32 == tag) {
            if (counter.compare_exchange_weak(current, current + 1, std::memory_order_acq_rel)) return true;
        }
        return false;
    }

    unsigned missing(const InputEventCounts& expected) const {
        const auto mouse = static_cast<std::uint32_t>(mouse_.load(std::memory_order_acquire));
        const auto keyboard = static_cast<std::uint32_t>(keyboard_.load(std::memory_order_acquire));
        return (mouse < expected.mouse ? mouseObservation : 0u)
            | (keyboard < expected.keyboard ? keyboardObservation : 0u);
    }

private:
    std::atomic<std::uint64_t> mouse_{0}, keyboard_{0};
};

} // namespace desktop::windows
