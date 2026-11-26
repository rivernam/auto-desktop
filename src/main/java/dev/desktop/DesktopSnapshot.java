package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import java.util.stream.Collectors;
import java.util.stream.Stream;

/** The tree and reference store for one bounded observation of a window. */
final class DesktopSnapshot {
    private static final long TTL_NANOS = TimeUnit.SECONDS.toNanos(120);
    private final String id = UUID.randomUUID().toString();
    private final String windowId;
    private final long capturedAt;
    private final boolean truncated;
    // True when the adapter names the elements whose own subtree was cut short.
    private final boolean partialMarked;
    private final Map<String, Element> byRef = new LinkedHashMap<>();
    private final Map<String, String> refByKey = new HashMap<>();
    private final Map<String, List<Element>> childrenByKey = new HashMap<>();
    private Element root;
    // True when the capture started at a held element rather than at the window.
    private boolean scoped;

    static final class Element {
        private final String ref;
        private final String key;
        private final String parentKey;
        private final int processId;
        private final ObjectNode properties;

        Element(String ref, String key, String parentKey, int processId, ObjectNode properties) {
            this.ref = ref;
            this.key = key;
            this.parentKey = parentKey;
            this.processId = processId;
            this.properties = properties;
        }

        public String ref() { return ref; }
        public String key() { return key; }
        public String parentKey() { return parentKey; }
        public int processId() { return processId; }
        public ObjectNode properties() { return properties; }

        @Override public boolean equals(Object other) {
            if (this == other) return true;
            if (!(other instanceof Element)) return false;
            Element that = (Element) other;
            return Objects.equals(ref, that.ref)
                    && Objects.equals(key, that.key)
                    && Objects.equals(parentKey, that.parentKey)
                    && processId == that.processId
                    && Objects.equals(properties, that.properties);
        }
        @Override public int hashCode() { return Objects.hash(ref, key, parentKey, processId, properties); }
        @Override public String toString() {
            return "Element[" + "ref=" + ref
                    + ", key=" + key
                    + ", parentKey=" + parentKey
                    + ", processId=" + processId
                    + ", properties=" + properties + "]";
        }

        static Element read(String ref, JsonNode row) {
            if (!(row instanceof ObjectNode) || !row.path("key").isTextual()
                    || row.get("key").textValue().isBlank() || !row.has("parentKey")
                    || !(row.get("parentKey").isNull() || row.get("parentKey").isTextual())
                    || !row.path("processId").isIntegralNumber() || !row.get("processId").canConvertToInt()
                    || row.get("processId").intValue() <= 0 || !row.path("enabled").isBoolean()
                    || !row.path("actions").isArray()) throw malformed();
            ObjectNode object = (ObjectNode) row;
            // Metadata is an explicit projection. An adapter may carry additional private fields.
            ObjectNode properties = object.objectNode();
            for (String field : ElementLocator.FIELDS) {
                copyText(object, properties, field);
            }
            copyText(object, properties, "backend");
            // Optional diagnostics. They describe the provider and take no part in lookup.
            copyText(object, properties, "nativeRole");
            copyText(object, properties, "referenceStrength");
            copyText(object, properties, "partialReason");
            String setValueSupport = row.path("setValueSupport").asText();
            if (setValueSupport.equals("unverified") || setValueSupport.equals("unsupported"))
                properties.put("setValueSupport", setValueSupport);
            if (row.has("offscreen")) {
                if (!row.get("offscreen").isBoolean()) throw malformed();
                properties.set("offscreen", row.get("offscreen"));
            }
            if (row.has("selected")) {
                if (!row.get("selected").isBoolean()) throw malformed();
                properties.set("selected", row.get("selected"));
            }
            if (row.has("bounds")) properties.set("bounds", bounds(row.get("bounds")));
            if (row.has("partial")) {
                if (!row.get("partial").isBoolean()) throw malformed();
                if (row.get("partial").booleanValue()) properties.put("partial", true);
            }
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

        boolean partial() { return properties.path("partial").asBoolean(); }

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
            if (element.parentKey() == null) {
                roots++;
                root = element;
            }
            else childrenByKey.computeIfAbsent(element.parentKey(), unused -> new ArrayList<>()).add(element);
        }
        if (roots != 1) throw malformed();
        partialMarked = byRef.values().stream().anyMatch(Element::partial);
        if (partialMarked && !truncated) throw malformed();
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

    String windowId() { return windowId; }

    /** The first element of the capture: the window itself unless the capture was scoped. */
    Element root() { return root; }

    boolean scoped() { return scoped; }

    DesktopSnapshot markScoped() {
        scoped = true;
        return this;
    }

    String id() { return id; }

    boolean has(String ref) { return byRef.containsKey(ref); }

    Element resolve(String ref) {
        Element element = byRef.get(ref);
        if (element == null) throw stale();
        return element;
    }

    Element resolveInWindow(String requestedWindowId, String ref) {
        if (!windowId.equals(requestedWindowId)) throw stale();
        return resolve(ref);
    }

    ObjectNode find(String snapshotId, String scopeRef, JsonNode query) {
        if (!id.equals(snapshotId)) throw stale();
        ElementLocator locator = ElementLocator.parse(query);
        Stream<Element> candidates = scopeRef == null ? byRef.values().stream() : subtree(resolve(scopeRef));
        List<Element> matches = candidates.filter(element -> locator.matches(element.properties())).limit(2).collect(Collectors.toUnmodifiableList());
        if (matches.size() == 2) throw new AgentException("AMBIGUOUS_ELEMENT", "More than one element matches.");
        // A cut elsewhere in the tree hides no match inside a scope whose every row is whole.
        boolean complete = !truncated || (scopeRef != null && partialMarked
                && subtree(resolve(scopeRef)).noneMatch(Element::partial));
        if (!complete) throw new AgentException("INCOMPLETE_SNAPSHOT", "A complete snapshot is required for lookup.");
        if (matches.isEmpty()) throw new AgentException("ELEMENT_NOT_FOUND", "No element matches the locator.");
        return publicElement(matches.get(0));
    }

    private Stream<Element> subtree(Element root) {
        return Stream.concat(Stream.of(root), childrenByKey.getOrDefault(root.key(), List.of()).stream()
                .flatMap(this::subtree));
    }

    ObjectNode liveInfo(Element captured, JsonNode row) {
        Element live = Element.read(captured.ref(), row);
        if (!captured.key().equals(live.key()) || captured.processId() != live.processId()
                || (live.parentKey() != null && !refByKey.containsKey(live.parentKey()))) throw malformed();
        // Completeness describes the capture. A live property read cannot change it.
        live.properties().remove("partial");
        live.properties().remove("partialReason");
        if (captured.partial()) {
            live.properties().put("partial", true);
            if (captured.properties().has("partialReason"))
                live.properties().set("partialReason", captured.properties().get("partialReason"));
        }
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
