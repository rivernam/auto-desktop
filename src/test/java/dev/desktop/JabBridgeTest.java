package dev.desktop;

import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledOnOs;
import org.junit.jupiter.api.condition.OS;
import org.junit.jupiter.api.io.TempDir;
import static org.junit.jupiter.api.Assertions.*;

/** Library selection and start-up failures of the Java Access Bridge backend. No JVM is contacted. */
class JabBridgeTest {
    @Test void invokeNeedsTrueAndTheBridgeSuccessIndex() {
        assertTrue(JabBridge.invokeConfirmed(1, -1));
        assertFalse(JabBridge.invokeConfirmed(1, 0), "A return without an updated failure index cannot confirm Invoke.");
        assertFalse(JabBridge.invokeConfirmed(0, -1));
        assertFalse(JabBridge.invokeConfirmed(17, -1));
    }

    @Test void anExplicitLibraryIsTheOnlyCandidate() {
        Path explicit = Path.of("C:\\equipment\\jre\\bin\\WindowsAccessBridge-64.dll").toAbsolutePath();
        assertEquals(List.of(explicit), JabBridge.candidates(explicit.toString(), "C:\\agent-jre", "C:\\Windows\\System32", true));
        assertThrows(JabBridge.Unavailable.class,
                () -> JabBridge.candidates("WindowsAccessBridge-64.dll", "C:\\agent-jre", "C:\\Windows\\System32", true),
                "A relative path would be resolved against the working directory.");
    }

    @Test void defaultCandidatesAreTheAgentRuntimeThenTheSystemDirectory() {
        assertEquals(List.of(Path.of("C:\\agent-jre", "bin", "WindowsAccessBridge-64.dll"),
                        Path.of("C:\\Windows\\System32", "WindowsAccessBridge-64.dll")),
                JabBridge.candidates(null, "C:\\agent-jre", "C:\\Windows\\System32", true));
        assertEquals(List.of(Path.of("C:\\Windows\\System32", "WindowsAccessBridge-32.dll")),
                JabBridge.candidates(null, null, "C:\\Windows\\System32", false),
                "A 32-bit agent never loads the 64-bit library or the legacy ABI.");
        assertTrue(JabBridge.candidates(null, " ", null, true).isEmpty());
    }

    @Test void machineIsReadFromThePortableExecutableHeader(@TempDir Path directory) throws Exception {
        byte[] image = new byte[0x100];
        image[0] = 'M';
        image[1] = 'Z';
        image[0x3c] = (byte) 0x80;
        image[0x80] = 'P';
        image[0x81] = 'E';
        image[0x84] = 0x64;
        image[0x85] = (byte) 0x86;
        Path x64 = Files.write(directory.resolve("x64.dll"), image);
        assertEquals(0x8664, JabBridge.machine(x64));
        image[0x84] = 0x4c;
        image[0x85] = 0x01;
        assertEquals(0x14c, JabBridge.machine(Files.write(directory.resolve("x86.dll"), image)));
        assertEquals(0, JabBridge.machine(Files.write(directory.resolve("text.dll"), "not an image".getBytes())));
        image[0x3c] = (byte) 0xff;
        assertEquals(0, JabBridge.machine(Files.write(directory.resolve("cut.dll"), image)));
    }

    @EnabledOnOs(OS.WINDOWS)
    @Test void aMissingOrForeignLibraryIsReportedWithoutLoadingIt(@TempDir Path directory) throws Exception {
        Path missing = directory.resolve("WindowsAccessBridge-64.dll");
        assertEquals("The specified Java Access Bridge library does not exist.",
                assertThrows(JabBridge.Unavailable.class, () -> JabBridge.open(missing.toString())).getMessage());
        Path text = Files.write(missing, "not an image".getBytes());
        assertTrue(assertThrows(JabBridge.Unavailable.class, () -> JabBridge.open(text.toString())).getMessage()
                .startsWith("The Java Access Bridge library does not match this"));
        Path legacy = Files.write(directory.resolve("WindowsAccessBridge.dll"), "not an image".getBytes());
        assertEquals("The legacy WindowsAccessBridge.dll ABI is not supported.",
                assertThrows(JabBridge.Unavailable.class, () -> JabBridge.open(legacy.toString())).getMessage());
    }

    @EnabledOnOs(OS.WINDOWS)
    @Test void aFailedStartIsACapabilityWithItsReasonAndNeverAnotherBackend(@TempDir Path directory) {
        String missing = directory.resolve("WindowsAccessBridge-64.dll").toString();
        try (var adapter = new JnaDesktopAdapter(() -> new JabSession(missing), Duration.ofSeconds(5), "JAB",
                "Java Access Bridge", 50)) {
            var caps = adapter.capabilities();
            assertFalse(caps.get("available").asBoolean());
            assertEquals("JAB", caps.get("backend").asText());
            assertEquals("The specified Java Access Bridge library does not exist.", caps.get("reason").asText());
            assertTrue(caps.get("operations").isEmpty());
            AgentException later = assertThrows(AgentException.class, adapter::listWindows);
            assertEquals("BACKEND_UNAVAILABLE", later.code());
            assertEquals("The specified Java Access Bridge library does not exist.", later.getMessage());
            assertEquals("The specified Java Access Bridge library does not exist.",
                    adapter.capabilities().get("reason").asText(), "The reason is kept for later requests.");
        }
    }

    @Test void anIdleSessionIsTickedOnItsOwnThread() throws Exception {
        var ticks = new CountDownLatch(3);
        var tickThread = new AtomicReference<Thread>();
        var sessionThread = new AtomicReference<Thread>();
        final class Session implements NativeSession {
            Session() { sessionThread.set(Thread.currentThread()); }
            @Override public com.fasterxml.jackson.databind.JsonNode capabilities() {
                return com.fasterxml.jackson.databind.node.JsonNodeFactory.instance.objectNode().put("available", true);
            }
            @Override public com.fasterxml.jackson.databind.JsonNode listWindows() { return capabilities(); }
            @Override public com.fasterxml.jackson.databind.JsonNode snapshot(String id, int depth, int limit) { return capabilities(); }
            @Override public com.fasterxml.jackson.databind.JsonNode elementInfo(String key, int pid) { return capabilities(); }
            @Override public com.fasterxml.jackson.databind.JsonNode perform(DesktopAction action, String key, int pid,
                                                                             String value, Runnable beforeMutation) {
                beforeMutation.run();
                return capabilities();
            }
            @Override public void idle() {
                tickThread.set(Thread.currentThread());
                ticks.countDown();
            }
            @Override public void close() {}
        }
        try (var adapter = new JnaDesktopAdapter(Session::new, Duration.ofSeconds(5), "JAB", "Java Access Bridge", 20)) {
            Thread.sleep(100);
            assertNull(sessionThread.get(), "Idle ticks do not start the provider.");
            assertTrue(adapter.capabilities().get("available").asBoolean());
            assertTrue(ticks.await(5, TimeUnit.SECONDS));
            assertSame(sessionThread.get(), tickThread.get());
            assertTrue(adapter.perform(DesktopAction.INVOKE, "k", 1, null).get("available").asBoolean());
        }
    }
}
