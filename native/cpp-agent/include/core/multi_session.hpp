#pragma once

#include "core/session_worker.hpp"

namespace desktop {
// One client session over several backends. Each backend runs in its own SessionWorker: its own
// thread, native session, latest snapshot and fault state. This class only routes. Requests stay
// serialized, command IDs are unique for the whole session, and a reference reaches no backend other
// than the one that issued it.
class MultiSession {
public:
    struct Backend {
        // The name that element rows carry, such as "UIA" or "JAB".
        std::string name;
        SessionWorker::AdapterFactory factory;
        // A worker that a fault retired is replaced once its thread has released the provider.
        bool restartable = false;
    };

    // The first backend is the default for a snapshot that names none.
    MultiSession(std::vector<Backend> backends, std::string session, AllowedProcess allowedProcess,
                 std::set<Action> actions, std::chrono::milliseconds budget = requestBudget);
    ~MultiSession();
    Json handle(Json request);
    // Replaces the default end of a process whose provider thread never returned.
    void onAbandon(std::function<void()> handler);

private:
    struct Slot {
        Backend config;
        std::unique_ptr<SessionWorker> worker;
        unsigned generation = 0;
        // Every snapshot ID and reference of the current worker starts with this.
        std::string prefix;
    };

    void start(Slot& slot);
    SessionWorker& live(Slot& slot);
    Slot* owner(const std::string& token);
    Slot* route(const Json& request, std::string_view op, const Json& id);
    Json capabilities(const Json& id);
    Json windows(const Json& id);

    std::string session_;
    AllowedProcess allowedProcess_;
    std::set<Action> actions_;
    const std::chrono::milliseconds budget_;
    std::function<void()> abandon_;
    CommandHistory history_;
    std::vector<Slot> slots_;
};
} // namespace desktop
