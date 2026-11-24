package dev.desktop;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sun.jna.platform.win32.Kernel32;
import dev.desktop.protocol.Utf8Frames;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.file.Path;
import java.time.Instant;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;
import java.util.function.IntPredicate;

/** One local foreground session. Every request and response occupies one UTF-8 line. */
public final class Cli {
    private static final Set<String> OPERATIONS = Set.of("getCapabilities", "listWindows", "snapshot",
            "findElement", "getElementInfo", "invoke", "setValue");
    static final int MAX_FRAME = Utf8Frames.COMMAND_LIMIT;
    private static final ObjectMapper JSON = new ObjectMapper()
            .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
            .enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION);

    public static void main(String[] args) throws IOException {
        int status = run(args, System.in, System.out);
        System.out.flush();
        // A provider thread that never returned holds native state that a normal exit would wait on.
        if (JnaDesktopAdapter.abandonedNativeThread() || JabBridge.detachWouldBlock()) {
            System.err.flush();
            // Unloading Java Access Bridge sends untimed messages to every JVM, so library detach is skipped.
            Kernel32.INSTANCE.TerminateProcess(Kernel32.INSTANCE.GetCurrentProcess(), status);
        }
        System.exit(status);
    }

    static int run(String[] args, InputStream input, OutputStream output) throws IOException {
        Map<Integer, Instant> allowedPids = new HashMap<>();
        Set<String> allowedActions = new HashSet<>();
        Path worker = null;
        String backend = null;
        String jabLibrary = null;
        DesktopAdapter selected;
        try {
            for (int i = 0; i < args.length; i += 2) {
                if (i + 1 >= args.length) throw new IllegalArgumentException();
                String value = args[i + 1];
                switch (args[i]) {
                    case "--backend" -> {
                        if (backend != null || !Set.of("jna", "jab", "powershell", Agent.MULTI).contains(value))
                            throw new IllegalArgumentException("Unknown or repeated backend.");
                        backend = value;
                    }
                    case "--jab-dll" -> {
                        if (jabLibrary != null || !Path.of(value).isAbsolute())
                            throw new IllegalArgumentException("Specify one absolute Java Access Bridge library.");
                        jabLibrary = value;
                    }
                    case "--csharp-worker" -> {
                        if (worker != null) throw new IllegalArgumentException("Specify one C# worker.");
                        worker = Path.of(value);
                    }
                    case "--allow-pid" -> {
                        int pid = Integer.parseInt(value);
                        if (pid <= 0) throw new IllegalArgumentException();
                        Instant started = ProcessHandle.of(pid).flatMap(handle -> handle.info().startInstant())
                                .orElseThrow(() -> new IllegalArgumentException("Cannot identify allowed PID."));
                        allowedPids.put(pid, started);
                    }
                    case "--allow-action" -> {
                        if (!Set.of("invoke", "setValue").contains(value))
                            throw new IllegalArgumentException();
                        allowedActions.add(value);
                    }
                    default -> throw new IllegalArgumentException();
                }
            }
            if (jabLibrary != null) {
                if (!"jab".equals(backend) && !Agent.MULTI.equals(backend))
                    throw new IllegalArgumentException("--jab-dll requires --backend jab or multi.");
                System.setProperty(JabBridge.LIBRARY_PROPERTY, jabLibrary);
            }
            // A multi-backend session opens its own adapters, one per backend.
            selected = Agent.MULTI.equals(backend) ? DesktopAdapters.none(worker) : DesktopAdapters.open(worker, backend);
        } catch (IllegalArgumentException invalid) {
            System.err.println("Usage: java -jar desktop-agent.jar [--allow-pid PID] "
                    + "[--allow-action invoke] [--allow-action setValue] "
                    + "[--backend jna|jab|multi|powershell OR --csharp-worker ABSOLUTE_EXE_PATH] [--jab-dll ABSOLUTE_DLL_PATH]");
            System.err.println("Each allowed PID must identify a running process with a readable start time.");
            System.err.println("The optional C# worker path must identify an existing .exe.");
            return 2;
        }
        Utf8Frames source = new Utf8Frames(input, MAX_FRAME);
        IntPredicate allowedProcess = pid -> allowedPids.containsKey(pid)
                && ProcessHandle.of(pid).filter(ProcessHandle::isAlive)
                        .flatMap(handle -> handle.info().startInstant())
                        .filter(allowedPids.get(pid)::equals).isPresent();
        try (Agent agent = selected == null ? Agent.multi(DesktopAdapters.multi(), allowedProcess, allowedActions)
                : new Agent(DesktopAdapters.label(worker, backend), selected, allowedProcess, allowedActions)) {
            long sequence = 0;
            while (true) {
                String frame;
                try {
                    frame = source.read();
                    if (frame == null) break;
                } catch (Utf8Frames.InvalidFrameException invalid) {
                    frame = "";
                }
                ObjectNode reply = dispatch(agent, frame, ++sequence);
                output.write(JSON.writeValueAsBytes(reply));
                output.write('\n');
                output.flush();
            }
        }
        return 0;
    }

    private static ObjectNode dispatch(Agent agent, String frame, long sequence) {
        long start = System.nanoTime();
        String op = "invalid";
        ObjectNode reply = invalidRequest();
        try {
            JsonNode node = JSON.readTree(frame);
            if (node instanceof ObjectNode request) {
                String requested = request.path("op").asText();
                if (OPERATIONS.contains(requested)) op = requested;
                reply = agent.handle(request);
            }
        } catch (IOException malformed) {
            // Parser diagnostics can contain input values. Keep them out of the protocol and logs.
        }
        String status = reply.path("ok").asBoolean() ? "OK" : reply.at("/error/code").asText();
        System.err.printf("%s seq=%d op=%s status=%s elapsedMs=%d%n", Instant.now(), sequence,
                op, status, (System.nanoTime() - start) / 1_000_000L);
        return reply;
    }

    private static ObjectNode invalidRequest() {
        ObjectNode reply = JSON.createObjectNode().putNull("id").put("ok", false);
        reply.putObject("error").put("code", "INVALID_REQUEST")
                .put("message", "Expected one UTF-8 JSON object within the frame limit.");
        return reply;
    }

    private Cli() {}
}
