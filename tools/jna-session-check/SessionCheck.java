package dev.desktop;

import java.time.Duration;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

/** Runs the packaged JnaUiaSession bytecode against a simulated COM implementation. */
final class SessionCheck {
    static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
    static void fails(String code, Runnable operation) {
        try { operation.run(); }
        catch (AgentException error) {
            require(code.equals(error.code()), error.toString());
            return;
        }
        throw new AssertionError("Expected " + code);
    }
    static void verifyScopedCapture() {
        UiaCom.window.children.clear();
        var container = UiaCom.window.add(new UiaCom.Node(10, 50033, "Container"));
        var group = container.add(new UiaCom.Node(11, 50026, "Group"));
        var button = group.add(new UiaCom.Node(12, 50000, "Button"));
        button.button = true;
        var unrelated = UiaCom.window.add(new UiaCom.Node(13, 50033, "Unrelated"));
        try (var session = new JnaUiaSession()) {
            var limited = session.snapshot("3", 2, 20);
            require(limited.path("truncated").asBoolean(), "initial snapshot was bounded");
            String containerKey = limited.at("/elements/1/key").asText();
            var subtree = session.snapshotSubtree("3", containerKey, 42, 2, 3);
            require(!subtree.path("truncated").asBoolean() && subtree.path("elements").size() == 3,
                    "only the selected branch is captured");
            require(subtree.at("/elements/0/parentKey").isNull() && UiaCom.references == 4,
                    "private window anchor and visible nodes are retained");
            require(!containerKey.equals(subtree.at("/elements/0/key").asText()), "scope root has a new key");
            fails("STALE_REFERENCE", () -> session.elementInfo(containerKey, 42));

            String groupKey = subtree.at("/elements/1/key").asText();
            var nested = session.snapshotSubtree("3", groupKey, 42, 1, 2);
            String buttonKey = nested.at("/elements/1/key").asText();
            require(UiaCom.references == 4 && nested.at("/elements/0/parentKey").isNull(),
                    "nested scope retains only its descendants and private ancestry");
            session.perform(DesktopAction.INVOKE, buttonKey, 42, null);
            require(button.invoked == 1, "a scope descendant remains actionable");

            UiaCom.window.children.remove(container);
            unrelated.add(container);
            fails("STALE_REFERENCE", () -> session.elementInfo(buttonKey, 42));
            fails("STALE_REFERENCE", () -> session.snapshotSubtree("3", buttonKey, 42, 1, 2));
            require(UiaCom.references == 0, "failed subtree releases both public and private references");
            unrelated.children.remove(container);
            UiaCom.window.children.add(0, container);
            container.parent = UiaCom.window;

            String refreshedContainer = session.snapshot("3", 3, 20).at("/elements/1/key").asText();
            button.failRuntimeId = true;
            fails("STALE_REFERENCE", () -> session.snapshotSubtree("3", refreshedContainer, 42, 2, 3));
            require(UiaCom.references == 0, "partial subtree releases both visited and failed nodes");
            button.failRuntimeId = false;

            var full = session.snapshot("3", 3, 20);
            String visibleContainerKey = full.at("/elements/1/key").asText();
            String visibleButtonKey = full.at("/elements/3/key").asText();
            container.password = true;
            fails("STALE_REFERENCE", () -> session.elementInfo(visibleButtonKey, 42));
            fails("STALE_REFERENCE", () -> session.perform(DesktopAction.INVOKE, visibleButtonKey, 42, null));
            container.password = false;
            var visibleGroup = session.snapshotSubtree("3", visibleContainerKey, 42, 2, 3);
            String visibleGroupKey = visibleGroup.at("/elements/1/key").asText();
            container.password = true;
            fails("STALE_REFERENCE", () -> session.snapshotSubtree("3", visibleGroupKey, 42, 1, 2));
            require(UiaCom.references == 0, "capture cannot traverse a newly protected ancestor");
        }
    }
    static void verifyProviderTimeout() {
        UiaCom.window.children.clear();
        var button = UiaCom.window.add(new UiaCom.Node(14, 50000, "Timed-out button"));
        button.button = true;
        try (var session = new JnaUiaSession()) {
            String key = session.snapshot("3", 1, 20).at("/elements/1/key").asText();
            button.runtimeError = 0x80131505; // UIA_E_TIMEOUT
            fails("TIMEOUT", () -> session.elementInfo(key, 42));
            button.runtimeError = 0;
            button.invokeError = 0x8001011f; // RPC_E_TIMEOUT
            fails("TIMEOUT", () -> session.perform(DesktopAction.INVOKE, key, 42, null));
            require(button.invoked == 1, "a native action timeout is never retried inside the session");
        }
    }

    private static void await(CountDownLatch latch) {
        try { require(latch.await(5, TimeUnit.SECONDS), "Timed out awaiting simulated provider."); }
        catch (InterruptedException ex) { throw new AssertionError(ex); }
    }

