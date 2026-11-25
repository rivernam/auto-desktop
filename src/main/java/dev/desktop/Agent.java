package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.FutureTask;
import java.util.function.IntPredicate;
import java.util.function.LongSupplier;
import java.util.function.Supplier;

/**
 * One serialized client session over one or more accessibility backends. Each backend keeps the
 * references of its own most recent successful snapshot. Command IDs and the action policy belong to
 * the session as a whole.
 */
public final class Agent implements AutoCloseable {
    /** The name that selects every configured backend at once on the command line. */
    static final String MULTI = "multi";

    /** One backend of the session: its adapter and the references of its latest snapshot. */
    private static final class Backend {
        // Null for a session built without a backend name. Such a session ignores the backend field.
        final String name;
        // Null when a retired adapter must not be replaced within this process.
        final Supplier<? extends DesktopAdapter> restart;
        DesktopAdapter adapter;
        DesktopSnapshot snapshot;

        Backend(String name, DesktopAdapter adapter, Supplier<? extends DesktopAdapter> restart) {
            this.name = name;
            this.adapter = adapter;
            this.restart = restart;
        }
    }

    /** How a multi-backend session opens one backend. */
    static final class BackendSource {
        private final Supplier<? extends DesktopAdapter> factory;
        private final boolean restartable;

        BackendSource(Supplier<? extends DesktopAdapter> factory, boolean restartable) {
            this.factory = factory;
            this.restartable = restartable;
        }

        public Supplier<? extends DesktopAdapter> factory() { return factory; }
        public boolean restartable() { return restartable; }

        @Override public boolean equals(Object other) {
            if (this == other) return true;
            if (!(other instanceof BackendSource)) return false;
            BackendSource that = (BackendSource) other;
            return Objects.equals(factory, that.factory)
                    && restartable == that.restartable;
        }
        @Override public int hashCode() { return Objects.hash(factory, restartable); }
        @Override public String toString() {
            return "BackendSource[" + "factory=" + factory
                    + ", restartable=" + restartable + "]";
        }
    }

    private final List<Backend> backends = new ArrayList<>();
    private final boolean multi;
    private final ActionDispatcher actions;
    private final LongSupplier nanoTime;

    public Agent(DesktopAdapter adapter, Set<Integer> allowedPids, Set<String> allowedActions) {
        this(adapter, allowedPids, allowedActions, System::nanoTime);
    }

    public Agent(DesktopAdapter adapter, IntPredicate allowedProcess, Set<String> allowedActions) {
        this(null, adapter, allowedProcess, allowedActions, System::nanoTime);
    }

    /** A single-backend session that also checks the optional backend field of a snapshot request. */
    public Agent(String backend, DesktopAdapter adapter, IntPredicate allowedProcess, Set<String> allowedActions) {
        this(backend, adapter, allowedProcess, allowedActions, System::nanoTime);
    }

    Agent(DesktopAdapter adapter, Set<Integer> allowedPids, Set<String> allowedActions, LongSupplier nanoTime) {
        this(null, adapter, Set.copyOf(allowedPids)::contains, allowedActions, nanoTime);
    }

    private Agent(String backend, DesktopAdapter adapter, IntPredicate allowedProcess, Set<String> allowedActions,
                  LongSupplier nanoTime) {
        backends.add(new Backend(backend, adapter, null));
        multi = false;
        actions = new ActionDispatcher(allowedProcess, allowedActions);
        this.nanoTime = nanoTime;
    }

    private Agent(Map<String, BackendSource> sources, IntPredicate allowedProcess, Set<String> allowedActions,
                  LongSupplier nanoTime) {
        if (sources.isEmpty()) throw new IllegalArgumentException("A session needs one or more backends.");
        for (var source : sources.entrySet()) {
            var factory = source.getValue().factory();
            backends.add(new Backend(source.getKey(), factory.get(), source.getValue().restartable() ? factory : null));
        }
        multi = true;
        actions = new ActionDispatcher(allowedProcess, allowedActions);
        this.nanoTime = nanoTime;
    }

    /**
     * One session over several backends, in the given order. The first is the default for a snapshot
     * that names none. The session owns the adapters and closes them.
     */
    public static Agent multi(LinkedHashMap<String, BackendSource> sources, IntPredicate allowedProcess,
                              Set<String> allowedActions) {
        return new Agent(sources, allowedProcess, allowedActions, System::nanoTime);
    }

    static Agent multi(LinkedHashMap<String, BackendSource> sources, Set<Integer> allowedPids,
                       Set<String> allowedActions, LongSupplier nanoTime) {
        return new Agent(sources, Set.copyOf(allowedPids)::contains, allowedActions, nanoTime);
    }

