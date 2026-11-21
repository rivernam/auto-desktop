package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

/**
 * Implement this interface for a native provider. Implement each typed operation and
 * close the native session in {@link #close()}. Existing {@link DesktopAdapter#call}
 * clients can then use the provider through the same internal worker frames.
 * The caller supplies backend keys, process identity and explicit snapshot limits.
 */
public interface TypedDesktopAdapter extends DesktopAdapter {
    @Override JsonNode capabilities();
    @Override JsonNode listWindows();
    @Override JsonNode snapshot(String windowId, int maxDepth, int maxElements);
    @Override JsonNode elementInfo(String key, int processId);
    @Override JsonNode perform(DesktopAction action, String key, int processId, String value);

    @Override
    default JsonNode call(ObjectNode request) {
        if (request == null) throw new AgentException("INVALID_REQUEST", "Expected a request object.");
        return switch (text(request, "op", false)) {
            case "getCapabilities" -> capabilities();
            case "listWindows" -> listWindows();
            case "snapshot" -> snapshot(text(request, "windowId", false),
                    number(request, "maxDepth", 0, 32), number(request, "maxElements", 1, 2000));
            case "getElementInfo" -> elementInfo(text(request, "key", false), processId(request));
            case "invoke" -> perform(DesktopAction.INVOKE, text(request, "key", false), processId(request), null);
            case "setValue" -> perform(DesktopAction.SET_VALUE, text(request, "key", false), processId(request),
                    text(request, "value", true));
            default -> throw new AgentException("UNKNOWN_OPERATION", "Unknown desktop operation.");
        };
    }

    private static String text(ObjectNode request, String field, boolean allowBlank) {
        JsonNode value = request.path(field);
        if (!value.isTextual() || (!allowBlank && value.textValue().isBlank())) {
            throw invalid(field);
        }
        return value.textValue();
    }

    private static int processId(ObjectNode request) {
        return number(request, "processId", 1, Integer.MAX_VALUE);
    }

    private static int number(ObjectNode request, String field, int min, int max) {
        JsonNode value = request.path(field);
        if (!value.isIntegralNumber() || !value.canConvertToInt()
                || value.intValue() < min || value.intValue() > max) throw invalid(field);
        return value.intValue();
    }

    private static AgentException invalid(String field) {
        return new AgentException("INVALID_REQUEST", "Invalid " + field + ".");
    }
}
