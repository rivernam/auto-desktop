package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.HashMap;
import java.util.Map;
import java.util.Set;

/** A durable query over element properties. Resolving it requires a current snapshot. */
final class ElementLocator {
    static final Set<String> FIELDS = Set.of("name", "role", "automationId", "className");
    private final Map<String, String> conditions;

    private ElementLocator(Map<String, String> conditions) {
        this.conditions = Map.copyOf(conditions);
    }

    static ElementLocator parse(JsonNode input) {
        if (!(input instanceof ObjectNode object) || object.isEmpty())
            throw new AgentException("INVALID_REQUEST", "Provide one or more locator fields.");
        Map<String, String> conditions = new HashMap<>();
        for (var field : object.properties()) {
            if (!FIELDS.contains(field.getKey()))
                throw new AgentException("INVALID_REQUEST", "Unknown locator field.");
            JsonNode value = field.getValue();
            if (!value.isTextual() || value.textValue().length() > 4096)
                throw new AgentException("INVALID_REQUEST", "Invalid locator field value.");
            conditions.put(field.getKey(), value.textValue());
        }
        return new ElementLocator(conditions);
    }

    boolean matches(ObjectNode properties) {
        for (var field : conditions.entrySet()) {
            if (!field.getValue().equals(properties.path(field.getKey()).textValue())) return false;
        }
        return true;
    }
}
