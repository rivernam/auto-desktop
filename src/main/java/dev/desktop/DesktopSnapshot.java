package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.List;
import java.util.UUID;
import java.util.concurrent.TimeUnit;

/** The tree and reference store for one bounded observation of a window. */
final class DesktopSnapshot {
    private static final long TTL_NANOS = TimeUnit.SECONDS.toNanos(120);
    private final String id = UUID.randomUUID().toString();
    private final String windowId;
    private final long capturedAt;
    private final boolean truncated;
    private final Map<String, Element> byRef = new LinkedHashMap<>();
    private final Map<String, String> refByKey = new HashMap<>();

    record Element(String ref, String key, String parentKey, int processId, ObjectNode properties) {
        static Element read(String ref, JsonNode row) {
            if (!(row instanceof ObjectNode object) || !row.path("key").isTextual()
                    || row.get("key").textValue().isBlank() || !row.has("parentKey")
                    || !(row.get("parentKey").isNull() || row.get("parentKey").isTextual())
                    || !row.path("processId").isIntegralNumber() || !row.get("processId").canConvertToInt()
                    || row.get("processId").intValue() <= 0 || !row.path("enabled").isBoolean()
                    || !row.path("actions").isArray()) throw malformed();
            // Metadata is an explicit projection. An adapter may carry additional private fields.
            ObjectNode properties = object.objectNode();
            for (String field : ElementLocator.FIELDS) {
                copyText(object, properties, field);
            }
            copyText(object, properties, "backend");
            if (row.has("offscreen")) {
                if (!row.get("offscreen").isBoolean()) throw malformed();
                properties.set("offscreen", row.get("offscreen"));
            }
            if (row.has("bounds")) properties.set("bounds", bounds(row.get("bounds")));
            properties.set("processId", row.get("processId"));
            properties.set("enabled", row.get("enabled"));
            var actions = properties.putArray("actions");
            for (JsonNode action : row.get("actions")) {
                if (!action.isTextual()) throw malformed();
                actions.add(action.textValue());
            }
            return new Element(ref, row.get("key").textValue(), row.get("parentKey").textValue(),
                    row.get("processId").intValue(), properties);
        }

        private static void copyText(ObjectNode source, ObjectNode destination, String field) {
            JsonNode value = source.get(field);
            if (value == null || value.isNull()) return;
            if (!value.isTextual()) throw malformed();
            destination.put(field, value.textValue());
        }

        private static JsonNode bounds(JsonNode input) {
            if (input.isNull()) return input;
            ObjectNode result = JsonNodeFactory.instance.objectNode();
            for (String axis : List.of("x", "y", "width", "height")) {
                JsonNode coordinate = input.path(axis);
                if (!coordinate.isNumber() || !Double.isFinite(coordinate.doubleValue())) throw malformed();
                result.set(axis, coordinate);
            }
            return result;
        }

        boolean offers(DesktopAction action) {
            for (JsonNode label : properties.get("actions")) {
                if (action.wireName().equals(label.textValue())) return true;
            }
            return false;
        }
    }

    DesktopSnapshot(String windowId, JsonNode capture, int maxDepth, int maxElements, long capturedAt) {
        if (capture == null || !capture.path("truncated").isBoolean() || !capture.path("elements").isArray()
                || capture.get("elements").isEmpty() || capture.get("elements").size() > maxElements) throw malformed();
        this.windowId = windowId;
        this.capturedAt = capturedAt;
        this.truncated = capture.get("truncated").booleanValue();
        int roots = 0;
        for (JsonNode row : capture.get("elements")) {
            Element element = Element.read(UUID.randomUUID().toString(), row);
            if (refByKey.put(element.key(), element.ref()) != null) throw malformed();
            byRef.put(element.ref(), element);
            if (element.parentKey() == null) roots++;
        }
        if (roots != 1) throw malformed();
        // Providers may return children before parents. Validate each path after indexing the full tree.
        for (Element element : byRef.values()) {
            int depth = 0;
            while (element.parentKey() != null) {
                element = byRef.get(refByKey.get(element.parentKey()));
                if (element == null || ++depth > maxDepth) throw malformed();
            }
        }
    }

    boolean expired(long now) { return now - capturedAt >= TTL_NANOS; }

    Element resolve(String ref) {
        Element element = byRef.get(ref);
        if (element == null) throw stale();
        return element;
    }

    ObjectNode find(String snapshotId, JsonNode query) {
        if (!id.equals(snapshotId)) throw stale();
        ElementLocator locator = ElementLocator.parse(query);
        Element match = null;
        for (Element element : byRef.values()) {
            if (locator.matches(element.properties())) {
                if (match != null) throw new AgentException("AMBIGUOUS_ELEMENT", "More than one element matches.");
                match = element;
            }
        }
        if (truncated) throw new AgentException("INCOMPLETE_SNAPSHOT", "A complete snapshot is required for lookup.");
        if (match == null) throw new AgentException("ELEMENT_NOT_FOUND", "No element matches the locator.");
        return publicElement(match);
    }

    ObjectNode liveInfo(Element captured, JsonNode row) {
        Element live = Element.read(captured.ref(), row);
        if (!captured.key().equals(live.key()) || captured.processId() != live.processId()
                || (live.parentKey() != null && !refByKey.containsKey(live.parentKey()))) throw malformed();
        return publicElement(live);
    }

    ObjectNode describe() {
        ObjectNode result = JsonNodeFactory.instance.objectNode().put("snapshotId", id)
                .put("windowId", windowId).put("truncated", truncated);
        var rows = result.putArray("elements");
        for (Element element : byRef.values()) rows.add(publicElement(element));
        return result;
    }

    private ObjectNode publicElement(Element element) {
        return element.properties().deepCopy().put("ref", element.ref()).put("parentRef", refByKey.get(element.parentKey()));
    }

    static AgentException stale() {
        return new AgentException("STALE_REFERENCE", "Capture a new snapshot and resolve the element again.");
    }

    private static AgentException malformed() {
        return new AgentException("WORKER_PROTOCOL", "Invalid response from the accessibility worker.");
    }
}
