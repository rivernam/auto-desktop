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

/**
 * One thread owns an in-process provider session for its entire lifetime: the COM apartment of
 * UI Automation, or the message window of Java Access Bridge.
 */
public final class JnaDesktopAdapter implements TypedDesktopAdapter {
    static final Duration REQUEST_BUDGET = Duration.ofSeconds(10);
    // Normal process shutdown is unsafe with an abandoned owner thread or uncertain JAB cleanup.
    private static volatile boolean nativeExitRequired;
    private final Supplier<? extends TypedDesktopAdapter> factory;
    private final boolean windows;
    private final String backend;
    private final String provider;
    private final long idleMillis;
    private final long timeoutNanos;
    private final ThreadPoolExecutor apartment;
    private volatile Thread apartmentThread;
    // Only the apartment thread may touch the native session.
    private TypedDesktopAdapter session;
    // Guarded by this. Native operations and waiting for results never hold the monitor.
    private boolean retired;
    // Guarded by this. Why the session never started, repeated to later requests.
    private String startFailure;
    // Guarded by this. Set by close(), which ends the adapter for good.
    private boolean closed;
    private volatile boolean cleanupFailure;
    // True while another backend of the same session runs a request.
    private volatile boolean attending;
    // The session once it exists, for the one call that any thread may make on it.
    private volatile NativeSession waker;

    private static final class Request {
        // Guarded by the adapter monitor, including the claim by the apartment thread.
        boolean started;
        boolean cancelled;
        volatile boolean dispatched;
    }

    public JnaDesktopAdapter() {
        this(JnaUiaSession::new, REQUEST_BUDGET, onWindows(), "UIA", "Windows UI Automation", 0);
    }

    /** Java Access Bridge needs its window messages delivered between requests as well. */
    static JnaDesktopAdapter javaAccessBridge() {
        return new JnaDesktopAdapter(JabSession::new, REQUEST_BUDGET, onWindows(), "JAB",
                "Java Access Bridge", 250);
    }

    JnaDesktopAdapter(Supplier<? extends TypedDesktopAdapter> factory, Duration timeout) {
        this(factory, timeout, true, "UIA", "Windows UI Automation", 0);
    }

    JnaDesktopAdapter(Supplier<? extends TypedDesktopAdapter> factory, Duration timeout, String backend,
                      String provider, long idleMillis) {
        this(factory, timeout, true, backend, provider, idleMillis);
    }

    private static boolean onWindows() {
        return System.getProperty("os.name", "").toLowerCase(Locale.ROOT).startsWith("windows");
    }

    static boolean nativeExitRequired() { return nativeExitRequired; }

    private JnaDesktopAdapter(Supplier<? extends TypedDesktopAdapter> factory, Duration timeout, boolean windows,
                              String backend, String provider, long idleMillis) {
        this.factory = Objects.requireNonNull(factory);
        this.backend = backend;
        this.provider = provider;
        this.idleMillis = idleMillis;
        timeoutNanos = timeout.toNanos();
        if (timeoutNanos <= 0) throw new IllegalArgumentException("A positive timeout is required.");
        this.windows = windows;
        apartment = new ThreadPoolExecutor(1, 1, 0, TimeUnit.MILLISECONDS, new LinkedBlockingQueue<>(), task -> {
            Thread thread = new Thread(task, "jna-" + backend.toLowerCase(Locale.ROOT) + "-session");
            thread.setDaemon(true);
            apartmentThread = thread;
            return thread;
        });
        if (idleMillis > 0 && windows) startIdleTicks();
    }

    /** Lets an idle session run its housekeeping on its own thread. Stops with the session. */
    private void startIdleTicks() {
        Thread ticker = new Thread(() -> {
            try {
                while (true) {
                    Thread.sleep(idleMillis);
                    synchronized (this) {
                        if (retired) return;
                        if (waker == null || apartment.getActiveCount() > 0 || !apartment.getQueue().isEmpty())
                            continue;
                        apartment.submit(() -> {
                            if (session instanceof NativeSession idle) idle.idle();
                        });
                    }
                }
            } catch (InterruptedException | RuntimeException stopped) {
                // The session retired or its thread is gone.
            }
        }, "jna-" + backend.toLowerCase(Locale.ROOT) + "-idle");
        ticker.setDaemon(true);
        ticker.start();
    }

