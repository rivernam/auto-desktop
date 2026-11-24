package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.Set;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class ScopedLocatorTest {
    private static final String WINDOW = "window-1";
    private final ScopeDesktop desktop = new ScopeDesktop();
    private long nanos;
    private final Agent agent = new Agent(desktop, Set.of(42), Set.of("invoke"), () -> nanos);

    @Test void locatorIncludesTheScopeRootAndMatchesOnlyInsideTheScope() {
        JsonNode snapshot = result(capture());
        String left = ref(snapshot, 1);
        assertEquals(left, result(find(snapshot, left, "Editor")).path("ref").asText());
        assertEquals(ref(snapshot, 2), result(find(snapshot, left, "Save")).path("ref").asText());
        assertEquals(ref(snapshot, 4), result(find(snapshot, ref(snapshot, 3), "Save")).path("ref").asText());
        error("AMBIGUOUS_ELEMENT", find(snapshot, null, "Save"));
        error("ELEMENT_NOT_FOUND", find(snapshot, left, "Preview"));
        error("STALE_REFERENCE", find(snapshot, "foreign-ref", "Save"));
    }

    @Test void truncatedWindowCannotProveScopeCompletenessButFreshSubtreeCan() {
        desktop.truncated = true;
        JsonNode window = result(capture());
        String previous = ref(window, 1);
        error("INCOMPLETE_SNAPSHOT", find(window, previous, "Save"));

        JsonNode scope = result(capture().put("scopeRef", previous).put("maxDepth", 3).put("maxElements", 12));
        assertEquals(1, desktop.scopeCaptures);
        assertFalse(scope.path("truncated").asBoolean());
        assertEquals(WINDOW, scope.path("windowId").asText());
        assertTrue(scope.at("/elements/0/parentRef").isNull());
        String save = result(find(scope, null, "Save")).path("ref").asText();
        assertEquals(ref(scope, 1), save);
        error("STALE_REFERENCE", find(scope, previous, "Save"));
        error("STALE_REFERENCE", find(window, null, "Editor"));
        assertTrue(result(request("invoke").put("ref", save)).path("performed").asBoolean());
    }

    @Test void truncatedSubtreeCannotReturnAUniqueMatchOrAFalseNegative() {
        desktop.scopeTruncated = true;
        JsonNode window = result(capture());
        JsonNode scope = result(capture().put("scopeRef", ref(window, 1)).put("maxDepth", 3).put("maxElements", 12));
        assertTrue(scope.path("truncated").asBoolean());
        error("INCOMPLETE_SNAPSHOT", find(scope, null, "Save"));
        error("INCOMPLETE_SNAPSHOT", find(scope, ref(scope, 0), "Absent"));
    }

    @Test void markedPartialRowsLimitLookupToScopesThatWereCapturedWhole() {
        desktop.truncated = true;
        desktop.partial = Set.of("root", "right");
        JsonNode window = result(capture());
        assertTrue(window.path("truncated").asBoolean());
        assertTrue(window.at("/elements/0/partial").asBoolean());
        assertTrue(window.at("/elements/3/partial").asBoolean());
        for (int whole : new int[] {1, 2, 4}) assertFalse(window.path("elements").path(whole).has("partial"));

        // The left branch was captured whole, so a match or a miss inside it is conclusive.
        String left = ref(window, 1);
        assertEquals(ref(window, 2), result(find(window, left, "Save")).path("ref").asText());
        error("ELEMENT_NOT_FOUND", find(window, left, "Preview"));
        // A cut branch and the whole window can still hide a match.
        error("INCOMPLETE_SNAPSHOT", find(window, ref(window, 3), "Save"));
        error("INCOMPLETE_SNAPSHOT", find(window, ref(window, 0), "Editor"));
        error("INCOMPLETE_SNAPSHOT", find(window, null, "Editor"));
        // A duplicate already captured is reported before completeness, as for an unmarked snapshot.
        error("AMBIGUOUS_ELEMENT", find(window, null, "Save"));
    }

    @Test void partialMarkWithoutTruncationIsRejectedAsAnInconsistentCapture() {
        desktop.partial = Set.of("right");
        error("WORKER_PROTOCOL", capture());
        desktop.partial = Set.of();
        desktop.malformedPartial = true;
        error("WORKER_PROTOCOL", capture());
    }

    @Test void malformedWrongWindowExpiredOrForeignScopesNeverReachAdapter() {
        JsonNode window = result(capture());
        String previous = ref(window, 1);
        error("INVALID_REQUEST", capture().putNull("scopeRef"));
        error("INVALID_REQUEST", find(window, null, "Save").put("scopeRef", 12));
        error("STALE_REFERENCE", capture().put("windowId", "window-2").put("scopeRef", previous));
        error("STALE_REFERENCE", capture().put("scopeRef", "foreign-ref"));
        nanos += TimeUnit.MINUTES.toNanos(3);
        error("STALE_REFERENCE", capture().put("scopeRef", previous));
        assertEquals(0, desktop.scopeCaptures);
    }

    @Test void unsupportedScopedCapturePreservesCurrentSnapshotButBackendFailureInvalidatesIt() {
        JsonNode window = result(capture());
        String previous = ref(window, 1);
        ObjectNode scoped = capture().put("scopeRef", previous).put("maxDepth", 3).put("maxElements", 12);
        desktop.scopeFailure = "SNAPSHOT_SCOPE_UNSUPPORTED";
        error(desktop.scopeFailure, scoped);
        assertEquals(previous, result(find(window, null, "Editor")).path("ref").asText());
        desktop.scopeFailure = "STALE_REFERENCE";
        error(desktop.scopeFailure, scoped);
        error("STALE_REFERENCE", find(window, null, "Editor"));
    }

    private static ObjectNode request(String op) {
        return JsonNodeFactory.instance.objectNode().put("id", "request-" + op).put("op", op);
    }

    private static ObjectNode capture() {
        return request("snapshot").put("windowId", WINDOW);
    }

    private static String ref(JsonNode snapshot, int index) {
        return snapshot.path("elements").path(index).path("ref").asText();
    }

    private static ObjectNode find(JsonNode snapshot, String scope, String name) {
        ObjectNode request = request("findElement").put("snapshotId", snapshot.path("snapshotId").asText());
        if (scope != null) request.put("scopeRef", scope);
        request.putObject("locator").put("name", name);
        return request;
    }

    private JsonNode result(ObjectNode request) {
        JsonNode response = agent.handle(request);
        assertTrue(response.path("ok").asBoolean(), response::toString);
        return response.path("result");
    }

    private void error(String expected, ObjectNode request) {
        JsonNode response = agent.handle(request);
        assertEquals(expected, response.at("/error/code").textValue(), response::toString);
    }

    private static final class ScopeDesktop implements TypedDesktopAdapter {
        boolean truncated;
        boolean scopeTruncated;
        int scopeCaptures;
        String scopeFailure;
        Set<String> partial = Set.of();
        boolean malformedPartial;

        private ObjectNode row(String key, String parent, String name) {
            ObjectNode row = JsonNodeFactory.instance.objectNode().put("key", key).put("parentKey", parent)
                    .put("name", name).put("processId", 42).put("enabled", true);
            row.putArray("actions").add("invoke");
            if (partial.contains(key)) row.put("partial", true);
            if (malformedPartial) row.put("partial", "yes");
            return row;
        }

        @Override public JsonNode snapshot(String windowId, int depth, int limit) {
            ObjectNode result = JsonNodeFactory.instance.objectNode().put("truncated", truncated);
            result.putArray("elements").add(row("root", null, "Window"))
                    .add(row("left", "root", "Editor")).add(row("left-save", "left", "Save"))
                    .add(row("right", "root", "Preview")).add(row("right-save", "right", "Save"));
            return result;
        }

        @Override public JsonNode snapshotSubtree(String windowId, String key, int pid, int depth, int limit) {
            scopeCaptures++;
            assertEquals(WINDOW, windowId);
            assertEquals("left", key);
            assertEquals(42, pid);
            assertEquals(3, depth);
            assertEquals(12, limit);
            if (scopeFailure != null) throw new AgentException(scopeFailure, "Simulated capture error.");
            ObjectNode result = JsonNodeFactory.instance.objectNode().put("truncated", scopeTruncated);
            result.putArray("elements").add(row("new-left", null, "Editor"))
                    .add(row("new-save", "new-left", "Save"));
            return result;
        }

        @Override public JsonNode perform(DesktopAction action, String key, int pid, String value) {
            assertEquals("new-save", key);
            assertEquals(42, pid);
            return JsonNodeFactory.instance.objectNode().put("performed", true);
        }

        @Override public JsonNode capabilities() { throw new AssertionError(); }
        @Override public JsonNode listWindows() { throw new AssertionError(); }
        @Override public JsonNode elementInfo(String key, int processId) { throw new AssertionError(); }
        @Override public void close() {}
    }
}
