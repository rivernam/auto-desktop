#include "core/session_worker.hpp"

#include <cstdio>
#include <cstdlib>

namespace desktop {
SessionWorker::SessionWorker(AdapterFactory factory, std::string session, AllowedProcess process,
                             std::set<Action> actions, std::chrono::milliseconds budget)
    : budget_(budget),
      thread_([this, factory = std::move(factory), session = std::move(session),
               process = std::move(process), actions = std::move(actions)]() mutable {
          run(factory, session, std::move(process), std::move(actions));
          exited_.set_value();
      }) {}

SessionWorker::~SessionWorker() {
    stop();
    if (exited_.get_future().wait_for(requestBudget) != std::future_status::ready) {
        // A provider can prevent even Release from returning. End the process
        // so its resources are reclaimed, without unwinding a live COM apartment.
        std::fputs("UI Automation apartment did not shut down.\n", stderr);
        std::quick_exit(1);
    }
    thread_.join();
}

void SessionWorker::stop() {
    {
        const std::lock_guard<std::mutex> lock(mutex_);
        stopped_ = true;
        pending_.reset();
    }
    ready_.notify_one();
}

Json SessionWorker::handle(Json request) {
    auto id = requestId(request);
    if (id.is_null()) return failure(nullptr, {"INVALID_REQUEST", "Expected one valid UTF-8 JSON request."});
    const auto* op = operation(request);
    if (std::string_view(op) == "invalid") {
        const auto raw = request.find("op");
        if (raw == request.end() || !raw->is_string()
            || isBlank(raw->get_ref<const std::string&>())
            || utf16Length(raw->get_ref<const std::string&>()) > 32)
            return failure(std::move(id), {"INVALID_REQUEST", "Invalid operation field."});
        return failure(std::move(id), {"UNKNOWN_OPERATION", "Unknown operation."});
    }
    auto work = std::make_shared<Work>(std::move(request), Clock::now() + budget_);
    auto reply = work->reply.get_future();
    {
        const std::lock_guard<std::mutex> lock(mutex_);
        if (stopped_) {
            if (std::string_view(op) == "getCapabilities")
                return {{"id", std::move(id)}, {"ok", true}, {"result", capabilities("UIA", false)}};
            if (isMutation(op) && history_.contains(id.get_ref<const std::string&>()))
                return failure(std::move(id), {"DUPLICATE_COMMAND", "This command ID has already been dispatched."});
            return failure(std::move(id), {"BACKEND_UNAVAILABLE", "Restart the retired UI Automation session."});
        }
        pending_ = work;
    }
    ready_.notify_one();
    if (reply.wait_until(work->deadline.expires) == std::future_status::ready) return reply.get();
    const bool dispatched = work->deadline.cancel();
    stop();
    if (dispatched)
        return failure(std::move(id), {"ACTION_OUTCOME_UNKNOWN", "The provider did not confirm the action."});
    return failure(std::move(id), {"TIMEOUT", "UI Automation exceeded the request deadline."});
}

void SessionWorker::run(const AdapterFactory& factory, const std::string& session, AllowedProcess process,
                        std::set<Action> actions) {
    std::unique_ptr<DesktopAdapter> adapter;
    std::optional<Agent> agent;
    for (;;) {
        std::shared_ptr<Work> work;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            const auto ready = [&] { return stopped_ || pending_; };
            if (agent && agent->nextExpiry() != Clock::time_point::max()) {
                ready_.wait_until(lock, agent->nextExpiry(), ready);
            } else {
                ready_.wait(lock, ready);
            }
            if (stopped_) return;
            work = std::move(pending_);
        }
        if (!work) {
            agent->expire();
            continue;
        }
        Json reply;
        try {
            if (!agent) {
                adapter = factory();
                agent.emplace(*adapter, session, std::move(process), std::move(actions), Clock::now, &history_);
            }
            reply = agent->handle(work->request, work->deadline);
        } catch (const std::exception&) {
            work->deadline.retire();
            reply = failure(requestId(work->request), {"INTERNAL_ERROR", "Could not start the native session."});
        }
        if (work->deadline.retiring()) stop();
        work->reply.set_value(std::move(reply));
    }
}
} // namespace desktop
