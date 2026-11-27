package dev.desktop;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

/** Deterministic hook delivery faults. These cases never start a native hook or send input. */
class InputHookObservationTest {
    @Test void aMouseObservationCannotReplaceAMissingKeyboardObservation() {
        WindowsInputDriver.Monitor monitor = new WindowsInputDriver.Monitor(1);
        monitor.expect(1, 2);
        monitor.recordMouse(true);
        monitor.recordMouse(true);
        monitor.recordKeyboard(true);

        assertFalse(monitor.awaitObserved(System.nanoTime(), () -> {}, () -> fail("already expired")));
        assertTrue(monitor.unhealthy());
    }

    @Test void bothDevicesMustObserveAllAcceptedEvents() {
        WindowsInputDriver.Monitor monitor = new WindowsInputDriver.Monitor(1);
        monitor.expect(1, 1);
        assertFalse(monitor.awaitObserved(System.nanoTime(), () -> {}, () -> fail("already expired")));
        assertTrue(monitor.unhealthy());

        WindowsInputDriver.Monitor replacement = new WindowsInputDriver.Monitor(2);
        replacement.expect(1, 1);
        replacement.recordMouse(true);
        replacement.recordKeyboard(true);
        assertTrue(replacement.awaitObserved(System.nanoTime(), () -> {}, () -> fail("already observed")));
        assertFalse(replacement.unhealthy());
    }

    @Test void foreignInputDoesNotCountAsAnObservation() {
        WindowsInputDriver.Monitor monitor = new WindowsInputDriver.Monitor(1);
        monitor.expect(1, 0);
        monitor.recordMouse(false);
        assertEquals(1, monitor.foreign.get());
        assertFalse(monitor.awaitObserved(System.nanoTime(), () -> {}, () -> fail("already expired")));
    }
}
