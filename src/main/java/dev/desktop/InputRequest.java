package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.List;
import java.util.Locale;
import java.util.Map;

/** One validated physical input request. Window-targeted operations only; clickElement resolves to a click. */
final class InputRequest {
    enum Kind { ACTIVATE, MOVE, CLICK, DRAG, SCROLL, KEY_PRESS, KEY_DOWN, KEY_UP, TYPE_TEXT }

    enum Space { SCREEN, WINDOW, CLIENT }

    enum Button { LEFT, RIGHT, MIDDLE }

    enum TextMethod {
        UNICODE("unicode"), VIRTUAL_KEY("virtualKey"), SCAN_CODE("scanCode");

        final String protocolName;

        TextMethod(String protocolName) { this.protocolName = protocolName; }

        static TextMethod parse(JsonNode field) {
            if (field == null) return UNICODE;
            if (field.isTextual()) {
                for (TextMethod method : values()) {
                    if (method.protocolName.equals(field.textValue())) return method;
                }
            }
            throw invalid("Invalid method.");
        }
    }

    static final class Point {
        final int x;
        final int y;
        final Space space;

        Point(int x, int y, Space space) {
            this.x = x;
            this.y = y;
            this.space = space;
        }
    }

    /** Operation name to the action that allows it. Insertion order is the capability order. */
    static final Map<String, String> OPERATIONS = orderedOperations();
    static final List<String> ACTIONS = List.of("activate", "keyboard", "pointer");
    static final int DEFAULT_QUIET_MS = 500;
    static final int HELD_KEY_LIMIT = 8;
    static final int TEXT_CHUNK = 16;

    final Kind kind;
    final long window;
    final int processId;
    final int quietMs;
    Point point;
    Point from;
    Point to;
    Button button = Button.LEFT;
    int clicks = 1;
    int steps = 10;
    int stepDelayMs = 10;
    int delta;
    boolean horizontal;
    List<InputKeys.Key> keys = List.of();
    List<InputKeys.Unit> text = List.of();
    TextMethod textMethod = TextMethod.UNICODE;
    int intervalMs;

    private InputRequest(Kind kind, long window, int processId, int quietMs) {
        this.kind = kind;
        this.window = window;
        this.processId = processId;
        this.quietMs = quietMs;
    }

    private static Map<String, String> orderedOperations() {
        var operations = new java.util.LinkedHashMap<String, String>();
        operations.put("activateWindow", "activate");
        for (String op : List.of("pointerMove", "pointerClick", "pointerDrag", "pointerScroll", "clickElement"))
            operations.put(op, "pointer");
        for (String op : List.of("keyPress", "keyDown", "keyUp", "typeText")) operations.put(op, "keyboard");
        return java.util.Collections.unmodifiableMap(operations);
    }

    static boolean isInput(String op) { return OPERATIONS.containsKey(op); }

    boolean keyboard() {
        return kind == Kind.KEY_PRESS || kind == Kind.KEY_DOWN || kind == Kind.KEY_UP || kind == Kind.TYPE_TEXT;
    }

    /** A click at a resolved screen point, for clickElement. */
    static InputRequest click(long window, int processId, int x, int y, Button button, int clicks, int quietMs) {
        InputRequest request = new InputRequest(Kind.CLICK, window, processId, quietMs);
        request.point = new Point(x, y, Space.SCREEN);
        request.button = button;
        request.clicks = clicks;
        return request;
    }

