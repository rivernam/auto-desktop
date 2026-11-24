#include "core/agent.hpp"
#include "core/session_worker.hpp"
#include "protocol/ndjson.hpp"

#include <iostream>
#include <sstream>
#include <thread>

using namespace desktop;
using namespace std::chrono_literals;

namespace {
void check(bool passed, const char* message) {
    if (!passed) throw std::runtime_error(message);
}

class Fixture final : public DesktopAdapter {
public:
    int mutations = 0;
    int clears = 0;
    bool alive = true;
    bool captureFails = false;
    bool timeoutAfterDispatch = false;
    std::string value;
    std::function<void()> beforePreflight;
    std::function<void()> afterDispatch;
    std::function<void()> onClose;

    ~Fixture() override { if (onClose) onClose(); }

    bool forceTruncated = false;
    std::vector<std::size_t> partialRows;

    std::vector<Window> windows() override { return {{"42", 123, "Fixture"}, {"43", 123, "Dialog", "42"}}; }
    Capture capture(const std::string&, std::optional<std::size_t> scope, int depth, int limit) override {
        if (captureFails) throw Error("WINDOW_NOT_FOUND", "Missing fixture.");
        Element root;
        root.pid = 123;
        root.identity = {"Fixture", "Window", "", "Window"};
        Element button;
        button.pid = 123;
        button.identity = {"Duplicate", "Button", "button", "Button"};
        button.parent = 0;
        button.invoke = true;
        Element edit;
        edit.pid = 123;
        edit.identity = {"", "Edit", "edit", "TextBox"};
        edit.parent = 0;
        edit.writable = true;
        if (scope) {
            edit.parent.reset();
            return {{edit}, false};
        }
        std::vector<Element> rows{root, button, button, edit};
        rows[2].identity.automationId = "another";
        if (depth == 0) limit = 1;
        const bool truncated = limit < static_cast<int>(rows.size());
        if (truncated) rows.resize(static_cast<std::size_t>(limit));
        for (const auto index : partialRows) rows.at(index).partial = true;
        return {std::move(rows), truncated || forceTruncated};
    }
    Element info(std::size_t index) override {
        return capture("42", {}, 12, 20).elements.at(index);
    }
    void perform(Action, std::size_t, const std::string& text, const BeforeMutation& before) override {
        if (beforePreflight) beforePreflight();
        before();
        ++mutations;
        value = text;
        if (afterDispatch) afterDispatch();
        if (timeoutAfterDispatch) throw Error("ACTION_OUTCOME_UNKNOWN", "Provider timeout.", true);
    }
    void clear() noexcept override { ++clears; }
};

Json request(Agent& agent, const char* op, Json args = Json::object(), std::string id = "id") {
    args["id"] = std::move(id);
    args["op"] = op;
    RequestDeadline deadline(Clock::now() + 10s);
    return agent.handle(args, deadline);
}

void error(const Json& reply, const char* code) {
    if (reply.at("ok") != false || reply.at("error").at("code") != code)
        throw std::runtime_error(std::string("Expected ") + code + ", got " + reply.dump());
}

void core() {
    Fixture fixture;
    auto now = Clock::now();
    Agent agent(fixture, "session", [&](int pid) { return fixture.alive && pid == 123; },
                {Action::invoke, Action::setValue}, [&] { return now; });
    const auto snap = request(agent, "snapshot", {{"windowId", "42"}}).at("result");
    const auto id = snap.at("snapshotId");
    const auto& rows = snap.at("elements");
    const auto root = rows.at(0).at("ref");
    const auto button = rows.at(1).at("ref");
    const auto edit = rows.at(3).at("ref");
    check(rows.at(0).at("parentRef").is_null() && rows.at(1).at("parentRef") == root, "parent links");
    check(request(agent, "getElementInfo", {{"ref", button}}).at("result").at("ref") == button, "live ref");
    const auto find = [&](const Json& locator, const Json& scope) {
        return request(agent, "findElement", {{"snapshotId", id}, {"locator", locator}, {"scopeRef", scope}});
    };
    error(find({{"name", "Duplicate"}}, root), "AMBIGUOUS_ELEMENT");
    error(find({{"role", "button"}}, root), "ELEMENT_NOT_FOUND");
    check(find({{"role", "Button"}, {"automationId", "button"}}, root).at("result").at("ref") == button,
          "exact AND lookup");
    error(find({{"automationId", "button"}}, edit), "ELEMENT_NOT_FOUND");
    error(find({{"pid", "123"}}, root), "INVALID_REQUEST");
    error(request(agent, "snapshot", {{"windowId", "42"}, {"maxDepth", 1.0}}), "INVALID_REQUEST");
    const auto invoked = request(agent, "invoke", {{"ref", button}});
    check(invoked.at("ok") == true && invoked.at("result").at("performed") == true, "invoke dispatched");
    // A provider's return shows dispatch only. The reply must never claim an observed effect.
    check(invoked.at("result").at("effectVerified") == false, "dispatch is not a verified effect");
    const auto windows = request(agent, "listWindows").at("result");
    check(windows.size() == 2 && !windows[0].contains("ownerWindowId") && windows[0].at("windowId") == "42"
          && windows[1].at("ownerWindowId") == "42" && windows[1].at("processId") == 123, "owned window row");
    error(request(agent, "invoke", {{"ref", button}}), "DUPLICATE_COMMAND");
    check(fixture.mutations == 1, "duplicate did not dispatch");
    check(request(agent, "setValue", {{"ref", edit}, {"value", ""}}, "empty").at("ok") == true, "empty value");
    error(request(agent, "setValue", {{"ref", edit}, {"value", std::string(16385, 'a')}}, "oversize"),
          "INVALID_REQUEST");
    fixture.alive = false;
    error(request(agent, "invoke", {{"ref", button}}, "lost-pid"), "PERMISSION_DENIED");
    fixture.alive = true;
    const auto scoped = request(agent, "snapshot", {{"windowId", "42"}, {"scopeRef", edit}}).at("result");
    check(scoped.at("elements").size() == 1 && scoped.at("elements")[0].at("parentRef").is_null(), "scope root");
    error(request(agent, "getElementInfo", {{"ref", edit}}), "STALE_REFERENCE");
    const auto limited = request(agent, "snapshot", {{"windowId", "42"}, {"maxElements", 3}}).at("result");
    check(limited.at("truncated") == true, "limit retained");
    error(request(agent, "findElement", {{"snapshotId", limited.at("snapshotId")},
          {"locator", {{"name", "Duplicate"}}}}), "AMBIGUOUS_ELEMENT");
    error(request(agent, "findElement", {{"snapshotId", limited.at("snapshotId")},
          {"locator", {{"role", "Window"}}}, {"scopeRef", limited.at("elements")[0].at("ref")}}),
          "INCOMPLETE_SNAPSHOT");
    const auto stale = limited.at("elements")[0].at("ref");
    now += 120s;
    agent.expire();
    error(request(agent, "getElementInfo", {{"ref", stale}}), "STALE_REFERENCE");
    check(fixture.clears == 1, "TTL released adapter cache");
    const auto next = request(agent, "snapshot", {{"windowId", "42"}}).at("result");
    error(request(agent, "getElementInfo", {{"ref", stale}}), "STALE_REFERENCE");
    fixture.captureFails = true;
    error(request(agent, "snapshot", {{"windowId", "42"}}), "WINDOW_NOT_FOUND");
    error(request(agent, "getElementInfo", {{"ref", next.at("elements")[0].at("ref")}}), "STALE_REFERENCE");
    check(fixture.clears == 2, "failed capture cleared adapter cache");
}

void completeness() {
    Fixture fixture;
    Agent agent(fixture, "partial", [](int) { return true; }, {Action::invoke});
    fixture.forceTruncated = true;
    fixture.partialRows = {0, 2};
    const auto snap = request(agent, "snapshot", {{"windowId", "42"}}).at("result");
    const auto& rows = snap.at("elements");
    check(snap.at("truncated") == true && rows.at(0).at("partial") == true && rows.at(2).at("partial") == true
          && !rows.at(1).contains("partial") && !rows.at(3).contains("partial"), "partial rows are named");
    const auto find = [&](const Json& locator, const Json& scope) {
        Json args{{"snapshotId", snap.at("snapshotId")}, {"locator", locator}};
        if (!scope.is_null()) args["scopeRef"] = scope;
        return request(agent, "findElement", std::move(args));
    };
    // The first button was captured whole, so a match or a miss inside it is conclusive.
    const auto whole = rows.at(1).at("ref");
    check(find({{"automationId", "button"}}, whole).at("result").at("ref") == whole, "whole scope lookup");
    error(find({{"automationId", "absent"}}, whole), "ELEMENT_NOT_FOUND");
    // A cut branch and the whole window can still hide a match.
    error(find({{"automationId", "another"}}, rows.at(2).at("ref")), "INCOMPLETE_SNAPSHOT");
    error(find({{"automationId", "button"}}, rows.at(0).at("ref")), "INCOMPLETE_SNAPSHOT");
    error(find({{"automationId", "button"}}, nullptr), "INCOMPLETE_SNAPSHOT");
    error(find({{"name", "Duplicate"}}, nullptr), "AMBIGUOUS_ELEMENT");
    check(request(agent, "getElementInfo", {{"ref", rows.at(2).at("ref")}}).at("result").at("partial") == true
          && !request(agent, "getElementInfo", {{"ref", whole}}).at("result").contains("partial"),
          "live info keeps capture completeness");
    // Without named rows a truncated snapshot proves nothing about any scope.
    fixture.partialRows.clear();
    const auto unmarked = request(agent, "snapshot", {{"windowId", "42"}}).at("result");
    error(request(agent, "findElement", {{"snapshotId", unmarked.at("snapshotId")},
          {"locator", {{"automationId", "button"}}}, {"scopeRef", unmarked.at("elements")[1].at("ref")}}),
          "INCOMPLETE_SNAPSHOT");
    fixture.forceTruncated = false;
    fixture.partialRows = {1};
    error(request(agent, "snapshot", {{"windowId", "42"}}), "WORKER_PROTOCOL");
}

void history() {
    Fixture fixture;
    Agent agent(fixture, "limit", [](int) { return true; }, {Action::invoke});
    const auto snap = request(agent, "snapshot", {{"windowId", "42"}}).at("result");
    const auto button = snap.at("elements")[1].at("ref");
    const auto edit = snap.at("elements")[3].at("ref");
    error(request(agent, "setValue", {{"ref", edit}, {"value", "ignored"}}), "PERMISSION_DENIED");
    error(request(agent, "invoke", {{"ref", edit}}), "PATTERN_UNSUPPORTED");
    for (int i = 0; i < 4095; ++i)
        check(request(agent, "invoke", {{"ref", button}}, std::to_string(i)).at("ok") == true, "history capacity");
    fixture.timeoutAfterDispatch = true;
    error(request(agent, "invoke", {{"ref", button}}, "uncertain"), "ACTION_OUTCOME_UNKNOWN");
    error(request(agent, "invoke", {{"ref", button}}, "uncertain"), "DUPLICATE_COMMAND");
    error(request(agent, "invoke", {{"ref", button}}, "overflow"), "SESSION_LIMIT");
    check(fixture.mutations == 4096, "bounded mutations");
}

void framing() {
    std::istringstream input(std::string(frameLimit + 1, 'x')
        + "\n{\"a\":{\"b\":1,\"b\":2}}\n{\"a\":1} {\"b\":2}\n{\"a\":\"\xFF\"}\n"
          "{\"id\":\"j\",\"op\":\"getCapabilities\"}\r\n{\"last\":true}");
    std::string raw;
    for (int i = 0; i < 4; ++i) {
        check(readFrame(input, raw), "invalid frame drained");
        check(parseFrame(raw).is_null(), "malformed frame rejected");
    }
    check(readFrame(input, raw) && parseFrame(raw).at("id") == "j", "recovery");
    check(readFrame(input, raw) && parseFrame(raw).at("last") == true, "unterminated final frame");
    check(!readFrame(input, raw), "EOF");
    check(utf16Length("\xF0\x9F\x98\x80") == 2, "supplementary UTF-16 width");
    check(isBlank("\xE3\x80\x80") && !isBlank("\xC2\xA0"), "Java whitespace semantics");
    check(parseFrame(std::string(200, '[') + std::string(200, ']')).is_null(), "depth ceiling");
    check(parseFrame(std::string("\xEF\xBB\xBF") + "{}").is_null(), "BOM rejected");
}

void deadline() {
    RequestDeadline cancelled(Clock::now() + 1s);
    check(!cancelled.cancel(), "cancelled before provider dispatch");
    try {
        cancelled.beginMutation();
        throw std::runtime_error("late mutation was allowed");
    } catch (const Error& ex) {
        check(std::string(ex.code) == "TIMEOUT", "preflight timeout");
    }
    RequestDeadline dispatched(Clock::now() + 1s);
    dispatched.beginMutation();
    check(dispatched.cancel(), "already dispatched, outcome unknown");
}

void workerTimeout(bool afterDispatch) {
    std::promise<void> unblock;
    const auto release = unblock.get_future().share();
    const auto caller = std::this_thread::get_id();
    std::thread::id created, destroyed;
    int performed = -1;
    Json timeout, duplicate, next;
    {
        SessionWorker worker([&] {
            created = std::this_thread::get_id();
            auto fixture = std::make_unique<Fixture>();
            auto* provider = fixture.get();
            auto& pause = afterDispatch ? fixture->afterDispatch : fixture->beforePreflight;
            pause = [release] {
                // Bound the fake provider even if the test itself fails.
                release.wait_for(2s);
            };
            fixture->onClose = [&, provider] {
                destroyed = std::this_thread::get_id();
                performed = provider->mutations;
            };
            return fixture;
        }, "worker", [](int) { return true; }, {Action::invoke}, 200ms);
        const auto snap = worker.handle({{"id", "capture"}, {"op", "snapshot"}, {"windowId", "42"}});
        const Json invoke{{"id", "action"}, {"op", "invoke"}, {"ref", snap.at("result").at("elements")[1].at("ref")}};
        timeout = worker.handle(invoke);
        duplicate = worker.handle(invoke);
        next = worker.handle({{"id", "next"}, {"op", "listWindows"}});
        unblock.set_value();
    }
    error(timeout, afterDispatch ? "ACTION_OUTCOME_UNKNOWN" : "TIMEOUT");
    error(duplicate, "DUPLICATE_COMMAND");
    error(next, "BACKEND_UNAVAILABLE");
    check(created != caller && created == destroyed, "adapter released on its owning thread");
    check(performed == (afterDispatch ? 1 : 0), "timeout did not allow a late or duplicate mutation");
}
// A second provider behind the same core: its own backend name, capability detail, role and
// completeness diagnostics, idle ticks, and errors that leave the session usable.
class Bridged final : public DesktopAdapter {
public:
    bool loaded = true;
    bool silent = false;
    int* ticks = nullptr;
    std::thread::id* tickThread = nullptr;

