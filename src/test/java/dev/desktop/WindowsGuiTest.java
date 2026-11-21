package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.awt.GraphicsEnvironment;
import java.io.IOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.TimeUnit;
import java.util.function.Supplier;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIfSystemProperty;
import org.junit.jupiter.api.io.TempDir;

import static org.junit.jupiter.api.Assertions.*;

class WindowsGuiTest {
    @TempDir Path directory;

    @Test
    @EnabledIfSystemProperty(named = "desktop.windowsIT", matches = "true")
    void operatesDedicatedWpfWindowWithoutMovingPhysicalCursor() throws Exception {
        verifyWpfWindow(WindowsAdapter::new, null);
    }

    @Test
    @EnabledIfSystemProperty(named = "desktop.csharpIT", matches = "true")
    void csharpWorkerOperatesDedicatedWpfWindowWithoutMovingPhysicalCursor() throws Exception {
        String configured = System.getProperty("desktop.csharpWorker");
        assertTrue(configured != null && !configured.isBlank(), "Specify -Ddesktop.csharpWorker=<absolute exe path>.");
        Path executable = Path.of(configured);
        assertTrue(executable.isAbsolute() && Files.isRegularFile(executable),
                "desktop.csharpWorker must be the absolute path of a published worker executable.");
        verifyWpfWindow(() -> WindowsAdapter.forCSharpWorker(executable), executable);
    }

    @Test
    @EnabledIfSystemProperty(named = "desktop.jnaIT", matches = "true")
    void jnaOperatesDedicatedWpfWindowWithoutMovingPhysicalCursor() throws Exception {
        verifyWpfWindow(JnaDesktopAdapter::new, null);
    }

