#include "core/session_worker.hpp"

#include <algorithm>
#include <cstdio>
#include <cstdlib>

namespace desktop {
SessionWorker::SessionWorker(AdapterFactory factory, std::string session, AllowedProcess process,
                             std::set<Action> actions, std::chrono::milliseconds budget, std::string backend,
                             CommandHistory* sharedHistory)
    : history_(sharedHistory ? *sharedHistory : ownHistory_), budget_(budget), backend_(std::move(backend)),
      thread_([this, factory = std::move(factory), session = std::move(session),
               process = std::move(process), actions = std::move(actions)]() mutable {
          run(factory, session, std::move(process), std::move(actions));
          finished_ = true;
          exited_.set_value();
      }) {}

SessionWorker::~SessionWorker() {
    requestStop(Clock::now() + requestBudget);
    if (exited_.get_future().wait_until(closeDeadline_) != std::future_status::ready) {
        // A provider can prevent even Release from returning. End the process
        // so its resources are reclaimed, without unwinding a live COM apartment.
        std::fprintf(stderr, "BACKEND_CLEANUP_FAILED: The %s worker did not clean up.\n", backend_.c_str());
        if (abandon_) abandon_();
        std::quick_exit(1);
    }
    thread_.join();
}

void SessionWorker::requestStop(Clock::time_point deadline) {
    closeDeadline_ = std::min(closeDeadline_, deadline);
    stop();
}

void SessionWorker::attend(bool on) {
    {
        const std::lock_guard<std::mutex> lock(mutex_);
        attending_ = on;
        if (!on && served_) served_->wake();
    }
    ready_.notify_one();
}

void SessionWorker::stop() {
    {
        const std::lock_guard<std::mutex> lock(mutex_);
        stopped_ = true;
        pending_.reset();
        if (served_) served_->wake();
    }
    ready_.notify_one();
}

Json SessionWorker::handle(Json request) {
    const std::lock_guard<std::mutex> serial(serial_);
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
    if (std::string_view(op) == "snapshot" && request.contains("backend")) {
        // A session has the backends it was started with. A request for another one is never
        // answered through this one.
        const auto& named = request["backend"];
        if (!named.is_string() || isBlank(named.get_ref<const std::string&>())
            || utf16Length(named.get_ref<const std::string&>()) > 32)
            return failure(std::move(id), {"INVALID_REQUEST", "Invalid request fields."});
        if (named.get_ref<const std::string&>() != backend_)
            return failure(std::move(id), {"BACKEND_UNAVAILABLE", "This session does not include the requested backend."});
    }
    return enqueue(std::move(request), Clock::now() + budget_)();
}

std::function<Json()> SessionWorker::startQuery(Json request, Clock::time_point deadline) {
    const std::string_view op = operation(request);
    if (op != "getCapabilities" && op != "listWindows") throw std::invalid_argument("Expected a backend query.");
    return enqueue(std::move(request), deadline);
}

std::function<Json()> SessionWorker::enqueue(Json request, Clock::time_point deadline) {
    auto work = std::make_shared<Work>(std::move(request), deadline);
    {
        const std::lock_guard<std::mutex> lock(mutex_);
        if (stopped_) {
            return [this, work] {
                auto id = requestId(work->request);
                const std::string_view op = operation(work->request);
                if (op == "getCapabilities") {
                    Availability state;
                    state.available = false;
                    state.reason = initializationFailed_ ? "Could not start the native session."
                                                        : "The backend session was retired after a fault.";
                    return Json{{"id", std::move(id)}, {"ok", true}, {"result", capabilities(backend_.c_str(), state)}};
                }
                if (isMutation(op) && history_.contains(id.get_ref<const std::string&>()))
                    return failure(std::move(id), {"DUPLICATE_COMMAND", "This command ID has already been dispatched."});
                return failure(std::move(id), {"BACKEND_UNAVAILABLE", "Restart the retired provider session."});
            };
        }
        pending_ = work;
        if (served_) served_->wake();
    }
    ready_.notify_one();
    return [this, work] { return await(work); };
}

Json SessionWorker::await(const std::shared_ptr<Work>& work) {
    if (work->result.wait_until(work->deadline.expires) == std::future_status::ready) return work->result.get();
    auto id = requestId(work->request);
    const bool dispatched = work->deadline.cancel();
    stop();
    if (dispatched)
        return failure(std::move(id), {"ACTION_OUTCOME_UNKNOWN", "The provider did not confirm the action."});
    return failure(std::move(id), {"TIMEOUT", backend_ == "UIA"
        ? "UI Automation exceeded the request deadline." : "The provider exceeded the request deadline."});
}

void SessionWorker::run(const AdapterFactory& factory, const std::string& session, AllowedProcess process,
                        std::set<Action> actions) {
    std::unique_ptr<DesktopAdapter> adapter;
    std::optional<Agent> agent;
    for (;;) {
        std::shared_ptr<Work> work;
        bool serve = false;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            const auto tick = adapter ? adapter->idleInterval() : std::chrono::milliseconds::zero();
            const bool serves = adapter && tick.count() > 0;
            const auto ready = [&] { return stopped_ || pending_ || (serves && attending_); };
            auto wake = agent ? agent->nextExpiry() : Clock::time_point::max();
            if (tick.count() > 0) wake = std::min(wake, Clock::now() + tick);
            if (wake != Clock::time_point::max()) {
                ready_.wait_until(lock, wake, ready);
            } else {
                ready_.wait(lock, ready);
            }
            if (stopped_) return;
            work = std::move(pending_);
            serve = !work && serves && attending_;
            if (serve) served_ = adapter.get();
        }
        if (serve) {
            // Another backend is inside a request. Answer the messages of this provider's windows at once.
            adapter->serve([&] {
                const std::lock_guard<std::mutex> lock(mutex_);
                return stopped_ || pending_ || !attending_;
            });
            const std::lock_guard<std::mutex> lock(mutex_);
            served_ = nullptr;
            continue;
        }
        if (!work) {
            agent->expire();
            adapter->idle();
            continue;
        }
        Json reply;
        if (Clock::now() >= work->deadline.expires) {
            stop();
            work->reply.set_value(failure(requestId(work->request), {"TIMEOUT", "The provider request expired before dispatch."}));
            continue;
        }
        if (!agent) {
            try {
                adapter = factory();
                if (!adapter) throw std::runtime_error("Provider factory returned no adapter.");
                agent.emplace(*adapter, session, std::move(process), std::move(actions), Clock::now, &history_);
            } catch (const std::exception&) {
                initializationFailed_ = true;
                stop();
                const auto error = Clock::now() >= work->deadline.expires
                    ? Error{"TIMEOUT", "The provider request expired during initialization."}
                    : Error{"BACKEND_UNAVAILABLE", "Could not start the native session."};
                work->reply.set_value(failure(requestId(work->request), error));
                continue;
            }
        }
        try {
            if (Clock::now() >= work->deadline.expires)
                throw Error("TIMEOUT", "The provider request expired during initialization.");
            reply = agent->handle(work->request, work->deadline);
            if (Clock::now() >= work->deadline.expires) {
                const bool dispatched = work->deadline.cancel();
                work->deadline.retire();
                reply = failure(requestId(work->request), dispatched
                    ? Error{"ACTION_OUTCOME_UNKNOWN", "The provider did not confirm the action before the deadline."}
                    : Error{"TIMEOUT", "The provider exceeded the request deadline."});
            }
        } catch (const Error& error) {
            work->deadline.retire();
            reply = failure(requestId(work->request), error);
        } catch (const std::exception&) {
            work->deadline.retire();
            reply = failure(requestId(work->request), {"INTERNAL_ERROR", "The provider could not complete the request."});
        }
        if (work->deadline.retiring()) stop();
        work->reply.set_value(std::move(reply));
    }
}
} // namespace desktop
