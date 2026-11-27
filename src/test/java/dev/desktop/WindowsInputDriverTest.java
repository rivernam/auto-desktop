package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sun.jna.Pointer;
import com.sun.jna.platform.win32.Kernel32;
import com.sun.jna.platform.win32.User32;
import com.sun.jna.platform.win32.WinDef.HWND;
import com.sun.jna.ptr.IntByReference;
import java.lang.reflect.Field;
import java.util.Set;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;
import static org.junit.jupiter.api.Assertions.*;

/**
 * The native device on the real desktop, through paths that end before any event: it reads the
 * environment and refuses. It never sends input, never activates a window and installs no hook.
 */
@EnabledOnOs(OS.WINDOWS)
class WindowsInputDriverTest {
    private static ObjectNode move(long window, int pid, int x, int y) {
        ObjectNode request = JsonNodeFactory.instance.objectNode().put("windowId", Long.toString(window))
                .put("processId", pid);
        request.putObject("point").put("x", x).put("y", y).put("space", "screen");
        return request;
    }

    private static Object monitor(WindowsInputDriver driver) throws ReflectiveOperationException {
        Field field = WindowsInputDriver.class.getDeclaredField("monitor");
        field.setAccessible(true);
        return field.get(driver);
    }

    @Test void describesTheInputEnvironment() {
        try (WindowsInputDriver driver = new WindowsInputDriver()) {
            JsonNode row = driver.describe();
            assertTrue(Set.of("perMonitorV2", "perMonitor", "system", "unaware").contains(row.get("dpiAwareness").asText()), row::toString);
            assertTrue(row.get("virtualScreen").get("width").asInt() > 0, row::toString);
            assertTrue(row.get("monitors").asInt() >= 1, row::toString);
            assertTrue(row.has("integrity") && row.has("inputDesktop") && row.has("buttonsSwapped"), row::toString);
            System.out.println("input environment: " + row);
        }
    }

    @Test void createsAndReleasesThePrivateClipboardOwnerWithoutOpeningTheClipboard() {
        try (WindowsInputDriver driver = new WindowsInputDriver()) {
            org.junit.jupiter.api.Assumptions.assumeTrue(driver.describe().path("available").asBoolean());
        }
        assertDoesNotThrow(() -> {
            try (WindowsClipboard ignored = new WindowsClipboard(Kernel32.INSTANCE.GetCurrentProcessId(),
                    () -> fail("Opening a private window must not start a paste."), System.nanoTime() + 1_000_000_000L)) {
                // Construction alone needs a valid pointer-sized HWND_MESSAGE on x64.
            }
        });
    }

    @Test void refusalsSendNothingAndInstallNoHook() throws ReflectiveOperationException {
        HWND tray = User32.INSTANCE.FindWindow("Shell_TrayWnd", null);
        AtomicInteger gates = new AtomicInteger();
        Runnable gate = gates::incrementAndGet;
        long deadline = System.nanoTime() + 5_000_000_000L;
        try (WindowsInputDriver driver = new WindowsInputDriver()) {
            InputException missing = assertThrows(InputException.class, () -> driver.execute(
                    InputRequest.parse("pointerMove", move(1, 4, 0, 0)), gate, deadline));
            assertEquals("WINDOW_NOT_FOUND", missing.code());
            assertFalse(missing.inputSent());
            if (tray != null) {
                long handle = Pointer.nativeValue(tray.getPointer());
                IntByReference pid = new IntByReference();
                User32.INSTANCE.GetWindowThreadProcessId(tray, pid);
                InputException wrongOwner = assertThrows(InputException.class, () -> driver.execute(
                        InputRequest.parse("pointerMove", move(handle, pid.getValue() + 1, 0, 0)), gate, deadline));
                assertEquals("WINDOW_NOT_FOUND", wrongOwner.code());
                // Far outside every window: even with the taskbar in front, step 9 refuses before input.
                InputException refused = assertThrows(InputException.class, () -> driver.execute(
                        InputRequest.parse("pointerMove", move(handle, pid.getValue(), -1_000_000, -1_000_000)), gate, deadline));
                assertTrue(Set.of("FOREGROUND_MISMATCH", "USER_INPUT_CONFLICT", "PRECONDITION_FAILED", "INTEGRITY_MISMATCH",
                        "INPUT_DESKTOP_UNAVAILABLE").contains(refused.code()), refused.code());
                assertFalse(refused.inputSent());
                assertEquals("WINDOW_NOT_FOUND", assertThrows(InputException.class,
                        () -> driver.windowRect(handle, pid.getValue() + 1)).code());
                InputGeometry.Rect rect = driver.windowRect(handle, pid.getValue());
                assertTrue(rect.width() > 0 && rect.height() > 0);
            }
            assertEquals(0, gates.get());
            assertNull(monitor(driver));
        }
    }
}
