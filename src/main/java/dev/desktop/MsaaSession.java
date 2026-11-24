package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sun.jna.Pointer;
import com.sun.jna.ptr.IntByReference;
import java.time.Instant;
import java.util.ArrayDeque;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.TimeUnit;
import java.util.function.IntPredicate;

/** MSAA observation and dispatch over one apartment. A position is never a mutation target. */
final class MsaaSession implements NativeSession {
    private static final int UNAVAILABLE = 0x00000001;
    private static final int SELECTED = 0x00000002;
    private static final int READ_ONLY = 0x00000040;
    private static final int INVISIBLE_OR_OFFSCREEN = 0x00018000;
    private static final int SELECTABLE = 0x00200000;
    private static final int PROTECTED = 0x20000000;
    private static final int TEXT = 42;
    private static final int MAX_IDENTITY_WINDOWS = 256;
    private static final String DESKTOP_UNAVAILABLE = "Microsoft Active Accessibility cannot access the input desktop.";

    private final MsaaCom com = new MsaaCom();
    private final IntByReference process = new IntByReference();
    private final char[] textBuffer = new char[MsaaCom.TEXT_LIMIT + 1];
    private final IntPredicate trustedProvider;
    private Cache active;

    MsaaSession(IntPredicate trustedProvider) { this.trustedProvider = trustedProvider; }

    private record Identity(int role, String name, boolean clipped, String className) {}
    private record Inspection(Identity identity, long window, long reported, int state,
                              boolean masked, int[] bounds, boolean defaultAction, boolean writable, boolean select) {
        boolean enabled() { return state >= 0 && (state & UNAVAILABLE) == 0; }
        boolean offscreen() { return state >= 0 && (state & INVISIBLE_OR_OFFSCREEN) != 0; }
    }
    private record Strong(MsaaCom.Node original, byte[] identity, long window)
            implements AutoCloseable {
        @Override public void close() { original.close(); }
    }
    private record Page(int start, int count, int obtained) {}
    private record Step(Step parent, int ordinal, int siblings, Page page, int child, int enumeratedId, long window, Identity identity,
                        Strong strong) {}
    private record Entry(Step step, String parentKey) {}
    private sealed interface Work permits Pending, Expand { MsaaCom.Node node(); }
    private record Pending(MsaaCom.Node node, Step path, ObjectNode parentRow, int ordinal, int siblings, Page page, int depth)
            implements Work {}
    private record Expand(MsaaCom.Node node, Step path, ObjectNode row, int start, int count, int depth)
            implements Work {}
    private record Live(MsaaCom.Node node, Inspection info) implements AutoCloseable {
        @Override public void close() { node.close(); }
    }

    private static final class Cache implements AutoCloseable {
        final long window;
        final int pid;
        final Instant started;
        final Map<String, Entry> entries = new HashMap<>();
        final List<Strong> owned = new ArrayList<>();
        long expires;

        Cache(long window, int pid, Instant started) {
            this.window = window;
            this.pid = pid;
            this.started = started;
        }

        void keepAncestors(Cache previous, Step step) {
            for (Step item = step; item != null; item = item.parent) {
                if (item.strong != null) {
                    owned.add(item.strong);
                    previous.owned.remove(item.strong);
                }
            }
        }

        @Override public void close() {
            entries.clear();
            for (Strong strong : owned) strong.close();
            owned.clear();
        }
    }

    private static ObjectNode object() { return JsonNodeFactory.instance.objectNode(); }

    private void checkDesktop() {
        try { UiaCom.checkDesktopAccess(process); }
        catch (UiaCom.ComFailure denied) { throw new AgentException("BACKEND_UNAVAILABLE", DESKTOP_UNAVAILABLE); }
    }

    private static UiaCom.DesktopApi user32() { return UiaCom.DesktopApi.INSTANCE; }