    private void verifyWpfWindow(Supplier<DesktopAdapter> factory, Path csharpWorker) throws Exception {
        String os = System.getProperty("os.name");
        assertTrue(Set.of("Windows 10", "Windows 11").contains(os),
                "This test requires an interactive Windows 10 or 11 desktop. Detected " + os);
        assertFalse(GraphicsEnvironment.isHeadless(), "This test requires an interactive desktop.");
        Path script = directory.resolve("fixture.ps1");
        try (InputStream resource = getClass().getResourceAsStream("/windows-gui-fixture.ps1")) {
            assertNotNull(resource);
            Files.copy(resource, script);
        }
        String title = "Desktop agent fixture " + UUID.randomUUID();
        Path powershell = Path.of(System.getenv("SystemRoot"), "System32", "WindowsPowerShell",
                "v1.0", "powershell.exe");
        Process fixture = new ProcessBuilder(powershell.toString(), "-NoProfile", "-NonInteractive", "-STA",
                "-ExecutionPolicy", "RemoteSigned", "-File", script.toString(), directory.toString(), title)
                .redirectErrorStream(true).redirectOutput(directory.resolve("fixture.log").toFile()).start();
        try {
            int pid = Math.toIntExact(fixture.pid());
            awaitFile(fixture, "ready", Integer.toString(pid));
            try (DesktopAdapter adapter = factory.get()) {
                Agent agent = new Agent(adapter, Set.of(pid), Set.of("invoke", "setValue"));
                JsonNode capabilities = result(agent, request("getCapabilities"));
                assertTrue(capabilities.path("available").asBoolean(), capabilities::toString);
                assertEquals("UIA", capabilities.path("backend").asText());
                assertFalse(capabilities.path("physicalInput").asBoolean(true));

                JsonNode windows = result(agent, request("listWindows"));
                assertTrue(windows.isArray());
                String windowId = null;
                for (JsonNode window : windows) {
                    if (window.path("processId").asInt() == pid && title.equals(window.path("name").asText())) {
                        assertNull(windowId, "Multiple windows claim the fixture identity.");
                        windowId = window.path("windowId").textValue();
                    }
                }
                assertNotNull(windowId, "Dedicated fixture window was absent from listWindows.");
                assertFalse(windowId.isBlank());

                JsonNode snapshot = result(agent, request("snapshot").put("windowId", windowId));
                assertTrue(snapshot.path("elements").isArray());
                assertFalse(snapshot.path("elements").isEmpty());
                assertFalse(snapshot.toString().contains("initial fixture value"), "Input value leaked in snapshot.");
                String snapshotId = snapshot.path("snapshotId").textValue();
                assertNotNull(snapshotId);
                String edit = result(agent, find(snapshotId, "automationId", "fixtureEdit", "Edit")).get("ref").asText();
                String button = result(agent, find(snapshotId, "name", "Increment fixture counter", "Button")).get("ref").asText();
                ObjectNode combined = find(snapshotId, "automationId", "fixtureIncrement", "Button");
                ((ObjectNode) combined.get("locator")).put("name", "Increment fixture counter");
                assertEquals(button, result(agent, combined).get("ref").asText());
                assertNotEquals(button, edit);
                JsonNode info = result(agent, request("getElementInfo").put("ref", button));
                assertEquals("fixtureIncrement", info.path("automationId").textValue());
                assertEquals("Button", info.path("role").textValue());
                assertEquals("UIA", info.path("backend").textValue());
                assertEquals(pid, info.path("processId").asInt());
                assertEquals(button, info.path("ref").textValue());
                assertTrue(info.path("enabled").asBoolean());
                assertTrue(info.path("bounds").path("width").asDouble() > 0);
                assertTrue(info.path("actions").isArray());

                for (var control : Map.of("fixtureCheck", "CheckBox", "fixtureCombo", "ComboBox",
                        "fixtureList", "List").entrySet()) {
                    JsonNode found = result(agent, find(snapshotId, "automationId", control.getKey(), control.getValue()));
                    assertEquals(control.getValue(), found.get("role").asText());
                }

                JsonNode disabled = result(agent, find(snapshotId, "automationId", "fixtureDisabled", "Button"));
                assertFalse(disabled.path("enabled").asBoolean(true));
                error(agent, request("invoke").put("ref", disabled.get("ref").asText()), "PRECONDITION_FAILED");
                JsonNode readOnly = result(agent, find(snapshotId, "automationId", "fixtureReadOnly", "Edit"));
                error(agent, request("setValue").put("ref", readOnly.get("ref").asText()).put("value", "wrong"),
                        "PATTERN_UNSUPPORTED");
                awaitFile(fixture, "disabled-click.txt", "0");
                awaitFile(fixture, "read-only.txt", "fixed fixture value");
                error(agent, find(snapshotId, "name", "Duplicate label", "Button"), "AMBIGUOUS_ELEMENT");
                error(agent, request("invoke").put("ref", edit), "PATTERN_UNSUPPORTED");
                awaitFile(fixture, "count.txt", "0");
                awaitFile(fixture, "value.txt", "initial fixture value");

                String cursor = cursor(fixture);
                String expected = "changed by UIA \u2713";
                assertTrue(result(agent, request("setValue").put("ref", edit).put("value", expected))
                        .path("performed").asBoolean());
                awaitFile(fixture, "value.txt", expected);
                assertEquals(cursor, cursor(fixture), "Physical cursor moved during setValue.");

                ObjectNode invoke = request("invoke").put("ref", button);
                assertTrue(result(agent, invoke).path("performed").asBoolean());
                awaitFile(fixture, "count.txt", "1");
                assertEquals(cursor, cursor(fixture), "Physical cursor moved during invoke.");
                error(agent, invoke, "DUPLICATE_COMMAND");
                awaitFile(fixture, "count.txt", "1");

                Files.createFile(directory.resolve("replace-control"));
                awaitFile(fixture, "replaced", "ready");
                error(agent, request("invoke").put("ref", button), "STALE_REFERENCE");
                awaitFile(fixture, "count.txt", "1");
                JsonNode refreshed = result(agent, request("snapshot").put("windowId", windowId));
                assertFalse(refreshed.toString().contains(expected), "Changed input value leaked in snapshot.");
                error(agent, request("getElementInfo").put("ref", edit), "STALE_REFERENCE");

                String freshEdit = result(agent, find(refreshed.get("snapshotId").asText(),
                        "automationId", "fixtureEdit", "Edit")).get("ref").asText();
                result(agent, request("getElementInfo").put("ref", freshEdit));
                if (adapter instanceof WindowsAdapter) {
                    verifyWorkerFailures(fixture, windowId, powershell, csharpWorker);
                }
                fixture.destroyForcibly();
                assertTrue(fixture.waitFor(10, TimeUnit.SECONDS), "Fixture did not exit.");
                error(agent, request("getElementInfo").put("ref", freshEdit), "STALE_REFERENCE");
            }
        } finally {
            fixture.destroyForcibly();
            assertTrue(fixture.waitFor(10, TimeUnit.SECONDS), "Fixture did not exit.");
        }
    }

