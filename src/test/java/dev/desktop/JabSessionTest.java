package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

/** The reference, completeness and action rules of the Java Access Bridge session against a scripted bridge. */
class JabSessionTest {
    private static final int VM = 4242;
    private static final int PID = 31;
    private static final long FRAME = 1001;

    private static final class Node {
        final String name;
        final String role;
        String states = "enabled,visible,showing";
        final List<Node> children = new ArrayList<>();
        final List<String> actions = new ArrayList<>();
        Node parent;
        boolean unreadable;
        // Swing builds list items, table cells and tree nodes anew for every request.
        boolean perRequest;

        Node(String name, String role, Node... children) {
            this.name = name;
            this.role = role;
            for (Node child : children) add(child);
        }

        Node add(Node child) {
            if (child != null) child.parent = this;
            children.add(child);
            return this;
        }

        Node states(String value) { states = value; return this; }
        Node actions(String... names) { actions.addAll(Arrays.asList(names)); return this; }
    }

    private static final class Bridge extends JabApi {
        final Map<Long, Node> windows = new LinkedHashMap<>();
        final Map<Long, Object[]> live = new HashMap<>();
        final List<String> performed = new ArrayList<>();
        final Set<Long> unbridgedJavaWindows = new java.util.HashSet<>();
        long nextHandle = 1;
        int acquired;
        boolean silent;
        boolean vmGone;
        boolean confirm = true;
        boolean silentDuringAction;
        boolean closed;

        private long handle(Node node) {
            if (node == null) return 0;
            acquired++;
            live.put(nextHandle, new Object[]{node, node.perRequest ? new Object() : node});
            return nextHandle++;
        }

        private Node node(long context) {
            Object[] held = live.get(context);
            if (held == null) throw new AssertionError("Use of a released or unknown handle " + context);
            return (Node) held[0];
        }

        @Override int pump() { return 0; }
        @Override boolean anySilent() { return silent && !vmGone; }
        @Override long[] topLevelWindows(int limit) {
            var all = new ArrayList<>(windows.keySet());
            all.addAll(unbridgedJavaWindows);
            return all.stream().mapToLong(Long::longValue).toArray();
        }
        @Override boolean topLevel(long hwnd) { return windows.containsKey(hwnd) || unbridgedJavaWindows.contains(hwnd); }
        @Override long ownerWindow(long hwnd) { return hwnd == FRAME + 1 ? FRAME : 0; }
        @Override boolean visible(long hwnd) { return topLevel(hwnd); }
        @Override int processId(long hwnd) { return topLevel(hwnd) ? PID : 0; }
        @Override int ownProcessId() { return 1; }
        @Override boolean javaWindowClass(long hwnd) { return topLevel(hwnd); }
        @Override boolean javaWindow(long hwnd) { return windows.containsKey(hwnd); }
        @Override JabBridge.Root root(long hwnd) {
            Node root = windows.get(hwnd);
            return root == null ? null : new JabBridge.Root(VM, handle(root));
        }
        @Override long windowOf(int vm, long context) {
            Node target = node(context);
            return windows.entrySet().stream().filter(entry -> entry.getValue() == target)
                    .map(Map.Entry::getKey).findFirst().orElse(0L);
        }
        @Override int vmProcessId(int vm) { return vmGone ? 0 : PID; }
        @Override void release(int vm, long context) {
            if (live.remove(context) == null) throw new AssertionError("Released twice or never acquired: " + context);
        }
        @Override int release(int vm, List<Long> contexts) {
            if (silent) return 0;
            for (long context : contexts) release(vm, context);
            return contexts.size();
        }
        @Override boolean same(int vm, long first, long second) { return live.get(first)[1] == live.get(second)[1]; }
        @Override JabBridge.ContextInfo info(int vm, long context) {
            Node node = node(context);
            if (node.unreadable) return null;
            return new JabBridge.ContextInfo(node.name, node.role, node.states, 0, node.children.size(), 10, 20, 30, 40,
                    !node.actions.isEmpty(), node.role.endsWith("text"));
        }
        @Override long child(int vm, long context, int index) { return handle(node(context).children.get(index)); }
        @Override long parent(int vm, long context) { return handle(node(context).parent); }
        @Override List<String> actions(int vm, long context) { return List.copyOf(node(context).actions); }
        @Override boolean act(int vm, long context, String action, Runnable beforeMutation) {
            beforeMutation.run();
            performed.add(node(context).name + ":" + action);
            if (silentDuringAction) throw new JabBridge.Silent();
            return confirm;
        }
        @Override boolean setText(int vm, long context, String value, Runnable beforeMutation) {
            beforeMutation.run();
            performed.add(node(context).name + "=" + value);
            return confirm;
        }
        @Override public void close() { closed = true; }
    }