    private static boolean topLevel(Pointer window) {
        return user32().IsWindowVisible(window) && user32().GetDesktopWindow().equals(user32().GetAncestor(window, 1));
    }

    private int pid(Pointer window) {
        return user32().GetWindowThreadProcessId(window, process) != 0 && process.getValue() > 0 ? process.getValue() : 0;
    }

    private static Instant started(int pid) {
        return pid > 0 ? ProcessHandle.of(pid).flatMap(handle -> handle.info().startInstant()).orElse(null) : null;
    }

    private boolean sameWindow(Cache cache) {
        Pointer window = MsaaCom.handle(cache.window);
        return topLevel(window) && pid(window) == cache.pid && cache.started.equals(started(cache.pid));
    }

    private static long parseWindow(String id) {
        try {
            if (!id.isEmpty() && id.charAt(0) >= '1' && id.charAt(0) <= '9'
                    && id.chars().allMatch(unit -> unit >= '0' && unit <= '9'))
                return Integer.toUnsignedLong(Integer.parseUnsignedInt(id));
        } catch (NumberFormatException invalid) {
            // The window ID is out of the HWND wire range.
        }
        throw missing();
    }

    @Override public JsonNode capabilities() {
        idle();
        try { checkDesktop(); }
        catch (AgentException denied) { return DesktopCapabilities.unavailable("MSAA", denied.getMessage()); }
        var result = object().put("backend", "MSAA").put("available", true)
                .put("physicalInput", false).put("screenshot", false);
        result.putArray("operations").add("getCapabilities").add("listWindows").add("snapshot")
                .add("findElement").add("getElementInfo").add("setValue").add("defaultAction").add("select");
        return result;
    }

    @Override public JsonNode listWindows() {
        idle();
        checkDesktop();
        var handles = new ArrayList<Pointer>();
        user32().EnumWindows((window, unused) -> {
            if (topLevel(window)) handles.add(window);
            return handles.size() < 4096;
        }, null);
        var result = JsonNodeFactory.instance.arrayNode();
        for (Pointer window : handles) {
            int pid = pid(window);
            if (pid == 0 || !topLevel(window)) continue;
            int length = user32().GetWindowTextW(window, textBuffer, textBuffer.length);
            long owner = MsaaCom.number(user32().GetWindow(window, 4)); // GW_OWNER
            if (pid(window) == pid) {
                var row = result.addObject().put("windowId", Long.toString(MsaaCom.number(window)))
                        .put("processId", pid).put("name", normalize(length));
                if (owner != 0) row.put("ownerWindowId", Long.toString(owner));
            }
        }
        return result;
    }

    private String normalize(int size) {
        // An unpaired UTF-16 surrogate cannot be written to NDJSON.
        for (int i = 0; i < size; i++) {
            char ch = textBuffer[i];
            if (Character.isHighSurrogate(ch)) {
                if (i + 1 < size && Character.isLowSurrogate(textBuffer[i + 1])) i++;
                else textBuffer[i] = '\ufffd';
            } else if (Character.isLowSurrogate(ch)) textBuffer[i] = '\ufffd';
        }
        return new String(textBuffer, 0, size);
    }

    private static String role(int role) {
        return switch (role) {
            case 9, 18 -> "Window";
            case 10, 16, 38 -> "Pane";
            case 33 -> "List";
            case 34 -> "ListItem";
            case 60 -> "Tab";
            case 37 -> "TabItem";
            case 24 -> "Table";
            case 28 -> "Row";
            case 29 -> "Cell";
            case 25, 26 -> "HeaderItem";
            case 35 -> "Tree";
            case 36 -> "TreeItem";
            case TEXT -> "Edit";
            case 41 -> "Text";
            case 43 -> "Button";
            case 44 -> "CheckBox";
            case 45 -> "RadioButton";
            case 46 -> "ComboBox";
            case 20 -> "Group";
            case 30 -> "Hyperlink";
            case 2 -> "MenuBar";
            case 11 -> "Menu";
            case 12 -> "MenuItem";
            case 51 -> "Slider";
            case 3 -> "ScrollBar";
            case 48 -> "ProgressBar";
            case 52 -> "Spinner";
            case 21 -> "Separator";
            case 22 -> "ToolBar";
            case 13 -> "ToolTip";
            case 23 -> "StatusBar";
            case 40 -> "Image";
            default -> "Custom";
        };
    }

