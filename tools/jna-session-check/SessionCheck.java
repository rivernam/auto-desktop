package dev.desktop;

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
    public static void main(String[] args) {
        UiaCom.window = UiaCom.desktop.add(new UiaCom.Node(2, 50032, "Fixture"));
        UiaCom.window.hwnd = 3;
        var edit = UiaCom.window.add(new UiaCom.Node(3, 50004, "private"));
        edit.writable = true;
        edit.add(new UiaCom.Node(4, 50020, "private child"));
        var button = UiaCom.window.add(new UiaCom.Node(5, 50000, "Submit"));
        button.button = true;
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
        System.out.println("PASS: packaged JNA session against simulated COM tree");
    }
}
