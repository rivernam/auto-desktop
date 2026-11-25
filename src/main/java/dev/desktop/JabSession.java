package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;
import java.util.function.BooleanSupplier;

/**
 * Java Access Bridge session for AWT and Swing windows, confined to the thread of its constructor.
 * It reads names, roles, states and action names. It never reads text content or values.
 */
final class JabSession implements NativeSession {
    /** Bridge roles (en_US) with one clear counterpart in the shared role vocabulary. Others stay Custom. */
    private static final Map<String, String> ROLES = Map.ofEntries(
            Map.entry("push button", "Button"), Map.entry("toggle button", "Button"),
            Map.entry("check box", "CheckBox"), Map.entry("radio button", "RadioButton"),
            Map.entry("combo box", "ComboBox"), Map.entry("text", "Edit"), Map.entry("password text", "Edit"),
            Map.entry("label", "Text"), Map.entry("list", "List"), Map.entry("list item", "ListItem"),
            Map.entry("table", "Table"), Map.entry("tree", "Tree"), Map.entry("page tab list", "Tab"),
            Map.entry("page tab", "TabItem"), Map.entry("menu bar", "MenuBar"), Map.entry("popup menu", "Menu"),
            Map.entry("menu", "MenuItem"), Map.entry("menu item", "MenuItem"),
            Map.entry("check box menu item", "MenuItem"), Map.entry("radio button menu item", "MenuItem"),
            Map.entry("scroll bar", "ScrollBar"), Map.entry("slider", "Slider"),
            Map.entry("progress bar", "ProgressBar"), Map.entry("tool bar", "ToolBar"),
            Map.entry("tool tip", "ToolTip"), Map.entry("separator", "Separator"),
            Map.entry("hyperlink", "Hyperlink"), Map.entry("spinbox", "Spinner"),
            Map.entry("status bar", "StatusBar"), Map.entry("icon", "Image"), Map.entry("group box", "Group"),
            Map.entry("header", "Header"), Map.entry("column header", "HeaderItem"),
            Map.entry("row header", "HeaderItem"), Map.entry("frame", "Window"), Map.entry("dialog", "Window"),
            Map.entry("window", "Window"), Map.entry("internal frame", "Window"), Map.entry("panel", "Pane"),
            Map.entry("root pane", "Pane"), Map.entry("layered pane", "Pane"), Map.entry("glass pane", "Pane"),
            Map.entry("viewport", "Pane"), Map.entry("scroll pane", "Pane"), Map.entry("split pane", "Pane"),
            Map.entry("desktop pane", "Pane"), Map.entry("option pane", "Pane"));
    /** Roles whose single accessible action activates the control once, as Invoke does. */
    private static final Set<String> INVOKE_ROLES = Set.of("push button", "menu item");
    private static final String CLICK = "click"; // javax.accessibility.AccessibleAction.CLICK
    private static final String PASSWORD = "password text";

    private final JabApi bridge;
    private final Map<Integer, List<Long>> deferred = new HashMap<>();
    private Capture active;
    private boolean closed;

    private static final class Entry {
        private final long node;
        private final String key;
        private final Entry parent;
        private final Identity identity;

        private Entry(long node, String key, Entry parent, Identity identity) {
            this.node = node;
            this.key = key;
            this.parent = parent;
            this.identity = identity;
        }

        public long node() { return node; }
        public String key() { return key; }
        public Entry parent() { return parent; }
        public Identity identity() { return identity; }

        @Override public boolean equals(Object other) {
            if (this == other) return true;
            if (!(other instanceof Entry)) return false;
            Entry that = (Entry) other;
            return node == that.node
                    && Objects.equals(key, that.key)
                    && Objects.equals(parent, that.parent)
                    && Objects.equals(identity, that.identity);
        }
        @Override public int hashCode() { return Objects.hash(node, key, parent, identity); }
        @Override public String toString() {
            return "Entry[" + "node=" + node
                    + ", key=" + key
                    + ", parent=" + parent
                    + ", identity=" + identity + "]";
        }
    }
    private static final class Identity {
        private final String name;
        private final String role;
        private final String nativeRole;
        private final boolean clipped;