    /**
     * While on, the session thread answers the messages of the provider's own windows as they
     * arrive. A request for this adapter ends that at once.
     */
    @Override public void attend(boolean on) {
        if (idleMillis <= 0 || !windows) return;
        synchronized (this) {
            attending = on;
            if (retired) return;
            if (on) {
                apartment.submit(() -> {
                    if (session instanceof NativeSession serving)
                        serving.serve(() -> !attending || !apartment.getQueue().isEmpty());
                });
                return;
            }
        }
        wake();
    }

    private void wake() {
        NativeSession target = waker;
        if (target != null) target.wake();
    }

    @Override public JsonNode capabilities() {
        try {
            return dispatch(TypedDesktopAdapter::capabilities);
        } catch (AgentException e) {
            if (!"BACKEND_UNAVAILABLE".equals(e.code())) throw e;
            return DesktopCapabilities.unavailable(backend, e.getMessage());
        }
    }

    @Override public JsonNode listWindows() {
        return dispatch(TypedDesktopAdapter::listWindows);
    }

    @Override public Supplier<JsonNode> startQuery(boolean windows, long deadline) {
        long now = System.nanoTime();
        long remaining = Math.min(deadline - now, timeoutNanos);
        if (remaining <= 0) return () -> { throw lost(false, true); };
        try {
            return submit((nativeSession, beforeMutation) -> windows
                    ? nativeSession.listWindows() : nativeSession.capabilities(),
                    now + remaining);
        } catch (AgentException unavailable) {
            return () -> { throw unavailable; };
        }
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
        return perform(action, key, processId, value, () -> {});
    }

    @Override public JsonNode perform(DesktopAction action, String key, int processId, String value, Runnable validate) {
        return dispatch((nativeSession, beforeMutation) -> {
            Runnable validatedDispatch = () -> {
                validate.run();
                beforeMutation.run();
            };
            if (nativeSession instanceof NativeSession aware) {
                return aware.perform(action, key, processId, value, validatedDispatch);
            }
            validatedDispatch.run();
            return nativeSession.perform(action, key, processId, value);
        });
    }

    private JsonNode dispatch(Function<TypedDesktopAdapter, JsonNode> operation) {
        return dispatch((nativeSession, beforeMutation) -> operation.apply(nativeSession));
    }

    private JsonNode dispatch(BiFunction<TypedDesktopAdapter, Runnable, JsonNode> operation) {
        return submit(operation, System.nanoTime() + timeoutNanos).get();
    }

