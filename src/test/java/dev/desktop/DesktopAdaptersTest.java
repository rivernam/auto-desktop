package dev.desktop;

import static org.junit.jupiter.api.Assertions.*;

import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import org.junit.jupiter.api.Test;

class DesktopAdaptersTest {
    @Test void onlyWindowsSelectsTheWindowsProvider() {
        try (DesktopAdapter adapter = DesktopAdapters.select("Windows 11", null)) {
            assertInstanceOf(WindowsAdapter.class, adapter);
        }
        for (String os : new String[]{"Linux", "FreeBSD"}) {
            try (DesktopAdapter adapter = DesktopAdapters.select(os, null)) {
                assertFalse(adapter instanceof WindowsAdapter);
                var probe = adapter.call(JsonNodeFactory.instance.objectNode().put("op", "getCapabilities"));
                assertEquals("none", probe.path("backend").asText());
                assertFalse(probe.path("available").asBoolean(true));
                assertTrue(probe.path("operations").isEmpty());
                assertFalse(probe.path("physicalInput").asBoolean(true));
                assertThrows(AgentException.class, () -> adapter.call(
                        JsonNodeFactory.instance.objectNode().put("op", "snapshot")));
            }
        }
    }
}
