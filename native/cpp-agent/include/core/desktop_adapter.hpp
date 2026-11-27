#pragma once

#include <chrono>
#include <functional>
#include <optional>
#include <stdexcept>
#include <string>
#include <vector>

namespace desktop {
struct Error : std::runtime_error {
    const char* code;
    bool retire;
    // Physical input operations only: whether any input left the process for this request, and whether
    // held keys or buttons were released on the way out. Other errors keep their JSON shape.
    std::optional<bool> inputSent;
    bool released = false;

    Error(const char* code, const char* message, bool retire = false)
        : std::runtime_error(message), code(code), retire(retire) {}
};

// The last three permit physical input operations, never an accessibility action.
enum class Action { invoke, setValue, defaultAction, select, pointer, keyboard, activate, clipboard };

struct Bounds {
    long x, y;
    long long width, height;
};

struct Identity {
    std::string name, role, automationId, className;
    bool clipped = false;
    // The role as the provider names it, when the shared role vocabulary is coarser. Not a locator field.
    std::string nativeRole;

    bool operator==(const Identity& other) const {
        return name == other.name && role == other.role && automationId == other.automationId
            && className == other.className && clipped == other.clipped && nativeRole == other.nativeRole;
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
    // The capture omitted or cut short part of this element's own subtree.
    bool partial = false;
    // Optional cause of partial: "limit", "provider" or "limit,provider".
    std::string partialReason;
    std::string referenceStrength;
    bool defaultAction = false;
    bool select = false;
    std::optional<bool> selected;
};

struct Window {
    std::string id;
    int pid;
    std::string name;
    // Set for an owned top-level window such as a modal dialog or popup.
    std::string owner;
};

struct Capture {
    // Parent-before-child order. Indices address the adapter's latest native cache.
    std::vector<Element> elements;
    bool truncated = false;
};

struct Availability {
    bool available = true;
    // Shown to the operator when the backend cannot be used.
    std::string reason = "UI Automation could not access the interactive desktop.";
    // Java Access Bridge: visible Java top-level windows, and those a bridge-enabled JVM answers for.
    std::optional<std::pair<int, int>> javaWindows;
};

using BeforeMutation = std::function<void()>;
using AllowedProcess = std::function<bool(int)>;

class DesktopAdapter {
public:
    virtual ~DesktopAdapter() = default;
    virtual const char* backend() const { return "UIA"; }
    virtual bool available() { return true; }
    virtual Availability availability() {
        Availability result;
        result.available = available();
        return result;
    }
    // A positive interval asks the session thread to call idle() while no request is running.
    virtual std::chrono::milliseconds idleInterval() const { return std::chrono::milliseconds::zero(); }
    virtual void idle() noexcept {}
    // Handles the provider's own window messages until done() holds. The session thread calls it
    // while another backend of the same process runs a request, so that request never waits for
    // this thread. Only an adapter with an idle interval is asked.
    virtual void serve(const std::function<bool()>& done) noexcept { (void)done; }
    // Ends a wait inside serve() early. Callable from any thread.
    virtual void wake() noexcept {}
    virtual std::vector<Window> windows() = 0;
    virtual Capture capture(const std::string& windowId, std::optional<std::size_t> scope,
                            int depth, int limit) = 0;
    virtual Element info(std::size_t index) = 0;
    virtual void perform(Action action, std::size_t index, const std::string& value,
                         const BeforeMutation& before) = 0;
    virtual void clear() noexcept = 0;
};
} // namespace desktop