    private static ObjectNode object() {
        return JsonNodeFactory.instance.objectNode();
    }

    public synchronized ObjectNode handle(ObjectNode request) {
        ObjectNode response = object().putNull("id");
        try {
            if (request == null) throw invalid("Expected a request object.");
            String id = string(request, "id", 128);
            response.put("id", id);
            String op = string(request, "op", 32);
            JsonNode result;
            switch (op) {
                case "getCapabilities":
                    result = multi ? capabilities() : backends.get(0).adapter.capabilities();
                    break;
                case "listWindows":
                    result = multi ? windows(response) : backends.get(0).adapter.listWindows();
                    break;
                case "snapshot":
                    result = capture(request);
                    break;
                case "findElement":
                    result = find(request);
                    break;
                case "getElementInfo":
                    result = info(request);
                    break;
                case "invoke":
                    result = perform(request, id, DesktopAction.INVOKE);
                    break;
                case "setValue":
                    result = perform(request, id, DesktopAction.SET_VALUE);
                    break;
                case "defaultAction":
                    result = perform(request, id, DesktopAction.DEFAULT_ACTION);
                    break;
                case "select":
                    result = perform(request, id, DesktopAction.SELECT);
                    break;
                default:
                    throw new AgentException("UNKNOWN_OPERATION", "Unknown operation.");
            }
            response.put("ok", true).set("result", result);
        } catch (AgentException ex) {
            response.put("ok", false).putObject("error").put("code", ex.code()).put("message", ex.getMessage());
        } catch (RuntimeException ex) {
            response.put("ok", false).putObject("error").put("code", "INTERNAL_ERROR")
                    .put("message", "The operation could not be completed.");
        }
        return response;
    }

    /** The adapter of a backend. A restartable adapter that a fault retired and released is replaced first. */
    private DesktopAdapter adapter(Backend backend) {
        if (backend.restart != null && backend.adapter.finished()) {
            backend.adapter.close();
            // References of the retired adapter name native objects that no longer exist.
            backend.snapshot = null;
            backend.adapter = backend.restart.get();
        }
        return backend.adapter;
    }

    /**
     * Tells every other backend that a request is about to run, or has ended. A provider that walks
     * the desktop also reaches the hidden windows of this process, and must not wait for their threads.
     */
    private void attend(Backend busy, boolean on) {
        if (!multi) return;
        for (Backend other : backends) {
            if (other != busy) other.adapter.attend(on);
        }
    }

    /** The adapter that issued the backend's current references. A replaced adapter cannot honour them. */
    private DesktopAdapter issuer(Backend backend) {
        DesktopAdapter issuer = backend.adapter;
        if (adapter(backend) != issuer) throw DesktopSnapshot.stale();
        return issuer;
    }

    private List<Supplier<JsonNode>> startQueries(boolean windows) {
        long deadline = System.nanoTime() + JnaDesktopAdapter.REQUEST_BUDGET.toNanos();
        List<Supplier<JsonNode>> queries = new ArrayList<>(backends.size());
        for (Backend backend : backends) queries.add(adapter(backend).startQuery(windows, deadline));
        return queries;
    }

    private void attendQueries(boolean on) {
        // A provider with a message window pumps it after its own query while its peers finish.
        for (Backend backend : backends) backend.adapter.attend(on);
    }

    private ObjectNode capabilities() {
        ObjectNode result = object().put("backend", MULTI);
        ArrayNode rows = JsonNodeFactory.instance.arrayNode();
        boolean available = false;
        boolean msaa = false;
        boolean invoke = false;
        var queries = startQueries(false);
        try {
            attendQueries(true);
            for (int i = 0; i < backends.size(); i++) {
                JsonNode row;
                try {
                    row = queries.get(i).get();
                } catch (AgentException failed) {
                    row = DesktopCapabilities.unavailable(backends.get(i).name, failed.getMessage());
                }
                if (row.path("available").asBoolean()) {
                    available = true;
                    if ("MSAA".equals(row.path("backend").asText())) msaa = true;
                    else invoke = true;
                }
                rows.add(row);
            }
        } finally {
            attendQueries(false);
        }
        result.put("available", available);
        if (!available) result.put("reason", "No backend of this session is available.");
        result.put("physicalInput", false).put("screenshot", false);
        ArrayNode operations = result.putArray("operations");
        if (available) {
            for (String op : List.of("getCapabilities", "listWindows", "snapshot", "findElement", "getElementInfo"))
                operations.add(op);
            if (invoke) operations.add("invoke");
            operations.add("setValue");
            if (msaa) operations.add("defaultAction").add("select");
        }
        result.put("defaultBackend", backends.get(0).name);
        result.set("backends", rows);
        return result;
    }

