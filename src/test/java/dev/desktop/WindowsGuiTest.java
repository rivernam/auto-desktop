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
import java.util.HashMap;
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
    private FixtureOutput fixtureOutput;

    private record TreeNode(String role, String automationId, String name) {}
    private record TreeShape(Map<List<TreeNode>, Integer> content, Map<List<TreeNode>, Integer> chrome) {}

    @Test
    @EnabledIfSystemProperty(named = "desktop.windowsIT", matches = "true")
    void operatesDedicatedWpfWindowWithoutMovingPhysicalCursor() throws Exception {
        verifyWpfWindow(WindowsAdapter::new, null);
    }

    @Test
    @EnabledIfSystemProperty(named = "desktop.csharpIT", matches = "true")
    void csharpWorkerOperatesDedicatedWpfWindowWithoutMovingPhysicalCursor() throws Exception {
        Path executable = csharpWorker();
        verifyWpfWindow(() -> WindowsAdapter.forCSharpWorker(executable), executable);
    }

    private static Path csharpWorker() {
        String configured = System.getProperty("desktop.csharpWorker");
        assertTrue(configured != null && !configured.isBlank(), "Specify -Ddesktop.csharpWorker=<absolute exe path>.");
        Path executable = Path.of(configured);
        assertTrue(executable.isAbsolute() && Files.isRegularFile(executable),
                "desktop.csharpWorker must be the absolute path of a published worker executable.");
        return executable;
    }

    @Test
    @EnabledIfSystemProperty(named = "desktop.jnaIT", matches = "true")
    void jnaOperatesDedicatedWpfWindowWithoutMovingPhysicalCursor() throws Exception {
        verifyWpfWindow(JnaDesktopAdapter::new, null);
    }

    @Test
    @EnabledIfSystemProperty(named = "desktop.jnaIT", matches = "true")
    @EnabledIfSystemProperty(named = "desktop.windowsIT", matches = "true")
    @EnabledIfSystemProperty(named = "desktop.csharpIT", matches = "true")
    void comparesDecoratedWpfTreeAcrossBackends() throws Exception {
        String title = "Desktop automation tree fixture " + UUID.randomUUID();
        Process fixture = startFixture(title);
        try {
            int pid = Math.toIntExact(fixture.pid());
            awaitFile(fixture, "ready", Integer.toString(pid));
            try (var powershell = new WindowsAdapter();
                 var csharp = WindowsAdapter.forCSharpWorker(csharpWorker());
                 var jna = new JnaDesktopAdapter()) {
                TreeShape shell = treeShape(capture(powershell, pid, title));
                TreeShape managed = treeShape(capture(csharp, pid, title));
                TreeShape nativeTree = treeShape(capture(jna, pid, title));
                assertFalse(shell.chrome().isEmpty(), "The decorated fixture should expose a title bar.");
                assertEquals(shell, managed, "Managed clients disagree on the decorated tree.");
                assertEquals(shell.content(), nativeTree.content(), "Native UIA lost WPF content or its parent path.");
                System.out.println("Managed title-bar paths: " + shell.chrome().keySet());
                System.out.println("Native title-bar paths: " + nativeTree.chrome().keySet());
            }
        } finally { stopFixture(fixture); }
    }

    private static JsonNode capture(DesktopAdapter adapter, int pid, String title) {
        Agent agent = new Agent(adapter, Set.of(), Set.of());
        String windowId = fixtureWindow(agent, pid, title);
        return result(agent, request("snapshot").put("windowId", windowId));
    }

    private static TreeShape treeShape(JsonNode snapshot) {
        assertFalse(snapshot.path("truncated").asBoolean(true));
        Map<String, List<TreeNode>> paths = new HashMap<>();
        Map<List<TreeNode>, Integer> content = new HashMap<>();
        Map<List<TreeNode>, Integer> chrome = new HashMap<>();
        for (JsonNode element : snapshot.path("elements")) {
            var parent = element.path("parentRef");
            var path = new ArrayList<TreeNode>();
            if (parent.isTextual()) {
                var ancestors = paths.get(parent.asText());
                assertNotNull(ancestors, "Control View traversal must report parents before their children.");
                path.addAll(ancestors);
            }
            path.add(new TreeNode(element.path("role").asText(), element.path("automationId").asText(),
                    element.path("name").asText()));
            var signature = List.copyOf(path);
            paths.put(element.path("ref").asText(), signature);
            var part = path.size() > 1 && path.get(1).role().equals("TitleBar") ? chrome : content;
            part.merge(signature, 1, Integer::sum);
        }
        return new TreeShape(content, chrome);
    }

    private Process startFixture(String title) throws IOException {
        String os = System.getProperty("os.name");
        assertTrue(Set.of("Windows 10", "Windows 11").contains(os),
                "This test requires an interactive Windows 10 or 11 desktop. Detected " + os);
        assertFalse(GraphicsEnvironment.isHeadless(), "This test requires an interactive desktop.");
        Path script = directory.resolve("fixture.ps1");
        try (InputStream resource = getClass().getResourceAsStream("/windows-gui-fixture.ps1")) {
            assertNotNull(resource);
            Files.copy(resource, script);
        }
        Process fixture = new ProcessBuilder(powershell().toString(), "-NoProfile", "-NonInteractive", "-STA",
                "-ExecutionPolicy", "RemoteSigned", "-File", script.toString(), directory.toString(), title)
                .redirectErrorStream(true).start();
        fixtureOutput = new FixtureOutput(fixture);
        return fixture;
    }

    private static Path powershell() {
        return Path.of(System.getenv("SystemRoot"), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
    }

    private void stopFixture(Process fixture) throws Exception {
        try {
            if (fixture.isAlive()) {
                Files.createFile(directory.resolve("close-fixture"));
                assertTrue(fixture.waitFor(5, TimeUnit.SECONDS), "Fixture did not close gracefully.");
                assertEquals(0, fixture.exitValue(), fixtureOutput::current);
            }
        } finally {
            if (fixture.isAlive()) {
                fixture.destroyForcibly();
                assertTrue(fixture.waitFor(10, TimeUnit.SECONDS), "Fixture did not exit.");
            }
            fixtureOutput.afterExit();
        }
    }

    private void verifyWpfWindow(Supplier<DesktopAdapter> factory, Path csharpWorker) throws Exception {
        String title = "Desktop agent fixture " + UUID.randomUUID();
        Process fixture = startFixture(title);
        try {
            int pid = Math.toIntExact(fixture.pid());
            awaitFile(fixture, "ready", Integer.toString(pid));
            try (DesktopAdapter adapter = factory.get()) {
                Agent agent = new Agent(adapter, Set.of(pid), Set.of("invoke", "setValue"));
                JsonNode capabilities = result(agent, request("getCapabilities"));
                assertTrue(capabilities.path("available").asBoolean(), capabilities::toString);
                assertEquals("UIA", capabilities.path("backend").asText());
                assertFalse(capabilities.path("physicalInput").asBoolean(true));

                String windowId = fixtureWindow(agent, pid, title);
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
                    verifyWorkerFailures(fixture, windowId, powershell(), csharpWorker);
                } else {
                    freshEdit = verifyScopedCapture(agent, windowId, refreshed, freshEdit);
                }
                fixture.destroyForcibly();
                assertTrue(fixture.waitFor(10, TimeUnit.SECONDS), "Fixture did not exit.");
                error(agent, request("getElementInfo").put("ref", freshEdit), "STALE_REFERENCE");
            }
        } finally { stopFixture(fixture); }
    }

    private static String verifyScopedCapture(Agent agent, String windowId, JsonNode original, String oldEdit) {
        String list = result(agent, find(original.path("snapshotId").asText(), "automationId", "fixtureList", "List"))
                .path("ref").asText();
        JsonNode scope = result(agent, request("snapshot").put("windowId", windowId).put("scopeRef", list));
        assertFalse(scope.path("truncated").asBoolean(true));
        JsonNode root = scope.path("elements").get(0);
        assertEquals("fixtureList", root.path("automationId").asText());
        assertTrue(root.path("parentRef").isNull());
        error(agent, request("getElementInfo").put("ref", oldEdit), "STALE_REFERENCE");
        String scopeId = scope.path("snapshotId").asText();
        String scopeRef = root.path("ref").asText();
        error(agent, find(scopeId, "automationId", "fixtureEdit", "Edit").put("scopeRef", scopeRef),
                "ELEMENT_NOT_FOUND");
        String item = result(agent, find(scopeId, "name", "Item one", "ListItem").put("scopeRef", scopeRef))
                .path("ref").asText();
        result(agent, request("getElementInfo").put("ref", item));
        JsonNode limited = result(agent, request("snapshot").put("windowId", windowId).put("scopeRef", scopeRef)
                .put("maxDepth", 0));
        assertTrue(limited.path("truncated").asBoolean());
        error(agent, find(limited.path("snapshotId").asText(), "name", "Item one", "ListItem"),
                "INCOMPLETE_SNAPSHOT");
        return limited.path("elements").get(0).path("ref").asText();
    }

    private static String fixtureWindow(Agent agent, int pid, String title) {
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
        return windowId;
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
        String output = fixture.isAlive() ? fixtureOutput.current() : fixtureOutput.afterExit();
        throw new IOException("Fixture failed while waiting for " + name + ". Output: " + output);
    }
}
