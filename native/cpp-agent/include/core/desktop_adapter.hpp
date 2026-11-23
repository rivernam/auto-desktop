#pragma once

#include <functional>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace desktop {
struct Error : std::runtime_error {
    const char* code;
    bool retire;

    Error(const char* code, const char* message, bool retire = false)
        : std::runtime_error(message), code(code), retire(retire) {}
};

enum class Action { invoke, setValue };

struct Bounds {
    long x, y;
    long long width, height;
};

struct Identity {
    std::string name, role, automationId, className;
    bool clipped = false;

    bool operator==(const Identity& other) const {
        return name == other.name && role == other.role && automationId == other.automationId
            && className == other.className && clipped == other.clipped;
    }
};

struct Element {
    Identity identity;
    int pid = 0;
    std::optional<std::size_t> parent;
    std::optional<Bounds> bounds;
    bool enabled = true;
    bool offscreen = false;
    bool invoke = false;
    bool writable = false;
};

struct Window {
    std::string id;
    int pid;
    std::string name;
};

struct Capture {
    // Parent-before-child order. Indices address the adapter's latest native cache.
    std::vector<Element> elements;
    bool truncated = false;
};

using BeforeMutation = std::function<void()>;
using AllowedProcess = std::function<bool(int)>;

class DesktopAdapter {
public:
    virtual ~DesktopAdapter() = default;
    virtual const char* backend() const { return "UIA"; }
    virtual bool available() { return true; }
    virtual std::vector<Window> windows() = 0;
    virtual Capture capture(const std::string& windowId, std::optional<std::size_t> scope,
                            int depth, int limit) = 0;
    virtual Element info(std::size_t index) = 0;
    virtual void perform(Action action, std::size_t index, const std::string& value,
                         const BeforeMutation& before) = 0;
    virtual void clear() noexcept = 0;
};
} // namespace desktop
