package dev.desktop;

import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;

/** Routing, reference ownership and fault isolation of a session over two scripted backends. */
class MultiBackendAgentTest {
    private static ObjectNode object() {
        return JsonNodeFactory.instance.objectNode();
    }

    private static final class Scripted implements TypedDesktopAdapter {
        final String backend;
        final List<String> performed = new ArrayList<>();
        String failure;
        String unavailable;
        boolean finished;
        boolean closed;
        int captures;

        Scripted(String backend) { this.backend = backend; }

        private void check() {
            if (failure != null) throw new AgentException(failure, backend + " failed.");
        }

        public JsonNode capabilities() {
            if (unavailable != null) return DesktopCapabilities.unavailable(backend, unavailable);
            ObjectNode result = object().put("backend", backend).put("available", true);
            result.putArray("operations").add("snapshot");
            return result;
        }

        public JsonNode listWindows() {
            check();
            var rows = JsonNodeFactory.instance.arrayNode();
            // Window 100 is visible to both backends. Each also has one window of its own.
            rows.addObject().put("windowId", "100").put("processId", 42).put("name", backend + " title");
            rows.addObject().put("windowId", backend.equals("UIA") ? "200" : "300").put("processId", 42)
                    .put("name", "only " + backend).put("ownerWindowId", "100");
            return rows;
        }

        public JsonNode snapshot(String windowId, int maxDepth, int maxElements) {
            check();
            captures++;
            ObjectNode snapshot = object().put("truncated", false);
            var rows = snapshot.putArray("elements");
            rows.add(row(backend + "-root-" + captures, null, "Window"));
            rows.add(row(backend + "-control-" + captures, backend + "-root-" + captures, "Button"));
            return snapshot;
        }

        private ObjectNode row(String key, String parent, String role) {
            ObjectNode row = object().put("key", key).put("name", "Shared name").put("role", role)
                    .put("automationId", "").put("className", "").put("enabled", true).put("processId", 42)
                    .put("backend", backend);
            if (parent == null) row.putNull("parentKey");
            else row.put("parentKey", parent);
            row.putArray("actions").add("invoke").add("setValue");
            return row;
        }

        public JsonNode elementInfo(String key, int processId) {
            check();
            return row(key, key.contains("root") ? null : key.replace("control", "root"),
                    key.contains("root") ? "Window" : "Button");
        }

        public JsonNode perform(DesktopAction action, String key, int processId, String value) {
            performed.add(action.wireName() + ":" + key);
            check();
            return object().put("performed", true);
        }

        @Override public boolean finished() { return finished; }

        public void close() { closed = true; }
    }

    private final List<Scripted> uiaSessions = new ArrayList<>();
    private final List<Scripted> jabSessions = new ArrayList<>();
    private long nanos;
    private int sequence;
    private final Agent agent = open(Set.of("invoke", "setValue"));

    private Agent open(Set<String> actions) {
        var sources = new LinkedHashMap<String, Agent.BackendSource>();
        sources.put("UIA", new Agent.BackendSource(() -> {
            uiaSessions.add(new Scripted("UIA"));
            return uiaSessions.get(uiaSessions.size() - 1);
        }, true));
        sources.put("JAB", new Agent.BackendSource(() -> {
            jabSessions.add(new Scripted("JAB"));
            return jabSessions.get(jabSessions.size() - 1);
        }, false));
        return Agent.multi(sources, Set.of(42), actions, () -> nanos);
    }

    private Scripted uia() { return uiaSessions.get(uiaSessions.size() - 1); }

    private Scripted jab() { return jabSessions.get(jabSessions.size() - 1); }

    private ObjectNode send(String op) {
        return object().put("id", "request-" + ++sequence).put("op", op);
    }

    private JsonNode ok(ObjectNode request) {
        JsonNode reply = agent.handle(request);
        assertTrue(reply.path("ok").asBoolean(), reply.toString());
        return reply.get("result");
    }

    private void fails(String code, ObjectNode request) {
        JsonNode reply = agent.handle(request);
        assertEquals(code, reply.at("/error/code").asText(), reply.toString());
    }

    private JsonNode capture(String backend) {
        ObjectNode request = send("snapshot").put("windowId", "100");
        if (backend != null) request.put("backend", backend);
        return ok(request);
    }

