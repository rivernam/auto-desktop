package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;

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
}