    private boolean belongs(long window, long root, int pid) {
        return pid(MsaaCom.handle(window)) == pid
                && (window == root || user32().IsChild(MsaaCom.handle(root), MsaaCom.handle(window)));
    }

    private static boolean masked(int role, int state) {
        return role == TEXT || state < 0 || role < 0 || (state & PROTECTED) != 0;
    }

    private Inspection inspect(MsaaCom.Node node, long inherited, long root, int pid) {
        int role = com.role(node), state = com.state(node);
        long reported = node.child() == 0 ? com.sourceWindow(node) : 0;
        if (reported != 0 && !belongs(reported, root, pid)) throw DesktopSnapshot.stale();
        long window = reported == 0 ? inherited : reported;
        int length = user32().GetClassNameW(MsaaCom.handle(window), textBuffer, 256);
        String className = normalize(length);
        int[] bounds = com.bounds(node);
        var emptyName = new MsaaCom.Name("", false);
        var name = masked(role, state) ? emptyName : com.name(node);
        // A provider can change a field's state while answering the name query.
        if (!name.text().isEmpty()) {
            role = com.role(node);
            state = com.state(node);
            if (masked(role, state)) name = emptyName;
        }
        return new Inspection(new Identity(role, name.text(), name.clipped(), className), window, reported,
                state, masked(role, state), bounds, false, false, false);
    }

    private Inspection actions(Inspection info, MsaaCom.Node node) {
        if (!info.enabled() || info.offscreen() || (info.state & PROTECTED) != 0) return info;
        return new Inspection(info.identity, info.window, info.reported, info.state, info.masked, info.bounds,
                com.hasDefaultAction(node), info.identity.role == TEXT && (info.state & READ_ONLY) == 0,
                (info.state & SELECTABLE) != 0);
    }

    private boolean sameObject(Strong strong, MsaaCom.Node node) {
        return node != null && node.child() == 0 && Arrays.equals(strong.identity, com.identityBytes(node));
    }

    private boolean currentObject(Strong strong) {
        try (var direct = com.fromWindow(strong.window)) { return sameObject(strong, direct); }
    }

    private long findDedicatedWindow(Cache cache, long inherited, byte[] identity) {
        var candidates = new ArrayList<Long>();
        user32().EnumChildWindows(MsaaCom.handle(cache.window), (window, unused) -> {
            candidates.add(MsaaCom.number(window));
            return candidates.size() <= MAX_IDENTITY_WINDOWS;
        }, null);
        if (candidates.size() > MAX_IDENTITY_WINDOWS) return 0;
        long found = 0;
        for (long window : candidates) {
            if (window == inherited || !belongs(window, cache.window, cache.pid)) continue;
            try (var direct = com.fromWindow(window)) {
                if (direct == null || !Arrays.equals(identity, com.identityBytes(direct))) continue;
                if (found != 0) return 0;
                found = window;
            }
        }
        return found;
    }

    private Strong prove(MsaaCom.Node node, Inspection info, long inherited, boolean root, Cache cache) {
        if (node.child() != 0 || info.identity.role < 0 || info.state < 0 || info.identity.clipped) return null;
        byte[] bytes = com.identityBytes(node);
        if (bytes == null || !com.opaqueIdentity(bytes)) return null;
        long dedicated = info.reported;
        if (root && dedicated != cache.window) return null;
        if (!root && (dedicated == 0 || dedicated == inherited || dedicated == cache.window))
            dedicated = findDedicatedWindow(cache, inherited, bytes);
        if (dedicated == 0) return null;
        var strong = new Strong(node.copy(), bytes, dedicated);
        boolean held = false;
        try {
            held = currentObject(strong);
            return held ? strong : null;
        } finally {
            if (!held) strong.close();
        }
    }

