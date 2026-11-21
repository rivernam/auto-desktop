package dev.desktop;

import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.List;
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
        List<String> lines = output.toString(StandardCharsets.UTF_8).lines().toList();
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

    @Test void invalidPolicyStopsBeforeReadingCommands() throws Exception {
        InputStream unreadable = new InputStream() {
            @Override public int read() { throw new AssertionError("read before policy validation"); }
        };
        assertEquals(2, Cli.run(new String[]{"--allow-action", "click"}, unreadable,
                new ByteArrayOutputStream()));
    }
}
