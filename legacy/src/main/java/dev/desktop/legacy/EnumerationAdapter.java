package dev.desktop.legacy;

import com.google.gson.*;
import dev.desktop.protocol.ReadOnlyDesktopAdapter;
import java.util.Arrays;

/** Maps an explicitly configured enumeration process to the two shared desktop operations. */
final class EnumerationAdapter implements ReadOnlyDesktopAdapter<JsonElement> {
    private static final String CAPS = "getCapabilities";
    private static final String WINDOWS = "listWindows";
    private final WorkerProcess worker;

    EnumerationAdapter(WorkerProcess worker) {
        this.worker = worker;
    }

    public JsonElement capabilities() {
        if (worker != null) {
            try {
                return result(CAPS, worker.call(CAPS));
            } catch (Fault fault) {
                if (!"BACKEND_UNAVAILABLE".equals(fault.code)) throw fault;
            }
        }
        JsonObject caps = new JsonObject();
        caps.addProperty("available", false);
        caps.addProperty("backend", "none");
        caps.addProperty("physicalInput", false);
        caps.addProperty("screenshot", false);
        caps.add("operations", new JsonArray());
        caps.addProperty("reason", worker == null ? "No enumeration worker was configured." : "The enumeration worker is unavailable.");
        return caps;
    }

    public JsonElement listWindows() {
        if (worker == null) throw Fault.unavailable();
        return result(WINDOWS, worker.call(WINDOWS));
    }

    private static JsonElement result(String op, JsonObject reply) {
        boolean ok = bool(reply.get("ok"));
        if (!ok) {
            if (reply.has("error") && reply.get("error").isJsonObject()) {
                JsonElement code = reply.getAsJsonObject("error").get("code");
                if (text(code) && "BACKEND_UNAVAILABLE".equals(code.getAsString())) throw Fault.unavailable();
            }
            throw Fault.protocol();
        }
        JsonElement result = reply.get("result");
        if (result == null) throw Fault.protocol();
        if (CAPS.equals(op)) return capabilities(result);
        if (!result.isJsonArray()) throw Fault.protocol();
        JsonArray windows = new JsonArray();
        for (JsonElement item : result.getAsJsonArray()) {
            if (!item.isJsonObject()) throw Fault.protocol();
            JsonObject row = item.getAsJsonObject();
            JsonElement pid = row.get("processId");
            if (pid == null || !pid.isJsonPrimitive() || !pid.getAsJsonPrimitive().isNumber()) throw Fault.protocol();
            // Reject fractional or out-of-range PIDs. Zero indicates unavailable process metadata.
            long number;
            try { number = pid.getAsBigDecimal().longValueExact(); }
            catch (ArithmeticException invalid) { throw Fault.protocol(); }
            if (number < 0 || number > 4294967295L || !text(row.get("windowId"))
                    || row.get("windowId").getAsString().isEmpty() || !text(row.get("name"))) throw Fault.protocol();
            JsonObject window = new JsonObject();
            window.add("windowId", row.get("windowId"));
            window.addProperty("processId", number);
            window.add("name", row.get("name"));
            windows.add(window);
        }
        return windows;
    }

    private static JsonObject capabilities(JsonElement result) {
        if (!result.isJsonObject()) throw Fault.protocol();
        JsonObject source = result.getAsJsonObject();
        boolean available = bool(source.get("available"));
        if (!text(source.get("backend")) || source.get("backend").getAsString().trim().isEmpty()
                || bool(source.get("physicalInput")) || bool(source.get("screenshot"))
                || !source.has("operations") || !source.get("operations").isJsonArray()) throw Fault.protocol();
        JsonArray operations = source.getAsJsonArray("operations");
        if (available) {
            if (operations.size() != 2 || !operations.contains(new JsonPrimitive(CAPS))
                    || !operations.contains(new JsonPrimitive(WINDOWS))) throw Fault.protocol();
        } else if (operations.size() != 0 || !text(source.get("reason")) || source.get("reason").getAsString().trim().isEmpty()) {
            throw Fault.protocol();
        }
        JsonObject caps = new JsonObject();
        for (String field : Arrays.asList("backend", "available", "operations", "physicalInput", "screenshot"))
            caps.add(field, source.get(field));
        if (!available) caps.add("reason", source.get("reason"));
        return caps;
    }

    private static boolean bool(JsonElement value) {
        if (value == null || !value.isJsonPrimitive() || !value.getAsJsonPrimitive().isBoolean()) throw Fault.protocol();
        return value.getAsBoolean();
    }

    private static boolean text(JsonElement value) {
        return value != null && value.isJsonPrimitive() && value.getAsJsonPrimitive().isString();
    }

}