    private Live resolve(Cache cache, Step step) {
        if (!sameWindow(cache)) throw DesktopSnapshot.stale();
        var path = new ArrayList<Step>();
        for (Step segment = step; segment != null; segment = segment.parent) path.add(segment);
        MsaaCom.Node node = com.fromWindow(cache.window);
        try {
            long inherited = cache.window;
            for (int i = path.size() - 1; i >= 0; i--) {
                Step expected = path.get(i);
                if (node == null) throw DesktopSnapshot.stale();
                if (expected.parent != null) {
                    if (com.count(node) != expected.siblings) throw DesktopSnapshot.stale();
                    // Some Win32 proxies cannot skip to an ordinal they returned in a page.
                    Page page = expected.page;
                    try (var children = com.children(node, page.start, page.count, expected.ordinal - page.start)) {
                        if (children.obtained() != page.obtained
                                || children.nodes().size() != 1 || children.nodes().get(0) == null)
                            throw DesktopSnapshot.stale();
                        node.close();
                        node = children.nodes().set(0, null);
                    }
                }
                Inspection live = inspect(node, inherited, cache.window, cache.pid);
                if (node.child() != expected.child || node.enumeratedId() != expected.enumeratedId
                        || live.window != expected.window || live.identity.role < 0
                        || live.state < 0 || live.identity.clipped || !expected.identity.equals(live.identity))
                    throw DesktopSnapshot.stale();
                if (expected.strong != null && (!sameObject(expected.strong, node)
                        || !currentObject(expected.strong) || !sameObject(expected.strong, expected.strong.original)))
                    throw DesktopSnapshot.stale();
                if (i == 0) {
                    var result = new Live(node, expected.strong == null ? live : actions(live, node));
                    node = null;
                    return result;
                }
                if (live.masked) throw DesktopSnapshot.stale();
                inherited = live.window;
            }
            throw DesktopSnapshot.stale();
        } finally { if (node != null) node.close(); }
    }

    private static ObjectNode row(Inspection info, int pid, boolean strong, String key, String parent) {
        var result = object().put("key", key).put("parentKey", parent).put("processId", pid)
                .put("backend", "MSAA").put("referenceStrength", strong ? "strong" : "weak")
                .put("role", role(info.identity.role)).put("name", info.identity.name).put("automationId", "")
                .put("className", info.identity.className)
                .put("nativeRole", info.identity.role < 0 ? "unknown" : Integer.toString(info.identity.role))
                .put("enabled", info.enabled()).put("offscreen", info.offscreen());
        if (info.state >= 0) result.put("selected", (info.state & SELECTED) != 0);
        if (info.bounds == null) result.putNull("bounds");
        else result.putObject("bounds").put("x", info.bounds[0]).put("y", info.bounds[1])
                .put("width", info.bounds[2]).put("height", info.bounds[3]);
        var actions = result.putArray("actions");
        if (info.writable) actions.add("setValue");
        if (info.defaultAction) actions.add("defaultAction");
        if (info.select) actions.add("select");
        return result;
    }

    private static void partial(ObjectNode result, ObjectNode row, String reason) {
        result.put("truncated", true);
        if (row.path("partial").asBoolean() && !row.path("partialReason").asText().equals(reason))
            reason = "limit,provider";
        row.put("partial", true).put("partialReason", reason);
    }

    @Override public JsonNode snapshot(String id, int depth, int limit) {
        return capture(id, null, 0, depth, limit);
    }

    @Override public JsonNode snapshotSubtree(String id, String key, int pid, int depth, int limit) {
        return capture(id, key, pid, depth, limit);
    }

