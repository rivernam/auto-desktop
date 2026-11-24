#include "core/multi_session.hpp"

#include <unordered_map>

namespace desktop {
namespace {
Error invalid() { return {"INVALID_REQUEST", "Invalid request fields."}; }
Error stale() { return {"STALE_REFERENCE", "Capture a new snapshot and resolve the element again."}; }

const std::string& text(const Json& request, const char* key, std::size_t limit) {
    const auto value = request.find(key);
    if (value == request.end() || !value->is_string()) throw invalid();
    const auto& result = value->get_ref<const std::string&>();
    if (utf16Length(result) > limit || isBlank(result)) throw invalid();
    return result;
}
} // namespace

MultiSession::MultiSession(std::vector<Backend> backends, std::string session, AllowedProcess allowedProcess,
                           std::set<Action> actions, std::chrono::milliseconds budget)
    : session_(std::move(session)), allowedProcess_(std::move(allowedProcess)), actions_(std::move(actions)),
      budget_(budget) {
    if (backends.empty()) throw std::invalid_argument("A session needs one or more backends.");
    slots_.reserve(backends.size());
    for (auto& backend : backends) {
        slots_.push_back({std::move(backend), nullptr, 0, {}});
        start(slots_.back());
    }
}

MultiSession::~MultiSession() {
    // A healthy backend releases its native references first. One that waits on a provider call
    // may end the process when its turn comes.
    for (auto& slot : slots_) {
        if (!slot.worker->stopped()) slot.worker.reset();
    }
    slots_.clear();
}

void MultiSession::onAbandon(std::function<void()> handler) {
    abandon_ = std::move(handler);
    for (auto& slot : slots_) slot.worker->onAbandon(abandon_);
}

void MultiSession::start(Slot& slot) {
    // The generation keeps a replaced worker from honouring a reference of its predecessor.
    const auto token = session_ + "." + slot.config.name + "." + std::to_string(++slot.generation);
    slot.prefix = token + "-";
    slot.worker = std::make_unique<SessionWorker>(slot.config.factory, token, allowedProcess_, actions_, budget_,
                                                  slot.config.name, &history_);
    if (abandon_) slot.worker->onAbandon(abandon_);
}

SessionWorker& MultiSession::live(Slot& slot) {
    if (slot.config.restartable && slot.worker->finished()) {
        slot.worker.reset();
        start(slot);
    }
    return *slot.worker;
}

// One request to one backend. The other backends serve the messages of their own windows meanwhile:
// a provider that walks the desktop also reaches the hidden windows of this process.
Json MultiSession::call(Slot& target, Json request) {
    auto& worker = live(target);
    for (auto& slot : slots_) {
        if (&slot != &target) slot.worker->attend(true);
    }
    auto reply = worker.handle(std::move(request));
    for (auto& slot : slots_) {
        if (&slot != &target) slot.worker->attend(false);
    }
    return reply;
}

MultiSession::Slot* MultiSession::owner(const std::string& token) {
    for (auto& slot : slots_) {
        if (token.compare(0, slot.prefix.size(), slot.prefix) == 0) return &slot;
    }
    return nullptr;
}

MultiSession::Slot* MultiSession::route(const Json& request, std::string_view op, const Json& id) {
    if (op == "snapshot") {
        Slot* named = nullptr;
        if (request.contains("backend")) {
            const auto& name = text(request, "backend", 32);
            for (auto& slot : slots_) {
                if (slot.config.name == name) named = &slot;
            }
            if (!named) throw Error("BACKEND_UNAVAILABLE", "This session does not include the requested backend.");
        }
        if (!request.contains("scopeRef")) return named ? named : &slots_.front();
        // A scope is a reference. It selects its own backend and is stale for any other.
        auto* scoped = owner(text(request, "scopeRef", 128));
        if (!scoped || (named && named != scoped)) throw stale();
        return scoped;
    }
    if (isMutation(op) && history_.contains(id.get_ref<const std::string&>()))
        throw Error("DUPLICATE_COMMAND", "This command ID has already been dispatched.");
    auto* issuer = owner(text(request, op == "findElement" ? "snapshotId" : "ref", 128));
    if (!issuer) throw stale();
    return issuer;
}

Json MultiSession::handle(Json request) {
    auto id = requestId(request);
    const std::string_view op = operation(request);
    // The worker answers a malformed frame before it touches its provider.
    if (id.is_null() || op == "invalid") return slots_.front().worker->handle(std::move(request));
    if (op == "getCapabilities") return capabilities(id);
    if (op == "listWindows") return windows(id);
    Slot* slot = nullptr;
    try {
        slot = route(request, op, id);
    } catch (const Error& error) {
        return failure(std::move(id), error);
    }
    auto reply = call(*slot, std::move(request));
    if (op == "snapshot" && reply.at("ok") == true) reply["result"]["backend"] = slot->config.name;
    return reply;
}

Json MultiSession::capabilities(const Json& id) {
    auto rows = Json::array();
    bool available = false;
    for (auto& slot : slots_) {
        auto& worker = live(slot);
        Availability failed;
        failed.available = false;
        Json row;
        if (worker.stopped()) {
            failed.reason = "The backend session was retired after a fault.";
            row = desktop::capabilities(slot.config.name.c_str(), failed);
        } else {
            const auto reply = call(slot, {{"id", id}, {"op", "getCapabilities"}});
            if (reply.at("ok") == true) {
                row = reply.at("result");
            } else {
                failed.reason = reply.at("error").at("message").get<std::string>();
                row = desktop::capabilities(slot.config.name.c_str(), failed);
            }
        }
        available = available || row.at("available") == true;
        rows.push_back(std::move(row));
    }
    Availability summary;
    summary.available = available;
    summary.reason = "No backend of this session is available.";
    auto result = desktop::capabilities("multi", summary);
    result["defaultBackend"] = slots_.front().config.name;
    result["backends"] = std::move(rows);
    return {{"id", id}, {"ok", true}, {"result", std::move(result)}};
}

Json MultiSession::windows(const Json& id) {
    auto status = Json::array();
    auto rows = Json::array();
    std::unordered_map<std::string, std::size_t> known;
    std::string firstCode, firstMessage;
    bool sameCode = true;
    std::size_t failures = 0;
    for (auto& slot : slots_) {
        const auto reply = call(slot, {{"id", id}, {"op", "listWindows"}});
        if (reply.at("ok") == true) {
            for (const auto& window : reply.at("result")) {
                // The same handle with another owner process is another window. Keep both rows.
                const auto key = window.at("windowId").get<std::string>() + "\n"
                    + std::to_string(window.at("processId").get<int>());
                auto found = known.find(key);
                if (found == known.end()) {
                    found = known.emplace(key, rows.size()).first;
                    rows.push_back(window);
                    rows.back()["backends"] = Json::array();
                }
                rows[found->second]["backends"].push_back(slot.config.name);
            }
            status.push_back({{"backend", slot.config.name}, {"ok", true}});
            continue;
        }
        const auto& error = reply.at("error");
        const auto code = error.at("code").get<std::string>();
        if (failures++ == 0) {
            firstCode = code;
            firstMessage = error.at("message").get<std::string>();
        } else if (code != firstCode) {
            sameCode = false;
        }
        status.push_back({{"backend", slot.config.name}, {"ok", false}, {"error", error}});
    }
    if (failures == slots_.size()) {
        Json error{{"code", sameCode ? firstCode : "BACKEND_UNAVAILABLE"},
                   {"message", sameCode ? firstMessage : "No backend could list windows."}};
        return {{"id", id}, {"ok", false}, {"error", std::move(error)}, {"backends", std::move(status)}};
    }
    return {{"id", id}, {"ok", true}, {"result", std::move(rows)}, {"backends", std::move(status)}};
}
} // namespace desktop