    private static String control(JsonNode snapshot) {
        return snapshot.at("/elements/1/ref").asText();
    }

    @Test void capabilitiesReportEachBackendWithItsReason() {
        jab().unavailable = "The Java Access Bridge library was not found.";
        JsonNode result = ok(send("getCapabilities"));
        assertEquals("multi", result.path("backend").asText());
        assertTrue(result.path("available").asBoolean());
        assertEquals("UIA", result.path("defaultBackend").asText());
        assertEquals(7, result.path("operations").size());
        assertEquals("UIA", result.at("/backends/0/backend").asText());
        assertTrue(result.at("/backends/0/available").asBoolean());
        assertEquals("JAB", result.at("/backends/1/backend").asText());
        assertFalse(result.at("/backends/1/available").asBoolean());
        assertEquals("The Java Access Bridge library was not found.", result.at("/backends/1/reason").asText());

        uia().unavailable = "No desktop.";
        result = ok(send("getCapabilities"));
        assertFalse(result.path("available").asBoolean());
        assertTrue(result.path("operations").isEmpty());
        assertTrue(result.has("reason"));
    }

    @Test void windowListMergesByWindowAndNamesItsBackends() {
        JsonNode reply = agent.handle(send("listWindows"));
        JsonNode rows = reply.get("result");
        assertEquals(3, rows.size(), "The window that both backends list appears once.");
        assertEquals("100", rows.at("/0/windowId").asText());
        assertEquals("UIA title", rows.at("/0/name").asText(), "The first backend that lists a window describes it.");
        assertEquals("[\"UIA\",\"JAB\"]", rows.at("/0/backends").toString());
        assertEquals("[\"UIA\"]", rows.at("/1/backends").toString());
        assertEquals("100", rows.at("/1/ownerWindowId").asText());
        assertEquals("300", rows.at("/2/windowId").asText());
        assertEquals("[\"JAB\"]", rows.at("/2/backends").toString());
        assertEquals("[{\"backend\":\"UIA\",\"ok\":true},{\"backend\":\"JAB\",\"ok\":true}]",
                reply.get("backends").toString());
    }

    @Test void windowListNamesTheBackendThatFailed() {
        jab().failure = "TARGET_NOT_RESPONDING";
        JsonNode reply = agent.handle(send("listWindows"));
        assertTrue(reply.path("ok").asBoolean());
        assertEquals(2, reply.get("result").size());
        assertEquals("[\"UIA\"]", reply.at("/result/0/backends").toString());
        assertFalse(reply.at("/backends/1/ok").asBoolean());
        assertEquals("TARGET_NOT_RESPONDING", reply.at("/backends/1/error/code").asText());

        uia().failure = "TARGET_NOT_RESPONDING";
        reply = agent.handle(send("listWindows"));
        assertEquals("TARGET_NOT_RESPONDING", reply.at("/error/code").asText(), "Every backend failed alike.");
        assertEquals(2, reply.get("backends").size());
        uia().failure = "TIMEOUT";
        assertEquals("BACKEND_UNAVAILABLE", agent.handle(send("listWindows")).at("/error/code").asText());
    }

    @Test void snapshotSelectsItsBackendExplicitly() {
        JsonNode byDefault = capture(null);
        assertEquals("UIA", byDefault.path("backend").asText());
        assertEquals("UIA", byDefault.at("/elements/0/backend").asText());
        JsonNode bridged = capture("JAB");
        assertEquals("JAB", bridged.path("backend").asText());
        assertEquals("JAB", bridged.at("/elements/1/backend").asText());
        assertEquals(1, uia().captures);
        assertEquals(1, jab().captures);
        fails("BACKEND_UNAVAILABLE", send("snapshot").put("windowId", "100").put("backend", "MSAA"));
        fails("INVALID_REQUEST", send("snapshot").put("windowId", "100").put("backend", 7));
        fails("INVALID_REQUEST", send("snapshot").put("windowId", "100").put("backend", " "));
    }

