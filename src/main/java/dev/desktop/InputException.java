package dev.desktop;

/** A refused or interrupted physical input request. Tells the caller whether any input reached the system. */
final class InputException extends AgentException {
    private final boolean inputSent;
    private final boolean released;

    InputException(String code, String message, boolean inputSent, boolean released) {
        super(code, message);
        this.inputSent = inputSent;
        this.released = released;
    }

    /** Refused before any event was sent. */
    static InputException refused(String code, String message) {
        return new InputException(code, message, false, false);
    }

    boolean inputSent() { return inputSent; }

    boolean released() { return released; }

    InputException withRelease(boolean sent, boolean releasedNow) {
        return new InputException(code(), getMessage(), inputSent || sent, released || releasedNow);
    }
}