        private Identity(String name, String role, String nativeRole, boolean clipped) {
            this.name = name;
            this.role = role;
            this.nativeRole = nativeRole;
            this.clipped = clipped;
        }

        public String name() { return name; }
        public String role() { return role; }
        public String nativeRole() { return nativeRole; }
        public boolean clipped() { return clipped; }

        @Override public boolean equals(Object other) {
            if (this == other) return true;
            if (!(other instanceof Identity)) return false;
            Identity that = (Identity) other;
            return Objects.equals(name, that.name)
                    && Objects.equals(role, that.role)
                    && Objects.equals(nativeRole, that.nativeRole)
                    && clipped == that.clipped;
        }
        @Override public int hashCode() { return Objects.hash(name, role, nativeRole, clipped); }
        @Override public String toString() {
            return "Identity[" + "name=" + name
                    + ", role=" + role
                    + ", nativeRole=" + nativeRole
                    + ", clipped=" + clipped + "]";
        }
    }
    private static final class Info {
        private final Identity identity;
        private final boolean protect;
        private final boolean enabled;
        private final boolean offscreen;
        private final String invoke;
        private final boolean writable;
        private final int[] bounds;
        private final int children;

        private Info(Identity identity,
                     boolean protect,
                     boolean enabled,
                     boolean offscreen,
                     String invoke,
                     boolean writable,
                     int[] bounds,
                     int children) {
            this.identity = identity;
            this.protect = protect;
            this.enabled = enabled;
            this.offscreen = offscreen;
            this.invoke = invoke;
            this.writable = writable;
            this.bounds = bounds;
            this.children = children;
        }

        public Identity identity() { return identity; }
        public boolean protect() { return protect; }
        public boolean enabled() { return enabled; }
        public boolean offscreen() { return offscreen; }
        public String invoke() { return invoke; }
        public boolean writable() { return writable; }
        public int[] bounds() { return bounds; }
        public int children() { return children; }

        @Override public boolean equals(Object other) {
            if (this == other) return true;
            if (!(other instanceof Info)) return false;
            Info that = (Info) other;
            return Objects.equals(identity, that.identity)
                    && protect == that.protect
                    && enabled == that.enabled
                    && offscreen == that.offscreen
                    && Objects.equals(invoke, that.invoke)
                    && writable == that.writable
                    && Objects.equals(bounds, that.bounds)
                    && children == that.children;
        }
        @Override public int hashCode() { return Objects.hash(identity, protect, enabled, offscreen, invoke, writable, bounds, children); }
        @Override public String toString() {
            return "Info[" + "identity=" + identity
                    + ", protect=" + protect
                    + ", enabled=" + enabled
                    + ", offscreen=" + offscreen
                    + ", invoke=" + invoke
                    + ", writable=" + writable
                    + ", bounds=" + bounds
                    + ", children=" + children + "]";
        }
    }

    private final class Capture implements AutoCloseable {
        final String windowId;
        final long hwnd;
        final int pid;
        final int vm;
        final Map<String, Entry> entries = new HashMap<>();
        final Set<Long> owned = new LinkedHashSet<>();
        Entry window;
        Entry root;
        int visited;

        Capture(String windowId, long hwnd, int pid, int vm) {
            this.windowId = windowId;
            this.hwnd = hwnd;
            this.pid = pid;
            this.vm = vm;
        }

        void takePath(Capture previous, Entry scope) {
            for (Entry entry = scope; entry != null; entry = entry.parent()) {
                owned.add(entry.node());
                previous.owned.remove(entry.node());
            }
            window = previous.window;
        }

        /** Hands every handle back to the JVM, now or once it answers again. */
        @Override public void close() {
            if (!owned.isEmpty()) deferred.computeIfAbsent(vm, unused -> new ArrayList<>()).addAll(owned);
            owned.clear();
            entries.clear();
            releaseDeferred();
        }
    }

    /** Handles of closed captures whose JVM was not answering. A JVM that exited needs no release. */
    private void releaseDeferred() {
        var pending = deferred.entrySet().iterator();
        while (pending.hasNext()) {
            var entry = pending.next();
            List<Long> handles = entry.getValue();
            if (bridge.vmProcessId(entry.getKey()) == 0) handles.clear();
            else handles.subList(0, bridge.release(entry.getKey(), handles)).clear();
            if (handles.isEmpty()) pending.remove();
        }
    }

