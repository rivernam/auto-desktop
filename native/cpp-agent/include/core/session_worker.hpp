#pragma once

#include "core/agent.hpp"

#include <condition_variable>
#include <future>
#include <memory>
#include <thread>

namespace desktop {
// A serialized executor. The adapter is constructed, used and destroyed here.
// Only protocol values and a cancellation gate cross the thread boundary.
class SessionWorker {
public:
    using AdapterFactory = std::function<std::unique_ptr<DesktopAdapter>()>;

    SessionWorker(AdapterFactory factory, std::string session, AllowedProcess allowedProcess,
                  std::set<Action> actions, std::chrono::milliseconds budget = requestBudget,
                  std::string backend = "UIA", CommandHistory* sharedHistory = nullptr);
    ~SessionWorker();
    Json handle(Json request);
    // Replaces the default end of a process whose provider thread never returned.
    void onAbandon(std::function<void()> handler) { abandon_ = std::move(handler); }
    // True once a fault or a timeout retired the session. Later requests are refused.
    bool stopped();
    // True once the session thread has released its provider and ended.
    bool finished() const { return finished_; }

private:
    struct Work {
        Work(Json request, Clock::time_point expires) : request(std::move(request)), deadline(expires) {}
        Json request;
        RequestDeadline deadline;
        std::promise<Json> reply;
    };

    void run(const AdapterFactory& factory, const std::string& session, AllowedProcess process,
             std::set<Action> actions);
    void stop();

    std::mutex mutex_;
    std::condition_variable ready_;
    std::shared_ptr<Work> pending_;
    bool stopped_ = false;
    CommandHistory ownHistory_;
    // Shared with the other backends of a multi-backend session.
    CommandHistory& history_;
    std::atomic<bool> finished_{false};
    std::promise<void> exited_;
    const std::chrono::milliseconds budget_;
    const std::string backend_;
    std::function<void()> abandon_;
    std::thread thread_;
};
} // namespace desktop
