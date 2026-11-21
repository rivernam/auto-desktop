package dev.desktop;

import java.util.ArrayList;
import java.util.List;

/** Test overlay for the native boundary. Never add to the application classpath. */
final class UiaCom implements AutoCloseable {
    static final class ComFailure extends RuntimeException {
        final int hresult = 0x80004005;
    }

    static final class Node {
        Node parent;
        final List<Node> children = new ArrayList<>();
        final int id, type;
        String name;
        long hwnd;
        boolean password, writable, button, offscreen, failAfterInvoke;
        int invoked;
        String value;
        Node(int id, int type, String name) { this.id = id; this.type = type; this.name = name; }
        Node add(Node child) { child.parent = this; children.add(child); return child; }
    }

    final class Ref implements AutoCloseable {
        final Node node;
        boolean open = true;
        Ref(Node node) { this.node = node; references++; }
        Node get() {
            if (!open) throw new AssertionError("Used released reference.");
            return node;
        }
        public void close() {
            if (!open) throw new AssertionError("Released reference twice.");
            open = false;
            references--;
        }
    }

    static int references;
    static final Node desktop = new Node(1, 50033, "Desktop");
    static Node window;
    static UiaCom open() { return new UiaCom(); }
    void checkDesktop() {}
    Ref root() { return new Ref(desktop); }
    Ref fromHandle(long id) { return window.hwnd == id ? new Ref(window) : null; }
    Ref firstChild(Ref node) {
        List<Node> children = node.get().children;
        return children.isEmpty() ? null : new Ref(children.get(0));
    }
    Ref nextSibling(Ref node) {
        List<Node> children = node.get().parent.children;
        int i = children.indexOf(node.node) + 1;
        return i == children.size() ? null : new Ref(children.get(i));
    }
    Ref parent(Ref node) { return node.get().parent == null ? null : new Ref(node.node.parent); }
    Ref invokePattern(Ref node) { return node.get().button ? new Ref(node.node) : null; }
    Ref valuePattern(Ref node) { return node.get().writable ? new Ref(node.node) : null; }
    boolean same(Ref a, Ref b) { return a.get() == b.get(); }
    int[] runtimeId(Ref node) { return new int[] { 7, node.get().id }; }
    int pid(Ref node) { node.get(); return 42; }
    int controlType(Ref node) { return node.get().type; }
    long hwnd(Ref node) { return node.get().hwnd; }
    String name(Ref node) {
        if (node.get().password || node.node.writable) throw new AssertionError("Read protected name.");
        return node.node.name;
    }
    String automationId(Ref node) { return "id" + node.get().id; }
    String className(Ref node) { node.get(); return "Fixture"; }
    boolean enabled(Ref node) { node.get(); return true; }
    boolean offscreen(Ref node) { return node.get().offscreen; }
    boolean password(Ref node) { return node.get().password; }
    boolean readOnly(Ref pattern) { return !pattern.get().writable; }
    int[] bounds(Ref node) { node.get(); return new int[] { 0, 0, 40, 20 }; }
    void invoke(Ref pattern) {
        pattern.get().invoked++;
        if (pattern.node.failAfterInvoke) throw new ComFailure();
    }
    void setValue(Ref pattern, String value) { pattern.get().value = value; }
    public void close() {
        if (references != 0) throw new AssertionError("Leaked " + references + " reference(s).");
    }
}
