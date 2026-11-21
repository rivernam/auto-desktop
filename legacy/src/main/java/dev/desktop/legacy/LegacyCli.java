package dev.desktop.legacy;

import com.google.gson.*;
import dev.desktop.protocol.Utf8Frames;
import dev.desktop.protocol.ReadOnlyDesktopAdapter;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.Arrays;
import java.util.Collections;

/** Foreground, read-only Java 7 agent for native legacy window enumerators. */
public final class LegacyCli {
    private static final String CAPS = "getCapabilities";
    private static final String WINDOWS = "listWindows";

    public static void main(String[] args) throws IOException {
        WorkerProcess worker = null;
        if (args.length != 0) {
            if (args.length != 2 || !"--worker".equals(args[0]) || !new File(args[1]).isAbsolute()) {
                System.err.println("Usage: java -jar legacy-agent.jar [--worker ABSOLUTE_EXECUTABLE]");
                System.exit(2);
                return;
            }
            worker = new WorkerProcess(Collections.singletonList(args[1]), 5000);
        }
        serve(new EnumerationAdapter(worker), System.in, System.out);
    }

    static void serve(ReadOnlyDesktopAdapter<JsonElement> adapter, InputStream in, OutputStream out) throws IOException {
        Utf8Frames frames = new Utf8Frames(in, Utf8Frames.COMMAND_LIMIT);
        while (true) {
            JsonObject response;
            try {
                String line = frames.read();
                if (line == null) return;
                response = dispatch(adapter, line);
            } catch (Utf8Frames.InvalidFrameException invalid) {
                response = error(null, invalidRequest());
            }
            out.write((response.toString() + "\n").getBytes(StandardCharsets.UTF_8));
            out.flush();
        }
    }

    private static JsonObject dispatch(ReadOnlyDesktopAdapter<JsonElement> adapter, String line) {
        String id = null;
        try {
            JsonObject request = JsonObjects.object(line);
            id = requestString(request, "id", 128);
            String op = requestString(request, "op", 32);
            if (!CAPS.equals(op) && !WINDOWS.equals(op)) {
                if (Arrays.asList("snapshot", "findElement", "getElementInfo", "invoke", "setValue").contains(op))
                    throw new Fault("OPERATION_UNSUPPORTED", "This worker supports only window enumeration.");
                throw new Fault("UNKNOWN_OPERATION", "Unknown operation.");
            }
            JsonElement result = CAPS.equals(op) ? adapter.capabilities() : adapter.listWindows();
            JsonObject response = envelope(id, true);
            response.add("result", result);
            return response;
        } catch (Fault fault) {
            return error(id, fault);
        } catch (IOException invalid) {
            return error(id, invalidRequest());
        } catch (NumberFormatException invalid) {
            return error(id, invalidRequest());
        }
    }

    private static String requestString(JsonObject request, String key, int limit) {
        JsonElement value = request.get(key);
        if (value == null || !value.isJsonPrimitive() || !value.getAsJsonPrimitive().isString()
                || value.getAsString().trim().isEmpty() || value.getAsString().length() > limit)
            throw invalidRequest();
        return value.getAsString();
    }

    private static Fault invalidRequest() {
        return new Fault("INVALID_REQUEST", "Expected a supported UTF-8 JSON request object.");
    }

    private static JsonObject envelope(String id, boolean ok) {
        JsonObject response = new JsonObject();
        response.add("id", id == null ? JsonNull.INSTANCE : new JsonPrimitive(id));
        response.addProperty("ok", ok);
        return response;
    }

    private static JsonObject error(String id, Fault fault) {
        JsonObject response = envelope(id, false);
        JsonObject error = new JsonObject();
        error.addProperty("code", fault.code);
        error.addProperty("message", fault.getMessage());
        response.add("error", error);
        return response;
    }

    private LegacyCli() {}
}
