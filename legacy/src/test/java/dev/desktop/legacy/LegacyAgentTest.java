package dev.desktop.legacy;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.io.*;
import java.util.Collections;
import java.util.Arrays;
import java.util.List;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

public class LegacyAgentTest {
    static final String CAPS = "{\"backend\":\"fixture\",\"available\":true,\"operations\":[\"getCapabilities\",\"listWindows\"],\"physicalInput\":false,\"screenshot\":false}";

    public static class Child {
        public static void main(String[] args) throws Exception {
            String frame = new BufferedReader(new InputStreamReader(System.in, "UTF-8")).readLine();
            if (args[0].equals("slow")) Thread.sleep(20000);
            if (args[0].equals("broken")) { System.out.println("not-json"); return; }
            if (args[0].equals("extra")) System.out.println("{}");
            String result = frame.equals("{\"op\":\"getCapabilities\"}") ? CAPS
                    : "[{\"processId\":0,\"name\":\"제목\",\"windowId\":\"1\"}]";
            if (args[0].equals("overclaim")) result = CAPS.replace("listWindows", "invoke");
            System.out.write(("{\"ok\":true,\"result\":" + result + "}\n").getBytes("UTF-8"));
        }
    }

    static WorkerProcess worker(String mode, int timeout) {
        File java = new File(new File(System.getProperty("java.home"), "bin"),
                File.separatorChar == '\\' ? "java.exe" : "java");
        List<String> argv = Arrays.asList(java.getAbsolutePath(), "-cp", System.getProperty("java.class.path"),
                Child.class.getName(), mode);
        return new WorkerProcess(argv, timeout);
    }

    static JsonObject send(WorkerProcess worker, String line) throws Exception {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        LegacyCli.serve(new EnumerationAdapter(worker), new ByteArrayInputStream((line + "\n").getBytes("UTF-8")), output);
        return JsonParser.parseString(output.toString("UTF-8")).getAsJsonObject();
    }

    static void code(JsonObject reply, String code) {
        assertFalse(reply.get("ok").getAsBoolean());
        assertEquals(code, reply.getAsJsonObject("error").get("code").getAsString());
    }

    @Test void realPipeRoundTripPreservesIdUnicodeAndReadOnlySurface() throws Exception {
        WorkerProcess worker = worker("normal", 5000);
        JsonObject reply = send(worker, "{\"id\":\"1\",\"op\":\"listWindows\"}");
        assertEquals("1", reply.get("id").getAsString());
        assertEquals("제목", reply.getAsJsonArray("result").get(0).getAsJsonObject().get("name").getAsString());
        assertEquals(2, send(worker, "{\"id\":\"2\",\"op\":\"getCapabilities\"}")
                .getAsJsonObject("result").getAsJsonArray("operations").size());
        code(send(worker, "{\"id\":\"3\",\"op\":\"invoke\"}"), "OPERATION_UNSUPPORTED");
        code(send(worker, "{\"id\":\"4\",\"op\":\"other\"}"), "UNKNOWN_OPERATION");
    }

    @Test void invalidFramesAndDishonestWorkerRepliesFailClosed() throws Exception {
        WorkerProcess worker = worker("normal", 5000);
        for (String input : Arrays.asList("[]", "{id:'1',op:'listWindows'}", "{}", "{} {}",
                "{\"id\":\"first\",\"id\":\"second\",\"op\":\"listWindows\"}")) {
            code(send(worker, input), "INVALID_REQUEST");
        }
        for (String mode : Arrays.asList("broken", "extra", "overclaim"))
            code(send(worker(mode, 5000), "{\"id\":\"x\",\"op\":\"getCapabilities\"}"), "WORKER_PROTOCOL");
    }

    @Test void absentOrMissingWorkerAdvertisesNoOperations() throws Exception {
        WorkerProcess missing = new WorkerProcess(Collections.singletonList(
                new File("absent-worker-for-test").getAbsolutePath()), 300);
        for (WorkerProcess worker : Arrays.asList(null, missing)) {
            JsonObject caps = send(worker, "{\"id\":\"c\",\"op\":\"getCapabilities\"}").getAsJsonObject("result");
            assertFalse(caps.get("available").getAsBoolean());
            assertTrue(caps.getAsJsonArray("operations").isEmpty());
            assertFalse(caps.get("reason").getAsString().isEmpty());
            code(send(worker, "{\"id\":\"w\",\"op\":\"listWindows\"}"), "BACKEND_UNAVAILABLE");
        }
    }

    @Test void deadlineEndsHungRead() throws Exception {
        long start = System.nanoTime();
        code(send(worker("slow", 300), "{\"id\":\"t\",\"op\":\"listWindows\"}"), "TIMEOUT");
        assertTrue(System.nanoTime() - start < 5000000000L);
    }
}