    JabSession() { this(System.getProperty(JabBridge.LIBRARY_PROPERTY)); }

    JabSession(String library) { this(open(library)); }

    JabSession(JabApi bridge) { this.bridge = bridge; }

    private static JabApi open(String library) {
        try {
            return JabBridge.open(library);
        } catch (JabBridge.Unavailable reason) {
            throw new AgentException("BACKEND_UNAVAILABLE", reason.getMessage());
        }
    }

    private static ObjectNode object() { return JsonNodeFactory.instance.objectNode(); }

    private void ready() {
        if (closed) throw unavailable();
        bridge.pump();
        releaseDeferred();
        // The library asks every JVM in turn about a window and waits seconds for one that is silent.
        if (bridge.anySilent()) throw silent();
    }

    @Override public void idle() {
        if (closed) return;
        bridge.pump();
        releaseDeferred();
    }

    /**
     * The bridge keeps a hidden window on this thread. A UI Automation client that walks the desktop
     * sends it messages and waits for the answer, so they are handled as they arrive.
     */
    @Override public void serve(BooleanSupplier done) {
        while (!closed && !done.getAsBoolean() && !Thread.currentThread().isInterrupted()) {
            bridge.pump();
            bridge.await(250);
        }
    }

    @Override public void wake() { bridge.wake(); }

    @Override public JsonNode capabilities() {
        try {
            return describeBridge();
        } catch (JabBridge.Silent waiting) {
            throw silent();
        }
    }

    private JsonNode describeBridge() {
        ready();
        int javaWindows = 0;
        int connected = 0;
        for (long hwnd : bridge.topLevelWindows(4096)) {
            boolean bridged = bridge.javaWindow(hwnd);
            if (bridged) connected++;
            if (bridged || bridge.javaWindowClass(hwnd)) javaWindows++;
        }
        ObjectNode caps = object().put("available", true).put("backend", "JAB")
                .put("physicalInput", false).put("screenshot", false);
        caps.putArray("operations").add("getCapabilities").add("listWindows").add("snapshot")
                .add("findElement").add("getElementInfo").add("invoke").add("setValue");
        // Java windows that no bridge-enabled JVM answers for cannot be read or operated here.
        caps.putObject("bridge").put("javaWindows", javaWindows).put("connectedWindows", connected);
        return caps;
    }

    @Override public JsonNode listWindows() {
        try {
            return windows();
        } catch (JabBridge.Silent waiting) {
            throw silent();
        }
    }

    private JsonNode windows() {
        ready();
        ArrayNode result = JsonNodeFactory.instance.arrayNode();
        int own = bridge.ownProcessId();
        for (long hwnd : bridge.topLevelWindows(4096)) {
            if (!bridge.javaWindow(hwnd)) continue;
            int pid = bridge.processId(hwnd);
            if (pid <= 0 || pid == own) continue;
            JabBridge.Root root = bridge.root(hwnd);
            if (root == null) continue;
            try {
                if (bridge.windowOf(root.vm(), root.context()) != hwnd) continue;
                JabBridge.ContextInfo info = bridge.info(root.vm(), root.context());
                if (info == null) continue;
                ObjectNode row = result.addObject().put("windowId", Long.toString(hwnd)).put("processId", pid)
                        .put("name", JnaUiaSession.clip(info.name()));
                long owner = bridge.ownerWindow(hwnd);
                // Swing gives ownerless dialogs a hidden shared owner. Only a window that can be listed is named.
                if (owner != 0 && bridge.visible(owner)) row.put("ownerWindowId", Long.toString(owner));
            } finally {
                bridge.release(root.vm(), root.context());
            }
        }
        return result;
    }

