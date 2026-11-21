package dev.desktop;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;

/** A separate JVM stands in for the native UIA host on any OS. */
public final class WindowsTransportFixture {
    public static void main(String[] args) throws Exception {
        if (args[0].equals("stall")) {
            Thread.sleep(60_000);
            return;
        }
        var input = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        for (String line; (line = input.readLine()) != null;) {
            if (args[0].equals("bad-frame")) {
                System.out.println("{\"ok\":true}");
                System.out.flush();
                continue;
            }
            if (line.contains("\"invoke\"")) {
                return;
            }
            System.out.println("{\"ok\":true,\"result\":" + ProcessHandle.current().pid() + "}");
            System.out.flush();
        }
    }
}