    private final Bridge bridge = new Bridge();
    private final Node increment = new Node("Increment", "push button").actions("누르기");
    private final Node edit = new Node("Lot", "text").states("enabled,showing,editable");
    private final Node readOnly = new Node("Recipe", "text");
    private final Node password = new Node("Operator secret", "password text").states("enabled,showing,editable");
    private final Node panel = new Node("", "panel", increment, edit, readOnly, password);
    private final Node frame = new Node("Equipment", "frame", panel);
    private final JabSession session = new JabSession(bridge);

    JabSessionTest() { bridge.windows.put(FRAME, frame); }

    private static ObjectNode row(JsonNode snapshot, String name, String nativeRole) {
        for (JsonNode element : snapshot.get("elements")) {
            if (element.get("name").asText().equals(name) && element.get("nativeRole").asText().equals(nativeRole))
                return (ObjectNode) element;
        }
        throw new AssertionError("No row " + name + " / " + nativeRole);
    }

    private JsonNode snapshot() { return session.snapshot(Long.toString(FRAME), 32, 2000); }

    private static String code(Runnable call) {
        return assertThrows(AgentException.class, call::run).code();
    }

    @Test void everyHandleIsReleasedExactlyOnce() {
        session.listWindows();
        assertTrue(bridge.live.isEmpty(), "Listing keeps no reference in the JVM.");
        JsonNode first = snapshot();
        assertEquals(6, first.get("elements").size());
        assertEquals(6, bridge.live.size(), "One held reference for each captured element.");
        String key = row(first, "Increment", "push button").get("key").asText();
        session.elementInfo(key, PID);
        session.perform(DesktopAction.INVOKE, key, PID, null);
        assertEquals(6, bridge.live.size(), "Verification returns the parents it fetched.");
        snapshot();
        assertEquals(6, bridge.live.size(), "A new capture replaces the old references.");
        session.close();
        assertTrue(bridge.live.isEmpty());
        assertTrue(bridge.closed);
        assertTrue(bridge.acquired > 12);
    }

    @Test void rowsCarryTheSharedRoleAndTheBridgeRole() {
        JsonNode snapshot = snapshot();
        ObjectNode button = row(snapshot, "Increment", "push button");
        assertEquals("Button", button.get("role").asText());
        assertEquals("JAB", button.get("backend").asText());
        assertEquals("", button.get("automationId").asText());
        assertEquals("", button.get("className").asText());
        assertEquals(PID, button.get("processId").asInt());
        assertEquals("[\"invoke\"]", button.get("actions").toString());
        assertEquals(30, button.at("/bounds/width").asInt());
        assertEquals("Window", row(snapshot, "Equipment", "frame").get("role").asText());
        assertEquals("[\"setValue\"]", row(snapshot, "Lot", "text").get("actions").toString());
        assertEquals("[]", row(snapshot, "Recipe", "text").get("actions").toString(), "Read-only text offers no setValue.");
        frame.add(new Node("Gauge", "dial"));
        assertEquals("Custom", row(snapshot(), "Gauge", "dial").get("role").asText());
    }