    /** The bridge context of a visible top-level Java window. The caller owns the returned context. */
    private JabBridge.Root window(long hwnd, int expectedPid) {
        if (!bridge.topLevel(hwnd)) throw missing();
        int pid = bridge.processId(hwnd);
        if (pid <= 0 || pid == bridge.ownProcessId() || (expectedPid != 0 && pid != expectedPid)) throw missing();
        JabBridge.Root root = bridge.javaWindow(hwnd) ? bridge.root(hwnd) : null;
        if (root == null) {
            if (bridge.javaWindowClass(hwnd)) throw new AgentException("BRIDGE_NOT_CONNECTED",
                    "The Java window has no Java Access Bridge connection. Enable the bridge in its JVM.");
            throw missing();
        }
        // The context must lead back to the same window, and the JVM that answered must be its process.
        boolean accepted = false;
        try {
            if (bridge.windowOf(root.vm(), root.context()) != hwnd) throw missing();
            int vmProcess = bridge.vmProcessId(root.vm());
            if (vmProcess != 0 && vmProcess != pid) throw missing();
            accepted = true;
            return root;
        } finally {
            if (!accepted) bridge.release(root.vm(), root.context());
        }
    }

    private static Set<String> states(String list) {
        var result = new java.util.HashSet<String>();
        for (String state : list.split(",")) {
            if (!state.isBlank()) result.add(state.trim());
        }
        return result;
    }

    /** Null when the bridge cannot read the context. */
    private Info inspect(int vm, long node) {
        JabBridge.ContextInfo raw = bridge.info(vm, node);
        if (raw == null) return null;
        String nativeRole = raw.role();
        Set<String> states = states(raw.states());
        boolean password = nativeRole.equals(PASSWORD);
        // The accessible name of a Java text component is its label. A password field stays unnamed.
        String name = password ? "" : raw.name();
        Identity identity = new Identity(JnaUiaSession.clip(name), ROLES.getOrDefault(nativeRole, "Custom"),
                JnaUiaSession.clip(nativeRole), name.length() > 256 || nativeRole.length() > 256
                        || raw.name().length() >= JabBridge.NAME_CHARS - 1);
        boolean writable = (password || nativeRole.equals("text")) && states.contains("editable");
        String invoke = raw.action() && INVOKE_ROLES.contains(nativeRole) ? invokeAction(bridge.actions(vm, node)) : null;
        int[] bounds = raw.width() > 0 && raw.height() > 0
                ? new int[]{raw.x(), raw.y(), raw.width(), raw.height()} : null;
        return new Info(identity, password, states.contains("enabled"), !states.contains("showing"), invoke,
                writable, bounds, Math.max(raw.children(), 0));
    }

    /**
     * The action that Invoke dispatches. A push button or menu item with one action is activated by it,
     * whatever its localized name. With several actions only an unambiguous "click" qualifies.
     */
    static String invokeAction(List<String> actions) {
        if (actions == null || actions.isEmpty()) return null;
        if (actions.size() == 1) return actions.get(0).isEmpty() ? null : actions.get(0);
        String found = null;
        for (String action : actions) {
            if (!action.equalsIgnoreCase(CLICK)) continue;
            if (found != null) return null;
            found = action;
        }
        return found;
    }

    private ObjectNode describe(Capture capture, Entry entry, Info info) {
        Identity id = info.identity();
        String parentKey = entry == capture.root ? null : entry.parent().key();
        ObjectNode row = object().put("key", entry.key()).put("parentKey", parentKey)
                .put("name", id.name()).put("role", id.role()).put("automationId", "").put("className", "")
                .put("nativeRole", id.nativeRole()).put("processId", capture.pid).put("enabled", info.enabled())
                .put("offscreen", info.offscreen()).put("backend", "JAB");
        var actions = row.putArray("actions");
        if (info.invoke() != null) actions.add("invoke");
        if (info.writable()) actions.add("setValue");
        if (id.role().equals("Edit")) row.put("setValueSupport", info.writable() ? "unverified" : "unsupported");
        int[] rect = info.bounds();
        if (rect == null) row.putNull("bounds");
        else row.putObject("bounds").put("x", rect[0]).put("y", rect[1]).put("width", rect[2]).put("height", rect[3]);
        return row;
    }

    @Override public JsonNode snapshot(String id, int maxDepth, int maxElements) {
        return capture(id, null, 0, maxDepth, maxElements);
    }

