package dev.desktop.legacy;

import com.google.gson.JsonObject;
import dev.desktop.protocol.Utf8Frames;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.*;

/** One enumeration process per request. A wedged process prevents starting additional children. */
final class WorkerProcess {
    private final List<String> command;
    private final int timeoutMillis;
    private Process child;
    private FutureTask<JsonObject> exchange;

    WorkerProcess(List<String> command, int timeoutMillis) {
        this.command = new ArrayList<String>(command);
        this.timeoutMillis = timeoutMillis;
    }

    synchronized JsonObject call(final String op) {
        if (exchange != null && (!exchange.isDone() || alive(child))) throw Fault.unavailable();
        ProcessBuilder builder = new ProcessBuilder(command);
        builder.redirectError(new File(File.separatorChar == '\\' ? "NUL" : "/dev/null"));
        try {
            child = builder.start();
        } catch (IOException ex) {
            throw Fault.unavailable();
        }
        final Process process = child;
        exchange = new FutureTask<JsonObject>(new Callable<JsonObject>() {
            public JsonObject call() throws Exception {
                try (OutputStream out = process.getOutputStream()) {
                    JsonObject request = new JsonObject();
                    request.addProperty("op", op);
                    out.write((request.toString() + "\n").getBytes(StandardCharsets.UTF_8));
                }
                try (InputStream in = new BufferedInputStream(process.getInputStream())) {
                    Utf8Frames frames = new Utf8Frames(in, 4 * 1024 * 1024);
                    String frame = frames.read();
                    if (frame == null || frames.read() != null) throw Fault.protocol();
                    if (process.waitFor() != 0) throw Fault.unavailable();
                    return JsonObjects.object(frame);
                }
            }
        });
        startDaemon(exchange, "enumeration-worker");
        try {
            return exchange.get(timeoutMillis, TimeUnit.MILLISECONDS);
        } catch (TimeoutException ex) {
            terminate(process);
            throw new Fault("TIMEOUT", "The enumeration worker timed out.");
        } catch (ExecutionException ex) {
            terminate(process);
            if (ex.getCause() instanceof Fault) throw (Fault)ex.getCause();
            throw Fault.protocol();
        } catch (InterruptedException ex) {
            terminate(process);
            Thread.currentThread().interrupt();
            throw Fault.unavailable();
        }
    }

    private static boolean alive(Process process) {
        try {
            process.exitValue();
            return false;
        } catch (IllegalThreadStateException running) {
            return true;
        }
    }

    private static void terminate(final Process process) {
        // Some Java 7 implementations close pipes synchronously inside destroy().
        startDaemon(new Runnable() {
            public void run() { process.destroy(); }
        }, "enumeration-worker-cleanup");
    }

    private static void startDaemon(Runnable task, String name) {
        Thread thread = new Thread(task, name);
        thread.setDaemon(true);
        thread.start();
    }
}