    private Supplier<JsonNode> submit(BiFunction<TypedDesktopAdapter, Runnable, JsonNode> operation,
                                      long deadline) {
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
                    } catch (AgentException reported) {
                        // The provider explained why it cannot start, for example a missing library.
                        if ("BACKEND_UNAVAILABLE".equals(reported.code())) startFailure(reported.getMessage());
                        checkDeadline(deadline, request);
                        retire();
                        throw reported;
                    } catch (RuntimeException | LinkageError e) {
                        String reason = "Could not initialize " + provider + " through JNA.";
                        startFailure(reason);
                        checkDeadline(deadline, request);
                        retire();
                        throw unavailable(reason);
                    }
                    if (session instanceof NativeSession created) waker = created;
                }
                // Initialization or an earlier native call may have consumed the budget.
                checkReady(deadline, request);
                try {
                    // Preflight may itself enter COM. Recheck just before Invoke/SetValue.
                    JsonNode result = operation.apply(session, () -> beginMutation(deadline, request));
                    checkDeadline(deadline, request);
                    return result;
                } catch (AgentException reported) {
                    if (!"TIMEOUT".equals(reported.code())) {
                        checkDeadline(deadline, request);
                        throw reported;
                    }
                    retire();
                    throw lost(request.dispatched, true);
                } catch (RuntimeException | LinkageError e) {
                    boolean timedOut = deadline - System.nanoTime() <= 0;
                    retire();
                    throw lost(request.dispatched, timedOut);
                }
            });
        }
        // A session that is serving its windows for another backend turns to this request now.
        wake();
        return () -> await(request, reply, deadline);
    }

    private JsonNode await(Request request, Future<JsonNode> reply, long deadline) {
        try {
            return reply.get(deadline - System.nanoTime(), TimeUnit.NANOSECONDS);
        } catch (TimeoutException e) {
            throw stopWaiting(request, reply, true);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw stopWaiting(request, reply, false);
        } catch (CancellationException e) {
            // Only work removed from the queue is cancelled.
            throw unavailable("The JNA desktop session closed before dispatch.");
        } catch (ExecutionException e) {
            Throwable cause = e.getCause();
            if (cause instanceof AgentException reported) throw reported;
            retire();
            throw lost(request.dispatched, false);
        }
    }

    private synchronized void claim(Request request, long deadline) {
        checkOpen();
        if (request.cancelled) throw lost(false, false);
        if (deadline - System.nanoTime() <= 0) throw lost(false, true);
        request.started = true;
    }

    private synchronized AgentException stopWaiting(Request request, Future<?> reply, boolean timedOut) {
        if (request.started) {
            retire();
            return lost(request.dispatched, timedOut);
        }
        // The request has not reached initialization or COM. Cancelling it need not retire
        // the unrelated request currently on the apartment thread.
        request.cancelled = true;
        reply.cancel(false);
        apartment.remove((Runnable) reply);
        return lost(false, timedOut);
    }

    private void checkOpen() {
        if (!windows) throw unavailable(provider + " requires Windows.");
        if (retired) throw unavailable(startFailure != null ? startFailure : "The JNA desktop session is closed.");
    }

    private synchronized void beginMutation(long deadline, Request request) {
        checkReady(deadline, request);
        request.dispatched = true;
    }

    private synchronized void checkReady(long deadline, Request request) {
        checkOpen();
        checkDeadline(deadline, request);
    }

    private synchronized void checkDeadline(long deadline, Request request) {
        if (deadline - System.nanoTime() <= 0) {
            retire();
            throw lost(request.dispatched, true);
        }
    }

    private static AgentException unavailable(String message) {
        return new AgentException("BACKEND_UNAVAILABLE", message);
    }

    private synchronized void startFailure(String reason) { startFailure = reason; }

    private AgentException lost(boolean mutation, boolean timedOut) {
        if (mutation) return new AgentException("ACTION_OUTCOME_UNKNOWN",
                "The native action was not confirmed. Inspect the target before retrying.");
        String name = backend.equals("UIA") ? "UI Automation" : provider;
        return timedOut ? new AgentException("TIMEOUT", "The native " + name + " call timed out.")
                : unavailable("The native " + name + " call did not finish.");
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
                waker = null;
                if (session != null) {
                    boolean completed = false;
                    try {
                        session.close();
                        completed = true;
                    } finally {
                        if (!completed) {
                            cleanupFailure = true;
                            if ("JAB".equals(backend)) nativeExitRequired = true;
                        }
                        session = null;
                    }
                }
            });
        }
        apartment.shutdown();
        wake();
    }

    /** A provider that cannot start is not retried. Its reason stays in the capabilities. */
    @Override public synchronized boolean finished() {
        return retired && !closed && startFailure == null && !cleanupFailure && apartment.isTerminated();
    }

    @Override public synchronized boolean retired() {
        return retired;
    }

    @Override public void close() {
        synchronized (this) { closed = true; }
        retire();
        if (Thread.currentThread() == apartmentThread) return;
        try {
            // EOF may follow a timeout. Give returning COM calls a bounded cleanup window.
            boolean finished = apartment.awaitTermination(timeoutNanos, TimeUnit.NANOSECONDS);
            if (!finished) {
                nativeExitRequired = true;
                throw cleanupFailed();
            }
            if (cleanupFailure) throw cleanupFailed();
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            if (!apartment.isTerminated()) nativeExitRequired = true;
            throw cleanupFailed();
        }
    }

    private AgentException cleanupFailed() {
        return new AgentException("BACKEND_CLEANUP_FAILED", "The " + backend + " worker did not clean up.");
    }
}