    @Override public JsonNode snapshotSubtree(String id, String key, int processId, int maxDepth, int maxElements) {
        return capture(id, Objects.requireNonNull(key), processId, maxDepth, maxElements);
    }

    private JsonNode capture(String id, String key, int pid, int maxDepth, int maxElements) {
        try {
            return read(id, key, pid, maxDepth, maxElements);
        } catch (JabBridge.Silent waiting) {
            throw silent();
        }
    }

    private JsonNode read(String id, String key, int pid, int maxDepth, int maxElements) {
        ready();
        Capture previous = active;
        active = null;
        Capture next = null;
        try {
            ObjectNode result = object().put("truncated", false);
            result.putArray("elements");
            long rootNode;
            Entry parent = null;
            try (previous) {
                if (maxDepth < 0 || maxDepth > 32 || maxElements < 1 || maxElements > 2000) throw precondition();
                if (key == null) {
                    long hwnd = JnaUiaSession.parseWindowId(id);
                    JabBridge.Root root = window(hwnd, 0);
                    next = new Capture(id, hwnd, bridge.processId(hwnd), root.vm());
                    rootNode = root.context();
                } else {
                    if (previous == null || !previous.windowId.equals(id)) throw stale();
                    Entry scope = resolve(previous, key, pid);
                    next = new Capture(id, previous.hwnd, previous.pid, previous.vm);
                    next.takePath(previous, scope);
                    rootNode = scope.node();
                    parent = scope.parent();
                }
            }
            if (visit(next, rootNode, parent, 0, maxDepth, maxElements, result) == null) throw stale();
            active = next;
            return result;
        } finally {
            if (next != null && active != next) next.close();
        }
    }

    /**
     * Takes ownership of node. Returns the row, or null when the bridge could not read the node and it
     * was omitted. A parent row records why its own subtree is incomplete.
     */
    private ObjectNode visit(Capture capture, long node, Entry parent, int depth, int maxDepth, int maxElements,
                             ObjectNode result) {
        capture.owned.add(node);
        capture.visited++;
        Info info = inspect(capture.vm, node);
        if (info == null) return null;
        Entry entry = new Entry(node, UUID.randomUUID().toString(), parent, info.identity());
        capture.entries.put(entry.key(), entry);
        if (depth == 0) capture.root = entry;
        if (parent == null) capture.window = entry;
        ObjectNode row = describe(capture, entry, info);
        result.withArray("elements").add(row);
        if (info.identity().clipped()) partial(result, row, "provider");
        if (info.protect()) return row;
        for (int index = 0; index < info.children(); index++) {
            if (depth >= maxDepth || capture.visited >= maxElements) {
                partial(result, row, "limit");
                break;
            }
            long child = bridge.child(capture.vm, node, index);
            if (child == 0 || visit(capture, child, entry, depth + 1, maxDepth, maxElements, result) == null)
                partial(result, row, "provider");
        }
        return row;
    }

    /** "limit" is the depth or element budget of the request. "provider" is a child the bridge did not deliver. */
    private static void partial(ObjectNode result, ObjectNode row, String reason) {
        result.put("truncated", true);
        row.put("partial", true);
        String known = row.path("partialReason").asText("");
        row.put("partialReason", known.isEmpty() || known.equals(reason) ? reason : "limit,provider");
    }

    /**
     * The captured element when its window, its JVM and every captured ancestor are still the same
     * objects. An accessible object that Swing creates per request cannot be proven and is refused.
     */
    private Entry resolve(Capture capture, String key, int pid) {
        if (capture == null) throw stale();
        Entry selected = capture.entries.get(key);
        if (selected == null || pid != capture.pid) throw stale();
        JabBridge.Root live;
        try {
            live = window(capture.hwnd, capture.pid);
        } catch (AgentException gone) {
            throw stale();
        }
        try {
            if (live.vm() != capture.vm || !bridge.same(capture.vm, live.context(), capture.window.node())) throw stale();
        } finally {
            bridge.release(live.vm(), live.context());
        }
        if (!matchesParents(capture, selected)) throw stale();
        return selected;
    }

