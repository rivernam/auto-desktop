package dev.desktop;

import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.List;
import java.util.Set;
import java.util.stream.Collectors;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

/** Platform-neutral rules of physical input: key names, typed text, coordinates and request fields. */
class InputLogicTest {
    private static final char HIGH = (char) 0xD83D;
    private static final char LOW = (char) 0xDE00;

    private static ObjectNode object() {
        return JsonNodeFactory.instance.objectNode();
    }

    private static void invalid(Runnable call) {
        AgentException failure = assertThrows(AgentException.class, call::run);
        assertEquals("INVALID_REQUEST", failure.code());
    }

    private static List<Integer> codes(List<InputKeys.Key> keys) {
        return keys.stream().map(k -> k.vk).collect(Collectors.toList());
    }

    @Test void chordsPressModifiersFirstAndRefuseShellShortcuts() {
        assertEquals(List.of(0x11, 0x10, 0x4B), codes(InputKeys.chord("ctrl+Shift+k")));
        assertEquals(List.of(0x12), codes(InputKeys.chord("Alt")));
        assertEquals(List.of(0x70), codes(InputKeys.chord("F1")));
        assertEquals(List.of(0x87), codes(InputKeys.chord("F24")));
        assertEquals(List.of(0x11, 0x2E), codes(InputKeys.chord("Control+Del")));
        for (String refused : List.of("Alt+Tab", "Alt+Shift+Tab", "Alt+Esc", "Ctrl+Escape", "Ctrl+Shift+Esc", "Win+R",
                "LWin", "CapsLock", "PrintScreen", "K+Ctrl", "Ctrl++K", "Ctrl+Ctrl+K", "A+B", "", "Ctrl+", "Hyper",
                " Ctrl+K", "Ctrl+K "))
            invalid(() -> InputKeys.chord(refused));
    }

    @Test void heldModifiersCountForShellShortcuts() {
        Set<InputKeys.Key> alt = Set.of(InputKeys.key("Alt"));
        ObjectNode tab = targeted("keyPress").put("keys", "Tab");
        invalid(() -> InputKeys.refuseShellShortcut(InputRequest.parse("keyPress", tab), alt));
        ObjectNode typed = targeted("typeText").put("text", "a\tb");
        invalid(() -> InputKeys.refuseShellShortcut(InputRequest.parse("typeText", typed), alt));
        ObjectNode escape = targeted("keyDown").put("key", "Esc");
        invalid(() -> InputKeys.refuseShellShortcut(InputRequest.parse("keyDown", escape), Set.of(InputKeys.key("Ctrl"))));
        InputKeys.refuseShellShortcut(InputRequest.parse("keyPress", tab), Set.of(InputKeys.key("Shift")));
        InputKeys.refuseShellShortcut(InputRequest.parse("typeText", typed), Set.of());
    }

    @Test void navigationKeysAreExtended() {
        for (String name : List.of("Insert", "Delete", "Home", "End", "PageUp", "PageDown", "Left", "Right", "Up", "Down",
                "Divide", "Apps"))
            assertTrue(InputKeys.key(name).extended, name);
        for (String name : List.of("Enter", "Tab", "A", "5", "NumPad5", "Shift", "Ctrl", "Alt", "Backspace"))
            assertFalse(InputKeys.key(name).extended, name);
    }

    @Test void textTurnsLineBreaksIntoKeysAndKeepsSurrogatePairs() {
        String text = "a\r\nb\rc\nd\t" + HIGH + LOW + "한";
        List<InputKeys.Unit> units = InputKeys.text(text);
        assertEquals(11, units.size());
        assertEquals('a', units.get(0).character);
        assertSame(InputKeys.ENTER, units.get(1).key);
        assertSame(InputKeys.ENTER, units.get(3).key);
        assertSame(InputKeys.ENTER, units.get(5).key);
        assertSame(InputKeys.TAB, units.get(7).key);
        assertEquals(HIGH, units.get(8).character);
        assertEquals(LOW, units.get(9).character);
        invalid(() -> InputKeys.text(""));
        invalid(() -> InputKeys.text("bell" + (char) 7));
        invalid(() -> InputKeys.text("x" + (char) 0x7F));
        invalid(() -> InputKeys.text(String.valueOf(HIGH)));
        invalid(() -> InputKeys.text(LOW + "x"));
        invalid(() -> InputKeys.text("x".repeat(1025)));
        assertEquals(1024, InputKeys.text("x".repeat(1024)).size());
    }