    const char* backend() const override { return "JAB"; }
    Availability availability() override {
        Availability result;
        result.available = loaded;
        result.reason = "The specified Java Access Bridge library does not exist.";
        if (loaded) result.javaWindows = std::make_pair(3, 2);
        return result;
    }
    std::chrono::milliseconds idleInterval() const override { return 10ms; }
    void idle() noexcept override {
        if (ticks) ++*ticks;
        if (tickThread) *tickThread = std::this_thread::get_id();
    }
    std::vector<Window> windows() override {
        if (!loaded) throw Error("BACKEND_UNAVAILABLE", "The specified Java Access Bridge library does not exist.");
        if (silent) throw Error("TARGET_NOT_RESPONDING", "A JVM is not answering Java Access Bridge.");
        return {{"7", 5, "Swing"}};
    }
    Capture capture(const std::string&, std::optional<std::size_t>, int, int) override {
        Element root;
        root.pid = 5;
        root.identity = {"Swing", "Window", "", ""};
        root.identity.nativeRole = "frame";
        root.partial = true;
        root.partialReason = "limit";
        Element gauge;
        gauge.pid = 5;
        gauge.parent = 0;
        gauge.identity = {"Gauge", "Custom", "", ""};
        gauge.identity.nativeRole = "dial";
        return {{root, gauge}, true};
    }
    Element info(std::size_t index) override { return capture("7", {}, 1, 2).elements.at(index); }
    void perform(Action, std::size_t, const std::string&, const BeforeMutation& before) override { before(); }
    void clear() noexcept override {}
};

void secondBackend() {
    int ticks = 0;
    std::thread::id created, ticked;
    Bridged* provider = nullptr;
    {
        SessionWorker worker([&] {
            created = std::this_thread::get_id();
            auto adapter = std::make_unique<Bridged>();
            adapter->ticks = &ticks;
            adapter->tickThread = &ticked;
            provider = adapter.get();
            return adapter;
        }, "bridge", [](int) { return true; }, {Action::invoke}, 2000ms, "JAB");
        const auto caps = worker.handle({{"id", "caps"}, {"op", "getCapabilities"}}).at("result");
        check(caps.at("backend") == "JAB" && caps.at("available") == true && caps.at("bridge").at("javaWindows") == 3
              && caps.at("bridge").at("connectedWindows") == 2 && caps.at("operations").size() == 7,
              "bridge capabilities carry the window counts");
        const auto snap = worker.handle({{"id", "snap"}, {"op", "snapshot"}, {"windowId", "7"}}).at("result");
        const auto& rows = snap.at("elements");
        check(rows[0].at("backend") == "JAB" && rows[0].at("nativeRole") == "frame"
              && rows[0].at("partialReason") == "limit" && rows[1].at("role") == "Custom"
              && rows[1].at("nativeRole") == "dial" && !rows[1].contains("partialReason"),
              "rows carry the provider role and the cause of a cut");
        const auto live = worker.handle({{"id", "info"}, {"op", "getElementInfo"}, {"ref", rows[0].at("ref")}});
        check(live.at("result").at("partialReason") == "limit" && live.at("result").at("nativeRole") == "frame",
              "a live read keeps the completeness of the capture");
        provider->silent = true;
        error(worker.handle({{"id", "busy"}, {"op", "listWindows"}}), "TARGET_NOT_RESPONDING");
        provider->silent = false;
        check(worker.handle({{"id", "again"}, {"op", "listWindows"}}).at("ok") == true,
              "a silent target does not retire the session");
        std::this_thread::sleep_for(200ms);
        check(worker.handle({{"id", "late"}, {"op", "listWindows"}}).at("ok") == true, "idle ticks leave the session usable");
    }
    check(ticks >= 3 && ticked == created, "an idle session is ticked on the thread that owns the provider");

    SessionWorker missing([] {
        auto adapter = std::make_unique<Bridged>();
        adapter->loaded = false;
        return adapter;
    }, "missing", [](int) { return true; }, {}, 2000ms, "JAB");
    const auto caps = missing.handle({{"id", "caps"}, {"op", "getCapabilities"}}).at("result");
    check(caps.at("backend") == "JAB" && caps.at("available") == false && caps.at("operations").empty()
          && caps.at("reason") == "The specified Java Access Bridge library does not exist." && !caps.contains("bridge"),
          "a provider that cannot start is a capability with its reason, on its own backend");
    error(missing.handle({{"id", "list"}, {"op", "listWindows"}}), "BACKEND_UNAVAILABLE");
}
} // namespace

int main() {
    try {
        secondBackend();
        core();
        completeness();
        history();
        framing();
        deadline();
        workerTimeout(false);
        workerTimeout(true);
    } catch (const std::exception& ex) {
        std::cerr << ex.what() << '\n';
        return 1;
    }
}
