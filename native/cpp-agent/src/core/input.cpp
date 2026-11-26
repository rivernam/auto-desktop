#include "core/input.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <climits>
#include <cmath>
#include <utility>

namespace desktop {
namespace {
Error invalid() { return {"INVALID_REQUEST", "Invalid request fields."}; }

constexpr std::array<std::pair<const char*, InputOp>, 10> inputOps{{
    {"activateWindow", InputOp::activateWindow}, {"pointerMove", InputOp::pointerMove},
    {"pointerClick", InputOp::pointerClick}, {"pointerDrag", InputOp::pointerDrag},
    {"pointerScroll", InputOp::pointerScroll}, {"clickElement", InputOp::clickElement},
    {"keyPress", InputOp::keyPress}, {"keyDown", InputOp::keyDown}, {"keyUp", InputOp::keyUp},
    {"typeText", InputOp::typeText}}};

constexpr std::array<std::pair<const char*, Action>, 7> actionNames{{
    {"invoke", Action::invoke}, {"setValue", Action::setValue}, {"defaultAction", Action::defaultAction},
    {"select", Action::select}, {"pointer", Action::pointer}, {"keyboard", Action::keyboard},
    {"activate", Action::activate}}};

struct NamedKey {
    const char* name;
    std::uint16_t vk;
    bool extended;
};

constexpr std::array<NamedKey, 27> namedKeys{{
    {"enter", vk::enter, false}, {"tab", vk::tab, false}, {"escape", vk::escape, false}, {"esc", vk::escape, false},
    {"space", vk::space, false}, {"backspace", vk::back, false}, {"delete", 0x2E, true}, {"del", 0x2E, true},
    {"insert", 0x2D, true}, {"home", 0x24, true}, {"end", 0x23, true}, {"pageup", 0x21, true},
    {"pagedown", 0x22, true}, {"left", 0x25, true}, {"up", 0x26, true}, {"right", 0x27, true},
    {"down", 0x28, true}, {"apps", vk::apps, true}, {"multiply", 0x6A, false}, {"add", 0x6B, false},
    {"subtract", 0x6D, false}, {"decimal", 0x6E, false}, {"divide", 0x6F, true}, {"shift", vk::shift, false},
    {"ctrl", vk::control, false}, {"control", vk::control, false}, {"alt", vk::alt, false}}};

std::string lower(std::string_view text) {
    std::string result(text);
    for (auto& c : result) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return result;
}

bool digits(std::string_view text) {
    return !text.empty() && std::all_of(text.begin(), text.end(), [](char c) { return c >= '0' && c <= '9'; });
}

int number(std::string_view text) {
    int value = 0;
    for (char c : text) value = value * 10 + (c - '0');
    return value;
}

long long integer(const Json& request, const char* key, std::optional<long long> fallback, long long min,
                  long long max) {
    const auto value = request.find(key);
    if (value == request.end()) {
        if (!fallback) throw invalid();
        return *fallback;
    }
    if (!value->is_number_integer()) throw invalid();
    if (value->is_number_unsigned()) {
        const auto unsignedValue = value->get<std::uint64_t>();
        if (unsignedValue > static_cast<std::uint64_t>(max)) throw invalid();
        return static_cast<long long>(unsignedValue);
    }
    const auto result = value->get<std::int64_t>();
    if (result < min || result > max) throw invalid();
    return result;
}

const std::string& string(const Json& request, const char* key, std::size_t limit) {
    const auto value = request.find(key);
    if (value == request.end() || !value->is_string()) throw invalid();
    const auto& text = value->get_ref<const std::string&>();
    if (utf16Length(text) > limit || isBlank(text)) throw invalid();
    return text;
}

template <typename T, std::size_t N>
T choice(const Json& request, const char* key, T fallback, const std::array<std::pair<const char*, T>, N>& names) {
    const auto value = request.find(key);
    if (value == request.end()) return fallback;
    if (!value->is_string()) throw invalid();
    for (const auto& [name, result] : names) {
        if (value->get_ref<const std::string&>() == name) return result;
    }
    throw invalid();
}

InputPoint point(const Json& request, const char* key) {
    const auto value = request.find(key);
    if (value == request.end() || !value->is_object()) throw invalid();
    InputPoint result;
    result.x = static_cast<long>(integer(*value, "x", std::nullopt, INT_MIN, INT_MAX));
    result.y = static_cast<long>(integer(*value, "y", std::nullopt, INT_MIN, INT_MAX));
    if (!value->contains("space")) throw invalid();
    result.space = choice<Space, 3>(*value, "space", Space::screen,
                                    {{{"screen", Space::screen}, {"window", Space::window}, {"client", Space::client}}});
    return result;
}

double fraction(const Json& position, const char* key) {
    const auto value = position.find(key);
    if (value == position.end() || !value->is_number()) throw invalid();
    const auto result = value->get<double>();
    if (!(result >= 0.0 && result <= 1.0)) throw invalid();
    return result;
}

long rounded(double value) { return static_cast<long>(roundHalfUp(value)); }
} // namespace

std::optional<InputOp> parseInputOp(std::string_view op) {
    for (const auto& [name, value] : inputOps) {
        if (op == name) return value;
    }
    return {};
}

const char* inputOpName(InputOp op) {
    for (const auto& [name, value] : inputOps) {
        if (op == value) return name;
    }
    return "invalid";
}

Action inputAction(InputOp op) {
    if (op == InputOp::activateWindow) return Action::activate;
    return isKeyboard(op) ? Action::keyboard : Action::pointer;
}

bool isKeyboard(InputOp op) {
    return op == InputOp::keyPress || op == InputOp::keyDown || op == InputOp::keyUp || op == InputOp::typeText;
}

bool isInputOperation(std::string_view op) { return parseInputOp(op).has_value(); }

bool isInputAction(Action action) {
    return action == Action::pointer || action == Action::keyboard || action == Action::activate;
}

bool allowsInput(const std::set<Action>& actions) {
    return std::any_of(actions.begin(), actions.end(), isInputAction);
}

std::optional<Action> parseActionName(std::string_view name) {
    for (const auto& [text, action] : actionNames) {
        if (name == text) return action;
    }
    return {};
}

const char* actionName(Action action) {
    for (const auto& [text, value] : actionNames) {
        if (action == value) return text;
    }
    return "invalid";
}

bool isModifier(std::uint16_t code) { return code == vk::shift || code == vk::control || code == vk::alt; }

std::optional<Key> parseKeyName(std::string_view name) {
    const auto key = lower(name);
    if (key.size() == 1 && ((key[0] >= 'a' && key[0] <= 'z') || (key[0] >= '0' && key[0] <= '9')))
        return Key{static_cast<std::uint16_t>(std::toupper(static_cast<unsigned char>(key[0]))), false};
    if (key.size() >= 2 && key.size() <= 3 && key[0] == 'f' && digits(key.substr(1)) && key[1] != '0') {
        const int index = number(key.substr(1));
        if (index >= 1 && index <= 24) return Key{static_cast<std::uint16_t>(0x70 + index - 1), false};
        return {};
    }
    if (key.size() == 7 && key.compare(0, 6, "numpad") == 0 && digits(key.substr(6)))
        return Key{static_cast<std::uint16_t>(0x60 + (key[6] - '0')), false};
    for (const auto& named : namedKeys) {
        if (key == named.name) return Key{named.vk, named.extended};
    }
    return {};
}

bool shellShortcut(const std::set<std::uint16_t>& modifiers, std::uint16_t key) {
    const bool alt = modifiers.count(vk::alt) || key == vk::alt;
    const bool control = modifiers.count(vk::control) || key == vk::control;
    return (alt && key == vk::tab) || (key == vk::escape && (alt || control));
}

Chord parseChord(std::string_view text) {
    std::vector<Key> parts;
    std::size_t start = 0;
    for (;;) {
        const auto end = text.find('+', start);
        const auto part = text.substr(start, end == std::string_view::npos ? std::string_view::npos : end - start);
        const auto key = parseKeyName(part);
        if (part.empty() || !key) throw invalid();
        parts.push_back(*key);
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    Chord chord;
    chord.key = parts.back();
    parts.pop_back();
    std::set<std::uint16_t> modifiers;
    for (const auto& part : parts) {
        // Only modifiers precede the key, each once.
        if (!isModifier(part.vk) || !modifiers.insert(part.vk).second) throw invalid();
        chord.modifiers.push_back(part);
    }
    if (isModifier(chord.key.vk) && modifiers.count(chord.key.vk)) throw invalid();
    if (shellShortcut(modifiers, chord.key.vk)) throw invalid();
    return chord;
}

std::uint32_t parseWindowId(const std::string& text) {
    if (utf16Length(text) > 256) throw invalid();
    const bool negative = !text.empty() && text[0] == '-';
    const std::string_view magnitude = std::string_view(text).substr(negative ? 1 : 0);
    if (!digits(magnitude)) throw invalid();
    // A handle is a 32-bit value. A larger number is well formed and names no window.
    unsigned long long value = 0;
    for (char c : magnitude) {
        value = value * 10 + static_cast<unsigned>(c - '0');
        if (value > 0xFFFFFFFFull) return 0;
    }
    if (!negative) return static_cast<std::uint32_t>(value);
    if (value > 0x80000000ull) return 0;
    // A sign-extended handle as a 32-bit process may print it.
    return static_cast<std::uint32_t>(-static_cast<long long>(value));
}

std::u16string typedText(std::string_view utf8) {
    std::u16string result;
    std::size_t i = 0;
    while (i < utf8.size()) {
        const auto lead = static_cast<unsigned char>(utf8[i]);
        const int extra = lead < 0x80 ? 0 : lead >= 0xF0 ? 3 : lead >= 0xE0 ? 2 : 1;
        if (i + static_cast<std::size_t>(extra) >= utf8.size()) throw invalid();
        std::uint32_t point = extra ? (lead & (0x3F >> extra)) : lead;
        for (int k = 1; k <= extra; ++k) point = (point << 6) | (static_cast<unsigned char>(utf8[i + k]) & 0x3F);
        i += static_cast<std::size_t>(extra) + 1;
        if (point == '\r') {
            if (i < utf8.size() && utf8[i] == '\n') ++i;
            result.push_back(u'\r');
        } else if (point == '\n') {
            result.push_back(u'\r');
        } else if (point == '\t') {
            result.push_back(u'\t');
        } else if (point < 0x20 || point == 0x7F || (point >= 0xD800 && point <= 0xDFFF) || point > 0x10FFFF) {
            throw invalid();
        } else if (point > 0xFFFF) {
            point -= 0x10000;
            result.push_back(static_cast<char16_t>(0xD800 + (point >> 10)));
            result.push_back(static_cast<char16_t>(0xDC00 + (point & 0x3FF)));
        } else {
            result.push_back(static_cast<char16_t>(point));
        }
    }
    return result;
}

InputCommand parseInputCommand(const Json& request, InputOp op) {
    InputCommand command;
    command.op = op;
    command.quietMs = static_cast<int>(integer(request, "quietMs", 500, 0, 10000));
    if (op == InputOp::clickElement) {
        command.ref = string(request, "ref", 128);
    } else {
        const auto window = request.find("windowId");
        if (window == request.end() || !window->is_string()) throw invalid();
        command.window = parseWindowId(window->get_ref<const std::string&>());
        command.processId = static_cast<int>(integer(request, "processId", std::nullopt, 1, INT_MAX));
    }
    const auto button = [&] {
        command.button = choice<Button, 3>(request, "button", Button::left,
            {{{"left", Button::left}, {"right", Button::right}, {"middle", Button::middle}}});
    };
    switch (op) {
    case InputOp::activateWindow:
        break;
    case InputOp::pointerMove:
        command.point = point(request, "point");
        break;
    case InputOp::pointerClick:
        command.point = point(request, "point");
        button();
        command.clicks = static_cast<int>(integer(request, "clicks", 1, 1, 2));
        break;
    case InputOp::pointerDrag:
        command.from = point(request, "from");
        command.to = point(request, "to");
        button();
        command.steps = static_cast<int>(integer(request, "steps", 10, 1, 100));
        command.stepDelayMs = static_cast<int>(integer(request, "stepDelayMs", 10, 0, 100));
        // Keeps a drag well inside the 10-second request budget.
        if (command.steps * command.stepDelayMs > 5000) throw invalid();
        break;
    case InputOp::pointerScroll:
        command.point = point(request, "point");
        command.delta = static_cast<int>(integer(request, "delta", std::nullopt, -20, 20));
        if (command.delta == 0) throw invalid();
        command.horizontal = choice<bool, 2>(request, "axis", false, {{{"vertical", false}, {"horizontal", true}}});
        break;
    case InputOp::keyPress:
        command.keys = parseChord(string(request, "keys", 64));
        break;
    case InputOp::keyDown:
    case InputOp::keyUp: {
        const auto key = parseKeyName(string(request, "key", 64));
        if (!key) throw invalid();
        command.keys.key = *key;
        break;
    }
    case InputOp::typeText: {
        const auto text = request.find("text");
        if (text == request.end() || !text->is_string()) throw invalid();
        const auto& raw = text->get_ref<const std::string&>();
        const auto units = utf16Length(raw);
        if (units < 1 || units > 1024) throw invalid();
        command.text = typedText(raw);
        command.intervalMs = static_cast<int>(integer(request, "intervalMs", 0, 0, 50));
        break;
    }
    case InputOp::clickElement: {
        button();
        command.clicks = static_cast<int>(integer(request, "clicks", 1, 1, 2));
        const auto position = request.find("position");
        if (position != request.end()) {
            if (!position->is_object()) throw invalid();
            command.fx = fraction(*position, "x");
            command.fy = fraction(*position, "y");
        }
        const auto weak = request.find("acceptWeakReference");
        if (weak != request.end()) {
            if (!weak->is_boolean()) throw invalid();
            command.acceptWeakReference = weak->get<bool>();
        }
        break;
    }
    }
    return command;
}

long long roundHalfUp(double value) { return static_cast<long long>(std::floor(value + 0.5)); }

std::int32_t normalizeAbsolute(long long p, long long origin, long long size) {
    if (size <= 0) return 0;
    const long long scaled = (p - origin) * 65536;
    long long result = scaled / size;
    if (scaled > 0 && scaled % size != 0) ++result;
    return static_cast<std::int32_t>(result);
}

bool contains(const Bounds& area, const ScreenPoint& point) {
    return point.x >= area.x && point.y >= area.y && point.x - static_cast<long long>(area.x) < area.width
        && point.y - static_cast<long long>(area.y) < area.height;
}

const char* mappingName(BoundsMapping mapping) {
    switch (mapping) {
    case BoundsMapping::physical: return "physical";
    case BoundsMapping::scaled: return "scaled";
    case BoundsMapping::assumedPhysical: return "assumedPhysical";
    }
    return "physical";
}

ElementPoint elementPoint(const Bounds& window, const std::optional<Bounds>& root, const Bounds& element,
                          bool scoped, std::string_view backend, double fx, double fy) {
    const Error unverified{"BOUNDS_UNVERIFIED", "The element bounds could not be matched to the window."};
    const auto inside = [&](const Bounds& rect, BoundsMapping mapping) {
        if (rect.width < 1 || rect.height < 1)
            throw Error("PRECONDITION_FAILED", "The element has no area on the screen.");
        return ElementPoint{{rect.x + rounded(fx * static_cast<double>(rect.width - 1)),
                             rect.y + rounded(fy * static_cast<double>(rect.height - 1))}, mapping};
    };
    if (scoped) {
        // A scoped capture has no window root to compare. Only the bridge is known to report logical pixels.
        if (backend == "JAB") throw unverified;
        return inside(element, BoundsMapping::assumedPhysical);
    }
    if (!root || window.width <= 0 || window.height <= 0 || root->width <= 0 || root->height <= 0) throw unverified;
    const double rx = static_cast<double>(root->width) / static_cast<double>(window.width);
    const double ry = static_cast<double>(root->height) / static_cast<double>(window.height);
    if (std::abs(rx - 1.0) <= 0.01 && std::abs(ry - 1.0) <= 0.01 && std::abs(root->x - window.x) <= 2
        && std::abs(root->y - window.y) <= 2)
        return inside(element, BoundsMapping::physical);
    const double sx = static_cast<double>(window.width) / static_cast<double>(root->width);
    const double sy = static_cast<double>(window.height) / static_cast<double>(root->height);
    if (std::abs(sx / sy - 1.0) > 0.02 || sx < 0.5 || sx > 4.0 || sy < 0.5 || sy > 4.0) throw unverified;
    const Bounds mapped{rounded(window.x + static_cast<double>(element.x - root->x) * sx),
                        rounded(window.y + static_cast<double>(element.y - root->y) * sy),
                        roundHalfUp(static_cast<double>(element.width) * sx),
                        roundHalfUp(static_cast<double>(element.height) * sy)};
    return inside(mapped, BoundsMapping::scaled);
}

void attachInput(Json& capabilities, InputDriver* driver, const std::set<Action>& actions) {
    if (!allowsInput(actions)) return;
    const auto status = driver ? driver->status() : InputStatus{};
    auto allowed = Json::array();
    std::vector<std::string> names;
    for (const auto action : actions) {
        if (isInputAction(action)) names.emplace_back(actionName(action));
    }
    std::sort(names.begin(), names.end());
    for (const auto& name : names) allowed.push_back(name);
    Json input{{"available", status.available}, {"allowedActions", std::move(allowed)},
               {"dpiAwareness", status.dpiAwareness}, {"integrity", status.integrity},
               {"inputDesktop", status.inputDesktop},
               {"virtualScreen", {{"x", status.virtualScreen.x}, {"y", status.virtualScreen.y},
                                  {"width", status.virtualScreen.width}, {"height", status.virtualScreen.height}}},
               {"monitors", status.monitors}, {"buttonsSwapped", status.buttonsSwapped}};
    if (!status.available) input["reason"] = status.reason;
    capabilities["physicalInput"] = status.available;
    capabilities["input"] = std::move(input);
    if (!status.available) return;
    auto& operations = capabilities["operations"];
    for (const auto& [name, op] : inputOps) {
        if (actions.count(inputAction(op))) operations.push_back(name);
    }
}
} // namespace desktop
