package dev.desktop;

import com.fasterxml.jackson.core.JsonParser;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sun.jna.platform.win32.Kernel32;
import dev.desktop.protocol.Utf8Frames;
import java.io.FileDescriptor;
import java.io.FileOutputStream;
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
            "findElement", "getElementInfo", "invoke", "setValue", "defaultAction", "select");
    static final int MAX_FRAME = Utf8Frames.COMMAND_LIMIT;
    private static final ObjectMapper JSON = new ObjectMapper()
            .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS)
            .enable(JsonParser.Feature.STRICT_DUPLICATE_DETECTION);

    public static void main(String[] args) {
        int status;
        try {
            status = run(args, System.in, new FileOutputStream(FileDescriptor.out));
        } catch (IOException failure) {
            System.err.println("The agent input or output stream failed.");
            status = 1;
        }
        System.out.flush();
        // A provider thread that never returned holds native state that a normal exit would wait on.
        if (JnaDesktopAdapter.nativeExitRequired() || JabBridge.detachWouldBlock()) {
            System.err.flush();
            // Unloading Java Access Bridge sends untimed messages to every JVM, so library detach is skipped.
            Kernel32.INSTANCE.TerminateProcess(Kernel32.INSTANCE.GetCurrentProcess(), status);
        }
        System.exit(status);
    }

    static int run(String[] args, InputStream input, OutputStream output) throws IOException {
        Map<Integer, Instant> allowedPids = new HashMap<>();
        Set<Integer> trustedMsaaPids = new HashSet<>();
        Set<String> allowedActions = new HashSet<>();
        IntPredicate allowedProcess = pid -> allowedPids.containsKey(pid)
                && ProcessHandle.of(pid).filter(ProcessHandle::isAlive)
                        .flatMap(handle -> handle.info().startInstant())
                        .filter(allowedPids.get(pid)::equals).isPresent();
        IntPredicate trustedMsaa = pid -> trustedMsaaPids.contains(pid) && allowedProcess.test(pid);
        Path worker = null;
        String backend = null;
        String jabLibrary = null;
        DesktopAdapter selected;
        try {
            for (int i = 0; i < args.length; i += 2) {
                if (i + 1 >= args.length) throw new IllegalArgumentException();
                String value = args[i + 1];
                switch (args[i]) {
                    case "--backend": {
                        if (backend != null || !Set.of("jna", "jab", "msaa", "powershell", Agent.MULTI).contains(value))
                            throw new IllegalArgumentException("Unknown or repeated backend.");
                        backend = value;
                        break;
                    }
                    case "--jab-dll": {
                        if (jabLibrary != null || !Path.of(value).isAbsolute())
                            throw new IllegalArgumentException("Specify one absolute Java Access Bridge library.");
                        jabLibrary = value;
                        break;
                    }
                    case "--csharp-worker": {
                        if (worker != null) throw new IllegalArgumentException("Specify one C# worker.");
                        worker = Path.of(value);
                        break;
                    }
                    case "--allow-pid": {
                        int pid = Integer.parseInt(value);
                        if (pid <= 0) throw new IllegalArgumentException();
                        Instant started = ProcessHandle.of(pid).flatMap(handle -> handle.info().startInstant())
                                .orElseThrow(() -> new IllegalArgumentException("Cannot identify allowed PID."));
                        allowedPids.put(pid, started);
                        break;
                    }
                    case "--trust-msaa-identity": {
                        int pid = Integer.parseInt(value);
                        if (pid <= 0) throw new IllegalArgumentException();
                        trustedMsaaPids.add(pid);
                        break;
                    }
                    case "--allow-action": {
                        if (!Set.of("invoke", "setValue", "defaultAction", "select").contains(value))
                            throw new IllegalArgumentException();
                        allowedActions.add(value);
                        break;
                    }
                    default:
                        throw new IllegalArgumentException();
                }
            }
            if (!trustedMsaaPids.isEmpty() && ((!"msaa".equals(backend) && !Agent.MULTI.equals(backend))
                    || !allowedPids.keySet().containsAll(trustedMsaaPids)))
                throw new IllegalArgumentException("Trusted MSAA providers must also be allowed targets.");
            if (jabLibrary != null) {
                if (!"jab".equals(backend) && !Agent.MULTI.equals(backend))
                    throw new IllegalArgumentException("--jab-dll requires --backend jab or multi.");
                System.setProperty(JabBridge.LIBRARY_PROPERTY, jabLibrary);
            }
            // A multi-backend session opens its own adapters, one per backend.
            selected = Agent.MULTI.equals(backend) ? DesktopAdapters.none(worker)
                    : DesktopAdapters.open(worker, backend, trustedMsaa);
        } catch (IllegalArgumentException invalid) {
            System.err.println("Usage: java -jar desktop-agent.jar [--allow-pid PID] "
                    + "[--allow-action invoke|setValue|defaultAction|select] "
                    + "[--backend jna|jab|msaa|multi|powershell OR --csharp-worker ABSOLUTE_EXE_PATH] "
                    + "[--jab-dll ABSOLUTE_DLL_PATH] [--trust-msaa-identity PID]");
            System.err.println("Each allowed PID must identify a running process with a readable start time.");
            System.err.println("The optional C# worker path must identify an existing .exe.");
            return 2;
        }
        Utf8Frames source = new Utf8Frames(input, MAX_FRAME);
        try (Agent agent = selected == null ? Agent.multi(DesktopAdapters.multi(trustedMsaa), allowedProcess, allowedActions)
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
        } catch (AgentException failure) {
            if (!"BACKEND_CLEANUP_FAILED".equals(failure.code())) throw failure;
            System.err.println("BACKEND_CLEANUP_FAILED: " + failure.getMessage());
            return 1;
        }
        return 0;
    }

    private static ObjectNode dispatch(Agent agent, String frame, long sequence) {
        long start = System.nanoTime();
        String op = "invalid";
        ObjectNode reply = invalidRequest();
        try {
            JsonNode node = JSON.readTree(frame);
            if (node instanceof ObjectNode) {
                ObjectNode request = (ObjectNode) node;
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