    @Test void normalizedCoordinatesLandOnTheRequestedPixel() {
        int[][] screens = {{0, 1920}, {-1920, 3840}, {-1280, 3200}, {0, 1366}, {-2560, 5120}, {0, 1}, {-3, 7}};
        for (int[] screen : screens) {
            for (int pixel = screen[0]; pixel < screen[0] + screen[1]; pixel++) {
                int normalized = InputGeometry.normalize(pixel, screen[0], screen[1]);
                assertTrue(normalized >= 0 && normalized <= 65535);
                assertEquals(pixel, InputGeometry.denormalize(normalized, screen[0], screen[1]));
            }
        }
        AgentException outside = assertThrows(AgentException.class, () -> InputGeometry.normalize(1920, 0, 1920));
        assertEquals("PRECONDITION_FAILED", outside.code());
        assertThrows(AgentException.class, () -> InputGeometry.normalize(-1921, -1920, 3840));
    }

    @Test void boundsAreMappedOnlyWhenTheWindowConfirmsTheScale() {
        var window = new InputGeometry.Rect(-1500, 200, -500, 950);
        var same = InputGeometry.mapping(window, new InputGeometry.Bounds(-1499, 201, 1000, 750));
        assertEquals("physical", same.kind);
        var element = same.apply(new InputGeometry.Bounds(-1400, 300, 100, 40));
        assertArrayEquals(new int[] {-1350, 320}, InputGeometry.point(element, 0.5, 0.5));
        assertArrayEquals(new int[] {-1400, 300}, InputGeometry.point(element, 0, 0));
        assertArrayEquals(new int[] {-1301, 339}, InputGeometry.point(element, 1, 1));

        // A HiDPI JVM reports logical pixels at 125 %.
        var scaled = InputGeometry.mapping(window, new InputGeometry.Bounds(-1200, 160, 800, 600));
        assertEquals("scaled", scaled.kind);
        var mapped = scaled.apply(new InputGeometry.Bounds(-1100, 240, 80, 32));
        assertEquals(-1375, mapped.x, 1e-9);
        assertEquals(300, mapped.y, 1e-9);
        assertEquals(100, mapped.width, 1e-9);
        assertEquals(40, mapped.height, 1e-9);

        for (var unrelated : List.of(new InputGeometry.Bounds(0, 0, 1000, 500), new InputGeometry.Bounds(0, 0, 100, 75),
                new InputGeometry.Bounds(0, 0, 0, 750)))
            assertEquals("BOUNDS_UNVERIFIED", assertThrows(AgentException.class,
                    () -> InputGeometry.mapping(window, unrelated)).code());
        assertEquals("BOUNDS_UNVERIFIED", assertThrows(AgentException.class,
                () -> InputGeometry.mapping(window, null)).code());
        assertEquals("PRECONDITION_FAILED", assertThrows(AgentException.class,
                () -> InputGeometry.point(new InputGeometry.Bounds(5, 5, 0.4, 10), 0.5, 0.5)).code());
    }

    @Test void physicalBoundsToleranceIncludesBothOnePercentLimits() {
        var root = new InputGeometry.Bounds(100, 200, 1000, 1000);
        for (int size : List.of(989, 990, 1010, 1011)) {
            var window = new InputGeometry.Rect(100, 200, 100 + size, 200 + size);
            assertEquals(size == 990 || size == 1010 ? "physical" : "scaled",
                    InputGeometry.mapping(window, root).kind, "window size " + size);
        }
    }

    @Test void halfPixelsRoundUpOnBothSides() {
        assertEquals(-2, InputGeometry.round(-2.5));
        assertEquals(3, InputGeometry.round(2.5));
        assertArrayEquals(new int[] {-3, 3}, InputGeometry.point(new InputGeometry.Bounds(-3.5, 2.5, 1, 1), 0, 0));
        // Fractional mapped bounds round before the fraction applies.
        assertArrayEquals(new int[] {-11, 7}, InputGeometry.point(new InputGeometry.Bounds(-12.5, 5.5, 2.4, 2.6), 0.5, 0.5));
    }

