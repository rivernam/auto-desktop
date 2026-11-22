package dev.desktop;

import java.nio.file.Path;
import java.util.concurrent.TimeUnit;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.*;

class FixtureOutputTest {
    @Test void drainsBothStreamsEvenAfterReachingDiagnosticLimit() throws Exception {
        Path java = Path.of(System.getProperty("java.home"), "bin", "java");
        Path classes = Path.of(Writer.class.getProtectionDomain().getCodeSource().getLocation().toURI());
        Process fixture = new ProcessBuilder(java.toString(), "-cp", classes.toString(), Writer.class.getName())
                .redirectErrorStream(true).start();
        try {
            FixtureOutput output = new FixtureOutput(fixture);
            assertTrue(fixture.waitFor(10, TimeUnit.SECONDS), "Fixture blocked while writing to its pipes.");
            assertEquals(0, fixture.exitValue());
            String diagnostic = output.afterExit();
            assertTrue(diagnostic.contains("fixture stdout"), diagnostic);
            assertTrue(diagnostic.contains("fixture stderr"), diagnostic);
            assertTrue(diagnostic.contains("[output truncated]"), diagnostic);
            assertTrue(diagnostic.length() < 20_000);
        } finally {
            if (fixture.isAlive()) fixture.destroyForcibly();
        }
    }

    public static final class Writer {
        public static void main(String[] args) {
            System.out.println("fixture stdout");
            System.err.println("fixture stderr");
            System.out.print("x".repeat(256 * 1024));
        }
    }
}
