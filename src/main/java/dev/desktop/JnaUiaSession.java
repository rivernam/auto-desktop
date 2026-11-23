package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.Arrays;
import java.util.HashMap;
import java.util.LinkedHashSet;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.UUID;

/** UI Automation session confined to the COM apartment of its constructor. */
final class JnaUiaSession implements TypedDesktopAdapter {
    private static final int ELEMENT_NOT_AVAILABLE = 0x80040201;
    private static final int UIA_TIMEOUT = 0x80131505;
    private static final int RPC_TIMEOUT = 0x8001011f;
    private static final int WIN32_TIMEOUT = 0x800705b4;
    private static final String[] TYPES = {
        "Button", "Calendar", "CheckBox", "ComboBox", "Edit", "Hyperlink", "Image", "ListItem", "List",
        "Menu", "MenuBar", "MenuItem", "ProgressBar", "RadioButton", "ScrollBar", "Slider", "Spinner",
        "StatusBar", "Tab", "TabItem", "Text", "ToolBar", "ToolTip", "Tree", "TreeItem", "Custom",
        "Group", "Thumb", "DataGrid", "DataItem", "Document", "SplitButton", "Window", "Pane",
        "Header", "HeaderItem", "Table", "TitleBar", "Separator", "SemanticZoom", "AppBar"
    };
    private final UiaCom com = UiaCom.open();
    private Capture active;
    private boolean closed;

    private record Entry(UiaCom.Ref node, String key, Entry parent, int pid, int[] runtime, Identity identity) {}
    private record Identity(String name, String role, String automationId, String className, boolean clipped) {}
    private record Info(Identity identity, boolean protect, boolean enabled, boolean offscreen,
                        boolean invoke, boolean writable, int[] bounds, int pid) {}

    private static final class Capture implements AutoCloseable {
        final String windowId;
        final Map<String, Entry> entries = new HashMap<>();
        final Set<UiaCom.Ref> owned = new LinkedHashSet<>();
        Entry window;
        Entry root;
        int visited;

        Capture(String windowId) { this.windowId = windowId; }

        void takePath(Capture previous, Entry scope) {
            for (Entry entry = scope; entry != null; entry = entry.parent()) {
                owned.add(entry.node());
                previous.owned.remove(entry.node());
            }
            window = previous.window;
        }

        @Override public void close() {
            RuntimeException failure = null;
            for (UiaCom.Ref ref : owned) {
                try { ref.close(); }
                catch (RuntimeException releaseFailure) {
                    if (failure == null) failure = releaseFailure;
                    else failure.addSuppressed(releaseFailure);
                }
            }
            owned.clear();
            entries.clear();
            if (failure != null) throw failure;
        }
    }

    private static ObjectNode object() { return JsonNodeFactory.instance.objectNode(); }

    private UiaCom.Ref desktop() {
        if (closed) throw unavailable();
        try {
            com.checkDesktop();
            UiaCom.Ref root = com.root();
            if (root == null) throw unavailable();
            return root;
        } catch (UiaCom.ComFailure failure) {
            propagateTimeout(failure);
            throw unavailable();
        }
    }

    @Override public JsonNode capabilities() {
        try (UiaCom.Ref root = desktop(); UiaCom.Ref first = com.firstChild(root)) {
            int[] runtime = com.runtimeId(root);
            if (runtime == null || runtime.length == 0) throw unavailable();
            ObjectNode caps = object().put("available", true).put("backend", "UIA")
                    .put("physicalInput", false).put("screenshot", false);
            caps.putArray("operations").add("getCapabilities").add("listWindows").add("snapshot")
                    .add("findElement").add("getElementInfo").add("invoke").add("setValue");
            return caps;
        } catch (RuntimeException failure) {
            propagateTimeout(failure);
            return DesktopCapabilities.unavailable("UIA", "UI Automation could not access the interactive desktop.");
        }
    }

    @Override public JsonNode listWindows() {
        for (int attempt = 0; attempt < 2; attempt++) {
            try (UiaCom.Ref root = desktop()) {
                return windows(root);
            } catch (UiaCom.ComFailure failure) {
                propagateTimeout(failure);
                if (failure.hresult != ELEMENT_NOT_AVAILABLE) throw unavailable();
            }
        }
        throw stale();
    }

