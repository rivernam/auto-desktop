#include "core/agent.hpp"
#include "core/input.hpp"
#include "core/multi_session.hpp"
#include "core/session_worker.hpp"

#include <atomic>
#include <iostream>
#include <thread>

using namespace desktop;
using namespace std::chrono_literals;

namespace {
void check(bool passed, const std::string& message) {
    if (!passed) throw std::runtime_error(message);
}

template <typename F>
std::string code(F&& call) {
    try {
        call();
    } catch (const Error& error) {
        return error.code;
    }
    return "OK";
}

void error(const Json& reply, const char* expected, bool sent = false) {
    if (reply.at("ok") != false || reply.at("error").at("code") != expected)
        throw std::runtime_error(std::string("Expected ") + expected + ", got " + reply.dump());
    check(reply.at("error").at("inputSent") == sent, "inputSent of " + reply.dump());
}

// Records commands and opens the gate, or runs a script in its place.
class FakeDriver final : public InputDriver {
public:
    InputStatus state;
    Bounds rect{100, 200, 400, 300};
    std::optional<Bounds> client;
    std::vector<std::uint16_t> keys;
    std::vector<InputCommand> commands;
    std::function<void(const InputCommand&, const InputGate&)> script;
    std::atomic<int> performs{0};
    std::thread::id thread;

    FakeDriver() {
        state.available = true;
        state.reason.clear();
        state.dpiAwareness = "perMonitorV2";
        state.inputDesktop = true;
        state.virtualScreen = {-1920, 0, 3840, 1080};
        state.monitors = 2;
    }
    InputStatus status() override { return state; }
    Bounds windowRect(std::uint32_t window, int pid) override {
        if (window != 42 || pid != 123) throw Error("WINDOW_NOT_FOUND", "Missing window.");
        return rect;
    }
    std::optional<Bounds> clientRect(std::uint32_t, int) override { return client; }
    std::vector<std::uint16_t> held() override { return keys; }
    InputOutcome perform(const InputCommand& command, const InputGate& gate) override {
        ++performs;
        thread = std::this_thread::get_id();
        commands.push_back(command);
        if (script) script(command, gate);
        else gate();
        InputOutcome outcome;
        outcome.events = 3;
        outcome.observed = true;
        if (command.op == InputOp::pointerDrag) {
            outcome.from = ScreenPoint{command.from.x, command.from.y};
            outcome.to = ScreenPoint{command.to.x, command.to.y};
        } else if (!isKeyboard(command.op) && command.op != InputOp::activateWindow) {
            outcome.point = ScreenPoint{command.point.x, command.point.y};
        }
        return outcome;
    }
};

// A window with one button. The live button can move, and the backend name and strength are set per test.
class Surface final : public DesktopAdapter {
public:
    explicit Surface(std::string name = "UIA") : name_(std::move(name)) {}
    Bounds root{100, 200, 400, 300};
    Bounds button{150, 250, 100, 20};
    std::string strength;
    bool moved = false;
    bool disabled = false;
    bool scoped = false;
    std::thread::id thread = std::this_thread::get_id();

