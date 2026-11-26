package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Set;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

/** Session rules of physical input with an in-memory provider and device. No input reaches the system. */
class AgentInputTest {
    private static ObjectNode object() {
        return JsonNodeFactory.instance.objectNode();
    }

    /** A window with one button. Bounds can be logical, as Java Access Bridge reports them in a HiDPI JVM. */
    private static final class Provider implements TypedDesktopAdapter {
        String backend = "UIA";
        double scale = 1;
        String strength;
        boolean liveEnabled = true;
        boolean liveOffscreen;
        int liveShift;
        // The live row of a scoped capture names no parent outside the capture.
        boolean scopedCapture;

        private ObjectNode row(String key, String parent, String name, double x, double y, double w, double h) {
            ObjectNode row = object().put("key", key).put("name", name).put("role", parent == null ? "Window" : "Button")
                    .put("automationId", key).put("className", "Fixture").put("enabled", true).put("offscreen", false)
                    .put("processId", 42).put("backend", backend);
            if (parent == null) row.putNull("parentKey");
            else row.put("parentKey", parent);
            if (strength != null) row.put("referenceStrength", strength);
            row.putObject("bounds").put("x", x / scale).put("y", y / scale).put("width", w / scale).put("height", h / scale);
            row.putArray("actions");
            return row;
        }

        ObjectNode window() { return row("window", null, "Fixture", 100, 50, 800, 600); }

        ObjectNode button() { return row("button", "window", "Run", 300, 250, 120, 40); }

        @Override public JsonNode capabilities() {
            ObjectNode caps = object().put("backend", backend).put("available", true).put("physicalInput", false)
                    .put("screenshot", false);
            caps.putArray("operations").add("getCapabilities").add("listWindows").add("snapshot");
            return caps;
        }

        @Override public JsonNode listWindows() { return JsonNodeFactory.instance.arrayNode(); }

        @Override public JsonNode snapshot(String windowId, int maxDepth, int maxElements) {
            scopedCapture = false;
            ObjectNode capture = object().put("truncated", false);
            capture.putArray("elements").add(window()).add(button());
            return capture;
        }

        @Override public JsonNode snapshotSubtree(String windowId, String key, int processId, int maxDepth, int maxElements) {
            scopedCapture = true;
            ObjectNode capture = object().put("truncated", false);
            capture.putArray("elements").add(button().putNull("parentKey"));
            return capture;
        }

        @Override public JsonNode elementInfo(String key, int processId) {
            ObjectNode live = "window".equals(key) ? window() : button();
            if ("button".equals(key)) {
                if (scopedCapture) live.putNull("parentKey");
                live.put("enabled", liveEnabled).put("offscreen", liveOffscreen);
                ObjectNode bounds = (ObjectNode) live.get("bounds");
                bounds.put("x", bounds.get("x").doubleValue() + liveShift);
            }
            return live;
        }

        @Override public JsonNode perform(DesktopAction action, String key, int processId, String value) {
            throw new AssertionError("Physical input never falls back to an accessibility action.");
        }

        @Override public void close() {}
    }

    /** Records requests, runs the session gate and returns or throws what the test sets. */
    private static class Device implements InputDriver {
        final List<InputRequest> requests = new ArrayList<>();
        boolean available = true;
        RuntimeException failure;
        boolean closed;
        InputGeometry.Rect window = new InputGeometry.Rect(100, 50, 900, 650);
        InputGeometry.Rect client;

        @Override public ObjectNode describe() {
            ObjectNode row = object().put("available", available).put("dpiAwareness", "perMonitorV2");
            if (!available) row.put("reason", "No device.");
            return row;
        }

        @Override public InputGeometry.Rect windowRect(long handle, int processId) {
            assertEquals(4242L, handle);
            return window;
        }

        @Override public InputGeometry.Rect clientRect(long handle, int processId) { return client; }

        @Override public ObjectNode execute(InputRequest request, Runnable gate, long deadline) {
            requests.add(request);
            gate.run();
            if (failure != null) throw failure;
            ObjectNode result = object().put("performed", true).put("inputSent", true).put("inputObserved", true)
                    .put("effectVerified", false).put("events", 2);
            if (request.point != null) result.putObject("point").put("x", request.point.x).put("y", request.point.y);
            return result;
        }

        @Override public void close() { closed = true; }
    }

    private final Provider provider = new Provider();
    private final Device device = new Device();
    private final Set<Integer> allowed = new HashSet<>(Set.of(42));
    private int sequence;

    private Agent session(String... actions) {
        return new Agent(provider.backend, provider, allowed::contains, Set.of(actions)).withInput(device);
    }

    private JsonNode send(Agent agent, ObjectNode request) {
        if (!request.has("id")) request.put("id", "r" + ++sequence);
        return agent.handle(request);
    }

    private static ObjectNode op(String op) {
        return object().put("op", op);
    }

    private static ObjectNode click(int pid) {
        ObjectNode request = op("pointerClick").put("windowId", "4242").put("processId", pid);
        request.putObject("point").put("x", 10).put("y", 20).put("space", "client");
        return request;
    }