    @Test void passwordFieldIsUnnamedAndItsChildrenAreNotRead() {
        password.add(new Node("typed secret", "label"));
        JsonNode snapshot = snapshot();
        ObjectNode field = row(snapshot, "", "password text");
        assertEquals("Edit", field.get("role").asText());
        assertEquals("[\"setValue\"]", field.get("actions").toString());
        for (JsonNode element : snapshot.get("elements")) {
            assertNotEquals("Operator secret", element.get("name").asText());
            assertNotEquals("typed secret", element.get("name").asText());
        }
    }

    @Test void invokeNeedsOneUnambiguousAction() {
        assertEquals("누르기", JabSession.invokeAction(List.of("누르기")));
        assertEquals("click", JabSession.invokeAction(List.of("togglePopup", "click")));
        assertNull(JabSession.invokeAction(List.of("expand", "collapse")), "The first action is never assumed to be a click.");
        assertNull(JabSession.invokeAction(List.of("click", "Click")));
        assertNull(JabSession.invokeAction(List.of()));
        assertNull(JabSession.invokeAction(null));
        Node toggle = new Node("Alarm", "check box").actions("click");
        frame.add(toggle);
        assertEquals("[]", row(snapshot(), "Alarm", "check box").get("actions").toString(),
                "Toggling is not Invoke. The role is reported and no action is offered.");
    }

    @Test void limitsAndProviderGapsAreMarkedWithTheirCause() {
        panel.add(null); // The bridge delivers no context for this child.
        JsonNode gap = snapshot();
        assertTrue(gap.get("truncated").asBoolean());
        ObjectNode holder = row(gap, "", "panel");
        assertTrue(holder.get("partial").asBoolean());
        assertEquals("provider", holder.get("partialReason").asText());
        assertFalse(row(gap, "Equipment", "frame").has("partial"), "Only the element whose own subtree is cut is marked.");

        panel.children.remove(panel.children.size() - 1);
        JsonNode cut = session.snapshot(Long.toString(FRAME), 32, 3);
        assertEquals(3, cut.get("elements").size());
        assertEquals("limit", row(cut, "", "panel").get("partialReason").asText());

        JsonNode shallow = session.snapshot(Long.toString(FRAME), 1, 2000);
        assertEquals("limit", row(shallow, "", "panel").get("partialReason").asText());

        Node broken = new Node("Broken", "panel");
        broken.unreadable = true;
        frame.add(broken);
        assertEquals("provider", row(snapshot(), "Equipment", "frame").get("partialReason").asText());
        session.close();
        assertTrue(bridge.live.isEmpty(), "Omitted children are released as well.");
    }

    @Test void aLimitAndAProviderGapOnOneElementAreBothNamed() {
        panel.children.add(0, null);
        JsonNode snapshot = session.snapshot(Long.toString(FRAME), 32, 4);
        assertEquals("limit,provider", row(snapshot, "", "panel").get("partialReason").asText());
    }

    @Test void aRemovedOrReplacedControlIsStale() {
        String key = row(snapshot(), "Increment", "push button").get("key").asText();
        panel.children.remove(increment);
        increment.parent = null;
        Node replacement = new Node("Increment", "push button").actions("누르기");
        panel.add(replacement);
        assertEquals("STALE_REFERENCE", code(() -> session.perform(DesktopAction.INVOKE, key, PID, null)));
        assertEquals("STALE_REFERENCE", code(() -> session.elementInfo(key, PID)));
        assertTrue(bridge.performed.isEmpty(), "The same name at the same position is not the same control.");
    }

