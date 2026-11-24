#pragma once

#include "core/desktop_adapter.hpp"
#include "protocol/ndjson.hpp"

#include <atomic>
#include <chrono>
#include <mutex>
#include <set>
#include <unordered_map>
#include <unordered_set>

namespace desktop {
using Clock = std::chrono::steady_clock;
inline constexpr std::chrono::seconds requestBudget{10};

class RequestDeadline {
public:
    explicit RequestDeadline(Clock::time_point expires) : expires(expires) {}
    void beginMutation();
    bool cancel();
    void retire() { retired = true; }
    bool retiring() const { return retired; }
    const Clock::time_point expires;

private:
    enum class State { pending, dispatched, cancelledBeforeDispatch, cancelledAfterDispatch };
    std::atomic<State> state{State::pending};
    bool retired = false; // Read and written only by the request worker.
};

class CommandHistory {
public:
    bool contains(const std::string& id) const;
    void remember(const std::string& id);

private:
    mutable std::mutex mutex_;
    std::unordered_set<std::string> ids_;
};

Json failure(Json id, const Error& error);
Json capabilities(const char* backend, bool available);
Json capabilities(const char* backend, const Availability& availability);
Json requestId(const Json& request);
const char* operation(const Json& request);
std::optional<Action> parseAction(std::string_view op);
bool isMutation(std::string_view op);

class Agent {
public:
    Agent(DesktopAdapter& adapter, std::string session, AllowedProcess allowedProcess,
          std::set<Action> allowedActions, std::function<Clock::time_point()> now = Clock::now,
          CommandHistory* sharedHistory = nullptr);
    Json handle(const Json& request, RequestDeadline& deadline);
    void expire();
    Clock::time_point nextExpiry() const;

private:
    struct Snapshot {
        std::string id, window;
        Clock::time_point expires;
        Capture capture;
        std::vector<std::string> refs;
        std::unordered_map<std::string, std::size_t> indices;
    };

    Json capture(const Json& request);
    Json find(const Json& request) const;
    Json info(const Json& request);
    Json perform(const Json& request, const std::string& id, Action action, RequestDeadline& deadline);
    const Snapshot& current() const;
    std::size_t resolve(const std::string& ref) const;
    Json publicElement(std::size_t index, const Element& row) const;
    std::string token();

    DesktopAdapter& adapter_;
    std::string session_;
    AllowedProcess allowedProcess_;
    std::set<Action> allowedActions_;
    std::function<Clock::time_point()> now_;
    CommandHistory localHistory_;
    CommandHistory& history_;
    std::optional<Snapshot> snapshot_;
    std::uint64_t sequence_ = 0;
};
} // namespace desktop
