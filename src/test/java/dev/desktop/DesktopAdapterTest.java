package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.ArrayList;
import java.util.List;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class DesktopAdapterTest {
    private static final ObjectMapper JSON = new ObjectMapper();

    @Test void existingWorkerReceivesExactRequestForEachTypedOperation() throws Exception {
        var received = new ArrayList<ObjectNode>();
        JsonNode result = JSON.createArrayNode().add("result");
        DesktopAdapter worker = new DesktopAdapter() {
            @Override public JsonNode call(ObjectNode request) {
                received.add(request);
                return result;
            }
            @Override public void close() {}
        };

        assertSame(result, worker.capabilities());
        assertSame(result, worker.listWindows());
        assertSame(result, worker.snapshot("17", 3, 100));
        assertSame(result, worker.elementInfo("item", 42));
        assertSame(result, worker.perform(DesktopAction.INVOKE, "item", 42, null));
        assertSame(result, worker.perform(DesktopAction.SET_VALUE, "item", 42, ""));

        assertEquals(List.of(
                JSON.readTree("{\"op\":\"getCapabilities\"}"),
                JSON.readTree("{\"op\":\"listWindows\"}"),
                JSON.readTree("{\"op\":\"snapshot\",\"windowId\":\"17\",\"maxDepth\":3,\"maxElements\":100}"),
                JSON.readTree("{\"op\":\"getElementInfo\",\"key\":\"item\",\"processId\":42}"),
                JSON.readTree("{\"op\":\"invoke\",\"key\":\"item\",\"processId\":42}"),
                JSON.readTree("{\"op\":\"setValue\",\"key\":\"item\",\"processId\":42,\"value\":\"\"}")
        ), received);
    }

    /** A provider whose implementation has no dependency on the worker message shape. */
    private static final class NativeProvider implements TypedDesktopAdapter {
        @Override public JsonNode capabilities() { return JSON.valueToTree("capabilities"); }
        @Override public JsonNode listWindows() { return JSON.valueToTree("windows"); }
        @Override public JsonNode snapshot(String windowId, int depth, int limit) {
            return JSON.createArrayNode().add(windowId).add(depth).add(limit);
        }
        @Override public JsonNode elementInfo(String key, int pid) {
            return JSON.createArrayNode().add(key).add(pid);
        }
        @Override public JsonNode perform(DesktopAction action, String key, int pid, String value) {
            return JSON.createArrayNode().add(action.wireName()).add(key).add(pid).add(value);
        }
        @Override public void close() {}
    }

    @Test void rawCallerReachesTypedNativeProvider() {
        DesktopAdapter nativeProvider = new NativeProvider();
        var request = JSON.createObjectNode();
        assertEquals("capabilities", nativeProvider.call(request.put("op", "getCapabilities")).asText());
        assertEquals("windows", nativeProvider.call(request.put("op", "listWindows")).asText());
        assertEquals(JSON.createArrayNode().add("window").add(2).add(50),
                nativeProvider.call(request.put("op", "snapshot").put("windowId", "window")
                        .put("maxDepth", 2).put("maxElements", 50)));
        request = JSON.createObjectNode().put("key", "field").put("processId", 7);
        assertEquals(JSON.createArrayNode().add("field").add(7),
                nativeProvider.call(request.put("op", "getElementInfo")));
        assertEquals(JSON.createArrayNode().add("invoke").add("field").add(7).addNull(),
                nativeProvider.call(request.put("op", "invoke")));
        assertEquals(JSON.createArrayNode().add("setValue").add("field").add(7).add(""),
                nativeProvider.call(request.put("op", "setValue").put("value", "")));
    }

    @Test void malformedRawRequestsFailBeforeNativeDispatch() throws Exception {
        DesktopAdapter nativeProvider = new NativeProvider();
        for (String json : List.of("{}", "{\"op\":3}", "{\"op\":\"snapshot\",\"windowId\":17}",
                "{\"op\":\"invoke\",\"key\":\"k\",\"processId\":2.3}",
                "{\"op\":\"setValue\",\"key\":\"k\",\"processId\":2}")) {
            ObjectNode request = (ObjectNode) JSON.readTree(json);
            var failure = assertThrows(AgentException.class, () -> nativeProvider.call(request));
            assertEquals("INVALID_REQUEST", failure.code());
        }
        var unknown = JSON.createObjectNode().put("op", "missing");
        assertEquals("UNKNOWN_OPERATION", assertThrows(AgentException.class,
                () -> nativeProvider.call(unknown)).code());
    }
}
