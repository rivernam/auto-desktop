package dev.desktop.legacy;

import com.google.gson.*;
import com.google.gson.stream.JsonReader;
import com.google.gson.stream.JsonToken;
import java.io.*;
import java.math.BigDecimal;

/** Strict bounded JSON trees with duplicate-key detection. */
final class JsonObjects {
    static JsonObject object(String frame) throws IOException {
        JsonReader reader = new JsonReader(new StringReader(frame));
        reader.setLenient(false);
        JsonElement value = readValue(reader, 0);
        if (!value.isJsonObject() || reader.peek() != JsonToken.END_DOCUMENT)
            throw new IOException("Expected a JSON object.");
        return value.getAsJsonObject();
    }

    private static JsonElement readValue(JsonReader reader, int depth) throws IOException {
        if (depth > 16) throw new IOException("Too deeply nested.");
        switch (reader.peek()) {
            case BEGIN_OBJECT:
                JsonObject object = new JsonObject();
                reader.beginObject();
                while (reader.hasNext()) {
                    String name = reader.nextName();
                    if (object.size() >= 128 || object.has(name)) throw new IOException("Invalid object.");
                    object.add(name, readValue(reader, depth + 1));
                }
                reader.endObject();
                return object;
            case BEGIN_ARRAY:
                JsonArray array = new JsonArray();
                reader.beginArray();
                while (reader.hasNext()) {
                    if (array.size() >= 4096) throw new IOException("Oversized array.");
                    array.add(readValue(reader, depth + 1));
                }
                reader.endArray();
                return array;
            case STRING: return new JsonPrimitive(reader.nextString());
            case BOOLEAN: return new JsonPrimitive(reader.nextBoolean());
            case NUMBER: return new JsonPrimitive(new BigDecimal(reader.nextString()));
            case NULL: reader.nextNull(); return JsonNull.INSTANCE;
            default: throw new IOException("Invalid JSON value.");
        }
    }

    private JsonObjects() {}
}