    @Test void anObjectBuiltPerRequestCannotBeProvenAndIsRefused() {
        Node item = new Node("Item one", "label");
        Node leaf = new Node("Crate", "label");
        item.perRequest = true;
        item.add(leaf);
        panel.add(new Node("Items", "list", item));
        JsonNode snapshot = snapshot();
        String itemKey = row(snapshot, "Item one", "label").get("key").asText();
        String leafKey = row(snapshot, "Crate", "label").get("key").asText();
        assertEquals("Item one", session.elementInfo(itemKey, PID).get("name").asText(),
                "Its parent, the list, is a lasting object.");
        assertEquals("STALE_REFERENCE", code(() -> session.elementInfo(leafKey, PID)));
    }

    @Test void aChangedWindowJvmOrProcessIsStale() {
        String key = row(snapshot(), "Increment", "push button").get("key").asText();
        assertEquals("STALE_REFERENCE", code(() -> session.elementInfo(key, PID + 1)));
        assertEquals("STALE_REFERENCE", code(() -> session.elementInfo("unknown", PID)));
        bridge.windows.put(FRAME, new Node("Equipment", "frame", panel));
        assertEquals("STALE_REFERENCE", code(() -> session.perform(DesktopAction.INVOKE, key, PID, null)));
        bridge.windows.remove(FRAME);
        assertEquals("STALE_REFERENCE", code(() -> session.elementInfo(key, PID)));
        assertEquals("WINDOW_NOT_FOUND", code(this::snapshot));
        assertTrue(bridge.performed.isEmpty());
    }

    @Test void aChangedIdentityOrStateStopsTheAction() {
        JsonNode snapshot = snapshot();
        String button = row(snapshot, "Increment", "push button").get("key").asText();
        String lot = row(snapshot, "Lot", "text").get("key").asText();
        String recipe = row(snapshot, "Recipe", "text").get("key").asText();
        assertEquals("PATTERN_UNSUPPORTED", code(() -> session.perform(DesktopAction.SET_VALUE, button, PID, "x")));
        assertEquals("PATTERN_UNSUPPORTED", code(() -> session.perform(DesktopAction.INVOKE, lot, PID, null)));
        assertEquals("PRECONDITION_FAILED", code(() -> session.perform(DesktopAction.SET_VALUE, recipe, PID, "x")));
        assertEquals("PRECONDITION_FAILED", code(() -> session.perform(DesktopAction.SET_VALUE, lot, PID,
                "x".repeat(JabBridge.MAX_TEXT + 1))), "The bridge cannot carry a longer text.");
        assertEquals("PRECONDITION_FAILED", code(() -> session.perform(DesktopAction.SET_VALUE, lot, PID, "a\0b")));
        increment.states = "visible,showing";
        assertEquals("PRECONDITION_FAILED", code(() -> session.perform(DesktopAction.INVOKE, button, PID, null)));
        increment.states = "enabled,visible";
        assertEquals("PRECONDITION_FAILED", code(() -> session.perform(DesktopAction.INVOKE, button, PID, null)));
        increment.states = "enabled,visible,showing";
        increment.actions.add("second");
        assertEquals("PATTERN_UNSUPPORTED", code(() -> session.perform(DesktopAction.INVOKE, button, PID, null)));
        assertTrue(bridge.performed.isEmpty());

        increment.actions.remove("second");
        session.perform(DesktopAction.SET_VALUE, lot, PID, "");
        session.perform(DesktopAction.SET_VALUE, lot, PID, "한글 😀");
        session.perform(DesktopAction.SET_VALUE, lot, PID, "x".repeat(JabBridge.MAX_TEXT));
        assertEquals(List.of("Lot=", "Lot=한글 😀", "Lot=" + "x".repeat(JabBridge.MAX_TEXT)), bridge.performed);
    }

    @Test void anUnconfirmedActionIsReportedAsUnknownAndNeverRepeated() {
        JsonNode snapshot = snapshot();
        String button = row(snapshot, "Increment", "push button").get("key").asText();
        String lot = row(snapshot, "Lot", "text").get("key").asText();
        bridge.confirm = false;
        assertEquals("ACTION_OUTCOME_UNKNOWN", code(() -> session.perform(DesktopAction.INVOKE, button, PID, null)));
        assertEquals("ACTION_OUTCOME_UNKNOWN", code(() -> session.perform(DesktopAction.SET_VALUE, lot, PID, "x")));
        assertEquals(List.of("Increment:누르기", "Lot=x"), bridge.performed);
    }

