package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.function.BooleanSupplier;

/** An in-process provider session that {@link JnaDesktopAdapter} confines to one thread. */
interface NativeSession extends TypedDesktopAdapter {
    /** Runs beforeMutation immediately before the provider call that changes the target. */
    JsonNode perform(DesktopAction action, String key, int processId, String value, Runnable beforeMutation);

    @Override
    default JsonNode perform(DesktopAction action, String key, int processId, String value) {
        return perform(action, key, processId, value, () -> {});
    }

    /** Called on the session thread while no request is running. */
    default void idle() {}

    /**
     * Handles the provider's own window messages on the session thread until done holds. Called
     * while another backend of the same process runs a request.
     */
    default void serve(BooleanSupplier done) {}

    /** Ends a wait inside {@link #serve} early. Callable from any thread. */
    default void wake() {}
}
