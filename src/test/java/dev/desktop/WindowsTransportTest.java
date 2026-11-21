package dev.desktop;

import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.net.URISyntaxException;
import java.nio.file.Path;
import java.time.Duration;
import java.util.List;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class WindowsTransportTest {
    private static final ObjectMapper JSON = new ObjectMapper();

    private static ObjectNode op(String name) {
        return JSON.createObjectNode().put("op", name);
    }

    private WindowsAdapter adapter(String mode, int timeoutMillis) throws URISyntaxException {
        Path classes = Path.of(WindowsTransportFixture.class.getProtectionDomain()
                .getCodeSource().getLocation().toURI());
        String java = Path.of(System.getProperty("java.home"), "bin", "java").toString();
        return new WindowsAdapter(List.of(java, "-cp", classes.toString(),
                WindowsTransportFixture.class.getName(), mode), Duration.ofMillis(timeoutMillis));
    }

    @Test void sessionIsReusedAndCrashedActionIsNeverReplayed() throws Exception {
        try (var adapter = adapter("normal", 4000)) {
            long first = adapter.call(op("getCapabilities")).longValue();
            assertTrue(first > 0);
            assertEquals(first, adapter.call(op("getCapabilities")).longValue());
            var error = assertThrows(AgentException.class, () -> adapter.call(op("invoke")));
            assertEquals("ACTION_OUTCOME_UNKNOWN", error.code());
            assertNotEquals(first, adapter.call(op("getCapabilities")).longValue());
        }
    }

    @Test void missingWorkerReportsUnavailableCapabilities() {
        try (var adapter = new WindowsAdapter(List.of("missing-uia-test-executable"), Duration.ofSeconds(2))) {
            var result = adapter.call(op("getCapabilities"));
            assertFalse(result.get("available").booleanValue());
            assertEquals("UIA", result.get("backend").textValue());
            assertTrue(result.get("operations").isEmpty());
            assertFalse(result.get("physicalInput").booleanValue());
            assertFalse(result.get("screenshot").booleanValue());
            assertFalse(result.get("reason").asText().isBlank());
            var failure = assertThrows(AgentException.class, () -> adapter.call(op("listWindows")));
            assertEquals("BACKEND_UNAVAILABLE", failure.code());
        }
    }

    @Test void readTimeoutRetiresWorker() throws Exception {
        try (var adapter = adapter("stall", 300)) {
            var error = assertThrows(AgentException.class, () -> adapter.call(op("listWindows")));
            assertEquals("TIMEOUT", error.code());
        }
    }

    @Test void malformedReplyLeavesMutationOutcomeUnknown() throws Exception {
        try (var adapter = adapter("bad-frame", 4000)) {
            var error = assertThrows(AgentException.class, () -> adapter.call(op("setValue")));
            assertEquals("ACTION_OUTCOME_UNKNOWN", error.code());
        }
    }

    @Test void blockedPipeWriteCannotOutliveDeadline() throws Exception {
        try (var adapter = adapter("stall", 300)) {
            ObjectNode request = op("setValue").put("value", "x".repeat(512 * 1024));
            assertTimeoutPreemptively(Duration.ofSeconds(4), () -> {
                var error = assertThrows(AgentException.class, () -> adapter.call(request));
                assertEquals("ACTION_OUTCOME_UNKNOWN", error.code());
            });
        }
    }
}