    /**
     * The windows of every backend, one row per window. Each row names the backends that listed it.
     * The response also carries one status per backend, so a backend that failed is told apart from
     * a backend that has no such window.
     */
    private ArrayNode windows(ObjectNode response) {
        var queries = startQueries(true);
        try {
            attendQueries(true);
            return mergeWindows(response, queries);
        } finally {
            attendQueries(false);
        }
    }

    private ArrayNode mergeWindows(ObjectNode response, List<Supplier<JsonNode>> queries) {
        ArrayNode status = response.putArray("backends");
        Map<String, ObjectNode> merged = new LinkedHashMap<>();
        AgentException first = null;
        boolean sameCode = true;
        int failures = 0;
        for (int i = 0; i < backends.size(); i++) {
            Backend backend = backends.get(i);
            ObjectNode entry = status.addObject().put("backend", backend.name);
            try {
                JsonNode listed = queries.get(i).get();
                if (!listed.isArray()) throw new AgentException("WORKER_PROTOCOL", "Invalid window list.");
                List<ObjectNode> added = new ArrayList<>();
                for (JsonNode row : listed) {
                    if (!(row instanceof ObjectNode) || !row.path("windowId").isTextual())
                        throw new AgentException("WORKER_PROTOCOL", "Invalid window list.");
                    ObjectNode window = (ObjectNode) row;
                    added.add(window);
                }
                for (ObjectNode window : added) {
                    // The same handle with another owner process is another window. Keep both rows.
                    String key = window.get("windowId").textValue() + "\n" + window.path("processId").asText();
                    ObjectNode known = merged.get(key);
                    if (known == null) {
                        known = window.deepCopy();
                        known.putArray("backends");
                        merged.put(key, known);
                    }
                    ((ArrayNode) known.get("backends")).add(backend.name);
                }
                entry.put("ok", true);
            } catch (AgentException failed) {
                entry.put("ok", false).putObject("error").put("code", failed.code()).put("message", failed.getMessage());
                failures++;
                if (first == null) first = failed;
                else sameCode &= first.code().equals(failed.code());
            }
        }
        if (failures == backends.size()) {
            throw sameCode ? first : new AgentException("BACKEND_UNAVAILABLE", "No backend could list windows.");
        }
        ArrayNode rows = JsonNodeFactory.instance.arrayNode();
        rows.addAll(merged.values());
        return rows;
    }

    private Backend named(ObjectNode request) {
        if (!request.has("backend")) return null;
        String name = string(request, "backend", 32);
        for (Backend backend : backends) {
            // A session built without a name predates the field and ignores it.
            if (backend.name == null || backend.name.equals(name)) return backend;
        }
        throw new AgentException("BACKEND_UNAVAILABLE", "This session does not include the requested backend.");
    }

    /** The backend whose current snapshot issued the reference. */
    private Backend owner(String ref) {
        long now = nanoTime.getAsLong();
        for (Backend backend : backends) {
            if (backend.snapshot == null) continue;
            if (backend.snapshot.expired(now)) backend.snapshot = null;
            else if (backend.snapshot.has(ref)) return backend;
        }
        throw DesktopSnapshot.stale();
    }

    private ObjectNode capture(ObjectNode request) {
        int limit = integer(request, "maxElements", 500, 1, 2000);
        String windowId = string(request, "windowId", 256);
        int depth = integer(request, "maxDepth", 12, 0, 32);
        String scopeRef = scopeRef(request);
        Backend target = named(request);
        DesktopSnapshot previous = null;
        if (scopeRef != null) {
            // A scope is a reference. It selects its own backend and is stale for any other.
            Backend owner = owner(scopeRef);
            if (target != null && target != owner) throw DesktopSnapshot.stale();
            target = owner;
            previous = owner.snapshot;
        }
        if (target == null) target = backends.get(0);
        DesktopSnapshot.Element scope = previous == null ? null : previous.resolveInWindow(windowId, scopeRef);
        DesktopAdapter adapter = scope == null ? adapter(target) : issuer(target);
        // The adapter may replace its native references even when a capture fails.
        target.snapshot = null;
        JsonNode captured;
        attend(target, true);
        try {
            captured = scope == null ? adapter.snapshot(windowId, depth, limit)
                    : adapter.snapshotSubtree(windowId, scope.key(), scope.processId(), depth, limit);
        } catch (AgentException ex) {
            if (scope != null && "SNAPSHOT_SCOPE_UNSUPPORTED".equals(ex.code())) target.snapshot = previous;
            throw ex;
        } finally {
            attend(target, false);
        }
        target.snapshot = new DesktopSnapshot(windowId, captured, depth, limit, nanoTime.getAsLong());
        ObjectNode described = target.snapshot.describe();
        if (multi) described.put("backend", target.name);
        return described;
    }