    private JsonNode capture(String id, String key, int scopePid, int depthLimit, int limit) {
        idle();
        Cache previous = active;
        active = null;
        try (previous) {
            checkDesktop();
            long window = parseWindow(id);
            Pointer hwnd = MsaaCom.handle(window);
            int pid = pid(hwnd);
            Instant started = started(pid);
            if (!topLevel(hwnd) || pid == 0 || started == null) throw key == null ? missing() : DesktopSnapshot.stale();
            var next = new Cache(window, pid, started);
            boolean trusted = trustedProvider.test(pid);
            var result = object().put("truncated", false);
            var rows = result.putArray("elements");
            var queue = new ArrayDeque<Work>();
            int scheduled = 1, examined = 0;
            try {
                if (key == null) {
                    var node = com.fromWindow(window);
                    if (node == null) throw missing();
                    queue.add(new Pending(node, null, null, 0, 0, null, 0));
                } else {
                    Step scope = entry(previous, key, scopePid).step;
                    if (previous.window != window) throw DesktopSnapshot.stale();
                    Live live = resolve(previous, scope);
                    queue.add(new Pending(live.node, scope.parent, null, scope.ordinal, scope.siblings, scope.page, 0));
                    next.keepAncestors(previous, scope.parent);
                }
                while (!queue.isEmpty()) {
                    var work = queue.removeFirst();
                    if (work instanceof Expand branch) {
                        boolean transferred = false;
                        try {
                            int requested = Math.min(MsaaCom.PAGE_SIZE, Math.min(limit - scheduled,
                                    Math.min(2 * limit - examined, branch.count - branch.start)));
                            if (requested == 0) {
                                partial(result, branch.row, "limit");
                                continue;
                            }
                            examined += requested;
                            int position = branch.start;
                            try (var children = com.children(branch.node, position, requested)) {
                                if (children.incomplete()) partial(result, branch.row, "provider");
                                var page = new Page(position, requested, children.obtained());
                                for (int i = 0; i < children.nodes().size(); i++) {
                                    var child = children.nodes().set(i, null);
                                    if (child == null) partial(result, branch.row, "provider");
                                    else {
                                        queue.add(new Pending(child, branch.path, branch.row, position, branch.count, page,
                                                branch.depth));
                                        scheduled++;
                                    }
                                    position++;
                                }
                                if (!children.incomplete() && position < branch.count) {
                                    queue.add(new Expand(branch.node, branch.path, branch.row, position, branch.count,
                                            branch.depth));
                                    transferred = true;
                                }
                            }
                        } finally {
                            if (!transferred) branch.node.close();
                        }
                        continue;
                    }
                    var pending = (Pending) work;
                    try (var node = pending.node) {
                        long inherited = pending.path == null ? window : pending.path.window;
                        Inspection info;
                        try { info = inspect(node, inherited, window, pid); }
                        catch (AgentException foreign) {
                            if (!"STALE_REFERENCE".equals(foreign.code()) || pending.parentRow == null) throw foreign;
                            partial(result, pending.parentRow, "provider");
                            continue;
                        }
                        Strong strong = trusted ? prove(node, info, inherited, pending.path == null, next) : null;
                        if (strong != null) {
                            next.owned.add(strong);
                            info = actions(info, node);
                        }
                        Step step = new Step(pending.path, pending.ordinal, pending.siblings, pending.page,
                                node.child(), node.enumeratedId(), info.window, info.identity, strong);
                        String token = Integer.toString(rows.size());
                        String parent = pending.parentRow == null ? null : pending.parentRow.path("key").asText();
                        next.entries.put(token, new Entry(step, parent));
                        ObjectNode row = row(info, pid, strong != null, token, parent);
                        rows.add(row);
                        if (info.identity.clipped) partial(result, row, "provider");
                        if (info.masked) {
                            if (info.identity.role < 0 || info.state < 0) partial(result, row, "provider");
                            continue;
                        }
                        int count = com.count(node);
                        if (count < 0) partial(result, row, "provider");
                        else if (count > 0 && pending.depth == depthLimit) partial(result, row, "limit");
                        else if (count > 0)
                            queue.add(new Expand(node.copy(), step, row, 0, count, pending.depth + 1));
                    }
                }
                if (!sameWindow(next)) throw DesktopSnapshot.stale();
                next.expires = System.nanoTime() + TimeUnit.SECONDS.toNanos(120);
                active = next;
                return result;
            } finally {
                for (Work work : queue) work.node().close();
                if (active != next) next.close();
            }
        }
    }

