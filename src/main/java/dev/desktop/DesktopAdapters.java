package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.nio.file.Path;
import java.util.Locale;

/** Composition root. Backend selection happens once per CLI session, outside the shared core. */
final class DesktopAdapters {
    static DesktopAdapter open(Path csharpWorker) {
        return select(System.getProperty("os.name", ""), csharpWorker);
    }

    static DesktopAdapter select(String os, Path csharpWorker) {
        if (csharpWorker != null) return WindowsAdapter.forCSharpWorker(csharpWorker);
        if (os.toLowerCase(Locale.ROOT).startsWith("windows")) return new WindowsAdapter();
        String reason = os.equalsIgnoreCase("linux")
                ? "This build does not include a Linux accessibility adapter."
                : "This build does not include an accessibility adapter for this operating system.";
        return new DesktopAdapter() {
            @Override public JsonNode call(ObjectNode request) {
                if ("getCapabilities".equals(request.path("op").asText())) {
                    return DesktopCapabilities.unavailable("none", reason);
                }
                throw new AgentException("BACKEND_UNAVAILABLE", reason);
            }
            @Override public void close() {}
        };
    }

    private DesktopAdapters() {}
}