    private JsonNode windows(UiaCom.Ref desktop) {
        var result = JsonNodeFactory.instance.arrayNode();
        UiaCom.Ref node = com.firstChild(desktop);
        int visited = 0;
        try {
            while (node != null) {
                if (++visited > 4096) throw precondition();
                long handle = com.hwnd(node);
                int pid = com.pid(node);
                if (handle != 0 && pid > 0) {
                    boolean masked = com.password(node) || com.controlType(node) == 50004;
                    if (!masked) {
                        try (UiaCom.Ref pattern = com.valuePattern(node)) { masked = pattern != null; }
                    }
                    result.addObject().put("windowId", Long.toString(handle)).put("processId", pid)
                            .put("name", masked ? "" : clip(com.name(node)));
                }
                UiaCom.Ref next = com.nextSibling(node);
                node.close();
                node = next;
            }
        } finally {
            if (node != null) node.close();
        }
        return result;
    }

    static String role(int typeId) {
        int index = typeId - 50000;
        return index >= 0 && index < TYPES.length ? TYPES[index] : "Custom";
    }

    static String clip(String text) {
        if (text == null) return "";
        if (text.length() <= 256) return text;
        return text.substring(0, Character.isHighSurrogate(text.charAt(255)) ? 255 : 256);
    }

    private static boolean clipped(String text) { return text != null && text.length() > 256; }

    static long parseWindowId(String id) {
        if (id == null || id.isEmpty() || id.length() > 10 || id.charAt(0) == '0') throw missing();
        for (int i = 0; i < id.length(); i++)
            if (id.charAt(i) < '0' || id.charAt(i) > '9') throw missing();
        long handle = Long.parseLong(id);
        if (handle > 0xffffffffL) throw missing();
        return handle;
    }

    private UiaCom.Ref window(String id, UiaCom.Ref desktop) {
        long handle = parseWindowId(id);
        UiaCom.Ref node = null;
        boolean retained = false;
        try {
            node = com.fromHandle(handle);
            if (node == null || com.hwnd(node) != handle) throw missing();
            try (UiaCom.Ref parent = com.parent(node)) {
                if (parent == null || !com.same(parent, desktop)) throw missing();
            }
            retained = true;
            return node;
        } catch (UiaCom.ComFailure failure) {
            propagateTimeout(failure);
            throw missing();
        } finally {
            if (!retained && node != null) node.close();
        }
    }

    private Info inspect(UiaCom.Ref node) {
        try (UiaCom.Ref invoke = com.invokePattern(node); UiaCom.Ref value = com.valuePattern(node)) {
            String role = role(com.controlType(node));
            boolean protect = com.password(node) || role.equals("Edit") || value != null;
            String name = protect ? "" : com.name(node);
            String automationId = com.automationId(node);
            String className = com.className(node);
            Identity id = new Identity(clip(name), role, clip(automationId), clip(className),
                    clipped(name) || clipped(automationId) || clipped(className));
            return new Info(id, protect, com.enabled(node), com.offscreen(node),
                    invoke != null, value != null && !com.readOnly(value), com.bounds(node), com.pid(node));
        }
    }

    private ObjectNode describe(Capture capture, Entry entry, Info info) {
        Identity id = info.identity();
        String parentKey = entry == capture.root ? null : entry.parent().key();
        ObjectNode row = object().put("key", entry.key()).put("parentKey", parentKey)
                .put("name", id.name()).put("role", id.role()).put("automationId", id.automationId())
                .put("className", id.className()).put("processId", info.pid()).put("enabled", info.enabled())
                .put("offscreen", info.offscreen()).put("backend", "UIA");
        var actions = row.putArray("actions");
        if (info.invoke()) actions.add("invoke");
        if (info.writable()) actions.add("setValue");
        int[] rect = info.bounds();
        if (rect == null || rect.length != 4 || rect[2] <= rect[0] || rect[3] <= rect[1]) {
            row.putNull("bounds");
        } else {
            row.putObject("bounds").put("x", rect[0]).put("y", rect[1])
                    .put("width", (long)rect[2] - rect[0]).put("height", (long)rect[3] - rect[1]);
        }
        return row;
    }

