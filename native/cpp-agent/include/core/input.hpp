#pragma once

#include "core/desktop_adapter.hpp"
#include "protocol/ndjson.hpp"

#include <chrono>
#include <cstdint>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <vector>

// Physical input (SendInput): the platform-neutral contract. docs/PHYSICAL-INPUT.md is the spec.
namespace desktop {
enum class InputOp {
    activateWindow, pointerMove, pointerClick, pointerDrag, pointerScroll, keyPress, keyDown, keyUp, typeText,
    clickElement
};

std::optional<InputOp> parseInputOp(std::string_view op);
const char* inputOpName(InputOp op);
// The --allow-action name that permits the operation.
Action inputAction(InputOp op);
bool isKeyboard(InputOp op);
bool isInputOperation(std::string_view op);
bool isInputAction(Action action);
bool allowsInput(const std::set<Action>& actions);
// Every --allow-action name, accessibility and input alike.
std::optional<Action> parseActionName(std::string_view name);
const char* actionName(Action action);

enum class Space { screen, window, client };
enum class Button { left, right, middle };
enum class TextMethod { unicode, virtualKey, scanCode };
const char* textMethodName(TextMethod method);

struct InputPoint {
    long x = 0, y = 0;
    Space space = Space::screen;
};

struct ScreenPoint {
    long x = 0, y = 0;
    bool operator==(const ScreenPoint& other) const { return x == other.x && y == other.y; }
};

// Windows virtual-key codes. The values are fixed by the platform, so the core needs no Windows header.
namespace vk {
inline constexpr std::uint16_t back = 0x08, tab = 0x09, enter = 0x0D, shift = 0x10, control = 0x11, alt = 0x12,
    escape = 0x1B, space = 0x20, apps = 0x5D;
}

struct Key {
    std::uint16_t vk = 0;
    // Sent with KEYEVENTF_EXTENDEDKEY: navigation keys outside the numeric keypad, Divide and Apps.
    bool extended = false;
    bool operator==(const Key& other) const { return vk == other.vk && extended == other.extended; }
};

// Modifiers in press order, then the key. A lone modifier is the key itself.
struct Chord {
    std::vector<Key> modifiers;
    Key key;
};

bool isModifier(std::uint16_t code);
// Case-insensitive key name, or nothing for an unknown or refused name (Windows, lock and PrintScreen keys).
std::optional<Key> parseKeyName(std::string_view name);
// Throws INVALID_REQUEST for a malformed chord or one the shell would take.
Chord parseChord(std::string_view text);
// Alt+Tab, Alt+Esc, Ctrl+Esc and Ctrl+Shift+Esc reach the shell, not the target window.
bool shellShortcut(const std::set<std::uint16_t>& modifiers, std::uint16_t key);

struct InputCommand {
    InputOp op = InputOp::pointerMove;
    // Zero when the ID is numeric but cannot name a window. The driver answers WINDOW_NOT_FOUND.
    std::uint32_t window = 0;
    int processId = 0;
    InputPoint point, from, to;
    Button button = Button::left;
    int clicks = 1;
    int steps = 10;
    int stepDelayMs = 10;
    int delta = 0;
    bool horizontal = false;
    // keyPress uses the whole chord; keyDown and keyUp use chord.key.
    Chord keys;
    // typeText: '\r' stands for Enter and '\t' for Tab.
    std::u16string text;
    TextMethod textMethod = TextMethod::unicode;
    int intervalMs = 0;
    int quietMs = 500;
    // clickElement
    std::string ref;
    double fx = 0.5, fy = 0.5;
    bool acceptWeakReference = false;
    // The request deadline. The driver finishes or stops before it.
    std::chrono::steady_clock::time_point expires = std::chrono::steady_clock::time_point::max();
};

// Validates the request fields of one input operation. Throws INVALID_REQUEST.
InputCommand parseInputCommand(const Json& request, InputOp op);
// The window ID as listWindows writes it, or zero when no window can have it. Throws INVALID_REQUEST.
std::uint32_t parseWindowId(const std::string& text);
// UTF-8 to the units typeText sends. Throws INVALID_REQUEST for control characters.
std::u16string typedText(std::string_view utf8);

// floor(v + 0.5): halves round up on both sides of zero, as Java's Math.round does.
long long roundHalfUp(double value);
// MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK coordinate: ceil((p - origin) * 65536 / size).
std::int32_t normalizeAbsolute(long long p, long long origin, long long size);
bool contains(const Bounds& area, const ScreenPoint& point);

enum class BoundsMapping { physical, scaled, assumedPhysical };
const char* mappingName(BoundsMapping mapping);

struct ElementPoint {
    ScreenPoint point;
    BoundsMapping mapping;
};

bool physicalBoundsMatch(const Bounds& physical, const Bounds& backend);

// Maps a backend's element bounds to a physical screen point. window is the live GetWindowRect, root the
// live bounds of the snapshot root (absent for a scoped snapshot). Throws BOUNDS_UNVERIFIED.
ElementPoint elementPoint(const Bounds& window, const std::optional<Bounds>& root, const Bounds& element,
                          bool scoped, std::string_view backend, double fx, double fy);

struct InputStatus {
    bool available = false;
    bool layoutText = false;
    std::string reason = "Physical input is not supported on this platform.";
    std::string dpiAwareness = "unaware";
    std::string integrity = "medium";
    bool inputDesktop = false;
    Bounds virtualScreen{0, 0, 0, 0};
    int monitors = 0;
    bool buttonsSwapped = false;
};

struct InputOutcome {
    int events = 0;
    bool observed = false;
    std::optional<ScreenPoint> point, from, to;
};

// Called once, after every check and right before the first input leaves the process. It re-checks the
// policy and the deadline and throws to refuse.
using InputGate = std::function<void()>;

// The device side. One driver serves a whole client session, every SessionWorker of a MultiSession
// included, so implementations are thread-safe. Errors are desktop::Error with inputSent set.
class InputDriver {
public:
    virtual ~InputDriver() = default;
    virtual InputStatus status() = 0;
    // Live GetWindowRect of a window owned by pid. Throws WINDOW_NOT_FOUND.
    virtual Bounds windowRect(std::uint32_t window, int pid) = 0;
    // Live client rectangle in screen pixels, when available.
    virtual std::optional<Bounds> clientRect(std::uint32_t, int) { return std::nullopt; }
    // Keys this session holds through keyDown.
    virtual std::vector<std::uint16_t> held() = 0;
    virtual InputOutcome perform(const InputCommand& command, const InputGate& gate) = 0;
};

struct InputSupport {
    InputDriver* driver = nullptr;
    // False for the backend rows of a multi-backend session: the input object belongs to the top level.
    bool advertise = true;
};

// Adds physicalInput, the input object and the allowed input operations to a capabilities result.
// Nothing changes for a session that allows no input action.
void attachInput(Json& capabilities, InputDriver* driver, const std::set<Action>& actions);
} // namespace desktop