    private void verifyWorkerFailures(Process fixture, String windowId, Path powershell, Path csharpWorker)
            throws Exception {
        Path classes = Path.of(WindowsGuiFaultProxy.class.getProtectionDomain().getCodeSource().getLocation().toURI());
        var command = new ArrayList<>(List.of(Path.of(System.getProperty("java.home"), "bin", "java.exe").toString(),
                "-cp", classes.toString(), WindowsGuiFaultProxy.class.getName(), directory.toString()));
        if (csharpWorker == null) {
            Path workerScript = directory.resolve("uia.ps1");
            try (InputStream input = WindowsGuiTest.class.getResourceAsStream("/windows/uia.ps1")) {
                assertNotNull(input);
                Files.copy(input, workerScript);
            }
            command.addAll(List.of(powershell.toString(), "-NoLogo", "-NoProfile", "-NonInteractive", "-Mta",
                    "-ExecutionPolicy", "RemoteSigned", "-File", workerScript.toString()));
        } else {
            command.add(csharpWorker.toString());
        }
        try (var adapter = new WindowsAdapter(command, Duration.ofSeconds(12))) {
            Agent agent = new Agent(adapter, Set.of(Math.toIntExact(fixture.pid())), Set.of("invoke"));
            String beforeCrash = snapshotButton(agent, windowId);
            Files.createFile(directory.resolve("kill-worker"));
            error(agent, request("getElementInfo").put("ref", beforeCrash), "BACKEND_UNAVAILABLE");
            assertTrue(Long.parseLong(awaitFile(fixture, "worker-killed", null)) > 0);
            assertTrue(result(agent, request("getCapabilities")).get("available").asBoolean());
            error(agent, request("getElementInfo").put("ref", beforeCrash), "STALE_REFERENCE");

            ObjectNode mutation = request("invoke").put("ref", snapshotButton(agent, windowId));
            Files.createFile(directory.resolve("withhold-reply"));
            error(agent, mutation, "ACTION_OUTCOME_UNKNOWN");
            JsonNode nativeReply = new ObjectMapper().readTree(awaitFile(fixture, "withheld.json", null));
            assertTrue(nativeReply.path("ok").asBoolean());
            assertTrue(nativeReply.at("/result/performed").asBoolean());
            awaitFile(fixture, "count.txt", "2");
            error(agent, mutation, "DUPLICATE_COMMAND");
            // A new ID and a fresh reference must reach the provider exactly once.
            assertTrue(result(agent, request("invoke").put("ref", snapshotButton(agent, windowId)))
                    .get("performed").asBoolean());
            awaitFile(fixture, "count.txt", "3");
        }
    }

    private static String snapshotButton(Agent agent, String windowId) {
        String snapshot = result(agent, request("snapshot").put("windowId", windowId)).get("snapshotId").asText();
        return result(agent, find(snapshot, "automationId", "fixtureIncrement", "Button")).get("ref").asText();
    }

    private static ObjectNode request(String op) {
        return JsonNodeFactory.instance.objectNode().put("op", op).put("id", UUID.randomUUID().toString());
    }

    private static ObjectNode find(String snapshotId, String field, String value, String role) {
        ObjectNode command = request("findElement").put("snapshotId", snapshotId);
        command.putObject("locator").put(field, value).put("role", role);
        return command;
    }

    private static JsonNode result(Agent agent, ObjectNode command) {
        JsonNode response = agent.handle(command);
        assertTrue(response.path("ok").asBoolean(), response::toString);
        return response.get("result");
    }

    private static void error(Agent agent, ObjectNode command, String code) {
        JsonNode response = agent.handle(command);
        assertFalse(response.path("ok").asBoolean(true), response::toString);
        assertEquals(code, response.at("/error/code").textValue(), response::toString);
    }

    private String cursor(Process fixture) throws Exception {
        String sample = UUID.randomUUID().toString();
        Files.createFile(directory.resolve(sample + ".request"));
        String coordinates = awaitFile(fixture, sample + ".reply", null);
        assertTrue(coordinates.matches("-?\\d+,-?\\d+"), "Invalid physical cursor sample.");
        return coordinates;
    }

    private String awaitFile(Process fixture, String name, String expected) throws Exception {
        Path path = directory.resolve(name);
        long deadline = System.nanoTime() + Duration.ofSeconds(20).toNanos();
        while (System.nanoTime() < deadline && fixture.isAlive()) {
            if (Files.exists(path)) {
                String value = Files.readString(path);
                if (expected == null || expected.equals(value)) return value;
            }
            Thread.sleep(40);
        }
        throw new IOException("Fixture failed while waiting for " + name + ". Output: "
                + Files.readString(directory.resolve("fixture.log")));
    }
}
