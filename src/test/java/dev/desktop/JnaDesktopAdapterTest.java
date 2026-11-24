package dev.desktop;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import java.time.Duration;
import java.util.Collections;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicReference;
import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class JnaDesktopAdapterTest {
    private static class Session implements TypedDesktopAdapter {
        final Set<Thread> threads = Collections.synchronizedSet(new HashSet<>());
        final CountDownLatch closed = new CountDownLatch(1);
        final AtomicInteger mutations = new AtomicInteger();
        Runnable duringMutation = () -> {};

        Session() { record(); }
        private JsonNode record() {
            threads.add(Thread.currentThread());
            return JsonNodeFactory.instance.objectNode().put("available", true);
        }

        @Override public JsonNode capabilities() { return record(); }
        @Override public JsonNode listWindows() { return record(); }
        @Override public JsonNode snapshot(String id, int depth, int limit) { return record(); }
        @Override public JsonNode elementInfo(String key, int processId) { return record(); }
        @Override public JsonNode perform(DesktopAction action, String key, int pid, String value) {
            mutations.incrementAndGet();
            duringMutation.run();
            return record();
        }
        @Override public void close() { record(); closed.countDown(); }
    }

    private static void await(CountDownLatch latch) {
        try {
            assertTrue(latch.await(5, TimeUnit.SECONDS));
        } catch (InterruptedException e) {
            throw new AssertionError(e);
        }
    }

    @Test void constructsUsesAndReleasesSessionOnOneDedicatedThread() {
        var session = new AtomicReference<Session>();
        try (var adapter = new JnaDesktopAdapter(() -> {
            Session created = new Session();
            session.set(created);
            return created;
        }, Duration.ofSeconds(2))) {
            assertNull(session.get());
            assertTrue(adapter.capabilities().path("available").asBoolean());
            adapter.listWindows();
            adapter.snapshot("1", 2, 5);
            adapter.elementInfo("k", 7);
            adapter.perform(DesktopAction.SET_VALUE, "k", 7, "x");
        }
        assertEquals(0, session.get().closed.getCount());
        assertEquals(1, session.get().threads.size());
        assertFalse(session.get().threads.contains(Thread.currentThread()));
    }

    @Test void timedOutInitializationCannotDispatchAnActionAfterRecovery() {
        var entered = new CountDownLatch(1);
        var unblock = new CountDownLatch(1);
        var session = new AtomicReference<Session>();
        try (var adapter = new JnaDesktopAdapter(() -> {
            Session created = new Session();
            session.set(created);
            entered.countDown();
            await(unblock);
            return created;
        }, Duration.ofMillis(250))) {
            try {
                assertTimeoutPreemptively(Duration.ofSeconds(3), () -> {
                    var failure = assertThrows(AgentException.class,
                            () -> adapter.perform(DesktopAction.INVOKE, "k", 7, null));
                    assertEquals("TIMEOUT", failure.code());
                });
                assertEquals(0, entered.getCount());
                assertFalse(adapter.capabilities().path("available").asBoolean());
            } finally { unblock.countDown(); }
            await(session.get().closed);
            assertEquals(0, session.get().mutations.get());
        }
    }

    @Test void failedNativeCleanupIsReportedByTheOwner() {
        var adapter = new JnaDesktopAdapter(() -> new Session() {
            @Override public void close() { throw new AssertionError("unsafe provider detail"); }
        }, Duration.ofSeconds(1));
        adapter.capabilities();
        assertEquals("BACKEND_CLEANUP_FAILED", assertThrows(AgentException.class, adapter::close).code());
    }

    @Test void aRequestThatExpiresBehindIdleComCleanupRetiresTheOwner() {
        var entered = new CountDownLatch(1);
        var release = new CountDownLatch(1);
        class IdleSession extends Session implements NativeSession {
            @Override public void idle() {
                entered.countDown();
                await(release);
            }
            @Override public JsonNode perform(DesktopAction action, String key, int pid, String value,
                                              Runnable beforeMutation) {
                throw new AssertionError("idle cleanup must never send an action");
            }
        }
        try (var adapter = new JnaDesktopAdapter(IdleSession::new, Duration.ofMillis(250), "MSAA", "MSAA", 10)) {
            assertTrue(adapter.capabilities().path("available").asBoolean());
            try {
                await(entered);
                assertEquals("TIMEOUT", assertThrows(AgentException.class, adapter::listWindows).code());
                assertTrue(adapter.retired(), "A queued request cannot recover an owner stuck releasing native objects.");
            } finally { release.countDown(); }
        }
    }

    @Test void aLateProviderErrorCannotBeatTheQueryDeadline() throws Exception {
        var entered = new CountDownLatch(1);
        var release = new CountDownLatch(1);
        try (var adapter = new JnaDesktopAdapter(() -> new Session() {
            @Override public JsonNode listWindows() {
                entered.countDown();
                await(release);
                throw new AgentException("TARGET_NOT_RESPONDING", "Provider replied late.");
            }
        }, Duration.ofSeconds(2))) {
            long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(250);
            var query = adapter.startQuery(true, deadline);
            try {
                await(entered);
                while (System.nanoTime() - deadline <= 0) Thread.sleep(5);
            } finally {
                release.countDown();
            }
            // A multi-backend caller may still be collecting another backend's reply.
            Thread.sleep(100);
            assertEquals("TIMEOUT", assertThrows(AgentException.class, query::get).code());
        }
    }

    @Test void closingTheAdapterDoesNotDiscardAnInTimeMutationReply() throws Exception {
        var entered = new CountDownLatch(1);
        var release = new CountDownLatch(1);
        try (var adapter = new JnaDesktopAdapter(() -> {
            Session created = new Session();
            created.duringMutation = () -> {
                entered.countDown();
                await(release);
            };
            return created;
        }, Duration.ofSeconds(2))) {
            var action = java.util.concurrent.CompletableFuture.supplyAsync(
                    () -> adapter.perform(DesktopAction.INVOKE, "k", 7, null));
            var owner = new Thread(adapter::close);
            try {
                await(entered);
                owner.start();
                long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(1);
                while (!adapter.retired() && System.nanoTime() - deadline < 0) Thread.sleep(5);
                assertTrue(adapter.retired());
            } finally {
                release.countDown();
                owner.join(2000);
            }
            assertTrue(action.get(2, TimeUnit.SECONDS).path("available").asBoolean());
        }
    }

    @Test void interruptRetiresSessionAndPreventsQueuedMutation() throws Exception {
        var entered = new CountDownLatch(1);
        var unblock = new CountDownLatch(1);
        var session = new AtomicReference<Session>();
        var interrupted = new AtomicReference<String>();
        var queued = new AtomicReference<String>();
        try (var adapter = new JnaDesktopAdapter(() -> {
            Session created = new Session();
            created.duringMutation = () -> { entered.countDown(); await(unblock); };
            session.set(created);
            return created;
        }, Duration.ofSeconds(3))) {
            Thread running = new Thread(() -> {
                try { adapter.perform(DesktopAction.INVOKE, "k", 7, null); }
                catch (AgentException e) { interrupted.set(e.code() + "/" + Thread.currentThread().isInterrupted()); }
            });
            Thread next = new Thread(() -> {
                try { adapter.perform(DesktopAction.INVOKE, "k", 7, null); }
                catch (AgentException e) { queued.set(e.code()); }
            });
            try {
                running.start();
                await(entered);
                next.start();
                long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
                while (next.getState() != Thread.State.TIMED_WAITING && System.nanoTime() < deadline) {
                    Thread.sleep(1);
                }
                assertEquals(Thread.State.TIMED_WAITING, next.getState());
                running.interrupt();
                running.join(2000);
                next.join(2000);
                assertEquals("ACTION_OUTCOME_UNKNOWN/true", interrupted.get());
                assertEquals("BACKEND_UNAVAILABLE", queued.get());
            } finally { unblock.countDown(); }
            await(session.get().closed);
            assertEquals(1, session.get().mutations.get());
            assertEquals(1, session.get().threads.size());
        }
    }

    @Test void providerTimeoutRetiresSessionAndDoesNotRetryMutation() {
        try (var adapter = new JnaDesktopAdapter(() -> {
            Session created = new Session();
            created.duringMutation = () -> { throw new AgentException("TIMEOUT", "Provider timed out."); };
            return created;
        }, Duration.ofSeconds(2))) {
            var failure = assertThrows(AgentException.class, () -> adapter.perform(DesktopAction.INVOKE, "k", 7, null));
            assertEquals("ACTION_OUTCOME_UNKNOWN", failure.code());
            assertFalse(adapter.capabilities().path("available").asBoolean());
        }
    }

    @Test void interruptingQueuedCallerDoesNotRetireRunningApartment() throws Exception {
        var entered = new CountDownLatch(1);
        var unblock = new CountDownLatch(1);
        var state = new AtomicReference<Session>();
        var firstResult = new AtomicReference<JsonNode>();
        var queuedResult = new AtomicReference<String>();
        try (var adapter = new JnaDesktopAdapter(() -> {
            Session created = new Session();
            created.duringMutation = () -> { entered.countDown(); await(unblock); };
            state.set(created);
            return created;
        }, Duration.ofSeconds(5))) {
            Thread running = new Thread(() -> firstResult.set(adapter.perform(DesktopAction.INVOKE, "k", 7, null)));
            Thread queued = new Thread(() -> {
                try { adapter.perform(DesktopAction.INVOKE, "k", 7, null); }
                catch (AgentException e) { queuedResult.set(e.code() + "/" + Thread.currentThread().isInterrupted()); }
            });
            try {
                running.start();
                await(entered);
                queued.start();
                long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(2);
                while (queued.getState() != Thread.State.TIMED_WAITING && System.nanoTime() < deadline) {
                    Thread.sleep(1);
                }
                assertEquals(Thread.State.TIMED_WAITING, queued.getState());
                queued.interrupt();
                queued.join(2000);
                assertEquals("BACKEND_UNAVAILABLE/true", queuedResult.get());
            } finally {
                unblock.countDown();
                running.join(2000);
            }
            assertNotNull(firstResult.get());
            assertTrue(adapter.capabilities().path("available").asBoolean());
            assertEquals(1, state.get().mutations.get());
        }
    }

    @Test void nativeCallSurvivesCallerTimeoutButSessionNeverDispatchesAgain() {
        var entered = new CountDownLatch(1);
        var unblock = new CountDownLatch(1);
        var state = new AtomicReference<Session>();
        try (var adapter = new JnaDesktopAdapter(() -> {
            Session created = new Session();
            created.duringMutation = () -> { entered.countDown(); await(unblock); };
            state.set(created);
            return created;
        }, Duration.ofMillis(500))) {
            try {
                assertEquals("ACTION_OUTCOME_UNKNOWN", assertThrows(AgentException.class,
                        () -> adapter.perform(DesktopAction.INVOKE, "k", 7, null)).code());
                assertEquals(0, entered.getCount());
                assertEquals(1, state.get().closed.getCount());
                assertFalse(adapter.capabilities().path("available").asBoolean());
                assertEquals(1, state.get().mutations.get());
            } finally { unblock.countDown(); }
            await(state.get().closed);
            assertEquals(1, state.get().threads.size());
        }
    }

    @Test void closeAllowsTimeForRetiredApartmentToReleaseReferences() throws Exception {
        var unblock = new CountDownLatch(1);
        var state = new AtomicReference<Session>();
        try (var adapter = new JnaDesktopAdapter(() -> {
            Session created = new Session();
            created.duringMutation = () -> await(unblock);
            state.set(created);
            return created;
        }, Duration.ofMillis(800))) {
            Thread close = new Thread(adapter::close);
            try {
                assertEquals("ACTION_OUTCOME_UNKNOWN", assertThrows(AgentException.class,
                        () -> adapter.perform(DesktopAction.INVOKE, "k", 7, null)).code());
                close.start();
                long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(500);
                while (close.isAlive() && close.getState() != Thread.State.TIMED_WAITING && System.nanoTime() < deadline) {
                    Thread.sleep(1);
                }
                assertEquals(Thread.State.TIMED_WAITING, close.getState(), "EOF should allow the MTA to clean up.");
            } finally {
                unblock.countDown();
                close.join(2000);
            }
            assertEquals(0, state.get().closed.getCount());
            assertEquals(1, state.get().threads.size());
        }
    }

    @Test void nativeLoadFailureProducesUnavailableCapabilities() {
        try (var adapter = new JnaDesktopAdapter(() -> { throw new UnsatisfiedLinkError(); }, Duration.ofSeconds(2))) {
            assertFalse(adapter.capabilities().path("available").asBoolean());
            assertEquals("BACKEND_UNAVAILABLE", assertThrows(AgentException.class, adapter::listWindows).code());
        }
    }

    @Test void aSessionWithWindowsServesThemWhileAnotherBackendWorks() throws Exception {
        var entered = new java.util.concurrent.Semaphore(0);
        var left = new java.util.concurrent.Semaphore(0);
        var signal = new java.util.concurrent.Semaphore(0);
        var threads = Collections.synchronizedSet(new HashSet<Thread>());
        NativeSession windowed = new NativeSession() {
            private JsonNode reply() {
                threads.add(Thread.currentThread());
                return JsonNodeFactory.instance.objectNode().put("available", true);
            }
            @Override public JsonNode capabilities() { return reply(); }
            @Override public JsonNode listWindows() { return reply(); }
            @Override public JsonNode snapshot(String id, int depth, int limit) { return reply(); }
            @Override public JsonNode elementInfo(String key, int processId) { return reply(); }
            @Override public JsonNode perform(DesktopAction action, String key, int pid, String value, Runnable before) {
                before.run();
                return reply();
            }
            @Override public void serve(java.util.function.BooleanSupplier done) {
                threads.add(Thread.currentThread());
                entered.release();
                try {
                    // Like a message wait: it ends on a wake-up, and otherwise only after a long time.
                    while (!done.getAsBoolean()) signal.tryAcquire(30, TimeUnit.SECONDS);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                } finally {
                    left.release();
                }
            }
            @Override public void wake() { signal.release(); }
            @Override public void close() {}
        };
        try (var adapter = new JnaDesktopAdapter(() -> windowed, Duration.ofSeconds(5), "JAB", "Java Access Bridge", 60_000)) {
            adapter.capabilities();
            adapter.attend(true);
            assertTrue(entered.tryAcquire(2, TimeUnit.SECONDS), "The session thread serves its windows.");
            // A request for this adapter is not held up by the service of its own windows.
            long started = System.nanoTime();
            adapter.listWindows();
            assertTrue(System.nanoTime() - started < TimeUnit.SECONDS.toNanos(2));
            assertTrue(left.tryAcquire(2, TimeUnit.SECONDS));
            adapter.attend(false);

            adapter.attend(true);
            assertTrue(entered.tryAcquire(2, TimeUnit.SECONDS));
            adapter.attend(false);
            assertTrue(left.tryAcquire(2, TimeUnit.SECONDS), "The service ends when the other backend is done.");
            adapter.snapshot("1", 2, 5);
        }
        assertEquals(1, threads.size(), "Requests and window service share the session thread.");
    }

    @Test void anAdapterWithoutWindowsIsNeverAskedToServe() {
        var session = new AtomicReference<Session>();
        try (var adapter = new JnaDesktopAdapter(() -> {
            session.set(new Session());
            return session.get();
        }, Duration.ofSeconds(2))) {
            adapter.attend(true);
            adapter.attend(false);
            assertNull(session.get(), "Attention alone starts no session.");
            adapter.listWindows();
        }
        assertEquals(1, session.get().threads.size());
    }
}
