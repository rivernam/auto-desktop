package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.CsvSource;

import static org.junit.jupiter.api.Assertions.*;

class DesktopContractTest {
    private static final ObjectMapper JSON = new ObjectMapper();

    @ParameterizedTest
    @CsvSource({"17, window-1, false", "306, 경로/창 #12, true"})
    void replayPublicCommands(int pid, String windowId, boolean reverseChildren) throws Exception {
        JsonNode contract;
        try (InputStream input = getClass().getResourceAsStream("/contracts/desktop-v1.json")) {
            assertNotNull(input);
            contract = JSON.readTree(input);
        }
        assertEquals(1, contract.get("version").intValue());
        try (FixtureAdapter provider = new FixtureAdapter(contract.get("target"), pid, windowId, reverseChildren)) {
            Agent agent = new Agent(provider, Set.of(pid), Set.of("invoke", "setValue"));
            Map<String, JsonNode> bindings = new HashMap<>();
            for (JsonNode step : contract.get("steps")) {
                ObjectNode request = step.get("request").deepCopy();
                request.properties().forEach(field -> field.setValue(resolve(field.getValue(), bindings)));
                ObjectNode reply = agent.handle(request);
                String id = request.get("id").textValue();
                assertEquals(request.get("id"), reply.get("id"), id);
                assertEquals(JSON.getNodeFactory().booleanNode(!step.has("error")), reply.get("ok"), reply::toString);
                if (step.has("error")) {
                    assertEquals(step.get("error"), reply.at("/error/code"), id);
                    assertTrue(reply.at("/error/message").isTextual() && !reply.at("/error/message").asText().isBlank(), id);
                } else {
                    assertTrue(reply.has("result"), id);
                }
                step.path("expect").properties().forEach(check ->
                        assertEquals(resolve(check.getValue(), bindings), reply.at(check.getKey()), id + check.getKey()));
                step.path("bind").properties().forEach(binding -> {
                    JsonNode captured = reply.at(binding.getValue().textValue());
                    assertTrue(captured.isTextual() && !captured.textValue().isBlank(), id + ": " + binding);
                    assertNull(bindings.put(binding.getKey(), captured), "Duplicate binding: " + binding.getKey());
                });
            }
            assertEquals(contract.get("effects"), provider.effects);
        }
    }

    private static JsonNode resolve(JsonNode value, Map<String, JsonNode> bindings) {
        if (value.isTextual() && value.textValue().startsWith("$")) {
            JsonNode captured = bindings.get(value.textValue().substring(1));
            assertNotNull(captured, "Undefined binding: " + value);
            return captured;
        }
        return value;
    }

    private static final class FixtureAdapter implements TypedDesktopAdapter {
        private final int pid;
        private final String windowId;
        private final String windowName;
        private final Map<String, ObjectNode> rows = new LinkedHashMap<>();
        private final ObjectNode effects = JSON.createObjectNode().put("invoke", 0).put("setValue", 0).put("value", "");

        FixtureAdapter(JsonNode target, int pid, String windowId, boolean reverseChildren) {
            this.pid = pid;
            this.windowId = windowId;
            this.windowName = target.get("name").textValue();
            var nodes = new ArrayList<JsonNode>();
            target.get("elements").forEach(nodes::add);
            if (reverseChildren) Collections.reverse(nodes.subList(1, nodes.size()));
            String parentKey = null;
            for (JsonNode node : nodes) {
                String key = windowId + "/" + rows.size();
                ObjectNode element = node.deepCopy();
                element.put("key", key).put("parentKey", parentKey).put("processId", pid)
                        .put("enabled", true).put("offscreen", false).put("className", "TestControl")
                        .put("backend", "memory").putNull("bounds");
                rows.put(key, element);
                if (parentKey == null) parentKey = key;
            }
        }

        public JsonNode capabilities() {
            ObjectNode result = JSON.createObjectNode().put("backend", "memory").put("available", true)
                    .put("physicalInput", false).put("screenshot", false);
            result.putArray("operations").add("getCapabilities").add("listWindows").add("snapshot")
                    .add("findElement").add("getElementInfo").add("invoke").add("setValue");
            return result;
        }

        public JsonNode listWindows() {
            return JSON.createArrayNode().add(JSON.createObjectNode()
                    .put("windowId", windowId).put("name", windowName).put("processId", pid));
        }

        public JsonNode snapshot(String id, int maxDepth, int maxElements) {
            assertEquals(windowId, id);
            assertTrue(maxDepth >= 1 && maxElements >= rows.size());
            ObjectNode result = JSON.createObjectNode().put("truncated", false);
            var elements = result.putArray("elements");
            rows.values().forEach(elements::add);
            return result;
        }

        public JsonNode elementInfo(String key, int processId) {
            assertEquals(pid, processId);
            ObjectNode row = rows.get(key);
            assertNotNull(row, "Unknown private key: " + key);
            return row;
        }

        public JsonNode perform(DesktopAction action, String key, int processId, String value) {
            String op = action.wireName();
            JsonNode row = elementInfo(key, processId);
            assertEquals(op, row.at("/actions/0").textValue());
            effects.put(op, effects.get(op).intValue() + 1);
            if (action == DesktopAction.SET_VALUE) effects.put("value", value);
            return JSON.createObjectNode().put("performed", true);
        }

        public void close() {}
    }
}