    const char* backend() const override { return name_.c_str(); }
    std::vector<Window> windows() override { return {{"42", 123, "Fixture"}}; }
    Capture capture(const std::string&, std::optional<std::size_t> scope, int, int) override {
        scoped = scope.has_value();
        auto rows = live();
        if (moved) rows[1].bounds->x -= 1;
        if (scoped) {
            rows.erase(rows.begin());
            rows[0].parent.reset();
        }
        return {rows, false};
    }
    Element info(std::size_t index) override {
        auto rows = live();
        if (scoped) rows.erase(rows.begin());
        return rows.at(index);
    }
    void perform(Action, std::size_t, const std::string&, const BeforeMutation& before) override { before(); }
    void clear() noexcept override {}

private:
    std::vector<Element> live() const {
        Element window;
        window.pid = 123;
        window.identity = {"Fixture", "Window", "", "Window"};
        window.bounds = root;
        Element target;
        target.pid = 123;
        target.parent = 0;
        target.identity = {"OK", "Button", "ok", "Button"};
        target.bounds = button;
        target.enabled = !disabled;
        target.invoke = true;
        target.referenceStrength = strength;
        return {window, target};
    }
    std::string name_;
};

Json send(Agent& agent, const char* op, Json args = Json::object(), std::string id = "id",
          Clock::time_point expires = Clock::now() + 10s) {
    args["id"] = std::move(id);
    args["op"] = op;
    RequestDeadline deadline(expires);
    return agent.handle(args, deadline);
}

Json screen(long x, long y) { return {{"x", x}, {"y", y}, {"space", "screen"}}; }

void parsing() {
    const auto parse = [](Json request, InputOp op) { return code([&] { parseInputCommand(request, op); }); };
    const Json base{{"windowId", "42"}, {"processId", 123}};
    const auto with = [&](Json extra) {
        auto request = base;
        for (auto& [key, value] : extra.items()) request[key] = value;
        return request;
    };
    check(parse(with({{"point", screen(1, 2)}}), InputOp::pointerMove) == "OK", "valid move");
    check(parse(base, InputOp::pointerMove) == "INVALID_REQUEST", "point required");
    check(parse(with({{"point", {{"x", 1}, {"y", 2}}}}), InputOp::pointerMove) == "INVALID_REQUEST", "space required");
    check(parse(with({{"point", {{"x", 1.5}, {"y", 2}, {"space", "screen"}}}}), InputOp::pointerMove) == "INVALID_REQUEST",
          "integer coordinates");
    check(parse(with({{"point", {{"x", 1}, {"y", 2}, {"space", "page"}}}}), InputOp::pointerMove) == "INVALID_REQUEST",
          "known space");
    check(parse(with({{"point", {{"x", 4294967296LL}, {"y", 2}, {"space", "screen"}}}}), InputOp::pointerMove)
          == "INVALID_REQUEST", "coordinate range");
    check(parse({{"windowId", "42"}, {"processId", 0}, {"point", screen(1, 2)}}, InputOp::pointerMove) == "INVALID_REQUEST",
          "positive PID");
    check(parse({{"windowId", "42"}, {"processId", "123"}, {"point", screen(1, 2)}}, InputOp::pointerMove)
          == "INVALID_REQUEST", "integer PID");
    check(parse({{"windowId", "0x2A"}, {"processId", 123}}, InputOp::activateWindow) == "INVALID_REQUEST", "decimal ID");
    check(parse({{"windowId", 42}, {"processId", 123}}, InputOp::activateWindow) == "INVALID_REQUEST", "string ID");
    check(parse({{"windowId", std::string(257, '1')}, {"processId", 123}}, InputOp::activateWindow) == "INVALID_REQUEST",
          "ID length");
    check(parseWindowId("42") == 42 && parseWindowId("-1") == 0xFFFFFFFFu && parseWindowId("4294967296") == 0
          && parseWindowId("-2147483649") == 0 && parseWindowId(std::string(256, '9')) == 0, "window ID values");
    check(parse(with({{"point", screen(1, 2)}, {"button", "x1"}}), InputOp::pointerClick) == "INVALID_REQUEST", "button");
    check(parse(with({{"point", screen(1, 2)}, {"clicks", 3}}), InputOp::pointerClick) == "INVALID_REQUEST", "clicks");
    const auto click = parseInputCommand(with({{"point", screen(1, 2)}, {"button", "middle"}, {"clicks", 2}}),
                                         InputOp::pointerClick);
    check(click.button == Button::middle && click.clicks == 2 && click.quietMs == 500, "click fields and defaults");
    const auto drag = parseInputCommand(with({{"from", screen(1, 2)}, {"to", screen(3, 4)}}), InputOp::pointerDrag);
    check(drag.steps == 10 && drag.stepDelayMs == 10, "drag defaults");
    check(parse(with({{"from", screen(1, 2)}, {"to", screen(3, 4)}, {"steps", 0}}), InputOp::pointerDrag)
          == "INVALID_REQUEST", "steps minimum");
    check(parse(with({{"from", screen(1, 2)}, {"to", screen(3, 4)}, {"steps", 101}}), InputOp::pointerDrag)
          == "INVALID_REQUEST", "steps maximum");
    check(parse(with({{"from", screen(1, 2)}, {"to", screen(3, 4)}, {"stepDelayMs", 101}}), InputOp::pointerDrag)
          == "INVALID_REQUEST", "step delay maximum");
    check(parse(with({{"from", screen(1, 2)}, {"to", screen(3, 4)}, {"steps", 100}, {"stepDelayMs", 51}}),
                InputOp::pointerDrag) == "INVALID_REQUEST", "drag budget");
    check(parse(with({{"from", screen(1, 2)}, {"to", screen(3, 4)}, {"steps", 100}, {"stepDelayMs", 50}}),
                InputOp::pointerDrag) == "OK", "drag budget limit");
    for (const int delta : {0, 21, -21})
        check(parse(with({{"point", screen(1, 2)}, {"delta", delta}}), InputOp::pointerScroll) == "INVALID_REQUEST",
              "delta range");
    check(parse(with({{"point", screen(1, 2)}}), InputOp::pointerScroll) == "INVALID_REQUEST", "delta required");
    check(parseInputCommand(with({{"point", screen(1, 2)}, {"delta", -20}, {"axis", "horizontal"}}),
                            InputOp::pointerScroll).horizontal, "horizontal axis");
    check(parse(with({{"point", screen(1, 2)}, {"delta", 1}, {"axis", "diagonal"}}), InputOp::pointerScroll)
          == "INVALID_REQUEST", "axis");
    check(parse(with({{"keys", ""}}), InputOp::keyPress) == "INVALID_REQUEST", "empty keys");
    check(parse(with({{"key", "Ctrl+A"}}), InputOp::keyDown) == "INVALID_REQUEST", "one key");
    check(parse(with({{"text", ""}}), InputOp::typeText) == "INVALID_REQUEST", "text minimum");
    check(parse(with({{"text", std::string(1025, 'a')}}), InputOp::typeText) == "INVALID_REQUEST", "text maximum");
    check(parse(with({{"text", std::string(1024, 'a')}}), InputOp::typeText) == "OK", "text limit");
    check(parse(with({{"text", "a\x01"}}), InputOp::typeText) == "INVALID_REQUEST", "control character");
    check(parse(with({{"text", "a\x7F"}}), InputOp::typeText) == "INVALID_REQUEST", "delete character");
    check(parse(with({{"text", "a"}, {"intervalMs", 51}}), InputOp::typeText) == "INVALID_REQUEST", "interval");
    check(typedText("a\r\nb\nc\rd\te") == u"a\rb\rc\rd\te", "line ends become Enter, tab stays Tab");
    check(typedText("\xF0\x9F\x98\x80") == u"\xD83D\xDE00", "supplementary character as a pair");
    check(parse(with({{"point", screen(1, 2)}, {"quietMs", 10001}}), InputOp::pointerMove) == "INVALID_REQUEST", "quiet");
    check(parseInputCommand(with({{"point", screen(1, 2)}, {"quietMs", 0}}), InputOp::pointerMove).quietMs == 0, "quiet 0");
    check(parse({{"ref", "r"}, {"position", {{"x", 1.5}, {"y", 0}}}}, InputOp::clickElement) == "INVALID_REQUEST",
          "position range");
    check(parse({{"ref", "r"}, {"position", {{"x", 0.5}}}}, InputOp::clickElement) == "INVALID_REQUEST", "position pair");
    check(parse({{"ref", "r"}, {"acceptWeakReference", "yes"}}, InputOp::clickElement) == "INVALID_REQUEST", "weak flag");
    const auto element = parseInputCommand({{"ref", "r"}, {"position", {{"x", 0}, {"y", 1}}}}, InputOp::clickElement);
    check(element.fx == 0.0 && element.fy == 1.0 && !element.acceptWeakReference, "element fields");
}

void keys() {
    const auto key = [](const char* name) { return parseKeyName(name); };
    check(key("a")->vk == 'A' && key("Z")->vk == 'Z' && key("7")->vk == '7', "letters and digits");
    check(key("f1")->vk == 0x70 && key("F24")->vk == 0x87 && !key("F25") && !key("F0") && !key("F01"), "function keys");
    check(key("NumPad0")->vk == 0x60 && key("numpad9")->vk == 0x69 && !key("NumPad10"), "keypad");
    check(key("esc")->vk == 0x1B && key("Escape")->vk == 0x1B && key("DEL")->vk == 0x2E, "aliases");
    for (const char* extended : {"Insert", "Delete", "Home", "End", "PageUp", "PageDown", "Left", "Right", "Up", "Down",
                                 "Divide", "Apps"})
        check(key(extended)->extended, std::string("extended ") + extended);
    for (const char* plain : {"Enter", "Tab", "Space", "Backspace", "Multiply", "Add", "Subtract", "Decimal", "A",
                              "Shift", "Ctrl", "Control", "Alt", "NumPad5"})
        check(key(plain) && !key(plain)->extended, std::string("not extended ") + plain);
    for (const char* refused : {"Win", "LWin", "RWin", "Windows", "CapsLock", "NumLock", "ScrollLock", "PrintScreen",
                                "Snapshot", "Pause", "LShift", "RControl"})
        check(!key(refused), std::string("refused ") + refused);
    const auto chord = parseChord("Ctrl+Shift+K");
    check(chord.modifiers.size() == 2 && chord.modifiers[0].vk == vk::control && chord.modifiers[1].vk == vk::shift
          && chord.key.vk == 'K', "chord order");
    check(parseChord("shift").modifiers.empty() && parseChord("shift").key.vk == vk::shift, "lone modifier");
    check(parseChord("Ctrl+Alt").key.vk == vk::alt, "modifiers only");
    check(parseChord("Esc").key.vk == vk::escape && parseChord("Shift+Tab").key.vk == vk::tab, "allowed Esc and Tab");
    for (const char* bad : {"Alt+Tab", "alt+esc", "Ctrl+Esc", "Ctrl+Shift+Esc", "Ctrl+Alt+Tab", "Win+R", "K+Ctrl",
                            "Ctrl+Ctrl+K", "Ctrl++", "+K", "Ctrl+", "Ctrl+A+B", "Shift+Shift", "Ctrl+CapsLock"})
        check(code([&] { parseChord(bad); }) == "INVALID_REQUEST", std::string("refused chord ") + bad);
}

void normalization() {
    check(normalizeAbsolute(0, 0, 1920) == 0 && normalizeAbsolute(1919, 0, 1920) == 65502, "single monitor");
    check(normalizeAbsolute(-1920, -1920, 3840) == 0 && normalizeAbsolute(0, -1920, 3840) == 32768
          && normalizeAbsolute(-1, -1920, 3840) == 32751, "negative origin");
    // Windows maps n back to origin + floor(n * size / 65536). Every pixel must come back unchanged.
    for (const long long size : {1366LL, 1920LL, 3840LL, 4480LL, 7680LL}) {
        for (long long p = 0; p < size; ++p) {
            const auto n = normalizeAbsolute(p - 1280, -1280, size);
            check(n >= 0 && n <= 65535 && n * size / 65536 == p, "round trip " + std::to_string(size));
        }
    }
    const Bounds desktop{-1920, -200, 3840, 1280};
    check(contains(desktop, {-1920, -200}) && contains(desktop, {1919, 1079}) && !contains(desktop, {1920, 0})
          && !contains(desktop, {0, 1080}) && !contains(desktop, {-1921, 0}), "virtual screen edges");
}

void mapping() {
    const Bounds window{100, 200, 400, 300};
    const Bounds element{150, 250, 100, 20};
    const auto at = [](const ElementPoint& p, long x, long y) { return p.point.x == x && p.point.y == y; };
    auto mapped = elementPoint(window, window, element, false, "UIA", 0.5, 0.5);
    check(mapped.mapping == BoundsMapping::physical && at(mapped, 200, 260), "physical centre");
    check(at(elementPoint(window, window, element, false, "UIA", 0, 0), 150, 250)
          && at(elementPoint(window, window, element, false, "UIA", 1, 1), 249, 269), "corners stay inside");
    check(elementPoint(window, Bounds{102, 198, 403, 298}, element, false, "JAB", .5, .5).mapping
          == BoundsMapping::physical, "physical tolerance");
    // A JAB window of a HiDPI Java app at 125 %.
    mapped = elementPoint(Bounds{100, 200, 500, 375}, Bounds{80, 160, 400, 300}, Bounds{120, 200, 80, 16}, false, "JAB",
                          .5, .5);
    check(mapped.mapping == BoundsMapping::scaled && at(mapped, 200, 260), "scaled " + std::to_string(mapped.point.x));
    // A shifted origin at the same size is not physical.
    check(elementPoint(window, Bounds{103, 200, 400, 300}, element, false, "UIA", .5, .5).mapping
          == BoundsMapping::scaled, "shifted origin");
    const auto unverified = [&](Bounds root, bool scoped, const char* backend) {
        return code([&] { elementPoint(window, root, element, scoped, backend, .5, .5); }) == "BOUNDS_UNVERIFIED";
    };
    // Halves round up on both sides of zero, as in Java: a left monitor maps -2.5 to -2, not -3.
    check(roundHalfUp(-2.5) == -2 && roundHalfUp(2.5) == 3 && roundHalfUp(-0.5) == 0 && roundHalfUp(-2.6) == -3,
          "half-up rounding");
    mapped = elementPoint(Bounds{-1000, -300, 500, 375}, Bounds{0, 0, 400, 300}, Bounds{798, 162, 2, 2}, false, "JAB",
                          .5, .5);
    // x = -1000 + 798 * 1.25 = -2.5 -> -2, width 2.5 -> 3, offset 0.5 * 2 = 1 -> -1.
    // y = -300 + 162 * 1.25 = -97.5 -> -97, height 3, offset 1 -> -96.
    check(mapped.mapping == BoundsMapping::scaled && at(mapped, -1, -96),
          "negative scaled " + std::to_string(mapped.point.x) + "," + std::to_string(mapped.point.y));
    check(at(elementPoint(Bounds{-1920, 0, 1920, 1080}, Bounds{-1920, 0, 1920, 1080}, Bounds{-1000, 10, 4, 6}, false,
                          "UIA", .5, .5), -998, 13), "physical fraction rounds half up");
    check(code([&] { elementPoint(window, window, Bounds{150, 250, 0, 20}, false, "UIA", .5, .5); })
          == "PRECONDITION_FAILED", "no area");
    check(unverified({100, 200, 400, 200}, false, "UIA"), "unequal axis ratios");
    check(unverified({100, 200, 80, 60}, false, "JAB"), "ratio above 4");
    check(unverified({100, 200, 900, 675}, false, "JAB"), "ratio below 0.5");
    check(unverified({100, 200, 0, 300}, false, "UIA"), "empty root");
    check(code([&] { elementPoint(window, std::nullopt, element, false, "UIA", .5, .5); }) == "BOUNDS_UNVERIFIED",
          "missing root");
    check(elementPoint(window, std::nullopt, element, true, "MSAA", .5, .5).mapping == BoundsMapping::assumedPhysical,
          "scoped MSAA");
    check(code([&] { elementPoint(window, std::nullopt, element, true, "JAB", .5, .5); }) == "BOUNDS_UNVERIFIED",
          "scoped JAB");
}

void policy() {
    Surface surface;
    FakeDriver driver;
    bool alive = true;
    Agent agent(surface, "s", [&](int pid) { return alive && pid == 123; }, {Action::pointer, Action::activate},
                Clock::now, nullptr, {&driver, true});
    const Json move{{"windowId", "42"}, {"processId", 123}, {"point", screen(150, 250)}};
    const auto moved = send(agent, "pointerMove", move, "m1");
    const auto& result = moved.at("result");
    check(result == Json{{"performed", true}, {"inputSent", true}, {"inputObserved", true}, {"effectVerified", false},
                         {"events", 3}, {"point", {{"x", 150}, {"y", 250}}}}, "move result " + moved.dump());
    error(send(agent, "pointerMove", move, "m1"), "DUPLICATE_COMMAND");
    check(driver.performs == 1, "a duplicate never reaches the driver");
    error(send(agent, "keyPress", {{"windowId", "42"}, {"processId", 123}, {"keys", "A"}}, "k1"), "PERMISSION_DENIED");
    error(send(agent, "pointerMove", {{"windowId", "42"}, {"processId", 7}, {"point", screen(1, 1)}}, "p1"),
          "PERMISSION_DENIED");
    // A request that fails validation or policy does not consume its ID.
    error(send(agent, "pointerMove", {{"windowId", "42"}, {"processId", 123}}, "p1"), "INVALID_REQUEST");
    check(send(agent, "pointerMove", move, "p1").at("ok") == true && driver.performs == 2, "unconsumed IDs");
    // A refusal from the driver consumes the ID.
    driver.script = [](const InputCommand&, const InputGate&) {
        Error refused("FOREGROUND_MISMATCH", "Not in front.");
        refused.inputSent = false;
        throw refused;
    };
    error(send(agent, "pointerMove", move, "f1"), "FOREGROUND_MISMATCH");
    error(send(agent, "pointerMove", move, "f1"), "DUPLICATE_COMMAND");
    // The gate re-checks the process right before input.
    driver.script = [&](const InputCommand&, const InputGate& gate) {
        alive = false;
        gate();
    };
    error(send(agent, "pointerMove", move, "g1"), "PERMISSION_DENIED");
    alive = true;
    driver.script = nullptr;
    error(send(agent, "pointerMove", move, "late", Clock::now() - 1ms), "TIMEOUT");
    driver.script = [](const InputCommand&, const InputGate& gate) {
        gate();
        Error partial("ACTION_OUTCOME_UNKNOWN", "Partly sent.");
        partial.inputSent = true;
        partial.released = true;
        throw partial;
    };
    const auto unknown = send(agent, "pointerMove", move, "u1");
    error(unknown, "ACTION_OUTCOME_UNKNOWN", true);
    check(unknown.at("error").at("released") == true, "released reported");
    driver.script = nullptr;
    const auto refused = send(agent, "pointerMove", move, "late2", Clock::now() - 1ms);
    check(!refused.at("error").contains("released"), "released only after a release");
    const auto activated = send(agent, "activateWindow", {{"windowId", "42"}, {"processId", 123}}, "a1");
    check(activated.at("result") == Json{{"performed", true}, {"inputSent", false}, {"foreground", true},
                                         {"effectVerified", false}}, "activate result " + activated.dump());
    const auto dragged = send(agent, "pointerDrag", {{"windowId", "42"}, {"processId", 123}, {"from", screen(1, 2)},
                                                     {"to", screen(3, 4)}}, "d1");
    check(dragged.at("result").at("from") == Json{{"x", 1}, {"y", 2}} && dragged.at("result").at("to")
          == Json{{"x", 3}, {"y", 4}} && !dragged.at("result").contains("point"), "drag result");
    // Accessibility errors keep their shape.
    const auto other = send(agent, "invoke", {{"ref", "missing"}}, "i1");
    check(other.at("error").at("code") == "STALE_REFERENCE" && !other.at("error").contains("inputSent"),
          "other operations carry no input fields");
    error(send(agent, "pointerMove", Json::object(), ""), "INVALID_REQUEST");
}

void keyboard() {
    Surface surface;
    FakeDriver driver;
    Agent agent(surface, "s", [](int pid) { return pid == 123; }, {Action::keyboard}, Clock::now, nullptr,
                {&driver, true});
    const auto with = [](Json extra) {
        Json request{{"windowId", "42"}, {"processId", 123}};
        for (auto& [key, value] : extra.items()) request[key] = value;
        return request;
    };
    const auto pressed = send(agent, "keyPress", with({{"keys", "ctrl+shift+k"}}), "k1");
    check(pressed.at("ok") == true && !pressed.at("result").contains("point") && pressed.at("result").at("events") == 3,
          "keyboard result " + pressed.dump());
    error(send(agent, "keyPress", with({{"keys", "Alt+Tab"}}), "k2"), "INVALID_REQUEST");
    // A held modifier joins the chord.
    driver.keys = {vk::alt};
    error(send(agent, "keyPress", with({{"keys", "Tab"}}), "k3"), "INVALID_REQUEST");
    error(send(agent, "keyDown", with({{"key", "Esc"}}), "k4"), "INVALID_REQUEST");
    error(send(agent, "typeText", with({{"text", "a\tb"}}), "k5"), "INVALID_REQUEST");
    check(send(agent, "typeText", with({{"text", "a\r\nb"}}), "k6").at("ok") == true
          && driver.commands.back().text == u"a\rb", "text reaches the driver normalized");
    driver.keys = {vk::control};
    error(send(agent, "keyPress", with({{"keys", "Esc"}}), "k7"), "INVALID_REQUEST");
    check(send(agent, "keyUp", with({{"key", "Ctrl"}}), "k8").at("ok") == true, "keyUp of a held key");
    error(send(agent, "pointerMove", with({{"point", screen(1, 1)}}), "k9"), "PERMISSION_DENIED");
}

void elements() {
    Surface surface;
    FakeDriver driver;
    Agent agent(surface, "s", [](int pid) { return pid == 123; }, {Action::pointer}, Clock::now, nullptr,
                {&driver, true});
    auto snap = send(agent, "snapshot", {{"windowId", "42"}}, "s1").at("result");
    auto ref = snap.at("elements")[1].at("ref");
    auto clicked = send(agent, "clickElement", {{"ref", ref}}, "c1");
    check(clicked.at("result") == Json{{"performed", true}, {"inputSent", true}, {"inputObserved", true},
                                       {"effectVerified", false}, {"events", 3}, {"point", {{"x", 200}, {"y", 260}}},
                                       {"backend", "UIA"}, {"boundsMapping", "physical"}}, "click result " + clicked.dump());
    const auto& command = driver.commands.back();
    check(command.op == InputOp::pointerClick && command.window == 42 && command.processId == 123
          && command.point.space == Space::screen, "element click becomes a screen click");
    error(send(agent, "clickElement", {{"ref", ref}}, "c1"), "DUPLICATE_COMMAND");
    error(send(agent, "clickElement", {{"ref", "nope"}}, "c2"), "STALE_REFERENCE");
    error(send(agent, "clickElement", {{"ref", ref}, {"clicks", 3}}, "c3"), "INVALID_REQUEST");
    // The live window no longer matches the root.
    driver.rect = {100, 200, 400, 150};
    error(send(agent, "clickElement", {{"ref", ref}}, "c4"), "BOUNDS_UNVERIFIED");
    error(send(agent, "clickElement", {{"ref", ref}}, "c4"), "DUPLICATE_COMMAND");
    driver.rect = {100, 200, 400, 300};
    // Weak references.
    surface.strength = "weak";
    snap = send(agent, "snapshot", {{"windowId", "42"}}, "s2").at("result");
    ref = snap.at("elements")[1].at("ref");
    error(send(agent, "clickElement", {{"ref", ref}}, "w1"), "PRECONDITION_FAILED");
    const auto weak = send(agent, "clickElement", {{"ref", ref}, {"acceptWeakReference", true}}, "w1");
    check(weak.at("result").at("referenceStrength") == "weak", "weak click accepted " + weak.dump());
    surface.moved = true;
    snap = send(agent, "snapshot", {{"windowId", "42"}}, "s3").at("result");
    ref = snap.at("elements")[1].at("ref");
    const int before = driver.performs;
    error(send(agent, "clickElement", {{"ref", ref}, {"acceptWeakReference", true}}, "w2"), "STALE_REFERENCE");
    check(driver.performs == before, "a weak element with other bounds is never clicked");
    surface.moved = false;
    surface.strength = "strong";
    snap = send(agent, "snapshot", {{"windowId", "42"}}, "s4").at("result");
    check(!send(agent, "clickElement", {{"ref", snap.at("elements")[1].at("ref")}}, "w3").at("result")
              .contains("referenceStrength"), "a strong reference is not named");
    // A scoped capture: UIA assumes physical pixels.
    surface.strength.clear();
    snap = send(agent, "snapshot", {{"windowId", "42"}}, "s5").at("result");
    auto scoped = send(agent, "snapshot", {{"windowId", "42"}, {"scopeRef", snap.at("elements")[1].at("ref")}}, "s6");
    const auto assumed = send(agent, "clickElement", {{"ref", scoped.at("result").at("elements")[0].at("ref")}}, "e1");
    check(assumed.at("result").at("boundsMapping") == "assumedPhysical", "scoped UIA " + assumed.dump());
    surface.scoped = false;
    surface.disabled = true;
    snap = send(agent, "snapshot", {{"windowId", "42"}}, "s7").at("result");
    error(send(agent, "clickElement", {{"ref", snap.at("elements")[1].at("ref")}}, "e2"), "PRECONDITION_FAILED");
    surface.disabled = false;

    Surface bridge("JAB");
    Agent java(bridge, "j", [](int pid) { return pid == 123; }, {Action::pointer}, Clock::now, nullptr, {&driver, true});
    snap = send(java, "snapshot", {{"windowId", "42"}}, "s1").at("result");
    scoped = send(java, "snapshot", {{"windowId", "42"}, {"scopeRef", snap.at("elements")[1].at("ref")}}, "s2");
    error(send(java, "clickElement", {{"ref", scoped.at("result").at("elements")[0].at("ref")}}, "j1"),
          "BOUNDS_UNVERIFIED");
    Surface msaa("MSAA");
    Agent accessibility(msaa, "a", [](int pid) { return pid == 123; }, {Action::pointer}, Clock::now, nullptr, {&driver, true});
    const auto savedWindow = driver.rect;
    driver.rect = {92, 169, 416, 339};
    driver.client = msaa.root;
    snap = send(accessibility, "snapshot", {{"windowId", "42"}}, "s1").at("result");
    ref = snap.at("elements")[1].at("ref");
    const auto msaaClick = send(accessibility, "clickElement", {{"ref", ref}}, "m1");
    check(msaaClick.at("result").at("boundsMapping") == "physical"
          && msaaClick.at("result").at("point") == Json{{"x", 200}, {"y", 260}}, "MSAA client bounds " + msaaClick.dump());
    driver.client->y += 4;
    error(send(accessibility, "clickElement", {{"ref", ref}}, "m2"), "BOUNDS_UNVERIFIED");
    driver.rect = savedWindow;
    driver.client.reset();
    Agent denied(surface, "d", [](int) { return false; }, {Action::pointer}, Clock::now, nullptr, {&driver, true});
    snap = send(denied, "snapshot", {{"windowId", "42"}}, "s1").at("result");
    error(send(denied, "clickElement", {{"ref", snap.at("elements")[1].at("ref")}}, "x"), "PERMISSION_DENIED");
    Agent unsupported(surface, "n", [](int) { return true; }, {Action::pointer});
    snap = send(unsupported, "snapshot", {{"windowId", "42"}}, "s1").at("result");
    error(send(unsupported, "clickElement", {{"ref", snap.at("elements")[1].at("ref")}}, "x"), "INPUT_UNAVAILABLE");
}

void capabilities() {
    Surface surface;
    FakeDriver driver;
    const auto caps = [&](std::set<Action> actions, InputDriver* input) {
        Agent agent(surface, "c", [](int) { return true; }, std::move(actions), Clock::now, nullptr, {input, true});
        return send(agent, "getCapabilities").at("result");
    };
    const auto plain = caps({Action::invoke, Action::setValue}, nullptr);
    check(plain == caps({Action::invoke, Action::setValue}, &driver) && !plain.contains("input")
          && plain.at("physicalInput") == false && plain.at("operations").size() == 7
          && plain.dump() == desktop::capabilities("UIA", true).dump(), "no input action, no change");
    const auto full = caps({Action::invoke, Action::keyboard, Action::pointer, Action::activate}, &driver);
    check(full.at("physicalInput") == true, "physical input available");
    check(full.at("operations") == Json::array({"getCapabilities", "listWindows", "snapshot", "findElement",
        "getElementInfo", "invoke", "setValue", "activateWindow", "pointerMove", "pointerClick", "pointerDrag",
        "pointerScroll", "clickElement", "keyPress", "keyDown", "keyUp", "typeText"}), "input operations " + full.dump());
    const auto& input = full.at("input");
    check(input == Json{{"available", true}, {"allowedActions", {"activate", "keyboard", "pointer"}},
                        {"dpiAwareness", "perMonitorV2"}, {"integrity", "medium"}, {"inputDesktop", true},
                        {"virtualScreen", {{"x", -1920}, {"y", 0}, {"width", 3840}, {"height", 1080}}},
                        {"monitors", 2}, {"buttonsSwapped", false}}, "input object " + input.dump());
    const auto keyboardOnly = caps({Action::keyboard}, &driver);
    check(keyboardOnly.at("operations").size() == 11 && keyboardOnly.at("operations").back() == "typeText",
          "only allowed operations");
    driver.state.available = false;
    driver.state.reason = "The input thread is DPI-unaware on a scaled display.";
    const auto unavailable = caps({Action::pointer}, &driver);
    check(unavailable.at("physicalInput") == false && unavailable.at("input").at("reason") == driver.state.reason
          && unavailable.at("operations").size() == 7, "unavailable input adds no operations");
    const auto missing = caps({Action::pointer}, nullptr);
    check(missing.at("input").at("available") == false && missing.at("input").contains("reason"), "no driver");
}

void multi() {
    FakeDriver driver;
    std::thread::id uiaThread, jabThread;
    MultiSession session({{"UIA", [&] { auto a = std::make_unique<Surface>("UIA"); uiaThread = a->thread; return a; }, true},
                          {"JAB", [&] { auto a = std::make_unique<Surface>("JAB"); jabThread = a->thread; return a; }, false}},
                         "m", [](int pid) { return pid == 123; }, {Action::invoke, Action::pointer}, requestBudget, &driver);
    const auto caps = session.handle({{"id", "caps"}, {"op", "getCapabilities"}}).at("result");
    check(caps.at("physicalInput") == true && caps.contains("input")
          && caps.at("input").at("allowedActions") == Json::array({"pointer"}), "multi top level " + caps.dump());
    for (const auto& row : caps.at("backends"))
        check(!row.contains("input") && row.at("physicalInput") == false && row.at("operations").size() == 7,
              "backend rows unchanged " + row.dump());
    const Json move{{"id", "m1"}, {"op", "pointerMove"}, {"windowId", "42"}, {"processId", 123}, {"point", screen(1, 1)}};
    check(session.handle(move).at("ok") == true && driver.thread == uiaThread, "pointer input on the default worker");
    error(session.handle(move), "DUPLICATE_COMMAND");
    const auto snap = session.handle({{"id", "s"}, {"op", "snapshot"}, {"windowId", "42"}, {"backend", "JAB"}});
    const auto ref = snap.at("result").at("elements")[1].at("ref");
    const auto clicked = session.handle({{"id", "c1"}, {"op", "clickElement"}, {"ref", ref}});
    check(clicked.at("ok") == true && driver.thread == jabThread && clicked.at("result").at("backend") == "JAB",
          "clickElement on the issuing worker " + clicked.dump());
    error(session.handle({{"id", "m1"}, {"op", "clickElement"}, {"ref", ref}}), "DUPLICATE_COMMAND");
    error(session.handle({{"id", "c2"}, {"op", "clickElement"}, {"ref", "other-1"}}), "STALE_REFERENCE");
    error(session.handle({{"id", "c3"}, {"op", "clickElement"}}), "INVALID_REQUEST");
    MultiSession plain({{"UIA", [] { return std::make_unique<Surface>("UIA"); }, true}}, "p", [](int) { return true; },
                       {Action::invoke}, requestBudget, &driver);
    const auto before = plain.handle({{"id", "caps"}, {"op", "getCapabilities"}}).at("result");
    check(!before.contains("input") && before.at("physicalInput") == false, "multi without input actions");
}

// A late or uncertain input request ends with its own error. The backend stays usable for the next request.
void inputErrorsKeepBackend() {
    {
        Surface surface;
        FakeDriver driver;
        Agent agent(surface, "s", [](int) { return true; }, {Action::pointer}, Clock::now, nullptr, {&driver, true});
        RequestDeadline late(Clock::now() - 1ms);
        const auto reply = agent.handle({{"id", "late"}, {"op", "pointerMove"}, {"windowId", "42"}, {"processId", 123},
                                         {"point", screen(1, 1)}}, late);
        error(reply, "TIMEOUT");
        check(!late.retiring(), "a gate timeout does not retire the worker");
    }
    for (const char* failure : {"TIMEOUT", "ACTION_OUTCOME_UNKNOWN"}) {
        FakeDriver driver;
        const bool sent = std::string_view(failure) != "TIMEOUT";
        driver.script = [failure, sent](const InputCommand&, const InputGate& gate) {
            if (sent) gate();
            Error ended(failure, "Driver ended the request.");
            ended.inputSent = sent;
            throw ended;
        };
        SessionWorker session([] { return std::make_unique<Surface>(); }, "w", [](int) { return true; },
                              {Action::pointer}, 2000ms, "UIA", nullptr, {&driver, true});
        error(session.handle({{"id", "i"}, {"op", "pointerMove"}, {"windowId", "42"}, {"processId", 123},
                              {"point", screen(1, 1)}}), failure, sent);
        check(session.handle({{"id", "s"}, {"op", "snapshot"}, {"windowId", "42"}}).at("ok") == true
              && session.handle({{"id", "c"}, {"op", "getCapabilities"}}).at("result").at("available") == true,
              std::string("backend usable after ") + failure);
    }
}

void worker(bool afterGate) {
    FakeDriver driver;
    driver.script = [afterGate](const InputCommand&, const InputGate& gate) {
        if (afterGate) gate();
        std::this_thread::sleep_for(400ms);
        if (!afterGate) gate();
    };
    Json reply, duplicate;
    {
        SessionWorker session([] { return std::make_unique<Surface>(); }, "w", [](int) { return true; },
                              {Action::pointer}, 200ms, "UIA", nullptr, {&driver, true});
        const Json move{{"id", "slow"}, {"op", "pointerMove"}, {"windowId", "42"}, {"processId", 123},
                        {"point", screen(1, 1)}};
        reply = session.handle(move);
        duplicate = session.handle(move);
    }
    error(reply, afterGate ? "ACTION_OUTCOME_UNKNOWN" : "TIMEOUT", afterGate);
    error(duplicate, "DUPLICATE_COMMAND");
}
} // namespace

int main() {
    try {
        parsing();
        keys();
        normalization();
        mapping();
        policy();
        keyboard();
        elements();
        capabilities();
        multi();
        inputErrorsKeepBackend();
        worker(false);
        worker(true);
    } catch (const std::exception& ex) {
        std::cerr << ex.what() << '\n';
        return 1;
    }
    std::cout << "input contract passed\n";
}
