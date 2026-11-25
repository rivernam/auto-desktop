package dev.desktop;

import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.List;
import java.util.stream.Collectors;
import java.nio.file.Path;
import java.nio.file.Files;
import org.junit.jupiter.api.io.TempDir;
import org.junit.jupiter.api.Test;

class CliTest {
    @Test void malformedFramesDoNotDesynchronizeTheNextCommand() throws Exception {
        String input = "{bad}\n{}{}\n{\"id\":\"a\",\"op\":\"getCapabilities\",\"id\":\"b\"}\n"
                + "x".repeat(Cli.MAX_FRAME + 1) + "\n"
                + "{\"id\":\"health\",\"op\":\"getCapabilities\"}";
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        assertEquals(0, Cli.run(new String[0], new ByteArrayInputStream(
                input.getBytes(StandardCharsets.UTF_8)), output));
        List<String> lines = output.toString(StandardCharsets.UTF_8).lines().collect(Collectors.toUnmodifiableList());
        assertEquals(5, lines.size());
        ObjectMapper mapper = new ObjectMapper();
        for (int i = 0; i < 4; i++) {
            JsonNode reply = mapper.readTree(lines.get(i));
            assertEquals("INVALID_REQUEST", reply.at("/error/code").asText());
        }
        assertEquals("health", mapper.readTree(lines.get(4)).path("id").asText());
    }

    @Test void protocolRequiresUtf8() throws Exception {
        var output = new ByteArrayOutputStream();
        var input = new ByteArrayInputStream("{\"id\":\"probe\",\"op\":\"getCapabilities\"}"
                .getBytes(StandardCharsets.UTF_16LE));
        assertEquals(0, Cli.run(new String[0], input, output));
        assertEquals("INVALID_REQUEST", new ObjectMapper().readTree(output.toByteArray())
                .at("/error/code").asText());
    }

    @Test void explicitWorkerIsValidatedWithoutStartingIt(@TempDir Path directory) throws Exception {
        Path executable = Files.createFile(directory.resolve("UIA worker.exe"));
        assertEquals(0, Cli.run(new String[]{"--csharp-worker", executable.toString()},
                InputStream.nullInputStream(), OutputStream.nullOutputStream()));
        for (String invalid : List.of("relative-worker.exe", directory.toString(),
                directory.resolve("missing.exe").toString())) {
            assertEquals(2, Cli.run(new String[]{"--csharp-worker", invalid},
                    InputStream.nullInputStream(), OutputStream.nullOutputStream()));
        }
    }

    @Test void backendSelectionIsExplicitAndExclusive() throws Exception {
        for (String[] args : List.of(new String[]{"--backend", "jna", "--csharp-worker", "worker.exe"},
                new String[]{"--backend", "unknown"}, new String[]{"--backend", "jna", "--backend", "powershell"})) {
            assertEquals(2, Cli.run(args, InputStream.nullInputStream(), OutputStream.nullOutputStream()));
        }
        assertEquals(0, Cli.run(new String[]{"--backend", "jna"},
                InputStream.nullInputStream(), OutputStream.nullOutputStream()));
    }

    @Test void javaAccessBridgeIsSelectedOnlyByName(@TempDir Path directory) throws Exception {
        String library = directory.resolve("WindowsAccessBridge-64.dll").toString();
        String previous = System.getProperty(JabBridge.LIBRARY_PROPERTY);
        try {
            for (String[] args : List.of(new String[]{"--jab-dll", library},
                    new String[]{"--backend", "jna", "--jab-dll", library},
                    new String[]{"--backend", "jab", "--jab-dll", "WindowsAccessBridge-64.dll"},
                    new String[]{"--backend", "jab", "--jab-dll", library, "--jab-dll", library},
                    new String[]{"--backend", "jab", "--csharp-worker", "worker.exe"})) {
                assertEquals(2, Cli.run(args, InputStream.nullInputStream(), OutputStream.nullOutputStream()));
            }
            assertNull(System.getProperty(JabBridge.LIBRARY_PROPERTY), "A rejected command line configures nothing.");
            assertEquals(0, Cli.run(new String[]{"--backend", "jab"},
                    InputStream.nullInputStream(), OutputStream.nullOutputStream()));

            // The named library is absent. The session reports that and does not answer through UI Automation.
            var output = new ByteArrayOutputStream();
            var input = new java.io.ByteArrayInputStream(("{\"id\":\"1\",\"op\":\"getCapabilities\"}\n"
                    + "{\"id\":\"2\",\"op\":\"listWindows\"}\n").getBytes(java.nio.charset.StandardCharsets.UTF_8));
            assertEquals(0, Cli.run(new String[]{"--backend", "jab", "--jab-dll", library}, input, output));
            String[] replies = output.toString(java.nio.charset.StandardCharsets.UTF_8).split("\n");
            assertEquals(2, replies.length);
            if (System.getProperty("os.name", "").startsWith("Windows")) {
                assertTrue(replies[0].contains("\"backend\":\"JAB\"") && replies[0].contains("\"available\":false")
                        && replies[0].contains("does not exist"), replies[0]);
            }
            assertTrue(replies[1].contains("BACKEND_UNAVAILABLE"), replies[1]);
        } finally {
            if (previous == null) System.clearProperty(JabBridge.LIBRARY_PROPERTY);
            else System.setProperty(JabBridge.LIBRARY_PROPERTY, previous);
        }
    }

