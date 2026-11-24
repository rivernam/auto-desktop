package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.Set;
import java.util.function.IntPredicate;
import java.util.function.LongSupplier;

/** One serialized client session, scoped to the most recent successful snapshot. */
public final class Agent {
    private final DesktopAdapter adapter;
    private final ActionDispatcher actions;
    private final LongSupplier nanoTime;
    private DesktopSnapshot snapshot;

    public Agent(DesktopAdapter adapter, Set<Integer> allowedPids, Set<String> allowedActions) {
        this(adapter, allowedPids, allowedActions, System::nanoTime);
    }

    public Agent(DesktopAdapter adapter, IntPredicate allowedProcess, Set<String> allowedActions) {
        this(adapter, allowedProcess, allowedActions, System::nanoTime);
    }

    Agent(DesktopAdapter adapter, Set<Integer> allowedPids, Set<String> allowedActions, LongSupplier nanoTime) {
        this(adapter, Set.copyOf(allowedPids)::contains, allowedActions, nanoTime);
    }

    private Agent(DesktopAdapter adapter, IntPredicate allowedProcess, Set<String> allowedActions, LongSupplier nanoTime) {
        this.adapter = adapter;
        this.actions = new ActionDispatcher(allowedProcess, allowedActions);
        this.nanoTime = nanoTime;
    }

    private static ObjectNode object() {
        return JsonNodeFactory.instance.objectNode();
    }

    public synchronized ObjectNode handle(ObjectNode request) {
        ObjectNode response = object().putNull("id");
        try {
            if (request == null) throw invalid("Expected a request object.");
            String id = string(request, "id", 128);
            response.put("id", id);
            String op = string(request, "op", 32);
            JsonNode result = switch (op) {
                case "getCapabilities" -> adapter.capabilities();
                case "listWindows" -> adapter.listWindows();
                case "snapshot" -> capture(request);
                case "findElement" -> find(request);
                case "getElementInfo" -> info(request);
                case "invoke" -> perform(request, id, DesktopAction.INVOKE);
                case "setValue" -> perform(request, id, DesktopAction.SET_VALUE);
                default -> throw new AgentException("UNKNOWN_OPERATION", "Unknown operation.");
            };
            response.put("ok", true).set("result", result);
        } catch (AgentException ex) {
            response.put("ok", false).putObject("error").put("code", ex.code()).put("message", ex.getMessage());
        } catch (RuntimeException ex) {
            response.put("ok", false).putObject("error").put("code", "INTERNAL_ERROR")
                    .put("message", "The operation could not be completed.");
        }
        return response;
    }

    private ObjectNode capture(ObjectNode request) {
        int limit = integer(request, "maxElements", 500, 1, 2000);
        String windowId = string(request, "windowId", 256);
        int depth = integer(request, "maxDepth", 12, 0, 32);
        String scopeRef = scopeRef(request);
        DesktopSnapshot previous = scopeRef == null ? null : currentSnapshot();
        DesktopSnapshot.Element scope = previous == null ? null : previous.resolveInWindow(windowId, scopeRef);
        // The adapter may replace its native references even when a capture fails.
        snapshot = null;
        JsonNode captured;
        try {
            captured = scope == null ? adapter.snapshot(windowId, depth, limit)
                    : adapter.snapshotSubtree(windowId, scope.key(), scope.processId(), depth, limit);
        } catch (AgentException ex) {
            if (scope != null && "SNAPSHOT_SCOPE_UNSUPPORTED".equals(ex.code())) snapshot = previous;
            throw ex;
        }
        snapshot = new DesktopSnapshot(windowId, captured, depth, limit, nanoTime.getAsLong());
        return snapshot.describe();
    }

    private DesktopSnapshot currentSnapshot() {
        if (snapshot == null || snapshot.expired(nanoTime.getAsLong())) {
            snapshot = null;
            throw DesktopSnapshot.stale();
        }
        return snapshot;
    }

    private ObjectNode find(ObjectNode request) {
        String snapshotId = string(request, "snapshotId", 128);
        String scopeRef = scopeRef(request);
        return currentSnapshot().find(snapshotId, scopeRef, request.get("locator"));
    }

    private static String scopeRef(ObjectNode request) {
        return request.has("scopeRef") ? string(request, "scopeRef", 128) : null;
    }

    private ObjectNode info(ObjectNode request) {
        String ref = string(request, "ref", 128);
        DesktopSnapshot current = currentSnapshot();
        DesktopSnapshot.Element element = current.resolve(ref);
        return current.liveInfo(element, adapter.elementInfo(element.key(), element.processId()));
    }

    private JsonNode perform(ObjectNode request, String id, DesktopAction action) {
        actions.checkUnused(id);
        String ref = string(request, "ref", 128);
        DesktopSnapshot.Element target = currentSnapshot().resolve(ref);
        JsonNode result = actions.dispatch(adapter, id, action, target, request.path("value"));
        // The provider accepted the call. Only the application can show that it had an effect.
        if (result instanceof ObjectNode reply && !reply.has("effectVerified")) {
            return reply.deepCopy().put("effectVerified", false);
        }
        return result;
    }

    private static String string(ObjectNode node, String field, int limit) {
        JsonNode value = node.path(field);
        if (!value.isTextual() || value.textValue().length() > limit
                || value.textValue().isBlank()) throw invalid("Invalid " + field + ".");
        return value.textValue();
    }

    private static int integer(ObjectNode node, String field, int fallback, int min, int max) {
        if (!node.has(field)) return fallback;
        JsonNode value = node.get(field);
        if (!value.isIntegralNumber() || !value.canConvertToInt() || value.intValue() < min || value.intValue() > max)
            throw invalid("Invalid " + field + ".");
        return value.intValue();
    }

    private static AgentException invalid(String message) {
        return new AgentException("INVALID_REQUEST", message);
    }
}
