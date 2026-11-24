#include "core/agent.hpp"
#include "core/multi_session.hpp"
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
// Two scripted backends behind one multi-backend session.
struct Script {
    std::atomic<int> mutations{0};
    std::atomic<int> sessions{0};
    std::atomic<bool> silent{false};
    std::atomic<bool> blocked{false};
    std::shared_future<void> release;
    // Set for a provider that owns windows: it serves their messages while its peer runs a request.
    std::atomic<bool> ownsWindows{false};
    std::atomic<bool> serving{false};
    std::atomic<int> served{0};
    std::atomic<int> woken{0};
    // The peer whose serving state a request observes.
    Script* peer = nullptr;
    std::atomic<bool> peerServedDuringRequest{false};
};

class Scripted final : public DesktopAdapter {
public:
    Scripted(const char* name, Script& script) : name_(name), script_(script) { ++script_.sessions; }
    const char* backend() const override { return name_; }
    std::chrono::milliseconds idleInterval() const override {
        return script_.ownsWindows ? 50ms : std::chrono::milliseconds::zero();
    }
    void serve(const std::function<bool()>& done) noexcept override {
        ++script_.served;
        script_.serving = true;
        while (!done()) std::this_thread::sleep_for(1ms);
        script_.serving = false;
    }
    void wake() noexcept override { ++script_.woken; }
    std::vector<Window> windows() override {
        if (script_.silent) throw Error("TARGET_NOT_RESPONDING", "The target is not answering.");
        if (script_.peer) {
            for (int attempt = 0; attempt < 200 && !script_.peer->serving; ++attempt) std::this_thread::sleep_for(1ms);
            script_.peerServedDuringRequest = script_.peer->serving.load();
        }
        // Bound the fake provider even if the test itself fails.
        if (script_.blocked) script_.release.wait_for(3s);
        const bool uia = std::string_view(name_) == "UIA";
        return {{"100", 42, std::string(name_) + " title"}, {uia ? "200" : "300", 42, "Only here", "100"}};
    }
    Capture capture(const std::string&, std::optional<std::size_t>, int, int) override {
        if (script_.silent) throw Error("TARGET_NOT_RESPONDING", "The target is not answering.");
        Element root;
        root.pid = 42;
        root.identity = {"Shared", "Window", "", ""};
        Element button;
        button.pid = 42;
        button.parent = 0;
        button.identity = {"Shared", "Button", "", ""};
        button.invoke = true;
        button.writable = true;
        return {{root, button}, false};
    }
    Element info(std::size_t index) override {
        if (script_.silent) throw Error("TARGET_NOT_RESPONDING", "The target is not answering.");
        return capture("100", {}, 1, 2).elements.at(index);
    }
    void perform(Action, std::size_t, const std::string&, const BeforeMutation& before) override {
        before();
        ++script_.mutations;
    }
    void clear() noexcept override {}

private:
    const char* name_;
    Script& script_;
};

