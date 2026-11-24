package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class AgentTest {
    private static ObjectNode object() {
        return JsonNodeFactory.instance.objectNode();
    }

    private static ObjectNode request(String op) {
        return object().put("id", "request-" + op).put("op", op);
    }

    private static final class FakeDesktop implements TypedDesktopAdapter {
        boolean truncated;
        ObjectNode malformedRow;
        boolean vendorProperties;
        boolean duplicateName;
        boolean timeout;
        boolean enabled = true;
        boolean disappeared;
        boolean canInvoke;
        int invokes;
        int writes;
        String value = "";

        ObjectNode element(String key) {
            ObjectNode row = object().put("key", key).putNull("parentKey").put("name", "Title")
                    .put("role", "Edit").put("automationId", "title").put("className", "TextBox")
                    .put("enabled", enabled).put("processId", 42);
            var actions = row.putArray("actions").add("setValue");
            if (canInvoke) actions.add("invoke");
            if (vendorProperties) {
                row.remove("automationId");
                row.put("providerToken", "private-provider-data").put("value", "private-input");
                row.putObject("bounds").put("x", 2).put("y", 3).put("width", 4).put("height", 5)
                        .put("vendorData", "private-bounds-data");
            }
            return row;
        }

        public JsonNode capabilities() { return object().put("available", true); }

        public JsonNode listWindows() { return JsonNodeFactory.instance.arrayNode(); }

        public JsonNode snapshot(String windowId, int maxDepth, int maxElements) {
            ObjectNode snapshot = object().put("truncated", truncated);
            var elements = snapshot.putArray("elements").add(element("private-key"));
            if (malformedRow != null) elements.add(malformedRow);
            if (duplicateName) elements.add(element("another-key").put("parentKey", "private-key"));
            return snapshot;
        }

        public JsonNode elementInfo(String key, int processId) {
            if (disappeared) throw new AgentException("STALE_REFERENCE", "Element has gone.");
            return element(key);
        }

        public JsonNode perform(DesktopAction action, String key, int processId, String text) {
            assertEquals(42, processId);
            assertEquals("private-key", key);
            switch (action) {
                case INVOKE -> {
                    assertNull(text);
                    invokes++;
                }
                case SET_VALUE -> {
                    value = text;
                    writes++;
                    if (timeout) throw new AgentException("TIMEOUT", "Worker timed out.");
                }
            }
            return object().put("performed", true);
        }

        public void close() {}
    }

    private final FakeDesktop desktop = new FakeDesktop();
    private long nanos;
    private final Agent agent = new Agent(desktop, Set.of(42), Set.of("setValue"), () -> nanos);

    private static JsonNode snapshot(Agent agent) {
        JsonNode response = agent.handle(request("snapshot").put("windowId", "window-1"));
        assertTrue(response.path("ok").asBoolean(), response::toString);
        return response.get("result");
    }

    private static String ref(JsonNode snapshot) {
        return snapshot.at("/elements/0/ref").textValue();
    }

    private static ObjectNode write(String ref) {
        return request("setValue").put("ref", ref).put("value", "new title");
    }

    private static void error(String code, JsonNode response) {
        assertFalse(response.path("ok").asBoolean(true));
        assertEquals(code, response.at("/error/code").textValue());
    }

    private static ObjectNode find(JsonNode snapshot) {
        ObjectNode request = request("findElement").put("snapshotId", snapshot.get("snapshotId").asText());
        request.putObject("locator").put("name", "Title").put("role", "Edit");
        return request;
    }

    @Test void referencesHideKeysAndRetainParentRelation() {
        desktop.duplicateName = true;
        var snapshot = snapshot(agent);
        assertEquals(ref(snapshot), snapshot.at("/elements/1/parentRef").textValue());
        assertFalse(snapshot.toString().contains("private-key"));
        var info = agent.handle(request("getElementInfo").put("ref", ref(snapshot)));
        assertEquals("Title", info.at("/result/name").asText());
        assertFalse(info.toString().contains("private-key"));
    }

    @Test void exactLocatorRequiresUniqueMatchAndCompleteSearch() {
        var snapshot = snapshot(agent);
        assertEquals(ref(snapshot), agent.handle(find(snapshot)).at("/result/ref").textValue());
        desktop.duplicateName = true;
        error("AMBIGUOUS_ELEMENT", agent.handle(find(snapshot(agent))));
        desktop.duplicateName = false;
        desktop.truncated = true;
        error("INCOMPLETE_SNAPSHOT", agent.handle(find(snapshot(agent))));
    }

    @Test void replacedAndExpiredReferencesNeverDispatch() {
        String old = ref(snapshot(agent));
        String current = ref(snapshot(agent));
        error("STALE_REFERENCE", agent.handle(write(old)));
        nanos += TimeUnit.MINUTES.toNanos(3);
        error("STALE_REFERENCE", agent.handle(write(current)));
        assertEquals(0, desktop.writes);
    }

    @Test void failedWriteCannotBeReplayedByReusingCommandId() {
        ObjectNode command = write(ref(snapshot(agent)));
        desktop.timeout = true;
        error("ACTION_OUTCOME_UNKNOWN", agent.handle(command));
        error("DUPLICATE_COMMAND", agent.handle(command));
        assertEquals("new title", desktop.value);
        assertEquals(1, desktop.writes);
    }

    @Test void bothProcessAndActionPermissionsAreRequired() {
        for (Agent restricted : new Agent[] {
                new Agent(desktop, Set.of(), Set.of("setValue")),
                new Agent(desktop, Set.of(7), Set.of("setValue")),
                new Agent(desktop, Set.of(42), Set.of("invoke"))}) {
            error("PERMISSION_DENIED", restricted.handle(write(ref(snapshot(restricted)))));
        }
        assertEquals(0, desktop.writes);
    }

    @Test void disabledElementCannotBeChanged() {
        desktop.enabled = false;
        error("PRECONDITION_FAILED", agent.handle(write(ref(snapshot(agent)))));
        assertEquals(0, desktop.writes);
    }

    @Test void setValueSupportsEmptyString() {
        var result = agent.handle(write(ref(snapshot(agent))).put("value", ""));
        assertTrue(result.path("ok").asBoolean(), result::toString);
        assertEquals("", desktop.value);
        assertEquals(1, desktop.writes);
    }

    @Test void unknownFieldsCannotBroadenALocator() {
        var request = find(snapshot(agent));
        ((ObjectNode) request.get("locator")).put("index", 0);
        error("INVALID_REQUEST", agent.handle(request));
    }

    @Test void outOfRangeTraversalLimitsAreRejected() {
        for (var bad : new ObjectNode[] {
                request("snapshot").put("maxDepth", -1), request("snapshot").put("maxDepth", 33),
                request("snapshot").put("maxElements", 0), request("snapshot").put("maxElements", 2001),
                request("snapshot").put("maxDepth", 1.1)}) {
            error("INVALID_REQUEST", agent.handle(bad.put("windowId", "window-1")));
        }
    }

    @Test void freshSessionRejectsReferencesEvenIfNativeKeysAreReused() {
        String previous = ref(snapshot(agent));
        Agent restarted = new Agent(desktop, Set.of(42), Set.of("setValue"));
        snapshot(restarted);
        error("STALE_REFERENCE", restarted.handle(write(previous)));
        assertEquals(0, desktop.writes);
    }

    @Test void workerCanInvalidateCachedElement() {
        String previous = ref(snapshot(agent));
        desktop.disappeared = true;
        error("STALE_REFERENCE", agent.handle(request("getElementInfo").put("ref", previous)));
    }

    @Test void invokeRequiresSupportedPattern() {
        Agent buttons = new Agent(desktop, Set.of(42), Set.of("invoke"));
        error("PATTERN_UNSUPPORTED", buttons.handle(request("invoke").put("ref", ref(snapshot(buttons)))));
        desktop.canInvoke = true;
        var result = buttons.handle(request("invoke").put("ref", ref(snapshot(buttons))));
        assertTrue(result.at("/result/performed").asBoolean());
        // A provider's return shows dispatch only. The reply must never claim an observed effect.
        assertTrue(result.at("/result/effectVerified").isBoolean());
        assertFalse(result.at("/result/effectVerified").asBoolean());
        assertEquals(1, desktop.invokes);
    }

    @Test void privateAdapterDataIsNeverProjectedBySnapshotFindOrLiveInfo() {
        desktop.vendorProperties = true;
        var capture = snapshot(agent);
        var found = agent.handle(find(capture));
        var info = agent.handle(request("getElementInfo").put("ref", ref(capture)));
        for (JsonNode row : new JsonNode[] {capture.at("/elements/0"), found.path("result"), info.path("result")}) {
            assertEquals(5, row.at("/bounds/height").asInt());
            assertFalse(row.toString().contains("private-"));
            assertFalse(row.has("providerToken"));
            assertFalse(row.has("value"));
            assertFalse(row.at("/bounds").has("vendorData"));
        }
        var missing = find(capture);
        missing.putObject("locator").put("automationId", "");
        error("ELEMENT_NOT_FOUND", agent.handle(missing));
    }

    @Test void malformedCaptureInvalidatesPreviousRefsWithoutPublishingNewOnes() {
        for (ObjectNode malformed : new ObjectNode[] {
                desktop.element("loop").put("parentKey", "loop"),
                desktop.element("orphan").put("parentKey", "missing"),
                desktop.element("wrong-actions").put("parentKey", "private-key"),
                desktop.element("extra-root"),
                desktop.element("private-key")}) {
            desktop.malformedRow = null;
            String old = ref(snapshot(agent));
            if (malformed.path("key").asText().equals("wrong-actions")) {
                malformed.putArray("actions").add(true);
            }
            desktop.malformedRow = malformed;
            error("WORKER_PROTOCOL", agent.handle(request("snapshot").put("windowId", "window-1")));
            error("STALE_REFERENCE", agent.handle(write(old)));
        }
        assertEquals(0, desktop.writes);
    }

    @Test void fullCommandHistoryRejectsFurtherDispatchAndProtectsOldIds() {
        ObjectNode command = write(ref(snapshot(agent)));
        for (int i = 0; i < 4096; i++) {
            assertTrue(agent.handle(command.put("id", Integer.toString(i))).path("ok").asBoolean());
        }
        error("SESSION_LIMIT", agent.handle(command.put("id", "new")));
        error("DUPLICATE_COMMAND", agent.handle(command.put("id", "0")));
        assertEquals(4096, desktop.writes);
    }
}
