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
    private static final class Session implements TypedDesktopAdapter {
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
                    assertEquals("ACTION_OUTCOME_UNKNOWN", failure.code());
                });
                assertEquals(0, entered.getCount());
                assertFalse(adapter.capabilities().path("available").asBoolean());
            } finally { unblock.countDown(); }
            await(session.get().closed);
            assertEquals(0, session.get().mutations.get());
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

    @Test void nativeLoadFailureProducesUnavailableCapabilities() {
        try (var adapter = new JnaDesktopAdapter(() -> { throw new UnsatisfiedLinkError(); }, Duration.ofSeconds(2))) {
            assertFalse(adapter.capabilities().path("available").asBoolean());
            assertEquals("BACKEND_UNAVAILABLE", assertThrows(AgentException.class, adapter::listWindows).code());
        }
    }
}
