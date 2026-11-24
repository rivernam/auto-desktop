package dev.desktop;

/** Semantic actions supported by the desktop protocol. */
public enum DesktopAction {
    INVOKE("invoke"),
    SET_VALUE("setValue"),
    DEFAULT_ACTION("defaultAction"),
    SELECT("select");

    private final String wireName;

    DesktopAction(String wireName) {
        this.wireName = wireName;
    }

    public String wireName() {
        return wireName;
    }
}