    @Test void eachBackendKeepsItsOwnLatestSnapshot() {
        JsonNode first = capture("UIA");
        JsonNode bridged = capture("JAB");
        // A capture through one backend leaves the references of the other in force.
        assertEquals(control(first), ok(send("getElementInfo").put("ref", control(first))).path("ref").asText());
        JsonNode second = capture("UIA");
        fails("STALE_REFERENCE", send("getElementInfo").put("ref", control(first)));
        fails("STALE_REFERENCE", send("findElement").put("snapshotId", first.path("snapshotId").asText())
                .set("locator", object().put("role", "Button")));
        assertEquals("JAB", ok(send("getElementInfo").put("ref", control(bridged))).path("backend").asText());
        assertEquals(control(bridged), ok(send("findElement").put("snapshotId", bridged.path("snapshotId").asText())
                .set("locator", object().put("role", "Button"))).path("ref").asText());
        assertEquals(control(second), ok(send("findElement").put("snapshotId", second.path("snapshotId").asText())
                .set("locator", object().put("role", "Button"))).path("ref").asText());
    }

    @Test void eachSnapshotExpiresOnItsOwnClock() {
        JsonNode first = capture("UIA");
        nanos = TimeUnit.SECONDS.toNanos(60);
        JsonNode bridged = capture("JAB");
        nanos = TimeUnit.SECONDS.toNanos(120);
        fails("STALE_REFERENCE", send("getElementInfo").put("ref", control(first)));
        fails("STALE_REFERENCE", send("invoke").put("ref", control(first)));
        ok(send("getElementInfo").put("ref", control(bridged)));
        nanos = TimeUnit.SECONDS.toNanos(180);
        fails("STALE_REFERENCE", send("getElementInfo").put("ref", control(bridged)));
        assertTrue(uia().performed.isEmpty() && jab().performed.isEmpty());
    }

    @Test void aReferenceIsStaleForEveryOtherBackend() {
        JsonNode first = capture("UIA");
        JsonNode bridged = capture("JAB");
        // A scope from one backend cannot root a capture or a lookup of the other.
        fails("STALE_REFERENCE", send("snapshot").put("windowId", "100").put("backend", "JAB")
                .put("scopeRef", control(first)));
        ObjectNode lookup = send("findElement").put("snapshotId", bridged.path("snapshotId").asText())
                .put("scopeRef", control(first));
        lookup.set("locator", object().put("role", "Button"));
        fails("STALE_REFERENCE", lookup);
        assertEquals(1, jab().captures, "The refused capture never reached the backend.");
        ok(send("getElementInfo").put("ref", control(bridged)));
        ok(send("getElementInfo").put("ref", control(first)));

        // Another session issues references that this one does not know.
        Agent other = open(Set.of("invoke"));
        JsonNode foreign = other.handle(send("snapshot").put("windowId", "100")).get("result");
        fails("STALE_REFERENCE", send("invoke").put("ref", control(foreign)));
    }

    @Test void actionsGoOnlyToTheBackendThatIssuedTheReference() {
        JsonNode first = capture("UIA");
        JsonNode bridged = capture("JAB");
        JsonNode done = ok(send("setValue").put("ref", control(first)).put("value", "text"));
        assertTrue(done.path("performed").asBoolean());
        assertFalse(done.path("effectVerified").asBoolean());
        ok(send("invoke").put("ref", control(bridged)));
        assertEquals(List.of("setValue:UIA-control-1"), uia().performed);
        assertEquals(List.of("invoke:JAB-control-1"), jab().performed);

        // A failed or uncertain action is reported. It is neither retried nor sent to the other backend.
        jab().failure = "TIMEOUT";
        fails("ACTION_OUTCOME_UNKNOWN", send("invoke").put("ref", control(bridged)));
        jab().failure = "PATTERN_UNSUPPORTED";
        fails("PATTERN_UNSUPPORTED", send("invoke").put("ref", control(bridged)));
        assertEquals(3, jab().performed.size());
        assertEquals(1, uia().performed.size());
    }

    @Test void commandIdsAreUniqueAcrossBackends() {
        JsonNode first = capture("UIA");
        JsonNode bridged = capture("JAB");
        ObjectNode write = object().put("id", "command-1").put("op", "setValue").put("ref", control(first))
                .put("value", "text");
        assertTrue(agent.handle(write).path("ok").asBoolean());
        ObjectNode click = object().put("id", "command-1").put("op", "invoke").put("ref", control(bridged));
        assertEquals("DUPLICATE_COMMAND", agent.handle(click).at("/error/code").asText());
        assertTrue(jab().performed.isEmpty());
    }

