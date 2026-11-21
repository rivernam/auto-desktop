package dev.desktop;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class JnaUiaMetadataTest {
    @Test void nativeTypeIdsMapToTheSameRolesAsManagedUia() {
        assertEquals("Button", JnaUiaSession.role(50000));
        assertEquals("Edit", JnaUiaSession.role(50004));
        assertEquals("Window", JnaUiaSession.role(50032));
        assertEquals("AppBar", JnaUiaSession.role(50040));
        assertEquals("Custom", JnaUiaSession.role(12345));
    }

    @Test void clippedLabelsNeverExposeHalfOfASurrogatePair() {
        String prefix = "x".repeat(255);
        assertEquals(prefix, JnaUiaSession.clip(prefix + "😀"));
        assertEquals(prefix + "a", JnaUiaSession.clip(prefix + "ab"));
        assertEquals("", JnaUiaSession.clip(null));
    }

    @Test void windowIdsAreCanonicalUnsigned32BitHandles() {
        assertEquals(4294967295L, JnaUiaSession.parseWindowId("4294967295"));
        for (String id : new String[]{"", "0", "01", "+1", "-1", "1 ", "4294967296", "１２"}) {
            assertEquals("WINDOW_NOT_FOUND", assertThrows(AgentException.class,
                    () -> JnaUiaSession.parseWindowId(id)).code());
        }
    }
}
