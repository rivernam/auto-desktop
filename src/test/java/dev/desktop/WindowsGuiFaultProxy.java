package dev.desktop;

import java.io.BufferedReader;
import java.io.BufferedWriter;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;

/** Test-only pipe relay. Each instance owns a single real worker process. */
public final class WindowsGuiFaultProxy {
    public static void main(String[] args) throws Exception {
        Path state = Path.of(args[0]);
        Process worker = new ProcessBuilder(Arrays.copyOfRange(args, 1, args.length))
                .redirectError(ProcessBuilder.Redirect.INHERIT).start();
        try (var clientIn = System.in;
             var lines = new BufferedReader(new InputStreamReader(clientIn, StandardCharsets.UTF_8));
             var workerIn = new BufferedWriter(new OutputStreamWriter(worker.getOutputStream(), StandardCharsets.UTF_8));
             var workerOut = new BufferedReader(new InputStreamReader(worker.getInputStream(), StandardCharsets.UTF_8));
             var clientOut = new BufferedWriter(new OutputStreamWriter(System.out, StandardCharsets.UTF_8))) {
            String request;
            while ((request = lines.readLine()) != null) {
                if (Files.deleteIfExists(state.resolve("kill-worker"))) {
                    worker.destroyForcibly().waitFor();
                    Files.writeString(state.resolve("worker-killed"), Long.toString(worker.pid()));
                    return;
                }
                workerIn.write(request);
                workerIn.newLine();
                workerIn.flush();
                String reply = workerOut.readLine();
                if (reply == null) return;
                if (Files.deleteIfExists(state.resolve("withhold-reply"))) {
                    Files.writeString(state.resolve("withheld.json"), reply);
                    // Let the real worker exit on EOF before the deadline kills this relay.
                    // The client still sees an open pipe with no reply.
                    worker.getOutputStream().close();
                    worker.waitFor();
                    lines.readLine();
                    return;
                }
                clientOut.write(reply);
                clientOut.newLine();
                clientOut.flush();
            }
        } finally {
            if (worker.isAlive()) worker.destroyForcibly().waitFor();
        }
    }

    private WindowsGuiFaultProxy() {}
}
