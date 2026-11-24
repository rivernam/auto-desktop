package dev.desktop;

import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.MissingNode;
import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.lang.management.ManagementFactory;
import java.util.Set;

/** Provider-free command history workload used by tools/Measure-CommandHistory.ps1. */
public final class HistoryMemoryProbe {
    private HistoryMemoryProbe() {}

    public static void main(String[] args) throws Exception {
        int length = Integer.parseInt(args[0]);
        if (length < 4 || length > 128) throw new IllegalArgumentException("Invalid ID length.");
        boolean retain = "retain".equals(args[1]);
        var history = new ActionDispatcher(pid -> true, Set.of("invoke"));
        var adapter = new DesktopAdapter() {
            @Override public com.fasterxml.jackson.databind.JsonNode call(
                    com.fasterxml.jackson.databind.node.ObjectNode unused) { return MissingNode.getInstance(); }
            @Override public void close() {}
        };
        var properties = JsonNodeFactory.instance.objectNode().put("enabled", true);
        properties.putArray("actions").add("invoke");
        var target = new DesktopSnapshot.Element("ref", "key", null, 42, properties);
        var memory = ManagementFactory.getMemoryMXBean();
        try (var input = new BufferedReader(new InputStreamReader(System.in))) {
            int count = 0;
            for (int stop : new int[]{0, 512, 1024, 2048, 4096}) {
                for (; count < stop; count++) {
                    String prefix = Integer.toString(count);
                    String id = prefix + "x".repeat(length - prefix.length());
                    if (retain) history.dispatch(adapter, id, DesktopAction.INVOKE, target, MissingNode.getInstance(), () -> {});
                    try {
                        history.checkUnused(id);
                        if (retain) throw new IllegalStateException("Missing command ID.");
                    } catch (AgentException duplicate) {
                        if (!retain || !"DUPLICATE_COMMAND".equals(duplicate.code())) throw duplicate;
                    }
                }
                System.gc();
                long used = memory.getHeapMemoryUsage().getUsed();
                System.out.printf("{\"generated\":%d,\"stored\":%d,\"idLength\":%d,\"heapUsedBytes\":%d}%n",
                        count, retain ? count : 0, length, used);
                if (input.readLine() == null) throw new IllegalStateException("History probe driver disconnected.");
            }
        }
    }
}
