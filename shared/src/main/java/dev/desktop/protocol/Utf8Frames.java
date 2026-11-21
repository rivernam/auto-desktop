package dev.desktop.protocol;

import java.io.BufferedInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.StandardCharsets;

/** Bounded UTF-8 NDJSON framing, shared by the modern and Java 7 builds. */
public final class Utf8Frames {
    public static final int COMMAND_LIMIT = 64 * 1024;
    private final BufferedInputStream source;
    private final int maxBytes;

    public static final class InvalidFrameException extends IOException {
        private static final long serialVersionUID = 1L;
        private InvalidFrameException() { super("Invalid UTF-8 frame or frame limit exceeded."); }
    }

    public Utf8Frames(InputStream source, int maxBytes) {
        if (maxBytes < 1) throw new IllegalArgumentException("Expected a positive frame limit.");
        this.source = new BufferedInputStream(source);
        this.maxBytes = maxBytes;
    }

    /** Returns null at EOF. An invalid frame is fully consumed before the exception is raised. */
    public String read() throws IOException {
        ByteArrayOutputStream line = new ByteArrayOutputStream();
        boolean oversized = false;
        int ch;
        while ((ch = source.read()) != -1 && ch != '\n') {
            if (line.size() < maxBytes) line.write(ch);
            else oversized = true;
        }
        if (ch == -1 && line.size() == 0) return null;
        if (oversized) throw new InvalidFrameException();
        try {
            return StandardCharsets.UTF_8.newDecoder().decode(ByteBuffer.wrap(line.toByteArray())).toString();
        } catch (CharacterCodingException malformed) {
            throw new InvalidFrameException();
        }
    }
}