    @Override public JsonNode snapshot(String id, int maxDepth, int maxElements) {
        return capture(id, null, 0, maxDepth, maxElements);
    }

    @Override public JsonNode snapshotSubtree(String id, String key, int processId, int maxDepth, int maxElements) {
        return capture(id, Objects.requireNonNull(key), processId, maxDepth, maxElements);
    }

    private JsonNode capture(String id, String key, int pid, int maxDepth, int maxElements) {
        Capture previous = active;
        active = null;
        var next = new Capture(id);
        try {
            ObjectNode result = object().put("truncated", false);
            result.putArray("elements");
            UiaCom.Ref root;
            Entry parent = null;
            try (previous) {
                if (maxDepth < 0 || maxDepth > 32 || maxElements < 1 || maxElements > 2000) throw precondition();
                try (UiaCom.Ref desktop = desktop()) {
                    if (key == null) {
                        root = window(id, desktop);
                        next.owned.add(root);
                    } else {
                        if (previous == null || !previous.windowId.equals(id)) throw stale();
                        Entry scope = resolve(previous, key, pid, desktop, true);
                        next.takePath(previous, scope);
                        root = scope.node();
                        parent = scope.parent();
                    }
                }
            }
            try {
                visit(next, root, parent, 0, maxDepth, maxElements, result);
            } catch (RuntimeException failure) {
                propagateTimeout(failure);
                throw stale();
            }
            active = next;
            return result;
        } finally {
            if (active != next) next.close();
        }
    }

    /** Takes ownership of node on entry, including when a provider call fails. */
    private void visit(Capture capture, UiaCom.Ref node, Entry parent, int depth, int maxDepth, int maxElements,
                       ObjectNode result) {
        capture.owned.add(node);
        capture.visited++;
        Info info = inspect(node);
        int[] runtime = com.runtimeId(node);
        if (info.pid() <= 0) throw stale();
        // Some providers return a valid, empty SAFEARRAY for virtual children.
        // No stable reference can be issued, and the omitted branch makes lookup incomplete.
        if (runtime.length == 0) {
            if (depth == 0) throw stale();
            result.put("truncated", true);
            return;
        }
        Entry entry = new Entry(node, UUID.randomUUID().toString(), parent, info.pid(), runtime, info.identity());
        capture.entries.put(entry.key(), entry);
        if (depth == 0) capture.root = entry;
        if (parent == null) capture.window = entry;
        result.withArray("elements").add(describe(capture, entry, info));
        if (info.identity().clipped()) result.put("truncated", true);
        if (info.protect()) return;
        for (UiaCom.Ref child = com.firstChild(node); child != null; child = com.nextSibling(child)) {
            if (depth >= maxDepth || capture.visited >= maxElements) {
                child.close();
                result.put("truncated", true);
                return;
            }
            visit(capture, child, entry, depth + 1, maxDepth, maxElements, result);
        }
    }

    private Entry resolve(Capture capture, String key, int pid, UiaCom.Ref desktop, boolean checkingScope) {
        if (capture == null) throw stale();
        Entry selected = capture.entries.get(key);
        if (selected == null || pid != selected.pid()) throw stale();
        try (UiaCom.Ref live = window(capture.windowId, desktop)) {
            if (!com.same(live, capture.window.node()) || !sameIdentity(capture.window, live)
                    || !sameIdentity(selected, selected.node())
                    || !matchesParents(capture, selected))
                throw stale();
            if (checkingScope && !selected.identity().equals(inspect(selected.node()).identity())) throw stale();
            return selected;
        } catch (AgentException | UiaCom.ComFailure failure) {
            propagateTimeout(failure);
            throw stale();
        }
    }

    private boolean sameIdentity(Entry entry, UiaCom.Ref node) {
        return com.pid(node) == entry.pid() && Arrays.equals(com.runtimeId(node), entry.runtime());
    }

