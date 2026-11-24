package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import java.util.HashSet;
import java.util.Set;
import java.util.function.IntPredicate;

/** Session-local action authorization and dispatch history, shared across snapshots. */
final class ActionDispatcher {
    private static final int COMMAND_LIMIT = 4096;
    private final IntPredicate allowedProcess;
    private final Set<String> allowedActions;
    private final Set<String> dispatched = new HashSet<>();

    ActionDispatcher(IntPredicate allowedProcess, Set<String> allowedActions) {
        this.allowedProcess = allowedProcess;
        this.allowedActions = Set.copyOf(allowedActions);
    }

    void checkUnused(String id) {
        if (dispatched.contains(id))
            throw new AgentException("DUPLICATE_COMMAND", "This command ID has already been dispatched.");
    }

    JsonNode dispatch(DesktopAdapter adapter, String id, DesktopAction action, DesktopSnapshot.Element target,
                      JsonNode value, Runnable checkReference) {
        if (!allowedProcess.test(target.processId()) || !allowedActions.contains(action.wireName()))
            throw new AgentException("PERMISSION_DENIED", "The process and action must both be allowed.");
        if (!target.properties().get("enabled").booleanValue())
            throw new AgentException("PRECONDITION_FAILED", "The element is disabled.");
        if (!target.offers(action))
            throw new AgentException("PATTERN_UNSUPPORTED", "The element does not support this action.");
        String text = null;
        if (action == DesktopAction.SET_VALUE) {
            if (!value.isTextual() || value.textValue().length() > 16384)
                throw new AgentException("INVALID_REQUEST", "Invalid value.");
            text = value.textValue();
        }
        if (dispatched.size() >= COMMAND_LIMIT)
            throw new AgentException("SESSION_LIMIT", "Start a new agent session to dispatch more commands.");
        // Remember the ID before dispatch. A timeout can arrive after the action has taken effect.
        dispatched.add(id);
        return adapter.perform(action, target.key(), target.processId(), text, () -> {
            checkReference.run();
            if (!allowedProcess.test(target.processId()))
                throw new AgentException("PERMISSION_DENIED", "The target process is no longer allowed.");
        });
    }
}
