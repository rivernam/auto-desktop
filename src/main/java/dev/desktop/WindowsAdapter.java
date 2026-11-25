package dev.desktop;

import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.Duration;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;

/** One serialized, disposable UI Automation worker per adapter. */
public final class WindowsAdapter implements DesktopAdapter {
    private static final ObjectMapper JSON = new ObjectMapper()
            .enable(DeserializationFeature.FAIL_ON_TRAILING_TOKENS);
    private static final int MAX_FRAME = 8 * 1024 * 1024;
    private final boolean available;
    private final List<String> workerCommand;
    private final Duration timeout;
    private final ExecutorService io = Executors.newCachedThreadPool(task -> {
        Thread thread = new Thread(task, "uia-worker-pipe");
        thread.setDaemon(true);
        return thread;
    });
    private Path script;
    private Process worker;
    private InputStream responses;
    private boolean closed;

    public WindowsAdapter() {
        this(null, Duration.ofSeconds(10), isWindows());
    }

    /** Select a locally installed managed worker at process startup, using the same pipe protocol. */
    public static WindowsAdapter forCSharpWorker(Path executable) {
        if (!executable.isAbsolute() || !Files.isRegularFile(executable)
                || !executable.getFileName().toString().toLowerCase(Locale.ROOT).endsWith(".exe")) {
            throw new IllegalArgumentException("Expected the absolute path of an existing C# worker .exe.");
        }
        return new WindowsAdapter(List.of(executable.toString()), Duration.ofSeconds(10), isWindows());
    }

    private static boolean isWindows() {
        return System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("windows");
    }

    WindowsAdapter(List<String> command, Duration timeout) {
        this(List.copyOf(command), timeout, true);
    }

    private WindowsAdapter(List<String> command, Duration timeout, boolean available) {
        this.available = available;
        this.workerCommand = command;
        this.timeout = timeout;
    }

    @Override
    public synchronized JsonNode call(ObjectNode request) {
        String operation = request.path("op").asText();
        if (closed) {
            throw unavailable("The desktop adapter is closed.");
        }
        try {
            if (!available) {
                throw unavailable("Windows UI Automation requires Windows.");
            }
            return callWorker(request, operation);
        } catch (AgentException failure) {
            if (!"getCapabilities".equals(operation) || !"BACKEND_UNAVAILABLE".equals(failure.code())) {
                throw failure;
            }
            return DesktopCapabilities.unavailable("UIA", failure.getMessage());
        }
    }

    private JsonNode callWorker(ObjectNode request, String operation) {
        byte[] frame;
        try {
            frame = JSON.writeValueAsBytes(request);
        } catch (IOException e) {
            throw new AgentException("INVALID_REQUEST", "Cannot encode the worker request.");
        }
        if (frame.length > MAX_FRAME) {
            throw new AgentException("INVALID_REQUEST", "The worker request exceeds the size limit.");
        }
        try {
            if (worker == null || !worker.isAlive()) {
                discardWorker();
                List<String> command = workerCommand == null ? powershellCommand() : workerCommand;
                worker = new ProcessBuilder(command).redirectError(ProcessBuilder.Redirect.DISCARD).start();
                responses = new BufferedInputStream(worker.getInputStream());
            }
        } catch (IOException | SecurityException e) {
            throw unavailable("Could not start the Windows UI Automation worker.");
        }

        Process current = worker;
        InputStream input = responses;
        var exchange = io.submit(() -> {
            var output = current.getOutputStream();
            output.write(frame);
            output.write('\n');
            output.flush();
            return readResponse(input);
        });
        try {
            return exchange.get(timeout.toMillis(), TimeUnit.MILLISECONDS);
        } catch (ExecutionException e) {
            if (e.getCause() instanceof AgentException) {
                throw (AgentException) e.getCause();
            }
            discardWorker();
            throw lost(operation, false);
        } catch (InterruptedException | TimeoutException e) {
            discardWorker();
            exchange.cancel(true);
            if (e instanceof InterruptedException) {
                Thread.currentThread().interrupt();
            }
            throw lost(operation, e instanceof TimeoutException);
        }
    }

    private List<String> powershellCommand() throws IOException {
        String systemRoot = System.getenv("SystemRoot");
        if (systemRoot == null || !Path.of(systemRoot).isAbsolute()) {
            throw new IOException("Missing Windows system directory.");
        }
        if (script == null) {
            try (InputStream source = WindowsAdapter.class.getResourceAsStream("/windows/uia.ps1")) {
                if (source == null) {
                    throw new IOException("Missing bundled UIA worker.");
                }
                Path extracted = Files.createTempFile("desktop-uia-", ".ps1");
                try {
                    Files.copy(source, extracted, StandardCopyOption.REPLACE_EXISTING);
                    script = extracted;
                } finally {
                    if (script == null) {
                        Files.deleteIfExists(extracted);
                    }
                }
            }
        }
        Path powershell = Path.of(systemRoot, "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        return List.of(powershell.toString(), "-NoLogo", "-NoProfile", "-NonInteractive", "-Mta",
                "-ExecutionPolicy", "RemoteSigned", "-File", script.toString());
    }

    private static JsonNode readResponse(InputStream input) throws IOException {
        var frame = new ByteArrayOutputStream();
        while (true) {
            int value = input.read();
            if (value == -1) {
                throw new EOFException();
            }
            if (value == '\n') {
                break;
            }
            if (frame.size() == MAX_FRAME) {
                throw new IOException("Oversized worker response.");
            }
            frame.write(value);
        }
        JsonNode response = JSON.readTree(frame.toByteArray());
        if (response != null && response.path("ok").isBoolean()) {
            if (response.get("ok").booleanValue() && response.has("result")) {
                return response.get("result");
            }
            JsonNode error = response.path("error");
            if (!response.get("ok").booleanValue() && error.path("code").isTextual()
                    && error.path("message").isTextual()) {
                throw new AgentException(error.get("code").textValue(), error.get("message").textValue());
            }
        }
        throw new IOException("Invalid worker response envelope.");
    }

    private static AgentException lost(String operation, boolean timedOut) {
        if ("invoke".equals(operation) || "setValue".equals(operation)) {
            return new AgentException("ACTION_OUTCOME_UNKNOWN",
                    "Worker communication ended before the action was confirmed. Inspect the target before retrying.");
        }
        return timedOut ? new AgentException("TIMEOUT", "The Windows UI Automation worker timed out.")
                : unavailable("Lost communication with the Windows UI Automation worker.");
    }

    private static AgentException unavailable(String message) {
        return new AgentException("BACKEND_UNAVAILABLE", message);
    }

    private void discardWorker() {
        if (worker != null) {
            // Process.destroyForcibly can synchronously close a pipe held by a blocked write.
            // Terminate via the handle first so the deadline thread never waits on that pipe.
            Process retired = worker;
            retired.toHandle().destroyForcibly();
            io.execute(() -> {
                try (var out = retired.getOutputStream(); var in = retired.getInputStream();
                        var err = retired.getErrorStream()) {
                    retired.waitFor();
                } catch (IOException ignored) {
                    // A killed process normally leaves broken pipes.
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                }
            });
            worker = null;
            responses = null;
        }
    }

    @Override
    public synchronized void close() {
        if (closed) {
            return;
        }
        closed = true;
        discardWorker();
        io.shutdown();
        if (script != null) {
            try {
                Files.deleteIfExists(script);
            } catch (IOException e) {
                script.toFile().deleteOnExit();
            }
        }
    }
}
