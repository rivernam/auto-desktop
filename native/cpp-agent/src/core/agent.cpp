#include "core/agent.hpp"

#include <algorithm>
#include <array>

namespace desktop {
namespace {
constexpr std::array<const char*, 7> operations{
    "getCapabilities", "listWindows", "snapshot", "findElement", "getElementInfo", "invoke", "setValue"};
constexpr std::array<const char*, 4> locatorFields{"name", "role", "automationId", "className"};

Error invalid() { return {"INVALID_REQUEST", "Invalid request fields."}; }
Error stale() { return {"STALE_REFERENCE", "Capture a new snapshot and resolve the element again."}; }
Error duplicate() { return {"DUPLICATE_COMMAND", "This command ID has already been dispatched."}; }
Error denied() { return {"PERMISSION_DENIED", "The process and action must both be allowed."}; }

bool validText(const Json& value, std::size_t limit) {
    if (!value.is_string()) return false;
    const auto& text = value.get_ref<const std::string&>();
    return utf16Length(text) <= limit && !isBlank(text);
}

const std::string& field(const Json& request, const char* key, std::size_t limit) {
    const auto value = request.find(key);
    if (value == request.end() || !validText(*value, limit)) throw invalid();
    return value->get_ref<const std::string&>();
}

int integer(const Json& request, const char* key, int fallback, int min, int max) {
    const auto value = request.find(key);
    if (value == request.end()) return fallback;
    if (!value->is_number_integer() || (value->is_number_unsigned() && value->get<std::uint64_t>() >
                                      static_cast<std::uint64_t>(max))) throw invalid();
    const auto number = value->get<std::int64_t>();
    if (number < min || number > max) throw invalid();
    return static_cast<int>(number);
}

const std::string& property(const Identity& identity, const std::string& key) {
    if (key == "name") return identity.name;
    if (key == "role") return identity.role;
    if (key == "automationId") return identity.automationId;
    return identity.className;
}
} // namespace

void RequestDeadline::beginMutation() {
    auto expected = State::pending;
    if (Clock::now() >= expires || !state.compare_exchange_strong(expected, State::dispatched))
        throw Error("TIMEOUT", "The request expired before native action dispatch.", true);
}

bool RequestDeadline::cancel() {
    return state.exchange(State::cancelled) == State::dispatched;
}

bool CommandHistory::contains(const std::string& id) const {
    const std::lock_guard<std::mutex> lock(mutex_);
    return ids_.count(id) != 0;
}

void CommandHistory::remember(const std::string& id) {
    const std::lock_guard<std::mutex> lock(mutex_);
    if (ids_.count(id)) throw duplicate();
    if (ids_.size() >= 4096) throw Error("SESSION_LIMIT", "Start a new agent session to dispatch more commands.");
    ids_.insert(id);
}

Json failure(Json id, const Error& error) {
    return {{"id", std::move(id)}, {"ok", false}, {"error", {{"code", error.code}, {"message", error.what()}}}};
}

Json capabilities(const char* backend, bool available) {
    Availability availability;
    availability.available = available;
    return capabilities(backend, availability);
}

Json capabilities(const char* backend, const Availability& availability) {
    Json result{{"backend", backend}, {"available", availability.available}, {"physicalInput", false},
                {"screenshot", false}, {"operations", Json::array()}};
    if (availability.available) result["operations"] = operations;
    else result["reason"] = availability.reason;
    if (availability.javaWindows)
        result["bridge"] = {{"javaWindows", availability.javaWindows->first},
                            {"connectedWindows", availability.javaWindows->second}};
    return result;
}

Json requestId(const Json& request) {
    const auto id = request.find("id");
    return id != request.end() && validText(*id, 128) ? *id : Json(nullptr);
}

const char* operation(const Json& request) {
    const auto op = request.find("op");
    if (op == request.end() || !op->is_string()) return "invalid";
    const auto& text = op->get_ref<const std::string&>();
    for (const char* known : operations) {
        if (text == known) return known;
    }
    return "invalid";
}

bool isMutation(std::string_view op) { return op == "invoke" || op == "setValue"; }

Agent::Agent(DesktopAdapter& adapter, std::string session, AllowedProcess allowedProcess,
             std::set<Action> allowedActions, std::function<Clock::time_point()> now,
             CommandHistory* sharedHistory)
    : adapter_(adapter), session_(std::move(session)), allowedProcess_(std::move(allowedProcess)),
      allowedActions_(std::move(allowedActions)), now_(std::move(now)),
      history_(sharedHistory ? *sharedHistory : localHistory_) {}

Json Agent::handle(const Json& request, RequestDeadline& deadline) {
    auto id = requestId(request);
    try {
        if (id.is_null()) throw invalid();
        const auto& op = field(request, "op", 32);
        Json result;
        expire();
        if (op == "getCapabilities") {
            result = capabilities(adapter_.backend(), adapter_.availability());
        } else if (op == "listWindows") {
            result = Json::array();
            for (const auto& window : adapter_.windows()) {
                Json row{{"windowId", window.id}, {"processId", window.pid}, {"name", window.name}};
                if (!window.owner.empty()) row["ownerWindowId"] = window.owner;
                result.push_back(std::move(row));
            }
        } else if (op == "snapshot") {
            result = capture(request);
        } else if (op == "findElement") {
            result = find(request);
        } else if (op == "getElementInfo") {
            result = info(request);
        } else if (isMutation(op)) {
            result = perform(request, id.get_ref<const std::string&>(),
                             op == "invoke" ? Action::invoke : Action::setValue, deadline);
        } else {
            throw Error("UNKNOWN_OPERATION", "Unknown operation.");
        }
        return {{"id", std::move(id)}, {"ok", true}, {"result", std::move(result)}};
    } catch (const Error& error) {
        if (error.retire) deadline.retire();
        return failure(std::move(id), error);
    } catch (const std::exception&) {
        return failure(std::move(id), {"INTERNAL_ERROR", "The operation could not be completed."});
    }
}

void Agent::expire() {
    if (snapshot_ && now_() >= snapshot_->expires) {
        snapshot_.reset();
        adapter_.clear();
    }
}

Clock::time_point Agent::nextExpiry() const {
    return snapshot_ ? snapshot_->expires : Clock::time_point::max();
}

const Agent::Snapshot& Agent::current() const {
    if (!snapshot_) throw stale();
    return *snapshot_;
}

std::size_t Agent::resolve(const std::string& ref) const {
    const auto& indices = current().indices;
    const auto index = indices.find(ref);
    if (index == indices.end()) throw stale();
    return index->second;
}

std::string Agent::token() { return session_ + "-" + std::to_string(++sequence_); }

Json Agent::capture(const Json& request) {
    const auto& window = field(request, "windowId", 256);
    const int depth = integer(request, "maxDepth", 12, 0, 32);
    const int limit = integer(request, "maxElements", 500, 1, 2000);
    std::optional<std::size_t> scope;
    if (request.contains("scopeRef")) {
        scope = resolve(field(request, "scopeRef", 128));
        if (current().window != window) throw stale();
    }
    snapshot_.reset();
    try {
        Snapshot next;
        next.capture = adapter_.capture(window, scope, depth, limit);
        next.expires = now_() + std::chrono::seconds(120);
        next.id = token();
        next.window = window;
        const auto count = next.capture.elements.size();
        if (count == 0 || count > static_cast<std::size_t>(limit))
            throw Error("WORKER_PROTOCOL", "Invalid snapshot size.");
        next.refs.reserve(count);
        next.indices.reserve(count);
        std::vector<int> depths(count);
        for (std::size_t i = 0; i < count; ++i) {
            const auto& row = next.capture.elements[i];
            if ((i == 0 && row.parent) || (i != 0 && (!row.parent || *row.parent >= i)) || row.pid <= 0
                || (row.partial && !next.capture.truncated))
                throw Error("WORKER_PROTOCOL", "Invalid snapshot tree.");
            depths[i] = row.parent ? depths[*row.parent] + 1 : 0;
            if (depths[i] > depth) throw Error("WORKER_PROTOCOL", "Invalid snapshot depth.");
            next.refs.push_back(token());
            next.indices.emplace(next.refs.back(), i);
        }
        snapshot_ = std::move(next);
        auto rows = Json::array();
        for (std::size_t i = 0; i < count; ++i) rows.push_back(publicElement(i, snapshot_->capture.elements[i]));
        return {{"snapshotId", snapshot_->id}, {"windowId", window}, {"elements", std::move(rows)},
                {"truncated", snapshot_->capture.truncated}};
    } catch (...) {
        snapshot_.reset();
        adapter_.clear();
        throw;
    }
}

Json Agent::find(const Json& request) const {
    const auto& id = field(request, "snapshotId", 128);
    const auto* scope = request.contains("scopeRef") ? &field(request, "scopeRef", 128) : nullptr;
    const auto& snapshot = current();
    if (snapshot.id != id) throw stale();
    const auto locator = request.find("locator");
    if (locator == request.end() || !locator->is_object() || locator->empty()) throw invalid();
    for (const auto& entry : locator->items()) {
        if (std::find(locatorFields.begin(), locatorFields.end(), entry.key()) == locatorFields.end()
            || !entry.value().is_string() || utf16Length(entry.value().get_ref<const std::string&>()) > 4096)
            throw invalid();
    }
    std::optional<std::size_t> match;
    const auto& rows = snapshot.capture.elements;
    const auto start = scope ? resolve(*scope) : 0;
    // A cut elsewhere in the tree hides no match inside a scope whose every row is whole. That needs
    // an adapter that names the cut rows.
    bool complete = !snapshot.capture.truncated
        || (scope && std::any_of(rows.begin(), rows.end(), [](const Element& row) { return row.partial; }));
    for (std::size_t i = start; i < rows.size(); ++i) {
        if (scope && i != start) {
            auto parent = rows[i].parent;
            while (parent && *parent > start) parent = rows[*parent].parent;
            if (parent != start) continue;
        }
        if (rows[i].partial) complete = false;
        bool matches = true;
        for (const auto& entry : locator->items()) {
            if (entry.value() != property(rows[i].identity, entry.key())) {
                matches = false;
                break;
            }
        }
        if (!matches) continue;
        if (match) throw Error("AMBIGUOUS_ELEMENT", "More than one element matches.");
        match = i;
    }
    if (!complete) throw Error("INCOMPLETE_SNAPSHOT", "A complete snapshot is required for lookup.");
    if (!match) throw Error("ELEMENT_NOT_FOUND", "No element matches the locator.");
    return publicElement(*match, rows[*match]);
}

Json Agent::info(const Json& request) {
    const auto index = resolve(field(request, "ref", 128));
    const auto& captured = current().capture.elements[index];
    auto live = adapter_.info(index);
    if (live.pid != captured.pid) throw stale();
    live.parent = captured.parent;
    // Completeness describes the capture. A live property read cannot change it.
    live.partial = captured.partial;
    live.partialReason = captured.partialReason;
    return publicElement(index, live);
}

Json Agent::perform(const Json& request, const std::string& id, Action action, RequestDeadline& deadline) {
    if (history_.contains(id)) throw duplicate();
    const auto index = resolve(field(request, "ref", 128));
    const auto& target = current().capture.elements[index];
    if (!allowedActions_.count(action) || !allowedProcess_(target.pid)) throw denied();
    if (!target.enabled) throw Error("PRECONDITION_FAILED", "The element is disabled.");
    if (!(action == Action::invoke ? target.invoke : target.writable))
        throw Error("PATTERN_UNSUPPORTED", "The element does not support this action.");
    const std::string empty;
    const std::string* text = &empty;
    if (action == Action::setValue) {
        const auto value = request.find("value");
        if (value == request.end() || !value->is_string()
            || utf16Length(value->get_ref<const std::string&>()) > 16384) throw invalid();
        text = &value->get_ref<const std::string&>();
    }
    history_.remember(id);
    adapter_.perform(action, index, *text, [&] {
        if (now_() >= current().expires) throw stale();
        if (!allowedProcess_(target.pid)) throw denied();
        deadline.beginMutation();
    });
    // The provider accepted the call. Only the application can show that it had an effect.
    return {{"performed", true}, {"effectVerified", false}};
}

Json Agent::publicElement(std::size_t index, const Element& row) const {
    Json actions = Json::array();
    if (row.invoke) actions.push_back("invoke");
    if (row.writable) actions.push_back("setValue");
    Json bounds = nullptr;
    if (row.bounds) {
        const auto& rect = *row.bounds;
        bounds = {{"x", rect.x}, {"y", rect.y}, {"width", rect.width}, {"height", rect.height}};
    }
    const auto& refs = current().refs;
    const auto& identity = row.identity;
    Json result{{"ref", refs[index]}, {"parentRef", row.parent ? Json(refs[*row.parent]) : Json(nullptr)},
                {"name", identity.name}, {"role", identity.role}, {"automationId", identity.automationId},
                {"className", identity.className}, {"processId", row.pid}, {"bounds", std::move(bounds)},
                {"enabled", row.enabled}, {"offscreen", row.offscreen}, {"actions", std::move(actions)},
                {"backend", adapter_.backend()}};
    if (!identity.nativeRole.empty()) result["nativeRole"] = identity.nativeRole;
    if (row.partial) {
        result["partial"] = true;
        if (!row.partialReason.empty()) result["partialReason"] = row.partialReason;
    }
    return result;
}
} // namespace desktop