void multiBackend() {
    Script uia, jab;
    // Like the bridge, the second provider owns windows from the start.
    jab.ownsWindows = true;
    std::promise<void> unblock;
    uia.release = jab.release = unblock.get_future().share();
    {
        MultiSession session({{"UIA", [&] { return std::make_unique<Scripted>("UIA", uia); }, true},
                              {"JAB", [&] { return std::make_unique<Scripted>("JAB", jab); }, false}},
                             "s", [](int pid) { return pid == 42; }, {Action::invoke, Action::setValue}, 300ms);
        int sequence = 0;
        const auto send = [&](const char* op, Json args = Json::object()) {
            args["id"] = "m" + std::to_string(++sequence);
            args["op"] = op;
            return session.handle(std::move(args));
        };
        const auto capture = [&](const char* backend) {
            Json args{{"windowId", "100"}};
            if (backend) args["backend"] = backend;
            const auto reply = send("snapshot", std::move(args));
            check(reply.at("ok") == true, "multi snapshot");
            return reply.at("result");
        };
        const auto button = [](const Json& snapshot) { return snapshot.at("elements")[1].at("ref"); };

        const auto caps = send("getCapabilities").at("result");
        check(caps.at("backend") == "multi" && caps.at("available") == true && caps.at("operations").size() == 7
              && caps.at("defaultBackend") == "UIA" && caps.at("backends")[0].at("backend") == "UIA"
              && caps.at("backends")[1].at("backend") == "JAB" && caps.at("backends")[1].at("available") == true,
              "multi capabilities list each backend");

        auto listed = send("listWindows");
        const auto& rows = listed.at("result");
        check(rows.size() == 3 && rows[0].at("windowId") == "100" && rows[0].at("name") == "UIA title"
              && rows[0].at("backends") == Json::array({"UIA", "JAB"}) && rows[1].at("backends") == Json::array({"UIA"})
              && rows[1].at("ownerWindowId") == "100" && rows[2].at("windowId") == "300"
              && rows[2].at("backends") == Json::array({"JAB"}), "one row per window with its backends");
        check(listed.at("backends") == Json::array({{{"backend", "UIA"}, {"ok", true}}, {{"backend", "JAB"}, {"ok", true}}}),
              "window list carries one status per backend");

        const auto first = capture(nullptr);
        check(first.at("backend") == "UIA" && first.at("elements")[0].at("backend") == "UIA", "default backend");
        const auto bridged = capture("JAB");
        check(bridged.at("backend") == "JAB" && bridged.at("elements")[1].at("backend") == "JAB", "explicit backend");
        error(send("snapshot", {{"windowId", "100"}, {"backend", "MSAA"}}), "BACKEND_UNAVAILABLE");
        error(send("snapshot", {{"windowId", "100"}, {"backend", 7}}), "INVALID_REQUEST");

        // Each backend keeps its own latest snapshot.
        check(send("getElementInfo", {{"ref", button(first)}}).at("ok") == true, "a bridge capture kept the UIA references");
        const auto second = capture("UIA");
        error(send("getElementInfo", {{"ref", button(first)}}), "STALE_REFERENCE");
        error(send("findElement", {{"snapshotId", first.at("snapshotId")}, {"locator", {{"role", "Button"}}}}),
              "STALE_REFERENCE");
        check(send("getElementInfo", {{"ref", button(bridged)}}).at("result").at("backend") == "JAB",
              "a UIA capture kept the bridge references");
        check(send("findElement", {{"snapshotId", bridged.at("snapshotId")}, {"locator", {{"role", "Button"}}}})
                  .at("result").at("ref") == button(bridged), "lookup in the named snapshot");

        // A reference is stale for every other backend.
        error(send("snapshot", {{"windowId", "100"}, {"backend", "JAB"}, {"scopeRef", button(second)}}), "STALE_REFERENCE");
        error(send("findElement", {{"snapshotId", bridged.at("snapshotId")}, {"scopeRef", button(second)},
                                   {"locator", {{"role", "Button"}}}}), "STALE_REFERENCE");
        error(send("invoke", {{"ref", "other-session-1"}}), "STALE_REFERENCE");
        error(send("invoke", {{"ref", 5}}), "INVALID_REQUEST");

        // While one backend runs a request, a backend that owns windows serves their messages.
        uia.peer = &jab;
        listed = send("listWindows");
        for (int attempt = 0; attempt < 200 && jab.serving; ++attempt) std::this_thread::sleep_for(1ms);
        check(listed.at("ok") == true && uia.peerServedDuringRequest && jab.served >= 1 && !jab.serving,
              "the bridge thread serves its windows during a UIA request and stops afterwards");
        check(send("getElementInfo", {{"ref", button(bridged)}}).at("ok") == true && !jab.serving,
              "a request for the serving backend is not delayed");
        check(uia.served == 0, "a backend without windows is never asked to serve");
        uia.peer = nullptr;

        // An action goes to the backend that issued the reference. Command IDs are shared.
        const auto done = session.handle({{"id", "command"}, {"op", "setValue"}, {"ref", button(second)}, {"value", "x"}});
        check(done.at("result").at("performed") == true && done.at("result").at("effectVerified") == false
              && uia.mutations == 1 && jab.mutations == 0, "action reached its own backend only");
        error(session.handle({{"id", "command"}, {"op", "invoke"}, {"ref", button(bridged)}}), "DUPLICATE_COMMAND");
        check(send("invoke", {{"ref", button(bridged)}}).at("ok") == true && jab.mutations == 1 && uia.mutations == 1,
              "bridge action");

        // A silent bridge target fails its own requests and nothing else.
        jab.silent = true;
        error(send("getElementInfo", {{"ref", button(bridged)}}), "TARGET_NOT_RESPONDING");
        listed = send("listWindows");
        check(listed.at("ok") == true && listed.at("result").size() == 2
              && listed.at("backends")[1].at("ok") == false
              && listed.at("backends")[1].at("error").at("code") == "TARGET_NOT_RESPONDING",
              "a partial window list names the backend that failed");
        check(send("invoke", {{"ref", button(second)}}).at("ok") == true && uia.mutations == 2, "UIA works beside a silent bridge");
        jab.silent = false;
        check(send("invoke", {{"ref", button(bridged)}}).at("ok") == true && jab.mutations == 2,
              "bridge references survive the silence");

        // A provider call that outlives the deadline retires its backend only.
        uia.blocked = true;
        listed = send("listWindows");
        check(listed.at("ok") == true && listed.at("backends")[0].at("error").at("code") == "TIMEOUT"
              && listed.at("result")[0].at("backends") == Json::array({"JAB"}), "timed-out backend is reported");
        error(send("snapshot", {{"windowId", "100"}}), "BACKEND_UNAVAILABLE");
        error(send("invoke", {{"ref", button(second)}}), "BACKEND_UNAVAILABLE");
        const auto during = send("getCapabilities").at("result");
        check(during.at("available") == true && during.at("backends")[0].at("available") == false
              && during.at("backends")[0].contains("reason") && during.at("backends")[1].at("available") == true,
              "capabilities name the retired backend");
        check(send("invoke", {{"ref", button(bridged)}}).at("ok") == true && jab.mutations == 3,
              "bridge works beside a retired UIA session");

        // Once the provider call returns, the retired backend is replaced. Its old references stay dead.
        uia.blocked = false;
        unblock.set_value();
        Json restarted;
        for (int attempt = 0; attempt < 100; ++attempt) {
            restarted = send("snapshot", {{"windowId", "100"}});
            if (restarted.at("ok") == true) break;
            std::this_thread::sleep_for(20ms);
        }
        check(restarted.at("ok") == true && uia.sessions == 2, "a released backend restarts in place");
        error(send("invoke", {{"ref", button(second)}}), "STALE_REFERENCE");
        check(button(restarted.at("result")) != button(second), "a replaced worker issues new references");
        check(send("invoke", {{"ref", button(restarted.at("result"))}}).at("ok") == true && uia.mutations == 3,
              "the replacement accepts its own references");
        check(send("invoke", {{"ref", button(bridged)}}).at("ok") == true && jab.mutations == 4 && jab.sessions == 1,
              "a restart of one backend leaves the other and its references alone");
    }

    // A backend that may not restart stays retired. The session keeps its other backend.
    Script fixed, stuck;
    std::promise<void> late;
    stuck.release = late.get_future().share();
    MultiSession session({{"UIA", [&] { return std::make_unique<Scripted>("UIA", fixed); }, true},
                          {"JAB", [&] { return std::make_unique<Scripted>("JAB", stuck); }, false}},
                         "t", [](int) { return true; }, {Action::invoke}, 200ms);
    stuck.blocked = true;
    auto listed = session.handle({{"id", "1"}, {"op", "listWindows"}});
    check(listed.at("backends")[1].at("error").at("code") == "TIMEOUT", "bridge timeout");
    stuck.blocked = false;
    late.set_value();
    std::this_thread::sleep_for(100ms);
    error(session.handle({{"id", "2"}, {"op", "snapshot"}, {"windowId", "100"}, {"backend", "JAB"}}), "BACKEND_UNAVAILABLE");
    check(stuck.sessions == 1 && session.handle({{"id", "3"}, {"op", "snapshot"}, {"windowId", "100"}}).at("ok") == true,
          "only a restartable backend is replaced");

    // A single-backend session refuses a snapshot that names another backend.
    Script alone;
    SessionWorker single([&] { return std::make_unique<Scripted>("JAB", alone); }, "one", [](int) { return true; },
                         {}, 2000ms, "JAB");
    const auto own = single.handle({{"id", "a"}, {"op", "snapshot"}, {"windowId", "100"}, {"backend", "JAB"}});
    check(own.at("ok") == true && !own.at("result").contains("backend"), "a single-backend reply keeps its shape");
    error(single.handle({{"id", "b"}, {"op", "snapshot"}, {"windowId", "100"}, {"backend", "UIA"}}), "BACKEND_UNAVAILABLE");
    error(single.handle({{"id", "c"}, {"op", "snapshot"}, {"windowId", "100"}, {"backend", ""}}), "INVALID_REQUEST");
}
} // namespace

int main() {
    try {
        multiBackend();
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
