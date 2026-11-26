package dev.desktop;

import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.Locale;

/**
 * Sends physical input to one validated top-level window. Implementations verify the window, its
 * process, the input desktop, integrity, DPI awareness, the foreground and the user's own input
 * before the first event, release everything they pressed when a request fails, and never retry.
 */
interface InputDriver extends AutoCloseable {
    /** The input row of getCapabilities: available, reason, dpiAwareness, integrity and the screen layout. */
    ObjectNode describe();

    /** The window rectangle in physical pixels. Fails with WINDOW_NOT_FOUND unless the process owns the window. */
    InputGeometry.Rect windowRect(long window, int processId);

    /**
     * Validates and sends one request within the deadline (System.nanoTime). gate runs right before
     * the first event and rechecks the session policy. Throws {@link InputException} with the
     * sent and released state, or TIMEOUT before and ACTION_OUTCOME_UNKNOWN after the first event.
     */
    ObjectNode execute(InputRequest request, Runnable gate, long deadline);

    /** Releases keys that the session still holds and stops monitoring. */
    @Override void close();

    static InputDriver open() {
        if (System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("windows"))
            return new WindowsInputDriver();
        return unavailable("This build sends physical input on Windows only.");
    }

    static InputDriver unavailable(String reason) {
        return new InputDriver() {
            @Override public ObjectNode describe() {
                return JsonNodeFactory.instance.objectNode().put("available", false).put("reason", reason);
            }

            @Override public InputGeometry.Rect windowRect(long window, int processId) {
                throw InputException.refused("INPUT_UNAVAILABLE", reason);
            }

            @Override public ObjectNode execute(InputRequest request, Runnable gate, long deadline) {
                throw InputException.refused("INPUT_UNAVAILABLE", reason);
            }

            @Override public void close() {}
        };
    }
}