    private ObjectNode find(ObjectNode request) {
        String snapshotId = string(request, "snapshotId", 128);
        String scopeRef = scopeRef(request);
        long now = nanoTime.getAsLong();
        for (Backend backend : backends) {
            if (backend.snapshot == null) continue;
            if (backend.snapshot.expired(now)) backend.snapshot = null;
            else if (backend.snapshot.id().equals(snapshotId)) {
                if (issuer(backend).retired())
                    throw new AgentException("BACKEND_UNAVAILABLE", "The snapshot's backend was retired.");
                return backend.snapshot.find(snapshotId, scopeRef, request.get("locator"));
            }
        }
        throw DesktopSnapshot.stale();
    }

    private static String scopeRef(ObjectNode request) {
        return request.has("scopeRef") ? string(request, "scopeRef", 128) : null;
    }

    private ObjectNode info(ObjectNode request) {
        String ref = string(request, "ref", 128);
        Backend backend = owner(ref);
        DesktopSnapshot current = backend.snapshot;
        DesktopSnapshot.Element element = current.resolve(ref);
        DesktopAdapter adapter = issuer(backend);
        attend(backend, true);
        try {
            return current.liveInfo(element, adapter.elementInfo(element.key(), element.processId()));
        } finally {
            attend(backend, false);
        }
    }

    private JsonNode perform(ObjectNode request, String id, DesktopAction action) {
        actions.checkUnused(id);
        String ref = string(request, "ref", 128);
        // The action goes to the backend that issued the reference and to no other.
        Backend backend = owner(ref);
        DesktopSnapshot current = backend.snapshot;
        DesktopSnapshot.Element target = current.resolve(ref);
        DesktopAdapter adapter = issuer(backend);
        JsonNode result;
        attend(backend, true);
        try {
            result = actions.dispatch(adapter, id, action, target, request.path("value"), () -> {
                if (current.expired(nanoTime.getAsLong())) throw DesktopSnapshot.stale();
            });
        } finally {
            attend(backend, false);
        }
        // The provider accepted the call. Only the application can show that it had an effect.
        if (result instanceof ObjectNode && !((ObjectNode) result).has("effectVerified")) {
            ObjectNode reply = (ObjectNode) result;
            return reply.deepCopy().put("effectVerified", false);
        }
        return result;
    }

    /** Closes every backend. One that waits on a provider call does not delay the release of the others. */
    @Override public synchronized void close() {
        if (backends.size() == 1) {
            backends.get(0).adapter.close();
            return;
        }
        List<FutureTask<Void>> cleanups = new ArrayList<>();
        for (Backend backend : backends) {
            var cleanup = new FutureTask<Void>(backend.adapter::close, null);
            cleanups.add(cleanup);
            Thread closer = new Thread(cleanup, "close-" + backend.name);
            closer.setDaemon(true);
            closer.start();
        }
        boolean failed = false;
        for (var cleanup : cleanups) {
            try {
                cleanup.get();
            } catch (ExecutionException failure) {
                failed = true;
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                throw new AgentException("BACKEND_CLEANUP_FAILED", "Interrupted while closing the backends.");
            }
        }
        if (failed) throw new AgentException("BACKEND_CLEANUP_FAILED", "A backend did not finish cleanup.");
    }

    private static String string(ObjectNode node, String field, int limit) {
        JsonNode value = node.path(field);
        if (!value.isTextual() || value.textValue().length() > limit
                || value.textValue().isBlank()) throw invalid("Invalid " + field + ".");
        return value.textValue();
    }

    private static int integer(ObjectNode node, String field, int fallback, int min, int max) {
        if (!node.has(field)) return fallback;
        JsonNode value = node.get(field);
        if (!value.isIntegralNumber() || !value.canConvertToInt() || value.intValue() < min || value.intValue() > max)
            throw invalid("Invalid " + field + ".");
        return value.intValue();
    }

    private static AgentException invalid(String message) {
        return new AgentException("INVALID_REQUEST", message);
    }
}
