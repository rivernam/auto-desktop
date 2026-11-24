package dev.desktop;

import java.util.List;

/**
 * What {@link JabSession} needs from Java Access Bridge and the window manager. A context handle is a
 * reference held inside the JVM. Each one that a call returns is released exactly once.
 */
abstract class JabApi implements AutoCloseable {
    abstract int pump();
    /** Waits on the bridge thread until a window message arrives, {@link #wake} is called or the time passes. */
    void await(int milliseconds) {
        try {
            Thread.sleep(Math.min(milliseconds, 5));
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
        }
    }
    /** Ends {@link #await} early. Callable from any thread. */
    void wake() {}
    /** A JVM that answered before still exists and does not handle bridge messages now. */
    abstract boolean anySilent();
    abstract long[] topLevelWindows(int limit);
    abstract boolean topLevel(long hwnd);
    abstract long ownerWindow(long hwnd);
    abstract boolean visible(long hwnd);
    abstract int processId(long hwnd);
    abstract int ownProcessId();
    abstract boolean javaWindowClass(long hwnd);
    abstract boolean javaWindow(long hwnd);
    /** Null when no connected JVM owns the window. The caller releases the context. */
    abstract JabBridge.Root root(long hwnd);
    abstract long windowOf(int vm, long context);
    /** The process that hosts the JVM, or 0 when the JVM is gone. */
    abstract int vmProcessId(int vm);
    abstract void release(int vm, long context);
    /** Releases a prefix of the list while the JVM answers and returns its length. */
    abstract int release(int vm, List<Long> contexts);
    abstract boolean same(int vm, long first, long second);
    /** Null when the bridge could not read the context. */
    abstract JabBridge.ContextInfo info(int vm, long context);
    /** 0 when the bridge delivered no child. The caller releases the context. */
    abstract long child(int vm, long context, int index);
    /** 0 when the object has no accessible parent. The caller releases the context. */
    abstract long parent(int vm, long context);
    abstract List<String> actions(int vm, long context);
    abstract boolean act(int vm, long context, String action, Runnable beforeMutation);
    abstract boolean setText(int vm, long context, String value, Runnable beforeMutation);
    @Override public abstract void close();
}