    private static ObjectNode targeted(String op) {
        return object().put("op", op).put("windowId", "4242").put("processId", 42);
    }

    @Test void requestsAreValidatedBeforeAnyDevice() {
        ObjectNode click = targeted("pointerClick");
        click.putObject("point").put("x", -10).put("y", 20).put("space", "screen");
        InputRequest parsed = InputRequest.parse("pointerClick", click.deepCopy().put("button", "right").put("clicks", 2));
        assertEquals(4242L, parsed.window);
        assertEquals(InputRequest.Button.RIGHT, parsed.button);
        assertEquals(2, parsed.clicks);
        assertEquals(500, parsed.quietMs);
        assertEquals(-10, parsed.point.x);
        assertEquals(-5L, InputRequest.parse("pointerClick", click.deepCopy().put("windowId", "-5")).window);

        invalid(() -> InputRequest.parse("pointerMove", targeted("pointerMove")));
        ObjectNode noSpace = targeted("pointerMove");
        noSpace.putObject("point").put("x", 1).put("y", 2);
        invalid(() -> InputRequest.parse("pointerMove", noSpace));
        ObjectNode fractional = targeted("pointerMove");
        fractional.putObject("point").put("x", 1.5).put("y", 2).put("space", "client");
        invalid(() -> InputRequest.parse("pointerMove", fractional));
        invalid(() -> InputRequest.parse("pointerClick", click.deepCopy().put("clicks", 3)));
        invalid(() -> InputRequest.parse("pointerClick", click.deepCopy().put("button", "x1")));
        invalid(() -> InputRequest.parse("pointerClick", click.deepCopy().put("windowId", "0x10")));
        invalid(() -> InputRequest.parse("pointerClick", click.deepCopy().put("windowId", "0")));
        invalid(() -> InputRequest.parse("pointerClick", click.deepCopy().without("processId")));
        invalid(() -> InputRequest.parse("pointerClick", click.deepCopy().put("quietMs", 10_001)));

        ObjectNode drag = targeted("pointerDrag");
        drag.putObject("from").put("x", 1).put("y", 2).put("space", "window");
        drag.putObject("to").put("x", 30).put("y", 2).put("space", "window");
        assertEquals(10, InputRequest.parse("pointerDrag", drag).steps);
        assertEquals(100, InputRequest.parse("pointerDrag", drag.deepCopy().put("steps", 100).put("stepDelayMs", 50)).steps);
        invalid(() -> InputRequest.parse("pointerDrag", drag.deepCopy().put("steps", 100).put("stepDelayMs", 51)));
        invalid(() -> InputRequest.parse("pointerDrag", drag.deepCopy().put("steps", 0)));

        ObjectNode scroll = targeted("pointerScroll");
        scroll.putObject("point").put("x", 1).put("y", 2).put("space", "client");
        invalid(() -> InputRequest.parse("pointerScroll", scroll));
        assertTrue(InputRequest.parse("pointerScroll", scroll.deepCopy().put("delta", -3).put("axis", "horizontal")).horizontal);
        invalid(() -> InputRequest.parse("pointerScroll", scroll.deepCopy().put("delta", 21)));

        assertEquals(3, InputRequest.parse("keyPress", targeted("keyPress").put("keys", "Ctrl+Shift+K")).keys.size());
        invalid(() -> InputRequest.parse("keyDown", targeted("keyDown").put("key", "Ctrl+K")));
        assertEquals(2, InputRequest.parse("typeText", targeted("typeText").put("text", "ab").put("intervalMs", 50)).text.size());
        invalid(() -> InputRequest.parse("typeText", targeted("typeText").put("text", "ab").put("intervalMs", 51)));
        invalid(() -> InputRequest.parse("typeText", targeted("typeText").put("text", 5)));
    }

    @Test void capabilityOrderIsFixed() {
        assertEquals(List.of("activateWindow", "pointerMove", "pointerClick", "pointerDrag", "pointerScroll", "clickElement",
                "keyPress", "keyDown", "keyUp", "typeText"), List.copyOf(InputRequest.OPERATIONS.keySet()));
    }
}