    @Test void multiBackendIsSelectedByNameAndReportsEachBackend(@TempDir Path directory) throws Exception {
        String library = directory.resolve("WindowsAccessBridge-64.dll").toString();
        String previous = System.getProperty(JabBridge.LIBRARY_PROPERTY);
        try {
            for (String[] args : List.of(new String[]{"--backend", "multi", "--csharp-worker", "worker.exe"},
                    new String[]{"--backend", "multi", "--backend", "jab"},
                    new String[]{"--backend", "multi", "--jab-dll", "WindowsAccessBridge-64.dll"})) {
                assertEquals(2, Cli.run(args, InputStream.nullInputStream(), OutputStream.nullOutputStream()));
            }
            // The named bridge library is absent. The session says so for that backend and keeps the other.
            var output = new ByteArrayOutputStream();
            var input = new ByteArrayInputStream(("{\"id\":\"1\",\"op\":\"getCapabilities\"}\n"
                    + "{\"id\":\"2\",\"op\":\"snapshot\",\"windowId\":\"1\",\"backend\":\"JAB\"}\n"
                    + "{\"id\":\"3\",\"op\":\"snapshot\",\"windowId\":\"1\",\"backend\":\"unknown\"}\n")
                    .getBytes(StandardCharsets.UTF_8));
            assertEquals(0, Cli.run(new String[]{"--backend", "multi", "--jab-dll", library}, input, output));
            ObjectMapper mapper = new ObjectMapper();
            List<String> lines = output.toString(StandardCharsets.UTF_8).lines().collect(Collectors.toUnmodifiableList());
            assertEquals(3, lines.size());
            JsonNode capabilities = mapper.readTree(lines.get(0)).get("result");
            assertEquals("multi", capabilities.path("backend").asText());
            assertEquals("UIA", capabilities.at("/backends/0/backend").asText());
            assertEquals("JAB", capabilities.at("/backends/1/backend").asText());
            assertEquals("MSAA", capabilities.at("/backends/2/backend").asText());
            assertEquals(3, capabilities.path("backends").size());
            assertFalse(capabilities.at("/backends/1/available").asBoolean());
            if (System.getProperty("os.name", "").startsWith("Windows")) {
                assertTrue(capabilities.at("/backends/1/reason").asText().contains("does not exist"), lines.get(0));
            }
            assertEquals("BACKEND_UNAVAILABLE", mapper.readTree(lines.get(1)).at("/error/code").asText());
            assertEquals("BACKEND_UNAVAILABLE", mapper.readTree(lines.get(2)).at("/error/code").asText());
        } finally {
            if (previous == null) System.clearProperty(JabBridge.LIBRARY_PROPERTY);
            else System.setProperty(JabBridge.LIBRARY_PROPERTY, previous);
        }
    }

    @Test void invalidPolicyStopsBeforeReadingCommands() throws Exception {
        InputStream unreadable = new InputStream() {
            @Override public int read() { throw new AssertionError("read before policy validation"); }
        };
        assertEquals(2, Cli.run(new String[]{"--allow-action", "click"}, unreadable,
                new ByteArrayOutputStream()));
    }
}
