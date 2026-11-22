package dev.desktop;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/** Drain a fixture's merged pipe without a file handle in its temporary state directory. */
final class FixtureOutput {
    private static final int LIMIT = 16 * 1024;
    private final ByteArrayOutputStream output = new ByteArrayOutputStream();
    private final Thread reader;
    private boolean truncated;
    private String readError;

    FixtureOutput(Process process) {
        reader = new Thread(() -> drain(process), "uia-fixture-output");
        reader.setDaemon(true);
        reader.start();
    }

    private void drain(Process process) {
        try (var input = process.getInputStream()) {
            byte[] buffer = new byte[4096];
            for (int count; (count = input.read(buffer)) != -1;) {
                synchronized (this) {
                    int saved = Math.min(count, LIMIT - output.size());
                    output.write(buffer, 0, saved);
                    truncated |= saved < count;
                }
            }
        } catch (IOException ex) {
            synchronized (this) { readError = ex.getMessage(); }
        }
    }

    synchronized String current() {
        String text = output.toString(StandardCharsets.UTF_8);
        if (truncated) text += "\n[output truncated]";
        if (readError != null) text += "\n[output read error: " + readError + "]";
        return text;
    }

    String afterExit() throws InterruptedException {
        reader.join(1000);
        String text = current();
        return reader.isAlive() ? text + "\n[output pipe still open after process exit]" : text;
    }
}