    private static JsonNode error(String code, JsonNode response) {
        assertFalse(response.path("ok").asBoolean(true), response::toString);
        assertEquals(code, response.at("/error/code").textValue(), response::toString);
        return response.get("error");
    }

    private JsonNode snapshot(Agent agent) {
        JsonNode response = send(agent, op("snapshot").put("windowId", "4242"));
        assertTrue(response.path("ok").asBoolean(), response::toString);
        return response.get("result");
    }

    private static String buttonRef(JsonNode snapshot) {
        for (JsonNode row : snapshot.get("elements")) if ("Run".equals(row.path("name").asText())) return row.get("ref").asText();
        throw new AssertionError("No button in " + snapshot);
    }

    @Test void capabilitiesStayTheSameWithoutPhysicalInput() {
        try (Agent agent = session("invoke", "setValue")) {
            assertEquals(provider.capabilities(), send(agent, op("getCapabilities")).get("result"));
        }
        assertTrue(device.requests.isEmpty());
    }

    @Test void capabilitiesListAllowedInputOperationsInOrder() {
        try (Agent agent = session("keyboard", "pointer")) {
            JsonNode caps = send(agent, op("getCapabilities")).get("result");
            assertTrue(caps.get("physicalInput").booleanValue());
            assertEquals("[\"keyboard\",\"pointer\"]", caps.at("/input/allowedActions").toString());
            List<String> operations = new ArrayList<>();
            caps.get("operations").forEach(node -> operations.add(node.asText()));
            assertEquals(List.of("getCapabilities", "listWindows", "snapshot", "pointerMove", "pointerClick", "pointerDrag",
                    "pointerScroll", "clickElement", "keyPress", "keyDown", "keyUp", "typeText"), operations);
        }
        device.available = false;
        try (Agent agent = session("activate")) {
            JsonNode caps = send(agent, op("getCapabilities")).get("result");
            assertFalse(caps.get("physicalInput").booleanValue());
            assertEquals("No device.", caps.at("/input/reason").asText());
            assertEquals(3, caps.get("operations").size());
        }
        assertTrue(device.closed);
    }

    @Test void policyRefusesBeforeTheDeviceAndKeepsTheId() {
        try (Agent agent = session("pointer")) {
            assertFalse(error("PERMISSION_DENIED", send(agent, click(7).put("id", "a"))).get("inputSent").booleanValue());
            ObjectNode typing = op("typeText").put("windowId", "4242").put("processId", 42).put("text", "x").put("id", "b");
            error("PERMISSION_DENIED", send(agent, typing));
            assertTrue(device.requests.isEmpty());
            allowed.add(7);
            assertTrue(send(agent, click(7).put("id", "a")).path("ok").asBoolean());
            assertFalse(error("INVALID_REQUEST", send(agent, click(42).put("windowId", "abc"))).get("inputSent").booleanValue());
        }
        try (Agent agent = new Agent("UIA", provider, allowed::contains, Set.of("invoke"))) {
            // A session started without physical input has no device at all.
            error("PERMISSION_DENIED", send(agent, click(42)));
        }
    }

    @Test void deviceRefusalsConsumeTheIdAndReportTheOutcome() {
        try (Agent agent = session("pointer")) {
            device.failure = InputException.refused("FOREGROUND_MISMATCH", "Not in front.");
            JsonNode refused = error("FOREGROUND_MISMATCH", send(agent, click(42).put("id", "same")));
            assertFalse(refused.get("inputSent").booleanValue());
            assertFalse(refused.has("released"));
            device.failure = null;
            assertFalse(error("DUPLICATE_COMMAND", send(agent, click(42).put("id", "same"))).get("inputSent").booleanValue());
            assertEquals(1, device.requests.size());

            device.failure = new InputException("USER_INPUT_CONFLICT", "User moved the mouse.", true, true);
            JsonNode conflict = error("USER_INPUT_CONFLICT", send(agent, click(42)));
            assertTrue(conflict.get("inputSent").booleanValue());
            assertTrue(conflict.get("released").booleanValue());
        }
    }

    @Test void theGateRechecksTheProcessRightBeforeInput() {
        try (Agent agent = session("pointer")) {
            Device racing = new Device() {
                @Override public ObjectNode execute(InputRequest request, Runnable gate, long deadline) {
                    allowed.remove(42);
                    return super.execute(request, gate, deadline);
                }
            };
            agent.withInput(racing);
            error("PERMISSION_DENIED", send(agent, click(42)));
        }
    }

