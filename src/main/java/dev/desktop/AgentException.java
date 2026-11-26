package dev.desktop;

/** A protocol error with a stable code. {@link InputException} adds the outcome of physical input. */
public class AgentException extends RuntimeException {
    private final String code;

    public AgentException(String code, String message) {
        super(message);
        this.code = code;
    }

    public String code() {
        return code;
    }
}
