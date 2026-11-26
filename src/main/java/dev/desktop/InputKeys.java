package dev.desktop;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/** Key names of the protocol and the keyboard events a request turns into. Platform-neutral. */
final class InputKeys {
    static final int VK_TAB = 0x09;
    static final int VK_RETURN = 0x0D;
    static final int VK_SHIFT = 0x10;
    static final int VK_CONTROL = 0x11;
    static final int VK_MENU = 0x12;
    static final int VK_ESCAPE = 0x1B;
    static final int TEXT_LIMIT = 1024;

    /** A virtual key. Extended keys need KEYEVENTF_EXTENDEDKEY to reach the application as the named key. */
    static final class Key {
        final String name;
        final int vk;
        final boolean extended;

        Key(String name, int vk, boolean extended) {
            this.name = name;
            this.vk = vk;
            this.extended = extended;
        }

        boolean modifier() { return vk == VK_SHIFT || vk == VK_CONTROL || vk == VK_MENU; }

        @Override public boolean equals(Object other) {
            return other instanceof Key && ((Key) other).vk == vk;
        }

        @Override public int hashCode() { return vk; }

        @Override public String toString() { return name; }
    }

    /** One typed unit: a UTF-16 code unit sent with KEYEVENTF_UNICODE, or Enter or Tab as a virtual key. */
    static final class Unit {
        final char character;
        final Key key;

        private Unit(char character, Key key) {
            this.character = character;
            this.key = key;
        }

        static Unit text(char character) { return new Unit(character, null); }

        static Unit key(Key key) { return new Unit('\0', key); }
    }

    private static final Map<String, Key> KEYS = new HashMap<>();
    // These reach the shell or change a global state rather than the target window.
    private static final Set<String> REFUSED = Set.of("win", "lwin", "rwin", "windows", "meta", "capslock",
            "numlock", "scrolllock", "printscreen", "prtsc", "snapshot", "pause", "break", "sleep");

    private static void add(String name, int vk, boolean extended, String... aliases) {
        Key key = new Key(name, vk, extended);
        KEYS.put(name.toLowerCase(Locale.ROOT), key);
        for (String alias : aliases) KEYS.put(alias.toLowerCase(Locale.ROOT), key);
    }

    static {
        for (char c = 'A'; c <= 'Z'; c++) add(String.valueOf(c), c, false);
        for (char c = '0'; c <= '9'; c++) add(String.valueOf(c), c, false);
        for (int f = 1; f <= 24; f++) add("F" + f, 0x6F + f, false);
        for (int n = 0; n <= 9; n++) add("NumPad" + n, 0x60 + n, false);
        add("Enter", VK_RETURN, false, "Return");
        add("Tab", VK_TAB, false);
        add("Escape", VK_ESCAPE, false, "Esc");
        add("Space", 0x20, false);
        add("Backspace", 0x08, false);
        add("Delete", 0x2E, true, "Del");
        add("Insert", 0x2D, true, "Ins");
        add("Home", 0x24, true);
        add("End", 0x23, true);
        add("PageUp", 0x21, true);
        add("PageDown", 0x22, true);
        add("Left", 0x25, true);
        add("Up", 0x26, true);
        add("Right", 0x27, true);
        add("Down", 0x28, true);
        add("Apps", 0x5D, true);
        add("Multiply", 0x6A, false);
        add("Add", 0x6B, false);
        add("Subtract", 0x6D, false);
        add("Decimal", 0x6E, false);
        add("Divide", 0x6F, true);
        add("Shift", VK_SHIFT, false);
        add("Ctrl", VK_CONTROL, false, "Control");
        add("Alt", VK_MENU, false);
    }

    static final Key ENTER = KEYS.get("enter");
    static final Key TAB = KEYS.get("tab");

    /** One key by name, for keyDown and keyUp. */
    static Key key(String name) {
        if (name == null) throw invalid("Invalid key.");
        String normalized = name.toLowerCase(Locale.ROOT);
        if (REFUSED.contains(normalized)) throw invalid("This key does not go to the target window.");
        Key key = KEYS.get(normalized);
        if (key == null) throw invalid("Unknown key name.");
        return key;
    }

    /** "Ctrl+Shift+K": modifiers in order, then at most one other key, which must come last. */
    static List<Key> chord(String text) {
        if (text == null || text.isBlank() || text.length() > 64) throw invalid("Invalid keys.");
        List<Key> keys = new ArrayList<>();
        String[] parts = text.split("\\+", -1);
        for (int i = 0; i < parts.length; i++) {
            if (parts[i].isBlank()) throw invalid("Invalid keys.");
            Key key = key(parts[i]);
            if (keys.contains(key)) throw invalid("A key appears twice.");
            if (!key.modifier() && i != parts.length - 1) throw invalid("Only the last key may be a non-modifier.");
            keys.add(key);
        }
        refuseShell(keys, Set.of());
        return keys;
    }

    /** Window switching combinations go to the shell, not to the target. Held modifiers count. */
    private static void refuseShell(List<Key> keys, Set<Key> held) {
        boolean alt = false;
        boolean ctrl = false;
        for (Key key : keys) {
            alt |= key.vk == VK_MENU;
            ctrl |= key.vk == VK_CONTROL;
        }
        for (Key key : held) {
            alt |= key.vk == VK_MENU;
            ctrl |= key.vk == VK_CONTROL;
        }
        for (Key key : keys) {
            if ((key.vk == VK_TAB && alt) || (key.vk == VK_ESCAPE && (alt || ctrl)))
                throw invalid("Window switching shortcuts are not sent.");
        }
    }

    /** Refuses a keyboard request that would combine with the session's held modifiers into a shell shortcut. */
    static void refuseShellShortcut(InputRequest request, Set<Key> held) {
        if (held.isEmpty()) return;
        List<Key> keys = new ArrayList<>(request.keys);
        for (Unit unit : request.text) if (unit.key != null) keys.add(unit.key);
        refuseShell(keys, held);
    }

    /** Typed text as units. CR LF, CR and LF become Enter, TAB becomes Tab. */
    static List<Unit> text(String text) {
        if (text == null || text.isEmpty() || text.length() > TEXT_LIMIT) throw invalid("Invalid text.");
        List<Unit> units = new ArrayList<>(text.length());
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (c == '\r') {
                if (i + 1 < text.length() && text.charAt(i + 1) == '\n') i++;
                units.add(Unit.key(ENTER));
            } else if (c == '\n') {
                units.add(Unit.key(ENTER));
            } else if (c == '\t') {
                units.add(Unit.key(TAB));
            } else if (c < 0x20 || c == 0x7F) {
                throw invalid("Control characters other than line breaks and tabs are not typed.");
            } else if (Character.isHighSurrogate(c)) {
                if (i + 1 >= text.length() || !Character.isLowSurrogate(text.charAt(i + 1)))
                    throw invalid("Invalid text.");
                units.add(Unit.text(c));
                units.add(Unit.text(text.charAt(++i)));
            } else if (Character.isLowSurrogate(c)) {
                throw invalid("Invalid text.");
            } else {
                units.add(Unit.text(c));
            }
        }
        return units;
    }

    private static AgentException invalid(String message) {
        return new AgentException("INVALID_REQUEST", message);
    }

    private InputKeys() {}
}