    private boolean matchesParents(Capture capture, Entry selected) {
        UiaCom.Ref parent = null;
        try {
            Entry cursor = selected;
            while (cursor.parent() != null) {
                UiaCom.Ref child = parent;
                parent = com.parent(child == null ? selected.node() : child);
                if (child != null) child.close();
                cursor = cursor.parent();
                if (parent == null || !com.same(cursor.node(), parent) || !sameIdentity(cursor, parent)
                        || protectsChildren(parent)) return false;
            }
            return cursor == capture.window;
        } finally {
            if (parent != null) parent.close();
        }
    }

    private boolean protectsChildren(UiaCom.Ref node) {
        if (com.password(node) || com.controlType(node) == 50004) return true;
        try (UiaCom.Ref value = com.valuePattern(node)) { return value != null; }
    }

    @Override public JsonNode elementInfo(String key, int processId) {
        try (UiaCom.Ref desktop = desktop()) {
            Entry entry = resolve(active, key, processId, desktop, false);
            return describe(active, entry, inspect(entry.node()));
        } catch (UiaCom.ComFailure failure) {
            propagateTimeout(failure);
            throw stale();
        }
    }

    @Override public JsonNode perform(DesktopAction action, String key, int processId, String value) {
        return perform(action, key, processId, value, () -> {});
    }

    JsonNode perform(DesktopAction action, String key, int processId, String value, Runnable beforeMutation) {
        try (UiaCom.Ref desktop = desktop()) {
            Entry entry = resolve(active, key, processId, desktop, false);
            Info info = inspect(entry.node());
            if (entry.identity().clipped() || !entry.identity().equals(info.identity()) || entry.pid() != info.pid())
                throw stale();
            if (!info.enabled() || info.offscreen() || action == null) throw precondition();
            if (action == DesktopAction.SET_VALUE && (value == null || value.length() > 16384))
                throw precondition();
            try (UiaCom.Ref pattern = action == DesktopAction.INVOKE
                    ? com.invokePattern(entry.node()) : com.valuePattern(entry.node())) {
                if (pattern == null) throw new AgentException("PATTERN_UNSUPPORTED", "The pattern is unavailable.");
                if (action == DesktopAction.SET_VALUE && com.readOnly(pattern)) throw precondition();
                // The provider may have changed the tree while fetching the action pattern.
                if (!matchesParents(active, entry)) throw stale();
                try {
                    if (action == DesktopAction.INVOKE) com.invoke(pattern, beforeMutation);
                    else com.setValue(pattern, value, beforeMutation);
                } catch (AgentException cancelled) {
                    throw cancelled;
                } catch (RuntimeException failure) {
                    propagateTimeout(failure);
                    throw new AgentException("ACTION_OUTCOME_UNKNOWN", "The provider did not confirm the action.");
                }
            }
            return object().put("performed", true);
        } catch (UiaCom.ComFailure failure) {
            propagateTimeout(failure);
            throw stale();
        }
    }

    @Override public void close() {
        if (closed) return;
        closed = true;
        try (Capture capture = active) { active = null; }
        finally { com.close(); }
    }

    private static void propagateTimeout(RuntimeException failure) {
        if (failure instanceof AgentException agent && "TIMEOUT".equals(agent.code())) throw agent;
        if (failure instanceof UiaCom.ComFailure comFailure
                && (comFailure.hresult == UIA_TIMEOUT || comFailure.hresult == RPC_TIMEOUT
                    || comFailure.hresult == WIN32_TIMEOUT))
            throw new AgentException("TIMEOUT", "The Windows UI Automation provider timed out.");
    }

    private static AgentException precondition() {
        return new AgentException("PRECONDITION_FAILED", "The request or current element state does not permit this operation.");
    }
    private static AgentException stale() {
        return new AgentException("STALE_REFERENCE", "The captured element or its window is no longer current.");
    }
    private static AgentException missing() {
        return new AgentException("WINDOW_NOT_FOUND", "The requested top-level window is unavailable.");
    }
    private static AgentException unavailable() {
        return new AgentException("BACKEND_UNAVAILABLE", "UI Automation could not access the interactive desktop.");
    }
}
