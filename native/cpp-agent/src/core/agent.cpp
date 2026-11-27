#include "core/agent.hpp"

#include <algorithm>
#include <array>

namespace desktop {
namespace {
constexpr std::array<const char*, 9> operations{
    "getCapabilities", "listWindows", "snapshot", "findElement", "getElementInfo", "invoke", "setValue",
    "defaultAction", "select"};
constexpr std::array<const char*, 4> locatorFields{"name", "role", "automationId", "className"};

Error invalid() { return {"INVALID_REQUEST", "Invalid request fields."}; }
Error stale() { return {"STALE_REFERENCE", "Capture a new snapshot and resolve the element again."}; }
Error duplicate() { return {"DUPLICATE_COMMAND", "This command ID has already been dispatched."}; }
Error denied() { return {"PERMISSION_DENIED", "The process and action must both be allowed."}; }
Error precondition(const char* message) { return {"PRECONDITION_FAILED", message}; }

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
    auto current = state.load();
    while (current == State::pending || current == State::dispatched) {
        const auto cancelled = current == State::dispatched ? State::cancelledAfterDispatch
                                                           : State::cancelledBeforeDispatch;
        if (state.compare_exchange_weak(current, cancelled)) return cancelled == State::cancelledAfterDispatch;
    }
    // The waiter and worker can cross the deadline at nearly the same instant.
    return current == State::cancelledAfterDispatch;
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
    Json detail{{"code", error.code}, {"message", error.what()}};
    if (error.inputSent) detail["inputSent"] = *error.inputSent;
    if (error.released) detail["released"] = true;
    return {{"id", std::move(id)}, {"ok", false}, {"error", std::move(detail)}};
}

Json failure(Json id, Error error, std::string_view op) {
    if (isInputOperation(op) && !error.inputSent) error.inputSent = false;
    return failure(std::move(id), error);
}

Json capabilities(const char* backend, bool available) {
    Availability availability;
    availability.available = available;
    return capabilities(backend, availability);
}

Json capabilities(const char* backend, const Availability& availability) {
    Json result{{"backend", backend}, {"available", availability.available}, {"physicalInput", false},
                {"screenshot", false}, {"operations", Json::array()}};
    if (availability.available) {
        const bool msaa = std::string_view(backend) == "MSAA";
        for (const char* op : operations) {
            const auto action = parseAction(op);
            if ((msaa && action == Action::invoke) || (!msaa && (action == Action::defaultAction || action == Action::select)))
                continue;
            result["operations"].push_back(op);
        }
    } else result["reason"] = availability.reason;
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
    if (const auto input = parseInputOp(text)) return inputOpName(*input);
    return "invalid";
}

std::optional<Action> parseAction(std::string_view op) {
    if (op == "invoke") return Action::invoke;
    if (op == "setValue") return Action::setValue;
    if (op == "defaultAction") return Action::defaultAction;
    if (op == "select") return Action::select;
    return {};
}

bool isMutation(std::string_view op) { return parseAction(op).has_value(); }

Agent::Agent(DesktopAdapter& adapter, std::string session, AllowedProcess allowedProcess,
             std::set<Action> allowedActions, std::function<Clock::time_point()> now,
             CommandHistory* sharedHistory, InputSupport input)
    : adapter_(adapter), session_(std::move(session)), allowedProcess_(std::move(allowedProcess)),
      allowedActions_(std::move(allowedActions)), now_(std::move(now)),
      history_(sharedHistory ? *sharedHistory : localHistory_), input_(input) {}

Json Agent::handle(const Json& request, RequestDeadline& deadline) {
    auto id = requestId(request);
    const std::string_view named = operation(request);
    try {
        if (id.is_null()) throw invalid();
        const auto& op = field(request, "op", 32);
        Json result;
        expire();
        if (op == "getCapabilities") {
            result = capabilities(adapter_.backend(), adapter_.availability());
            if (input_.advertise) attachInput(result, input_.driver, allowedActions_);
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
        } else if (const auto action = parseAction(op)) {
            result = perform(request, id.get_ref<const std::string&>(), *action, deadline);
        } else if (const auto input = parseInputOp(op)) {
            result = physical(request, id.get_ref<const std::string&>(), *input, deadline);
        } else {
            throw Error("UNKNOWN_OPERATION", "Unknown operation.");
        }
        return {{"id", std::move(id)}, {"ok", true}, {"result", std::move(result)}};
    } catch (const Error& error) {
        if (error.retire) deadline.retire();
        return failure(std::move(id), error, named);
    } catch (const std::exception&) {
        return failure(std::move(id), {"INTERNAL_ERROR", "The operation could not be completed."}, named);
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
        next.scoped = scope.has_value();
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
    const bool offered = (action == Action::invoke && target.invoke) || (action == Action::setValue && target.writable)
        || (action == Action::defaultAction && target.defaultAction) || (action == Action::select && target.select);
    if (!offered)
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

Json Agent::physical(const Json& request, const std::string& id, InputOp op, RequestDeadline& deadline) {
    if (history_.contains(id)) throw duplicate();
    auto command = parseInputCommand(request, op);
    command.expires = deadline.expires;
    const bool element = op == InputOp::clickElement;
    std::size_t index = 0;
    bool weak = false;
    if (element) {
        index = resolve(command.ref);
        const auto& target = current().capture.elements[index];
        command.processId = target.pid;
        try {
            command.window = parseWindowId(current().window);
        } catch (const Error&) {
            command.window = 0;
        }
    } else if (isKeyboard(op) && op != InputOp::keyUp) {
        // Keys held through keyDown combine with this request. Alt held and Tab typed is still Alt+Tab.
        std::set<std::uint16_t> modifiers;
        if (input_.driver) {
            for (const auto code : input_.driver->held()) {
                if (isModifier(code)) modifiers.insert(code);
            }
        }
        for (const auto& key : command.keys.modifiers) modifiers.insert(key.vk);
        const bool tab = command.text.find(u'\t') != std::u16string::npos;
        if ((op == InputOp::typeText && tab && shellShortcut(modifiers, vk::tab))
            || (op != InputOp::typeText && shellShortcut(modifiers, command.keys.key.vk))) throw invalid();
    }
    if (!allowedActions_.count(inputAction(op)) || !allowedProcess_(command.processId)) throw denied();
    if (element) {
        const auto& target = current().capture.elements[index];
        if (!target.enabled) throw precondition("The element is disabled.");
        weak = target.referenceStrength == "weak";
        if (weak && !command.acceptWeakReference)
            throw precondition("A weak reference may name another element. Set acceptWeakReference to accept it.");
    }
    history_.remember(id);
    auto* driver = input_.driver;
    if (!driver) throw Error("INPUT_UNAVAILABLE", "Physical input is not supported on this platform.");
    Json result{{"performed", true}, {"inputSent", op != InputOp::activateWindow}, {"effectVerified", false}};
    if (element) {
        const auto& snapshot = current();
        const auto& captured = snapshot.capture.elements[index];
        const auto live = adapter_.info(index);
        if (live.pid != captured.pid) throw stale();
        if (!live.enabled || live.offscreen || !live.bounds || live.bounds->width <= 0 || live.bounds->height <= 0)
            throw precondition("The element is disabled, offscreen or has no area.");
        if (weak) {
            const auto& a = live.identity;
            const auto& b = captured.identity;
            const auto& lb = *live.bounds;
            const bool sameBounds = captured.bounds && lb.x == captured.bounds->x && lb.y == captured.bounds->y
                && lb.width == captured.bounds->width && lb.height == captured.bounds->height;
            if (a.name != b.name || a.role != b.role || a.automationId != b.automationId
                || a.className != b.className || !sameBounds) throw stale();
        }
        std::optional<Bounds> root;
        if (!snapshot.scoped) {
            const auto window = adapter_.info(0);
            if (window.pid != snapshot.capture.elements[0].pid) throw stale();
            root = window.bounds;
        }
        auto rect = driver->windowRect(command.window, command.processId);
        const std::string_view backend = adapter_.backend();
        if (backend == "MSAA" && root && !physicalBoundsMatch(rect, *root)) {
            const auto client = driver->clientRect(command.window, command.processId);
            if (client && physicalBoundsMatch(*client, *root)) rect = *client;
        }
        const auto mapped = elementPoint(rect, root, *live.bounds, snapshot.scoped, backend,
                                         command.fx, command.fy);
        command.op = InputOp::pointerClick;
        command.point = {mapped.point.x, mapped.point.y, Space::screen};
        result["backend"] = adapter_.backend();
        result["boundsMapping"] = mappingName(mapped.mapping);
        if (weak) result["referenceStrength"] = "weak";
    }
    const auto pid = command.processId;
    const auto outcome = driver->perform(command, [&, pid] {
        if (element && now_() >= current().expires) throw stale();
        if (!allowedProcess_(pid)) throw denied();
        try {
            deadline.beginMutation();
        } catch (Error& error) {
            // Input never touches the provider, so a late input request leaves the backend usable. A worker
            // that really overran is retired by the worker's own deadline check.
            error.retire = false;
            throw;
        }
    });
    // Input reached the system. Only the application can show that it had an effect.
    if (op == InputOp::activateWindow) {
        result["foreground"] = true;
        return result;
    }
    result["inputObserved"] = outcome.observed;
    result["events"] = outcome.events;
    if (op == InputOp::typeText) result["method"] = textMethodName(command.textMethod);
    const auto point = [](const ScreenPoint& p) { return Json{{"x", p.x}, {"y", p.y}}; };
    if (outcome.point) result["point"] = point(*outcome.point);
    if (outcome.from) result["from"] = point(*outcome.from);
    if (outcome.to) result["to"] = point(*outcome.to);
    return result;
}

Json Agent::publicElement(std::size_t index, const Element& row) const {
    Json actions = Json::array();
    if (row.invoke) actions.push_back("invoke");
    if (row.writable) actions.push_back("setValue");
    if (row.defaultAction) actions.push_back("defaultAction");
    if (row.select) actions.push_back("select");
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
    if (!row.referenceStrength.empty()) result["referenceStrength"] = row.referenceStrength;
    if (row.selected) result["selected"] = *row.selected;
    if (identity.role == "Edit" && std::string_view(adapter_.backend()) == "JAB")
        result["setValueSupport"] = row.writable ? "unverified" : "unsupported";
    if (row.partial) {
        result["partial"] = true;
        if (!row.partialReason.empty()) result["partialReason"] = row.partialReason;
    }
    return result;
}
} // namespace desktop
