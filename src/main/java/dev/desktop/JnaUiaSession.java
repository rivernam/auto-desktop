package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.Arrays;
import java.util.HashMap;
import java.util.Map;
import java.util.UUID;

/** UI Automation session confined to the COM apartment of its constructor. */
final class JnaUiaSession implements TypedDesktopAdapter {
    private static final int ELEMENT_NOT_AVAILABLE = 0x80040201;
    private static final String[] TYPES = {
        "Button", "Calendar", "CheckBox", "ComboBox", "Edit", "Hyperlink", "Image", "ListItem", "List",
        "Menu", "MenuBar", "MenuItem", "ProgressBar", "RadioButton", "ScrollBar", "Slider", "Spinner",
        "StatusBar", "Tab", "TabItem", "Text", "ToolBar", "ToolTip", "Tree", "TreeItem", "Custom",
        "Group", "Thumb", "DataGrid", "DataItem", "Document", "SplitButton", "Window", "Pane",
        "Header", "HeaderItem", "Table", "TitleBar", "Separator", "SemanticZoom", "AppBar"
    };
    private final UiaCom com = UiaCom.open();
    private final Map<String, Entry> entries = new HashMap<>();
    private Entry anchor;
    private String windowId;
    private boolean closed;

    private record Entry(UiaCom.Ref node, String key, String parentKey, int pid, int[] runtime, Identity identity) {}
    private record Identity(String name, String role, String automationId, String className, boolean clipped) {}
    private record Info(Identity identity, boolean protect, boolean enabled, boolean offscreen,
                        boolean invoke, boolean writable, int[] bounds, int pid) {}

    private static ObjectNode object() { return JsonNodeFactory.instance.objectNode(); }

    private UiaCom.Ref desktop() {
        if (closed) throw unavailable();
        try {
            com.checkDesktop();
            UiaCom.Ref root = com.root();
            if (root == null) throw unavailable();
            return root;
        } catch (UiaCom.ComFailure failure) { throw unavailable(); }
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
            return DesktopCapabilities.unavailable("UIA", "UI Automation could not access the interactive desktop.");
        }
    }

    @Override public JsonNode listWindows() {
        for (int attempt = 0; attempt < 2; attempt++) {
            try (UiaCom.Ref root = desktop()) {
                return windows(root);
            } catch (UiaCom.ComFailure failure) {
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

    private ObjectNode describe(Entry entry, Info info) {
        Identity id = info.identity();
        ObjectNode row = object().put("key", entry.key()).put("parentKey", entry.parentKey())
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
        clearCapture();
        if (maxDepth < 0 || maxDepth > 32 || maxElements < 1 || maxElements > 2000) throw precondition();
        try (UiaCom.Ref desktop = desktop()) {
            UiaCom.Ref root = window(id, desktop);
            ObjectNode result = object().put("truncated", false);
            result.putArray("elements");
            try {
                visit(root, null, 0, maxDepth, maxElements, result);
                windowId = id;
                return result;
            } catch (RuntimeException failure) {
                clearCapture();
                throw stale();
            }
        }
    }

    /** Takes ownership of node on entry, including when a provider call fails. */
    private void visit(UiaCom.Ref node, String parentKey, int depth, int maxDepth, int maxElements, ObjectNode result) {
        boolean retained = false;
        try {
            Info info = inspect(node);
            int[] runtime = com.runtimeId(node);
            if (runtime == null || runtime.length == 0 || info.pid() <= 0) throw stale();
            Entry entry = new Entry(node, UUID.randomUUID().toString(), parentKey, info.pid(), runtime, info.identity());
            entries.put(entry.key(), entry);
            retained = true;
            if (depth == 0) anchor = entry;
            result.withArray("elements").add(describe(entry, info));
            if (info.identity().clipped()) result.put("truncated", true);
            if (info.protect()) return;
            for (UiaCom.Ref child = com.firstChild(node); child != null; child = com.nextSibling(child)) {
                if (depth >= maxDepth || entries.size() >= maxElements) {
                    child.close();
                    result.put("truncated", true);
                    return;
                }
                visit(child, entry.key(), depth + 1, maxDepth, maxElements, result);
            }
        } finally {
            if (!retained) node.close();
        }
    }

    private Entry resolve(String key, int pid, UiaCom.Ref desktop) {
        Entry selected = entries.get(key);
        if (anchor == null || selected == null || pid != selected.pid()) throw stale();
        try (UiaCom.Ref live = window(windowId, desktop)) {
            if (!com.same(live, anchor.node()) || !sameIdentity(anchor, live)
                    || !sameIdentity(selected, selected.node()) || !belongs(selected.node(), live, 0)) throw stale();
            return selected;
        } catch (AgentException | UiaCom.ComFailure failure) { throw stale(); }
    }

    private boolean sameIdentity(Entry entry, UiaCom.Ref node) {
        return com.pid(node) == entry.pid() && Arrays.equals(com.runtimeId(node), entry.runtime());
    }

    private boolean belongs(UiaCom.Ref node, UiaCom.Ref window, int depth) {
        if (com.same(node, window)) return true;
        if (depth >= 127) return false;
        try (UiaCom.Ref parent = com.parent(node)) {
            return parent != null && belongs(parent, window, depth + 1);
        }
    }

    @Override public JsonNode elementInfo(String key, int processId) {
        try (UiaCom.Ref desktop = desktop()) {
            Entry entry = resolve(key, processId, desktop);
            return describe(entry, inspect(entry.node()));
        } catch (UiaCom.ComFailure failure) { throw stale(); }
    }

    @Override public JsonNode perform(DesktopAction action, String key, int processId, String value) {
        try (UiaCom.Ref desktop = desktop()) {
            Entry entry = resolve(key, processId, desktop);
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
                try {
                    if (action == DesktopAction.INVOKE) com.invoke(pattern);
                    else com.setValue(pattern, value);
                } catch (RuntimeException failure) {
                    throw new AgentException("ACTION_OUTCOME_UNKNOWN", "The provider did not confirm the action.");
                }
            }
            return object().put("performed", true);
        } catch (UiaCom.ComFailure failure) { throw stale(); }
    }

    private void clearCapture() {
        anchor = null;
        windowId = null;
        for (Entry entry : entries.values()) entry.node().close();
        entries.clear();
    }

    @Override public void close() {
        if (closed) return;
        closed = true;
        try { clearCapture(); } finally { com.close(); }
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