    @Test void aSilentJvmIsReportedWithoutLosingTheSessionOrItsReferences() {
        String key = row(snapshot(), "Increment", "push button").get("key").asText();
        bridge.silentDuringAction = true;
        assertEquals("ACTION_OUTCOME_UNKNOWN", code(() -> session.perform(DesktopAction.INVOKE, key, PID, null)),
                "The click reached the application before the JVM stopped answering.");
        bridge.silentDuringAction = false;
        bridge.silent = true;
        assertEquals("TARGET_NOT_RESPONDING", code(session::listWindows));
        assertEquals("TARGET_NOT_RESPONDING", code(session::capabilities));
        assertEquals("TARGET_NOT_RESPONDING", code(this::snapshot));
        assertEquals("TARGET_NOT_RESPONDING", code(() -> session.elementInfo(key, PID)));
        assertEquals("TARGET_NOT_RESPONDING", code(() -> session.perform(DesktopAction.INVOKE, key, PID, null)));
        assertEquals(1, bridge.performed.size());
        assertEquals(6, bridge.live.size(), "Nothing is released into a JVM that cannot take the message.");

        bridge.silent = false;
        assertEquals("Increment", session.elementInfo(key, PID).get("name").asText(), "The capture survives the wait.");
        snapshot();
        assertEquals(6, bridge.live.size());
    }

    @Test void referencesOfASilentJvmAreReleasedOnceItAnswersOrDroppedWhenItExits() {
        snapshot();
        bridge.silent = true;
        session.close();
        assertEquals(6, bridge.live.size(), "Closing does not block on the silent JVM.");

        var second = new Bridge();
        second.windows.put(FRAME, frame);
        var other = new JabSession(second);
        other.snapshot(Long.toString(FRAME), 32, 2000);
        second.silent = true;
        assertEquals("TARGET_NOT_RESPONDING", code(() -> other.snapshot(Long.toString(FRAME), 32, 2000)));
        second.silent = false;
        other.idle();
        assertEquals(6, second.live.size(), "The failed request kept the current capture.");
        other.snapshot(Long.toString(FRAME), 32, 2000);
        second.vmGone = true;
        other.close();
        assertEquals(6, second.live.size(), "No message is sent to a JVM that exited.");
    }

    @Test void aScopedCaptureKeepsThePathToItsWindow() {
        JsonNode whole = snapshot();
        String panelKey = row(whole, "", "panel").get("key").asText();
        JsonNode scoped = session.snapshotSubtree(Long.toString(FRAME), panelKey, PID, 32, 2000);
        assertEquals(5, scoped.get("elements").size());
        assertTrue(scoped.get("elements").get(0).get("parentKey").isNull());
        assertEquals(6, bridge.live.size(), "The window stays referenced for later verification.");
        String key = row(scoped, "Increment", "push button").get("key").asText();
        session.perform(DesktopAction.INVOKE, key, PID, null);
        assertEquals(List.of("Increment:누르기"), bridge.performed);
        assertEquals("STALE_REFERENCE", code(() -> session.snapshotSubtree(Long.toString(FRAME), panelKey, PID, 32, 2000)),
                "A key of the replaced capture no longer resolves.");
    }

