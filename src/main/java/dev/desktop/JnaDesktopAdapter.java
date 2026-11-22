package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Locale;
import java.util.Objects;
import java.util.concurrent.CancellationException;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Future;
import java.util.concurrent.LinkedBlockingQueue;
import java.util.concurrent.ThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.BiFunction;
import java.util.function.Function;
import java.util.function.Supplier;

/** One thread owns the in-process UIA session and its entire COM apartment lifetime. */
public final class JnaDesktopAdapter implements TypedDesktopAdapter {
    private final Supplier<? extends TypedDesktopAdapter> factory;
    private final boolean windows;
    private final long timeoutNanos;
    private final ThreadPoolExecutor apartment;
    private volatile Thread apartmentThread;
    // Only the apartment thread may touch the native session.
    private TypedDesktopAdapter session;
    // Guarded by this. Native operations and waiting for results never hold the monitor.
    private boolean retired;

    private static final class Request {
        // Guarded by the adapter monitor, including the claim by the apartment thread.
        boolean started;
        boolean cancelled;
    }

    public JnaDesktopAdapter() {
        this(JnaUiaSession::new, Duration.ofSeconds(10),
                System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("windows"));
    }

    JnaDesktopAdapter(Supplier<? extends TypedDesktopAdapter> factory, Duration timeout) {
        this(factory, timeout, true);
    }

    private JnaDesktopAdapter(Supplier<? extends TypedDesktopAdapter> factory, Duration timeout, boolean windows) {
        this.factory = Objects.requireNonNull(factory);
        timeoutNanos = timeout.toNanos();
        if (timeoutNanos <= 0) throw new IllegalArgumentException("A positive timeout is required.");
        this.windows = windows;
        apartment = new ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, new LinkedBlockingQueue<>(), task -> {
            Thread thread = new Thread(task, "jna-uia-mta");
            thread.setDaemon(true);
            apartmentThread = thread;
            return thread;
        });
    }

    @Override public JsonNode capabilities() {
        try {
            return dispatch(TypedDesktopAdapter::capabilities);
        } catch (AgentException e) {
            if (!"BACKEND_UNAVAILABLE".equals(e.code())) throw e;
            return DesktopCapabilities.unavailable("UIA", e.getMessage());
        }
    }

    @Override public JsonNode listWindows() {
        return dispatch(TypedDesktopAdapter::listWindows);
    }

    @Override public JsonNode snapshot(String windowId, int maxDepth, int maxElements) {
        return dispatch(nativeSession -> nativeSession.snapshot(windowId, maxDepth, maxElements));
    }

    @Override public JsonNode snapshotSubtree(String windowId, String key, int processId, int maxDepth, int maxElements) {
        return dispatch(nativeSession -> nativeSession.snapshotSubtree(windowId, key, processId, maxDepth, maxElements));
    }

    @Override public JsonNode elementInfo(String key, int processId) {
        return dispatch(nativeSession -> nativeSession.elementInfo(key, processId));
    }

    @Override public JsonNode perform(DesktopAction action, String key, int processId, String value) {
        return dispatch((nativeSession, beforeMutation) -> {
            if (nativeSession instanceof JnaUiaSession jna) {
                return jna.perform(action, key, processId, value, beforeMutation);
            }
            beforeMutation.run();
            return nativeSession.perform(action, key, processId, value);
        }, true);
    }

    private JsonNode dispatch(Function<TypedDesktopAdapter, JsonNode> operation) {
        return dispatch((nativeSession, beforeMutation) -> operation.apply(nativeSession), false);
    }

    private JsonNode dispatch(BiFunction<TypedDesktopAdapter, Runnable, JsonNode> operation, boolean mutation) {
        long deadline = System.nanoTime() + timeoutNanos;
        Request request = new Request();
        Future<JsonNode> reply;
        synchronized (this) {
            checkOpen();
            if (Thread.currentThread().isInterrupted()) throw lost(false, false);
            reply = apartment.submit(() -> {
                claim(request, deadline);
                if (session == null) {
                    try {
                        session = Objects.requireNonNull(factory.get());
                    } catch (RuntimeException | LinkageError e) {
                        retire();
                        throw unavailable("Could not initialize Windows UI Automation through JNA.");
                    }
                }
                // Initialization or an earlier native call may have consumed the budget.
                checkReady(deadline, mutation);
                try {
                    // Preflight may itself enter COM. Recheck just before Invoke/SetValue.
                    return operation.apply(session, () -> checkReady(deadline, mutation));
                } catch (AgentException reported) {
                    if (!"TIMEOUT".equals(reported.code())) throw reported;
                    retire();
                    throw lost(mutation, true);
                } catch (RuntimeException | LinkageError e) {
                    retire();
                    throw lost(mutation, false);
                }
            });
        }
        try {
            return reply.get(deadline - System.nanoTime(), TimeUnit.NANOSECONDS);
        } catch (TimeoutException e) {
            throw stopWaiting(request, reply, mutation, true);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw stopWaiting(request, reply, mutation, false);
        } catch (CancellationException e) {
            // Only work removed from the queue is cancelled.
            throw unavailable("The JNA desktop session closed before dispatch.");
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof AgentException reported) throw reported;
            retire();
            throw lost(mutation, false);
        }
    }

    private synchronized void claim(Request request, long deadline) {
        checkOpen();
        if (request.cancelled) throw lost(false, false);
        if (deadline - System.nanoTime() <= 0) throw lost(false, true);
        request.started = true;
    }

    private synchronized AgentException stopWaiting(Request request, Future<?> reply,
                                                    boolean mutation, boolean timedOut) {
        if (request.started) {
            retire();
            return lost(mutation, timedOut);
        }
        // The request has not reached initialization or COM. Cancelling it need not retire
        // the unrelated request currently on the apartment thread.
        request.cancelled = true;
        reply.cancel(false);
        apartment.remove((Runnable) reply);
        return lost(false, timedOut);
    }

    private void checkOpen() {
        if (!windows) throw unavailable("Windows UI Automation requires Windows.");
        if (retired) throw unavailable("The JNA desktop session is closed.");
    }

    private synchronized void checkReady(long deadline, boolean mutation) {
        checkOpen();
        if (deadline - System.nanoTime() <= 0) {
            retire();
            throw lost(mutation, true);
        }
    }

    private static AgentException unavailable(String message) {
        return new AgentException("BACKEND_UNAVAILABLE", message);
    }

    private static AgentException lost(boolean mutation, boolean timedOut) {
        if (mutation) return new AgentException("ACTION_OUTCOME_UNKNOWN",
                "The native action was not confirmed. Inspect the target before retrying.");
        return timedOut ? new AgentException("TIMEOUT", "The native UI Automation call timed out.")
                : unavailable("The native UI Automation call did not finish.");
    }

    private synchronized void retire() {
        if (retired) return;
        retired = true;
        var queued = new ArrayList<Runnable>();
        apartment.getQueue().drainTo(queued);
        for (Runnable item : queued) ((Future<?>) item).cancel(false);
        if (apartment.getPoolSize() > 0) {
            // Release COM pointers on their owning apartment once an in-flight call returns.
            apartment.submit(() -> {
                if (session != null) {
                    try { session.close(); }
                    finally { session = null; }
                }
            });
        }
        apartment.shutdown();
    }

    @Override public void close() {
        retire();
        if (Thread.currentThread() == apartmentThread) return;
        try {
            // EOF may follow a timeout. Give returning COM calls a bounded cleanup window.
            apartment.awaitTermination(timeoutNanos, TimeUnit.NANOSECONDS);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
