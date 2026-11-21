package dev.desktop.legacy;

final class Fault extends RuntimeException {
    final String code;

    Fault(String code, String message) {
        super(message);
        this.code = code;
    }

    static Fault protocol() {
        return new Fault("WORKER_PROTOCOL", "Invalid enumeration worker response.");
    }

    static Fault unavailable() {
        return new Fault("BACKEND_UNAVAILABLE", "The enumeration worker is unavailable.");
    }
}