    private static Entry entry(Cache cache, String key, int pid) {
        if (cache == null || cache.pid != pid || !cache.entries.containsKey(key)) throw DesktopSnapshot.stale();
        return cache.entries.get(key);
    }

    @Override public JsonNode elementInfo(String key, int pid) {
        idle();
        checkDesktop();
        Entry entry = entry(active, key, pid);
        try (Live live = resolve(active, entry.step)) {
            return row(live.info, pid, entry.step.strong != null, key, entry.parentKey);
        }
    }

    @Override public JsonNode perform(DesktopAction action, String key, int pid, String value, Runnable before) {
        idle();
        checkDesktop();
        Entry entry = entry(active, key, pid);
        Strong strong = entry.step.strong;
        if (strong == null) throw unsupported();
        try (Live live = resolve(active, entry.step)) {
            Inspection info = live.info;
            if (!info.enabled() || info.offscreen())
                throw new AgentException("PRECONDITION_FAILED", "The current element state does not permit the action.");
            if (!(action == DesktopAction.DEFAULT_ACTION && info.defaultAction)
                    && !(action == DesktopAction.SET_VALUE && info.writable)
                    && !(action == DesktopAction.SELECT && info.select)) throw unsupported();
            try (var text = action == DesktopAction.SET_VALUE ? new MsaaCom.Text(value) : null) {
                if (action == DesktopAction.DEFAULT_ACTION && !com.hasDefaultAction(strong.original)) throw unsupported();
                if (!sameObject(strong, strong.original)
                        || com.role(strong.original) != entry.step.identity.role) throw DesktopSnapshot.stale();
                int state = com.state(strong.original);
                if (state < 0 || (state & (UNAVAILABLE | INVISIBLE_OR_OFFSCREEN | PROTECTED)) != 0
                        || (action == DesktopAction.SET_VALUE && (state & READ_ONLY) != 0)
                        || (action == DesktopAction.SELECT && (state & SELECTABLE) == 0))
                    throw new AgentException("PRECONDITION_FAILED", "The current element state does not permit the action.");
                if (!sameWindow(active)
                        || !belongs(strong.window, active.window, pid)) throw DesktopSnapshot.stale();
                before.run();
                // Dispatch to the original retained object, with CHILDID_SELF only.
                int hr = com.mutate(strong.original, action, text);
                if (MsaaCom.timeout(hr))
                    throw new AgentException("TIMEOUT", "The native Microsoft Active Accessibility call timed out.");
                if (hr != 0) throw new AgentException("ACTION_OUTCOME_UNKNOWN",
                        "The native action was not confirmed. Inspect the target before retrying.");
            }
        }
        return object().put("performed", true).put("effectVerified", false);
    }

    @Override public void idle() {
        if (active != null && System.nanoTime() - active.expires >= 0) {
            active.close();
            active = null;
        }
    }

    @Override public void close() {
        try { if (active != null) active.close(); }
        finally { com.close(); }
    }

    private static AgentException missing() {
        return new AgentException("WINDOW_NOT_FOUND", "The requested top-level window is unavailable.");
    }

    private static AgentException unsupported() {
        return new AgentException("PATTERN_UNSUPPORTED", "The live MSAA element does not safely support this action.");
    }
}