    @Test void clickElementUsesLiveBoundsInPhysicalPixels() {
        try (Agent agent = session("pointer")) {
            String ref = buttonRef(snapshot(agent));
            JsonNode response = send(agent, op("clickElement").put("ref", ref));
            assertTrue(response.path("ok").asBoolean(), response::toString);
            assertEquals("physical", response.at("/result/boundsMapping").asText());
            assertEquals("UIA", response.at("/result/backend").asText());
            InputRequest sent = device.requests.get(0);
            assertEquals(InputRequest.Kind.CLICK, sent.kind);
            assertEquals(InputRequest.Space.SCREEN, sent.point.space);
            assertEquals(360, sent.point.x);
            assertEquals(270, sent.point.y);
            assertEquals(4242L, sent.window);

            ObjectNode corner = op("clickElement").put("ref", ref).put("button", "right").put("clicks", 2);
            corner.putObject("position").put("x", 0).put("y", 1);
            assertTrue(send(agent, corner).path("ok").asBoolean());
            assertEquals(300, device.requests.get(1).point.x);
            assertEquals(289, device.requests.get(1).point.y);
            assertEquals(InputRequest.Button.RIGHT, device.requests.get(1).button);

            provider.liveShift = 7;
            assertTrue(send(agent, op("clickElement").put("ref", ref)).path("ok").asBoolean());
            assertEquals(367, device.requests.get(2).point.x);

            ObjectNode outside = op("clickElement").put("ref", ref);
            outside.putObject("position").put("x", 1.5);
            error("INVALID_REQUEST", send(agent, outside));
        }
    }

    @Test void msaaCanMatchClientBoundsWithoutScalingTheClick() {
        provider.backend = "MSAA";
        device.window = new InputGeometry.Rect(92, 19, 908, 658);
        device.client = new InputGeometry.Rect(100, 50, 900, 650);
        try (Agent agent = session("pointer")) {
            String ref = buttonRef(snapshot(agent));
            JsonNode response = send(agent, op("clickElement").put("ref", ref));
            assertEquals("physical", response.at("/result/boundsMapping").asText(), response::toString);
            assertEquals(360, device.requests.get(0).point.x);
            assertEquals(270, device.requests.get(0).point.y);

            device.client = new InputGeometry.Rect(100, 54, 900, 654);
            error("BOUNDS_UNVERIFIED", send(agent, op("clickElement").put("ref", ref)));
            assertEquals(1, device.requests.size());
        }
    }

    @Test void logicalBoundsAreScaledThroughTheWindow() {
        provider.backend = "JAB";
        provider.scale = 1.25;
        try (Agent agent = session("pointer")) {
            String ref = buttonRef(snapshot(agent));
            JsonNode response = send(agent, op("clickElement").put("ref", ref));
            assertTrue(response.path("ok").asBoolean(), response::toString);
            assertEquals("scaled", response.at("/result/boundsMapping").asText());
            assertEquals(360, device.requests.get(0).point.x);
            assertEquals(270, device.requests.get(0).point.y);

            device.window = new InputGeometry.Rect(100, 50, 1300, 650);
            error("BOUNDS_UNVERIFIED", send(agent, op("clickElement").put("ref", ref)));
        }
    }

    @Test void scopedSnapshotsAreAssumedPhysicalExceptForJab() {
        for (String backend : List.of("UIA", "JAB")) {
            provider.backend = backend;
            try (Agent agent = session("pointer")) {
                JsonNode full = snapshot(agent);
                ObjectNode scoped = op("snapshot").put("windowId", "4242").put("scopeRef", buttonRef(full));
                JsonNode subtree = send(agent, scoped).get("result");
                String ref = subtree.at("/elements/0/ref").asText();
                JsonNode response = send(agent, op("clickElement").put("ref", ref));
                if (backend.equals("JAB")) error("BOUNDS_UNVERIFIED", response);
                else assertEquals("assumedPhysical", response.at("/result/boundsMapping").asText(), response::toString);
            }
        }
    }

    @Test void weakReferencesNeedConsentAndAnUnchangedElement() {
        provider.backend = "MSAA";
        provider.strength = "weak";
        try (Agent agent = session("pointer")) {
            String ref = buttonRef(snapshot(agent));
            error("PRECONDITION_FAILED", send(agent, op("clickElement").put("ref", ref)));
            JsonNode accepted = send(agent, op("clickElement").put("ref", ref).put("acceptWeakReference", true));
            assertTrue(accepted.path("ok").asBoolean(), accepted::toString);
            assertEquals("weak", accepted.at("/result/referenceStrength").asText());
            provider.liveShift = 1;
            error("STALE_REFERENCE", send(agent, op("clickElement").put("ref", ref).put("acceptWeakReference", true)));
            error("INVALID_REQUEST", send(agent, op("clickElement").put("ref", ref).put("acceptWeakReference", "yes")));
            assertEquals(1, device.requests.size());
        }
    }

    @Test void liveStateDecidesWhetherAnElementCanBeClicked() {
        try (Agent agent = session("pointer")) {
            String ref = buttonRef(snapshot(agent));
            provider.liveEnabled = false;
            error("PRECONDITION_FAILED", send(agent, op("clickElement").put("ref", ref)));
            provider.liveEnabled = true;
            provider.liveOffscreen = true;
            error("PRECONDITION_FAILED", send(agent, op("clickElement").put("ref", ref)));
            error("STALE_REFERENCE", send(agent, op("clickElement").put("ref", "unknown")));
            assertTrue(device.requests.isEmpty());
        }
    }
}