    static void verifyMutationAfterPreflightTimeout() {
        UiaCom.window.children.clear();
        var button = UiaCom.window.add(new UiaCom.Node(15, 50000, "Slow preflight"));
        button.button = true;
        var entered = new CountDownLatch(1);
        var unblock = new CountDownLatch(1);
        var closed = new CountDownLatch(1);
        UiaCom.onClose = closed::countDown;
        try (var adapter = new JnaDesktopAdapter(JnaUiaSession::new, Duration.ofMillis(500))) {
            String key = adapter.snapshot("3", 1, 20).at("/elements/1/key").asText();
            button.beforeInvokePattern = () -> { entered.countDown(); await(unblock); };
            try {
                fails("ACTION_OUTCOME_UNKNOWN", () -> adapter.perform(DesktopAction.INVOKE, key, 42, null));
                require(entered.getCount() == 0, "preflight reached provider");
            } finally { unblock.countDown(); }
            await(closed);
            require(button.invoked == 0, "timed-out preflight must not send a new native mutation");
        } finally { UiaCom.onClose = () -> {}; }
    }

    static void verifyReparentWhileAcquiringPattern() {
        UiaCom.window.children.clear();
        var button = UiaCom.window.add(new UiaCom.Node(16, 50000, "Moving button"));
        button.button = true;
        var container = UiaCom.window.add(new UiaCom.Node(17, 50033, "Different container"));
        try (var session = new JnaUiaSession()) {
            String key = session.snapshot("3", 2, 20).at("/elements/1/key").asText();
            var acquisitions = new AtomicInteger();
            button.beforeInvokePattern = () -> {
                if (acquisitions.incrementAndGet() == 2) {
                    UiaCom.window.children.remove(button);
                    container.add(button);
                }
            };
            fails("STALE_REFERENCE", () -> session.perform(DesktopAction.INVOKE, key, 42, null));
            require(button.invoked == 0, "must check the captured path after acquiring the final pattern");
        }
    }
    public static void main(String[] args) {
        UiaCom.window = UiaCom.desktop.add(new UiaCom.Node(2, 50032, "Fixture"));
        UiaCom.window.hwnd = 3;
        if (args.length == 1 && "late-reparent".equals(args[0])) {
            verifyReparentWhileAcquiringPattern();
            return;
        }
        var edit = UiaCom.window.add(new UiaCom.Node(3, 50004, "private"));
        edit.writable = true;
        edit.add(new UiaCom.Node(4, 50020, "private child"));
        var button = UiaCom.window.add(new UiaCom.Node(5, 50000, "Submit"));
        button.button = true;
        var container = new UiaCom.Node(6, 50033, "Different container");
        try (var session = new JnaUiaSession()) {
            require(session.capabilities().path("available").asBoolean(), "capabilities");
            require(session.listWindows().size() == 1 && UiaCom.references == 0, "enumeration reference ownership");
            var capture = session.snapshot("3", 32, 2000);
            require(!capture.path("truncated").asBoolean() && capture.path("elements").size() == 3, "capture");
            require(UiaCom.references == 3 && !capture.toString().contains("private"), "retention and privacy");
            String editKey = capture.at("/elements/1/key").asText();
            String buttonKey = capture.at("/elements/2/key").asText();
            require("Submit".equals(session.elementInfo(buttonKey, 42).path("name").asText()), "inspection");
            session.perform(DesktopAction.SET_VALUE, editKey, 42, "한\0글");
            require("한\0글".equals(edit.value), "BSTR value contents");
            session.perform(DesktopAction.INVOKE, buttonKey, 42, null);
            fails("PATTERN_UNSUPPORTED", () -> session.perform(DesktopAction.INVOKE, editKey, 42, null));
            button.offscreen = true;
            fails("PRECONDITION_FAILED", () -> session.perform(DesktopAction.INVOKE, buttonKey, 42, null));
            button.offscreen = false;
            button.name = "Different";
            fails("STALE_REFERENCE", () -> session.perform(DesktopAction.INVOKE, buttonKey, 42, null));
            fails("STALE_REFERENCE", () -> session.elementInfo(buttonKey, 41));
            UiaCom.window.add(container);
            UiaCom.window.children.remove(button);
            container.add(button);
            button.name = "Submit";
            fails("STALE_REFERENCE", () -> session.elementInfo(buttonKey, 42));
            fails("STALE_REFERENCE", () -> session.perform(DesktopAction.INVOKE, buttonKey, 42, null));
            container.children.remove(button);
            UiaCom.window.children.remove(container);
            UiaCom.window.add(button);
            button.parent = UiaCom.desktop;
            fails("STALE_REFERENCE", () -> session.elementInfo(buttonKey, 42));
            button.parent = UiaCom.window;
            button.name = "Submit";
            button.failAfterInvoke = true;
            fails("ACTION_OUTCOME_UNKNOWN", () -> session.perform(DesktopAction.INVOKE, buttonKey, 42, null));
            require(button.invoked == 2 && UiaCom.references == 3, "actions and transient reference cleanup");
            var bounded = session.snapshot("3", 0, 1);
            require(bounded.path("truncated").asBoolean() && UiaCom.references == 1, "bounded replacement");
            fails("STALE_REFERENCE", () -> session.elementInfo(editKey, 42));
            fails("WINDOW_NOT_FOUND", () -> session.snapshot("4", 1, 2));
            require(UiaCom.references == 0, "failed capture invalidates and releases old refs");
        }
        verifyScopedCapture();
        verifyProviderTimeout();
        verifyMutationAfterPreflightTimeout();
        verifyReparentWhileAcquiringPattern();
        System.out.println("PASS: packaged JNA session against simulated COM tree");
    }
}