    @Test void aFaultedBackendLeavesTheOtherAndItsReferencesAlone() {
        JsonNode first = capture("UIA");
        JsonNode bridged = capture("JAB");
        jab().failure = "TARGET_NOT_RESPONDING";
        fails("TARGET_NOT_RESPONDING", send("getElementInfo").put("ref", control(bridged)));
        fails("TARGET_NOT_RESPONDING", send("invoke").put("ref", control(bridged)));
        ok(send("getElementInfo").put("ref", control(first)));
        ok(send("invoke").put("ref", control(first)));
        JsonNode again = capture("UIA");
        ok(send("setValue").put("ref", control(again)).put("value", "after"));
        assertEquals(2, uia().performed.size());

        // The bridge answers again. The references it issued before the fault are still in force.
        jab().failure = null;
        ok(send("getElementInfo").put("ref", control(bridged)));
        ok(send("invoke").put("ref", control(bridged)));

        // A capture that fails drops the references of its own backend only.
        jab().failure = "TARGET_NOT_RESPONDING";
        fails("TARGET_NOT_RESPONDING", send("snapshot").put("windowId", "100").put("backend", "JAB"));
        jab().failure = null;
        fails("STALE_REFERENCE", send("getElementInfo").put("ref", control(bridged)));
        ok(send("getElementInfo").put("ref", control(again)));
        ok(send("invoke").put("ref", control(capture("JAB"))));
    }

    @Test void aRetiredRestartableBackendIsReplacedInPlace() {
        JsonNode first = capture("UIA");
        JsonNode bridged = capture("JAB");
        Scripted retired = uia();
        retired.failure = "BACKEND_UNAVAILABLE";
        fails("BACKEND_UNAVAILABLE", send("snapshot").put("windowId", "100"));
        assertEquals(1, uiaSessions.size(), "A retired adapter is kept until its native session is released.");

        retired.finished = true;
        // The references of the retired adapter are gone. No action reaches the replacement through them.
        JsonNode stale = capture("UIA");
        assertEquals(2, uiaSessions.size());
        assertTrue(retired.closed);
        fails("STALE_REFERENCE", send("invoke").put("ref", control(first)));
        ok(send("invoke").put("ref", control(stale)));
        assertEquals(List.of("invoke:UIA-control-1"), uia().performed);
        assertEquals(1, jabSessions.size());
        ok(send("invoke").put("ref", control(bridged)));
    }

    @Test void aReferenceOfAReplacedAdapterNeverReachesItsReplacement() {
        JsonNode first = capture("UIA");
        uia().finished = true;
        fails("STALE_REFERENCE", send("invoke").put("ref", control(first)));
        assertEquals(2, uiaSessions.size());
        assertTrue(uia().performed.isEmpty());
        fails("STALE_REFERENCE", send("snapshot").put("windowId", "100").put("scopeRef", control(first)));
    }

    @Test void aBackendThatMayNotRestartStaysRetired() {
        capture("JAB");
        jab().failure = "BACKEND_UNAVAILABLE";
        jab().finished = true;
        fails("BACKEND_UNAVAILABLE", send("snapshot").put("windowId", "100").put("backend", "JAB"));
        assertEquals(1, jabSessions.size());
        capture("UIA");
    }

    @Test void closingTheSessionClosesEveryBackend() {
        agent.close();
        assertTrue(uia().closed && jab().closed);
    }

    @Test void aSingleBackendSessionChecksANamedBackend() {
        Scripted only = new Scripted("JAB");
        Agent single = new Agent("JAB", only, pid -> true, Set.of());
        JsonNode reply = single.handle(send("snapshot").put("windowId", "100").put("backend", "JAB"));
        assertTrue(reply.path("ok").asBoolean());
        assertFalse(reply.get("result").has("backend"), "A single-backend reply keeps its shape.");
        assertEquals("BACKEND_UNAVAILABLE", single.handle(send("snapshot").put("windowId", "100")
                .put("backend", "UIA")).at("/error/code").asText());
        JsonNode windows = single.handle(send("listWindows"));
        assertFalse(windows.has("backends"));
        assertFalse(windows.at("/result/0").has("backends"));
    }
}