    private boolean matchesParents(Capture capture, Entry selected) {
        Entry cursor = selected;
        List<Long> acquired = new ArrayList<>();
        try {
            long node = selected.node();
            while (cursor.parent() != null) {
                long parent = bridge.parent(capture.vm, node);
                if (parent == 0) return false;
                acquired.add(parent);
                cursor = cursor.parent();
                if (!bridge.same(capture.vm, parent, cursor.node())) return false;
                node = parent;
            }
            return cursor == capture.window;
        } finally {
            for (long parent : acquired) bridge.release(capture.vm, parent);
        }
    }

    @Override public JsonNode elementInfo(String key, int processId) {
        try {
            ready();
            Entry entry = resolve(active, key, processId);
            Info info = inspect(active.vm, entry.node());
            if (info == null) throw stale();
            return describe(active, entry, info);
        } catch (JabBridge.Silent waiting) {
            throw silent();
        }
    }

    @Override public JsonNode perform(DesktopAction action, String key, int processId, String value,
                                      Runnable beforeMutation) {
        if (action != DesktopAction.INVOKE && action != DesktopAction.SET_VALUE)
            throw new AgentException("PATTERN_UNSUPPORTED", "The action is unavailable for this Java object.");
        boolean[] dispatched = {false};
        try {
            return act(action, key, processId, value, () -> {
                beforeMutation.run();
                dispatched[0] = true;
            });
        } catch (JabBridge.Silent waiting) {
            // The request may have reached the application: a click that opens a modal dialog returns
            // only when the dialog closes, long after the library stopped waiting.
            if (dispatched[0]) throw new AgentException("ACTION_OUTCOME_UNKNOWN",
                    "The JVM did not answer the action. Inspect the target before retrying.");
            throw silent();
        }
    }

    private JsonNode act(DesktopAction action, String key, int processId, String value, Runnable beforeMutation) {
        ready();
        Entry entry = resolve(active, key, processId);
        Info info = inspect(active.vm, entry.node());
        if (info == null || entry.identity().clipped() || !entry.identity().equals(info.identity())) throw stale();
        if (!info.enabled() || info.offscreen() || action == null) throw precondition();
        boolean confirmed;
        if (action == DesktopAction.INVOKE) {
            if (info.invoke() == null) throw unsupported();
            if (!matchesParents(active, entry)) throw stale();
            confirmed = bridge.act(active.vm, entry.node(), info.invoke(), beforeMutation);
        } else {
            if (!info.identity().role().equals("Edit")) throw unsupported();
            // The bridge transports at most MAX_TEXT code units and ends the text at the first NUL.
            if (!info.writable() || value == null || value.length() > JabBridge.MAX_TEXT || value.indexOf('\0') >= 0)
                throw precondition();
            if (!matchesParents(active, entry)) throw stale();
            confirmed = bridge.setText(active.vm, entry.node(), value, beforeMutation);
        }
        // The bridge answers FALSE for a refusal and for a lost reply alike.
        if (!confirmed) throw new AgentException("ACTION_OUTCOME_UNKNOWN", "The provider did not confirm the action.");
        return object().put("performed", true);
    }

    @Override public void close() {
        if (closed) return;
        closed = true;
        try (Capture capture = active) { active = null; }
        finally { bridge.close(); }
    }

    private static AgentException precondition() {
        return new AgentException("PRECONDITION_FAILED", "The request or current element state does not permit this operation.");
    }
    private static AgentException unsupported() {
        return new AgentException("PATTERN_UNSUPPORTED", "The element does not provide this action through Java Access Bridge.");
    }
    private static AgentException stale() {
        return new AgentException("STALE_REFERENCE", "The captured element or its window is no longer current.");
    }
    private static AgentException missing() {
        return new AgentException("WINDOW_NOT_FOUND", "The requested top-level window is unavailable.");
    }
    private static AgentException silent() {
        return new AgentException("TARGET_NOT_RESPONDING",
                "A JVM is not answering Java Access Bridge. Retry when the application is responsive again.");
    }
    private static AgentException unavailable() {
        return new AgentException("BACKEND_UNAVAILABLE", "Java Access Bridge is not available in this session.");
    }
}
