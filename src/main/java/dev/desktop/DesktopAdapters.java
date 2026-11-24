package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Locale;

/** Composition root. Backend selection happens once per CLI session, outside the shared core. */
final class DesktopAdapters {
    static DesktopAdapter open(Path csharpWorker, String backend) {
        if (backend != null && csharpWorker != null) throw new IllegalArgumentException("Select one backend.");
        if ("jna".equals(backend)) return new JnaDesktopAdapter();
        // An explicit choice. A Java Access Bridge failure is reported, never answered through UI Automation.
        if ("jab".equals(backend)) return JnaDesktopAdapter.javaAccessBridge();
        if ("powershell".equals(backend)) return new WindowsAdapter();
        return select(System.getProperty("os.name", ""), csharpWorker);
    }

    /**
     * The backends of a multi-backend session, default first. Each has its own thread, native
     * session and fault state. A future adapter, such as MSAA, is one more entry here.
     */
    static LinkedHashMap<String, Agent.BackendSource> multi() {
        var sources = new LinkedHashMap<String, Agent.BackendSource>();
        sources.put("UIA", new Agent.BackendSource(JnaDesktopAdapter::new, true));
        // Not restarted in place: a retired bridge session may have left its library loaded for a silent JVM.
        sources.put("JAB", new Agent.BackendSource(JnaDesktopAdapter::javaAccessBridge, false));
        return sources;
    }

    /** A multi-backend session takes no single adapter. It cannot be combined with a worker. */
    static DesktopAdapter none(Path csharpWorker) {
        if (csharpWorker != null) throw new IllegalArgumentException("Select one backend.");
        return null;
    }

    /** The backend name that the rows of a single-backend session carry. */
    static String label(Path csharpWorker, String backend) {
        if ("jab".equals(backend)) return "JAB";
        boolean windows = System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("windows");
        return backend != null || csharpWorker != null || windows ? "UIA" : "none";
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