    @Test void windowsAreListedWithTheirOwnerAndUnbridgedJavaWindowsAreNamed() {
        bridge.windows.put(FRAME + 1, new Node("Confirm", "dialog"));
        bridge.unbridgedJavaWindows.add(2002L);
        JsonNode windows = session.listWindows();
        assertEquals(2, windows.size());
        assertEquals("Equipment", windows.get(0).get("name").asText());
        assertFalse(windows.get(0).has("ownerWindowId"));
        assertEquals(Long.toString(FRAME), windows.get(1).get("ownerWindowId").asText());
        JsonNode caps = session.capabilities();
        assertEquals("JAB", caps.get("backend").asText());
        assertEquals(3, caps.at("/bridge/javaWindows").asInt());
        assertEquals(2, caps.at("/bridge/connectedWindows").asInt());
        assertEquals("BRIDGE_NOT_CONNECTED", code(() -> session.snapshot("2002", 32, 2000)));
        assertEquals("WINDOW_NOT_FOUND", code(() -> session.snapshot("3003", 32, 2000)));
        assertTrue(bridge.live.isEmpty());
    }

    @Test void theSharedCoreFindsOperatesAndIsolatesBridgeElements() {
        var agent = new Agent(session, Set.of(PID), Set.of("invoke", "setValue"));
        ObjectNode snapshot = ok(agent, request("snapshot").put("windowId", Long.toString(FRAME)));
        ObjectNode find = request("findElement").put("snapshotId", snapshot.get("snapshotId").asText());
        find.putObject("locator").put("name", "Increment").put("role", "Button");
        ObjectNode button = ok(agent, find);
        assertEquals("push button", button.get("nativeRole").asText());
        ObjectNode reply = ok(agent, request("invoke").put("ref", button.get("ref").asText()));
        assertTrue(reply.get("performed").asBoolean());
        assertFalse(reply.get("effectVerified").asBoolean(), "A bridge reply says nothing about the application.");
        assertEquals(List.of("Increment:누르기"), bridge.performed);

        var uia = new Agent(new JnaDesktopAdapter(() -> { throw new IllegalStateException(); },
                java.time.Duration.ofSeconds(1)), Set.of(PID), Set.of("invoke"));
        ObjectNode foreign = uia.handle(request("invoke").put("ref", button.get("ref").asText()));
        assertEquals("STALE_REFERENCE", foreign.at("/error/code").asText(), "A reference means nothing to another backend.");

        ObjectNode denied = new Agent(session, Set.of(PID + 1), Set.of("invoke"))
                .handle(request("snapshot").put("windowId", Long.toString(FRAME)));
        assertTrue(denied.get("ok").asBoolean(), "Reading needs no allowed process.");
    }

    @Test void theSharedCoreRefusesOtherProcessesAndRepeatedCommands() {
        var readOnlyAgent = new Agent(session, Set.of(PID + 1), Set.of("invoke"));
        ObjectNode snapshot = ok(readOnlyAgent, request("snapshot").put("windowId", Long.toString(FRAME)));
        String ref = null;
        for (JsonNode element : snapshot.get("elements")) {
            if (element.get("name").asText().equals("Increment")) ref = element.get("ref").asText();
        }
        assertEquals("PERMISSION_DENIED", readOnlyAgent.handle(request("invoke").put("ref", ref)).at("/error/code").asText());

        var agent = new Agent(session, Set.of(PID), Set.of("invoke"));
        snapshot = ok(agent, request("snapshot").put("windowId", Long.toString(FRAME)));
        for (JsonNode element : snapshot.get("elements")) {
            if (element.get("name").asText().equals("Increment")) ref = element.get("ref").asText();
        }
        ObjectNode command = request("invoke").put("ref", ref);
        assertTrue(agent.handle(command).get("ok").asBoolean());
        assertEquals("DUPLICATE_COMMAND", agent.handle(command).at("/error/code").asText());
        assertEquals(1, bridge.performed.size());
    }

    private static int sequence;

    private static ObjectNode request(String op) {
        return JsonNodeFactory.instance.objectNode().put("id", "r" + ++sequence).put("op", op);
    }

    private static ObjectNode ok(Agent agent, ObjectNode request) {
        ObjectNode reply = agent.handle(request);
        assertTrue(reply.get("ok").asBoolean(), reply.toString());
        return (ObjectNode) reply.get("result");
    }
}
