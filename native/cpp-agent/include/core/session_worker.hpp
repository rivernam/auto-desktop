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
                  std::set<Action> actions, std::chrono::milliseconds budget = requestBudget);
    ~SessionWorker();
    Json handle(Json request);

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
    CommandHistory history_;
    std::promise<void> exited_;
    const std::chrono::milliseconds budget_;
    std::thread thread_;
};
} // namespace desktop
