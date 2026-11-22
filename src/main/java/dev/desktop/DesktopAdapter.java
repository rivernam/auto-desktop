package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.Objects;
import dev.desktop.protocol.ReadOnlyDesktopAdapter;

/**
 * Synchronous accessibility operations for one local desktop session.
 * New native backends implement {@link TypedDesktopAdapter} to serve typed and raw callers.
 * Worker-backed adapters can implement {@link #call(ObjectNode)} and reuse the
 * default translations to the worker protocol.
 */
public interface DesktopAdapter extends ReadOnlyDesktopAdapter<JsonNode>, AutoCloseable {
    default JsonNode capabilities() {
        return call(request("getCapabilities"));
    }

    default JsonNode listWindows() {
        return call(request("listWindows"));
    }

    /** Capture a bounded tree. Returned element keys identify objects in this session. */
    default JsonNode snapshot(String windowId, int maxDepth, int maxElements) {
        return call(request("snapshot").put("windowId", windowId)
                .put("maxDepth", maxDepth).put("maxElements", maxElements));
    }

    /** Recapture a held element as the root. Unsupported adapters preserve their current capture. */
    default JsonNode snapshotSubtree(String windowId, String key, int processId, int maxDepth, int maxElements) {
        throw new AgentException("SNAPSHOT_SCOPE_UNSUPPORTED", "This adapter does not support subtree snapshots.");
    }

    /** Read the held element and verify that it belongs to the given process. */
    default JsonNode elementInfo(String key, int processId) {
        return call(elementRequest("getElementInfo", key, processId));
    }

    /**
     * Verify the live element identity, process and supported pattern before dispatch.
     * SET_VALUE requires a value, including the empty string to clear a field.
     * INVOKE ignores the value. Report uncertain dispatch with ACTION_OUTCOME_UNKNOWN.
     */
    default JsonNode perform(DesktopAction action, String key, int processId, String value) {
        ObjectNode command = elementRequest(action.wireName(), key, processId);
        if (action == DesktopAction.SET_VALUE) {
            command.put("value", Objects.requireNonNull(value, "SET_VALUE requires a value"));
        }
        return call(command);
    }

    /** Compatibility entry point for existing JSON worker adapters. */
    JsonNode call(ObjectNode request);

    private static ObjectNode request(String op) {
        return JsonNodeFactory.instance.objectNode().put("op", op);
    }

    private static ObjectNode elementRequest(String op, String key, int processId) {
        return request(op).put("key", key).put("processId", processId);
    }

    @Override void close();
}
