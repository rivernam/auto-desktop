package dev.desktop;

import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;

/** Shared negative capability response for absent adapters, sessions, or providers. */
final class DesktopCapabilities {
    static ObjectNode unavailable(String backend, String reason) {
        ObjectNode result = JsonNodeFactory.instance.objectNode();
        result.put("backend", backend).put("available", false).put("reason", reason)
                .put("physicalInput", false).put("screenshot", false);
        result.putArray("operations");
        return result;
    }

    private DesktopCapabilities() {}
}