    /** Parses a window-targeted operation. clickElement is parsed by the session, which owns references. */
    static InputRequest parse(String op, ObjectNode request) {
        Kind kind;
        switch (op) {
            case "activateWindow": kind = Kind.ACTIVATE; break;
            case "pointerMove": kind = Kind.MOVE; break;
            case "pointerClick": kind = Kind.CLICK; break;
            case "pointerDrag": kind = Kind.DRAG; break;
            case "pointerScroll": kind = Kind.SCROLL; break;
            case "keyPress": kind = Kind.KEY_PRESS; break;
            case "keyDown": kind = Kind.KEY_DOWN; break;
            case "keyUp": kind = Kind.KEY_UP; break;
            case "typeText": kind = Kind.TYPE_TEXT; break;
            default: throw new AgentException("UNKNOWN_OPERATION", "Unknown operation.");
        }
        InputRequest parsed = new InputRequest(kind, window(request), processId(request), quietMs(request));
        switch (kind) {
            case MOVE:
                parsed.point = point(request, "point");
                break;
            case CLICK:
                parsed.point = point(request, "point");
                parsed.button = button(request);
                parsed.clicks = clicks(request);
                break;
            case DRAG:
                parsed.from = point(request, "from");
                parsed.to = point(request, "to");
                parsed.button = button(request);
                parsed.steps = integer(request, "steps", 10, 1, 100);
                parsed.stepDelayMs = integer(request, "stepDelayMs", 10, 0, 100);
                if (parsed.steps * parsed.stepDelayMs > 5000) throw invalid("The drag would take too long.");
                break;
            case SCROLL:
                parsed.point = point(request, "point");
                parsed.delta = integer(request, "delta", 0, -20, 20);
                if (parsed.delta == 0) throw invalid("Invalid delta.");
                parsed.horizontal = "horizontal".equals(choice(request, "axis", "vertical", "vertical", "horizontal"));
                break;
            case KEY_PRESS:
                parsed.keys = InputKeys.chord(text(request, "keys", 64));
                break;
            case KEY_DOWN:
            case KEY_UP:
                parsed.keys = List.of(InputKeys.key(text(request, "key", 32)));
                break;
            case TYPE_TEXT: {
                JsonNode value = request.get("text");
                if (value == null || !value.isTextual()) throw invalid("Invalid text.");
                parsed.text = InputKeys.text(value.textValue());
                parsed.textMethod = TextMethod.parse(request.get("method"));
                parsed.intervalMs = integer(request, "intervalMs", 0, 0, 50);
                break;
            }
            default:
                break;
        }
        return parsed;
    }

    static long window(ObjectNode request) {
        String id = text(request, "windowId", 256);
        if (!id.matches("-?[0-9]{1,20}")) throw invalid("Invalid windowId.");
        try {
            long handle = Long.parseLong(id);
            if (handle == 0) throw invalid("Invalid windowId.");
            return handle;
        } catch (NumberFormatException overflow) {
            throw invalid("Invalid windowId.");
        }
    }

    static int processId(ObjectNode request) {
        return integer(request, "processId", -1, 1, Integer.MAX_VALUE);
    }

    static int quietMs(ObjectNode request) {
        return integer(request, "quietMs", DEFAULT_QUIET_MS, 0, 10_000);
    }

    static Button button(ObjectNode request) {
        return Button.valueOf(choice(request, "button", "left", "left", "right", "middle").toUpperCase(Locale.ROOT));
    }

    static int clicks(ObjectNode request) {
        return integer(request, "clicks", 1, 1, 2);
    }

    static double fraction(JsonNode position, String axis) {
        if (position == null) return 0.5;
        JsonNode value = position.get(axis);
        if (value == null) return 0.5;
        if (!value.isNumber() || !(value.doubleValue() >= 0 && value.doubleValue() <= 1))
            throw invalid("Invalid position.");
        return value.doubleValue();
    }

    private static Point point(ObjectNode request, String field) {
        JsonNode node = request.get(field);
        if (node == null || !node.isObject()) throw invalid("Invalid " + field + ".");
        JsonNode x = node.get("x");
        JsonNode y = node.get("y");
        JsonNode space = node.get("space");
        if (x == null || y == null || !x.isIntegralNumber() || !y.isIntegralNumber() || !x.canConvertToInt()
                || !y.canConvertToInt() || space == null || !space.isTextual()) throw invalid("Invalid " + field + ".");
        Space parsed;
        switch (space.textValue()) {
            case "screen": parsed = Space.SCREEN; break;
            case "window": parsed = Space.WINDOW; break;
            case "client": parsed = Space.CLIENT; break;
            default: throw invalid("Invalid " + field + ".");
        }
        return new Point(x.intValue(), y.intValue(), parsed);
    }

    private static String choice(ObjectNode request, String field, String fallback, String... allowed) {
        JsonNode value = request.get(field);
        if (value == null) return fallback;
        if (value.isTextual()) for (String option : allowed) if (option.equals(value.textValue())) return option;
        throw invalid("Invalid " + field + ".");
    }

    private static String text(ObjectNode request, String field, int limit) {
        JsonNode value = request.get(field);
        if (value == null || !value.isTextual() || value.textValue().isBlank() || value.textValue().length() > limit)
            throw invalid("Invalid " + field + ".");
        return value.textValue();
    }

    /** A fallback of -1 makes the field required. */
    static int integer(ObjectNode request, String field, int fallback, int min, int max) {
        JsonNode value = request.get(field);
        if (value == null && fallback != -1) return fallback;
        if (value == null || !value.isIntegralNumber() || !value.canConvertToInt() || value.intValue() < min
                || value.intValue() > max) throw invalid("Invalid " + field + ".");
        return value.intValue();
    }

    private static AgentException invalid(String message) {
        return new AgentException("INVALID_REQUEST", message);
    }
}
