package dev.desktop;

import com.fasterxml.jackson.databind.node.JsonNodeFactory;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sun.jna.Function;
import com.sun.jna.Memory;
import com.sun.jna.Native;
import com.sun.jna.Pointer;
import com.sun.jna.platform.win32.BaseTSD.ULONG_PTR;
import com.sun.jna.platform.win32.Kernel32;
import com.sun.jna.platform.win32.User32;
import com.sun.jna.platform.win32.WinDef.DWORD;
import com.sun.jna.platform.win32.WinDef.HWND;
import com.sun.jna.platform.win32.WinDef.LONG;
import com.sun.jna.platform.win32.WinDef.LPARAM;
import com.sun.jna.platform.win32.WinDef.LRESULT;
import com.sun.jna.platform.win32.WinDef.POINT;
import com.sun.jna.platform.win32.WinDef.RECT;
import com.sun.jna.platform.win32.WinDef.WORD;
import com.sun.jna.platform.win32.WinDef.WPARAM;
import com.sun.jna.platform.win32.WinNT.HANDLE;
import com.sun.jna.platform.win32.WinNT.HANDLEByReference;
import com.sun.jna.platform.win32.WinUser;
import com.sun.jna.ptr.IntByReference;
import com.sun.jna.win32.StdCallLibrary;
import java.security.SecureRandom;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Set;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicLong;

/**
 * SendInput on a dedicated per-monitor DPI aware thread. Every check runs on that thread right
 * before the events it guards. Events carry a session tag so that a low-level hook can tell this
 * session's input from the user's.
 */
final class WindowsInputDriver implements InputDriver {
    interface Natives extends StdCallLibrary {
        Natives INSTANCE = Native.load("user32", Natives.class);
        HWND WindowFromPoint(POINT.ByValue point);
        boolean IsIconic(HWND window);
        boolean ClientToScreen(HWND window, POINT point);
        HANDLE OpenInputDesktop(int flags, boolean inherit, int access);
        HANDLE GetThreadDesktop(int threadId);
        boolean GetUserObjectInformationW(HANDLE object, int index, char[] buffer, int length, IntByReference needed);
        boolean CloseDesktop(HANDLE desktop);
        int MapVirtualKeyW(int code, int mapType);
    }

    interface Security extends StdCallLibrary {
        Security INSTANCE = Native.load("advapi32", Security.class);
        boolean OpenProcessToken(HANDLE process, int access, HANDLEByReference token);
        boolean GetTokenInformation(HANDLE token, int infoClass, Pointer buffer, int length, IntByReference needed);
        Pointer GetSidSubAuthorityCount(Pointer sid);
        Pointer GetSidSubAuthority(Pointer sid, int index);
    }

    private static final int INPUT_MOUSE = 0;
    private static final int INPUT_KEYBOARD = 1;
    private static final int MOVE = 0x0001;
    private static final int LEFT_DOWN = 0x0002;
    private static final int LEFT_UP = 0x0004;
    private static final int RIGHT_DOWN = 0x0008;
    private static final int RIGHT_UP = 0x0010;
    private static final int MIDDLE_DOWN = 0x0020;
    private static final int MIDDLE_UP = 0x0040;
    private static final int WHEEL = 0x0800;
    private static final int HWHEEL = 0x1000;
    private static final int VIRTUALDESK = 0x4000;
    private static final int ABSOLUTE = 0x8000;
    private static final int KEY_EXTENDED = 0x0001;
    private static final int KEY_UP = 0x0002;
    private static final int KEY_UNICODE = 0x0004;
    private static final int KEY_SCAN_CODE = 0x0008;
    private static final int WHEEL_DELTA = 120;
    private static final int GA_ROOT = 2;
    private static final int GA_ROOTOWNER = 3;
    private static final int TOKEN_QUERY = 0x0008;
    private static final int TOKEN_INTEGRITY_LEVEL = 25;
    private static final int PROCESS_QUERY_LIMITED_INFORMATION = 0x1000;
    private static final int UOI_NAME = 2;
    private static final int DESKTOP_READOBJECTS = 0x0001;
    private static final int LLMHF_INJECTED = 0x01;
    private static final int LLKHF_INJECTED = 0x10;
    private static final int[] USER_HELD_KEYS = {0x01, 0x02, 0x04, 0x05, 0x06, 0x10, 0x11, 0x12, 0x5B, 0x5C};
    private static final long OBSERVE_MILLIS = 500;
    private static final long CURSOR_MILLIS = 200;
    private static final int RECOVERY_QUIET_MILLIS = 500;

    private final ExecutorService thread = Executors.newSingleThreadExecutor(task -> {
        Thread worker = new Thread(task, "desktop-input");
        worker.setDaemon(true);
        return worker;
    });
    private final SecureRandom tags = new SecureRandom();
    private long tag = nextTag();
    // Input thread only.
    private final Set<InputKeys.Key> held = new LinkedHashSet<>();
    private String dpiAwareness;
    private boolean layoutTypingAvailable;
    private int ownIntegrity = -1;
    private Monitor monitor;
    private boolean recoveryPending;
    private volatile boolean closed;
    private HookFault hookFault;

    WindowsInputDriver() { this(null); }

    WindowsInputDriver(HookFault hookFault) { this.hookFault = hookFault; }

    // Explicitly injected by the test-only launcher. The production CLI never selects a fault.
    enum HookFault { MOUSE_REMOVE, KEYBOARD_REMOVE, BOTH_REMOVE, MOUSE_PARTIAL, KEYBOARD_PARTIAL }

    private long nextTag() {
        // Positive and outside the pen/touch dwExtraInfo signature range.
        return 0x10000L + tags.nextInt(0x7FFE0000);
    }

    /** One request's cancellation state, shared between the waiting caller and the input thread. */
    private static final class Job {
        boolean cancelled;
        boolean dispatched;
    }

    @Override public ObjectNode describe() {
        return call(() -> {
            ObjectNode result = JsonNodeFactory.instance.objectNode();
            boolean desktop = inputDesktopMatches();
            boolean available = !"unaware".equals(dpiAwareness) && desktop;
            result.put("available", available);
            if (available) {
                var methods = result.putArray("textMethods").add(InputRequest.TextMethod.UNICODE.protocolName);
                if (layoutTypingAvailable) methods.add(InputRequest.TextMethod.VIRTUAL_KEY.protocolName)
                        .add(InputRequest.TextMethod.SCAN_CODE.protocolName).add(InputRequest.TextMethod.CLIPBOARD.protocolName);
            }
            if (!available) result.put("reason", desktop
                    ? "The input thread could not obtain per-monitor or system DPI awareness."
                    : "The input desktop is not this session's desktop.");
            int left = metric(76);
            int top = metric(77);
            result.put("dpiAwareness", dpiAwareness).put("integrity", integrityName(ownIntegrity))
                    .put("inputDesktop", desktop);
            result.putObject("virtualScreen").put("x", left).put("y", top)
                    .put("width", metric(78)).put("height", metric(79));
            result.put("monitors", metric(80)).put("buttonsSwapped", metric(23) != 0);
            return result;
        });
    }

    @Override public InputGeometry.Rect windowRect(long window, int processId) {
        return call(() -> {
            HWND handle = owned(window, processId);
            return rect(handle);
        });
    }

    @Override public InputGeometry.Rect clientRect(long window, int processId) {
        return call(() -> {
            HWND handle = owned(window, processId);
            RECT rect = new RECT();
            if (!User32.INSTANCE.GetClientRect(handle, rect)) return null;
            POINT from = new POINT(rect.left, rect.top);
            POINT to = new POINT(rect.right, rect.bottom);
            if (!Natives.INSTANCE.ClientToScreen(handle, from) || !Natives.INSTANCE.ClientToScreen(handle, to))
                return null;
            return new InputGeometry.Rect(from.x, from.y, to.x, to.y);
        });
    }

    @Override public ObjectNode execute(InputRequest request, Runnable gate, long deadline) {
        if (closed) throw InputException.refused("INPUT_UNAVAILABLE", "The input session has ended.");
        Job job = new Job();
        Future<ObjectNode> future = thread.submit(() -> new Operation(request, gate, job, deadline).run());
        try {
            long remaining = deadline - System.nanoTime();
            return future.get(Math.max(0, remaining), TimeUnit.NANOSECONDS);
        } catch (TimeoutException | InterruptedException late) {
            if (late instanceof InterruptedException) Thread.currentThread().interrupt();
            boolean sent;
            synchronized (job) {
                job.cancelled = true;
                sent = job.dispatched;
            }
            future.cancel(false);
            if (sent) throw new InputException("ACTION_OUTCOME_UNKNOWN",
                    "The input did not finish in time. Inspect the target before retrying.", true, false);
            throw InputException.refused("TIMEOUT", "The request expired before any input was sent.");
        } catch (ExecutionException failed) {
            Throwable cause = failed.getCause();
            if (cause instanceof AgentException) throw (AgentException) cause;
            boolean sent;
            synchronized (job) { sent = job.dispatched; }
            throw new InputException("INTERNAL_ERROR", "The input could not be completed.", sent, false);
        }
    }

    @Override public void close() {
        if (closed) return;
        closed = true;
        try {
            thread.submit(() -> {
                releaseHeld();
                if (monitor != null) monitor.stop();
                monitor = null;
            }).get(2, TimeUnit.SECONDS);
        } catch (ExecutionException | TimeoutException | InterruptedException ignored) {
            if (ignored instanceof InterruptedException) Thread.currentThread().interrupt();
        } finally {
            thread.shutdown();
        }
    }

    private interface Task<T> { T run(); }

    /** Runs a read on the input thread within a short budget. */
    private <T> T call(Task<T> task) {
        if (closed) throw InputException.refused("INPUT_UNAVAILABLE", "The input session has ended.");
        Future<T> future = thread.submit(() -> {
            prepareThread();
            return task.run();
        });
        try {
            return future.get(5, TimeUnit.SECONDS);
        } catch (TimeoutException | InterruptedException late) {
            if (late instanceof InterruptedException) Thread.currentThread().interrupt();
            future.cancel(false);
            throw InputException.refused("TIMEOUT", "The input thread did not answer in time.");
        } catch (ExecutionException failed) {
            if (failed.getCause() instanceof AgentException) throw (AgentException) failed.getCause();
            throw InputException.refused("INTERNAL_ERROR", "The input state could not be read.");
        }
    }

    // ---------------------------------------------------------------- thread state

    /**
     * Per-monitor v2 for this thread where Windows has it (10 1607+). Otherwise the process
     * awareness decides: the java launcher declares DPI awareness, and Windows 7 has one system DPI.
     */
    private void prepareThread() {
        if (dpiAwareness != null) return;
        String awareness = null;
        Function setContext = optional("user32", "SetThreadDpiAwarenessContext");
        // The export and ToUnicodeEx's no-state-change flag arrived with Windows 10 1607.
        layoutTypingAvailable = setContext != null;
        Function getContext = optional("user32", "GetThreadDpiAwarenessContext");
        Function awarenessOf = optional("user32", "GetAwarenessFromDpiAwarenessContext");
        Function equal = optional("user32", "AreDpiAwarenessContextsEqual");
        if (setContext != null && getContext != null && awarenessOf != null) {
            Pointer v2 = new Pointer(-4L);
            Pointer v1 = new Pointer(-3L);
            if (setContext.invokePointer(new Object[] {v2}) == null) setContext.invokePointer(new Object[] {v1});
            Pointer current = getContext.invokePointer(new Object[0]);
            if (equal != null && equal.invokeInt(new Object[] {current, v2}) != 0) awareness = "perMonitorV2";
            else awareness = name(awarenessOf.invokeInt(new Object[] {current}));
        } else {
            Function process = optional("shcore", "GetProcessDpiAwareness");
            if (process != null) {
                IntByReference value = new IntByReference(-1);
                if (process.invokeInt(new Object[] {null, value}) == 0) awareness = name(value.getValue());
            }
            if (awareness == null) {
                Function aware = optional("user32", "IsProcessDPIAware");
                awareness = aware != null && aware.invokeInt(new Object[0]) != 0 ? "system" : "unaware";
            }
        }
        dpiAwareness = awareness;
        ownIntegrity = integrity(Kernel32.INSTANCE.GetCurrentProcess());
    }

    private static String name(int awareness) {
        switch (awareness) {
            case 1: return "system";
            case 2: return "perMonitor";
            default: return "unaware";
        }
    }

    private static Function optional(String library, String name) {
        try {
            return Function.getFunction(library, name, Function.ALT_CONVENTION);
        } catch (UnsatisfiedLinkError absent) {
            return null;
        }
    }

    private static int metric(int index) {
        return User32.INSTANCE.GetSystemMetrics(index);
    }

    // ---------------------------------------------------------------- window and environment checks

    private static HWND handle(long window) {
        return new HWND(new Pointer(window));
    }

    private static long value(HWND window) {
        return window == null ? 0 : Pointer.nativeValue(window.getPointer());
    }

    private static int processOf(HWND window) {
        IntByReference pid = new IntByReference();
        if (User32.INSTANCE.GetWindowThreadProcessId(window, pid) == 0) return 0;
        return pid.getValue();
    }

    /** The window, if it exists and the given process owns it. A reused handle shows as another owner. */
    private static HWND owned(long window, int processId) {
        HWND handle = handle(window);
        if (!User32.INSTANCE.IsWindow(handle) || processOf(handle) != processId)
            throw InputException.refused("WINDOW_NOT_FOUND", "The window does not exist or belongs to another process.");
        return handle;
    }

    private static InputGeometry.Rect rect(HWND window) {
        RECT rect = new RECT();
        if (!User32.INSTANCE.GetWindowRect(window, rect))
            throw InputException.refused("WINDOW_NOT_FOUND", "The window rectangle could not be read.");
        return new InputGeometry.Rect(rect.left, rect.top, rect.right, rect.bottom);
    }

    private static String desktopName(HANDLE desktop) {
        if (desktop == null) return null;
        char[] buffer = new char[256];
        IntByReference needed = new IntByReference();
        if (!Natives.INSTANCE.GetUserObjectInformationW(desktop, UOI_NAME, buffer, buffer.length * 2, needed))
            return null;
        return Native.toString(buffer);
    }

    /** False on the lock screen, the secure desktop of UAC, or a disconnected session. */
    private static boolean inputDesktopMatches() {
        HANDLE input = Natives.INSTANCE.OpenInputDesktop(0, false, DESKTOP_READOBJECTS);
        if (input == null) return false;
        try {
            String inputName = desktopName(input);
            String own = desktopName(Natives.INSTANCE.GetThreadDesktop(Kernel32.INSTANCE.GetCurrentThreadId()));
            return inputName != null && inputName.equalsIgnoreCase(own);
        } finally {
            Natives.INSTANCE.CloseDesktop(input);
        }
    }

    /** The mandatory integrity RID of a process token, or -1 when it cannot be read. */
    private static int integrity(HANDLE process) {
        if (process == null) return -1;
        HANDLEByReference token = new HANDLEByReference();
        if (!Security.INSTANCE.OpenProcessToken(process, TOKEN_QUERY, token)) return -1;
        try {
            Memory buffer = new Memory(256);
            IntByReference needed = new IntByReference();
            if (!Security.INSTANCE.GetTokenInformation(token.getValue(), TOKEN_INTEGRITY_LEVEL, buffer,
                    (int) buffer.size(), needed)) return -1;
            Pointer sid = buffer.getPointer(0);
            int count = Security.INSTANCE.GetSidSubAuthorityCount(sid).getByte(0) & 0xFF;
            if (count == 0) return -1;
            return Security.INSTANCE.GetSidSubAuthority(sid, count - 1).getInt(0);
        } finally {
            Kernel32.INSTANCE.CloseHandle(token.getValue());
        }
    }

    private static int integrityOf(int processId) {
        HANDLE process = Kernel32.INSTANCE.OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, processId);
        if (process == null) return -1;
        try {
            return integrity(process);
        } finally {
            Kernel32.INSTANCE.CloseHandle(process);
        }
    }

    static String integrityName(int rid) {
        if (rid < 0) return "unknown";
        if (rid < 0x1000) return "untrusted";
        if (rid < 0x2000) return "low";
        if (rid < 0x2100) return "medium";
        if (rid < 0x3000) return "mediumPlus";
        if (rid < 0x4000) return "high";
        return "system";
    }

    // ---------------------------------------------------------------- one request

    private final class Operation {
        private final InputRequest request;
        private final Runnable gate;
        private final Job job;
        private final long deadline;
        private final Set<Integer> pressedButtons = new LinkedHashSet<>();
        private final Set<InputKeys.Key> pressedKeys = new LinkedHashSet<>();
        private final List<WinUser.INPUT> partialTextReleases = new ArrayList<>();
        private HWND window;
        private InputGeometry.Rect bounds;
        private boolean dispatched;
        private HookFault pendingFault;
        private int events;
        private long foreignBaseline;
        private WindowsTextLayout textLayout;

        Operation(InputRequest request, Runnable gate, Job job, long deadline) {
            this.request = request;
            this.gate = gate;
            this.job = job;
            this.deadline = deadline;
        }

        ObjectNode run() {
            prepareThread();
            try {
                return perform();
            } catch (AgentException failure) {
                throw fail(failure);
            } catch (RuntimeException failure) {
                throw fail(new AgentException("INTERNAL_ERROR", "The input could not be completed."));
            }
        }

        /** Releases what this request pressed and what the session holds. Never gated: a release is always due. */
        private InputException fail(AgentException failure) {
            boolean released = false;
            if (!pressedButtons.isEmpty() || !pressedKeys.isEmpty() || !held.isEmpty() || !partialTextReleases.isEmpty()) {
                List<WinUser.INPUT> ups = new ArrayList<>();
                for (int down : pressedButtons) ups.add(mouse(0, 0, 0, down << 1));
                ups.addAll(partialTextReleases);
                Set<InputKeys.Key> keys = new LinkedHashSet<>(pressedKeys);
                keys.addAll(held);
                List<InputKeys.Key> reverse = new ArrayList<>(keys);
                java.util.Collections.reverse(reverse);
                for (InputKeys.Key key : reverse) ups.add(key(key, true));
                released = sendUnchecked(ups) == ups.size();
                pressedButtons.clear();
                pressedKeys.clear();
                held.clear();
                partialTextReleases.clear();
            }
            if (monitor != null && !monitor.observationsComplete()) monitor.invalidate();
            boolean sent = events > 0;
            if (failure instanceof InputException) return ((InputException) failure).withRelease(sent, released);
            return new InputException(failure.code(), failure.getMessage(), sent, released);
        }

        private ObjectNode perform() {
            if (request.keyboard()) InputKeys.refuseShellShortcut(request, held);
            if (!request.keys.isEmpty()) {
                InputKeys.Key key = request.keys.get(request.keys.size() - 1);
                if (request.kind == InputRequest.Kind.KEY_UP && !held.contains(key))
                    throw refused("PRECONDITION_FAILED", "This session does not hold the key.");
                if (request.kind == InputRequest.Kind.KEY_DOWN && held.contains(key))
                    throw refused("PRECONDITION_FAILED", "This session already holds the key.");
                if (request.kind == InputRequest.Kind.KEY_DOWN && held.size() >= InputRequest.HELD_KEY_LIMIT)
                    throw refused("PRECONDITION_FAILED", "This session holds too many keys.");
            }
            window = owned(request.window, request.processId);
            if (value(User32.INSTANCE.GetAncestor(window, GA_ROOT)) != request.window)
                throw refused("PRECONDITION_FAILED", "The target must be a top-level window.");
            if (!User32.INSTANCE.IsWindowVisible(window) || Natives.INSTANCE.IsIconic(window))
                throw refused("PRECONDITION_FAILED", "The target window is hidden or minimized.");
            if (!inputDesktopMatches())
                throw refused("INPUT_DESKTOP_UNAVAILABLE", "The input desktop is locked, secure or disconnected.");
            int target = integrityOf(request.processId);
            if (target < 0 || ownIntegrity < 0 || target > ownIntegrity)
                throw refused("INTEGRITY_MISMATCH", "The target runs at a higher or unreadable integrity level.");
            if ("unaware".equals(dpiAwareness))
                throw refused("INPUT_UNAVAILABLE", "The input thread has no DPI awareness.");
            bounds = rect(window);
            if (request.kind == InputRequest.Kind.ACTIVATE) return activate();
            requireForeground();
            requireQuiet();
            switch (request.kind) {
                case MOVE: return move();
                case CLICK: return click();
                case DRAG: return drag();
                case SCROLL: return scroll();
                case KEY_PRESS: return keyPress();
                case KEY_DOWN: return keyDown();
                case KEY_UP: return keyUp();
                case TYPE_TEXT: return type();
                default: throw new AgentException("UNKNOWN_OPERATION", "Unknown operation.");
            }
        }

        private InputException refused(String code, String message) {
            return new InputException(code, message, events > 0, false);
        }

        private boolean belongs(HWND other) {
            if (other == null) return false;
            HWND root = User32.INSTANCE.GetAncestor(other, GA_ROOT);
            if (value(root) == request.window) return true;
            return processOf(root) == request.processId && value(User32.INSTANCE.GetAncestor(root, GA_ROOTOWNER))
                    == value(User32.INSTANCE.GetAncestor(window, GA_ROOTOWNER));
        }

        private HWND requireForeground() {
            HWND foreground = User32.INSTANCE.GetForegroundWindow();
            if (!belongs(foreground))
                throw refused("FOREGROUND_MISMATCH", "The target window is not in the foreground.");
            if (!request.keyboard()) return foreground;
            WinUser.GUITHREADINFO info = new WinUser.GUITHREADINFO();
            info.cbSize = info.size();
            int threadId = User32.INSTANCE.GetWindowThreadProcessId(foreground, null);
            HWND focus = foreground;
            if (User32.INSTANCE.GetGUIThreadInfo(threadId, info)) {
                if (info.hwndFocus != null) focus = info.hwndFocus;
                else if (info.hwndActive != null) focus = info.hwndActive;
            }
            if (processOf(focus) != request.processId)
                throw refused("FOREGROUND_MISMATCH", "The keyboard focus is not in the target process.");
            return focus;
        }

        /** Buttons or modifiers that someone else holds, or recent input that is not this session's. */
        private void requireQuiet() {
            for (int vk : USER_HELD_KEYS) {
                boolean ours = false;
                for (InputKeys.Key key : held) ours |= key.vk == vk;
                if (!ours && User32.INSTANCE.GetAsyncKeyState(vk) < 0)
                    throw refused("USER_INPUT_CONFLICT", "A mouse button or modifier key is held down.");
            }
            if (monitor != null && !monitor.unhealthy() && !recoveryPending) {
                if (monitor.foreignWithin(request.quietMs))
                    throw refused("USER_INPUT_CONFLICT", "The user used the mouse or keyboard just now.");
            } else {
                requireDesktopQuiet(monitor == null ? request.quietMs : Math.max(RECOVERY_QUIET_MILLIS, request.quietMs),
                        monitor != null);
            }
        }

        private void requireDesktopQuiet(int millis, boolean recovering) {
            WinUser.LASTINPUTINFO last = new WinUser.LASTINPUTINFO();
            last.cbSize = last.size();
            if (User32.INSTANCE.GetLastInputInfo(last)) {
                long idle = Integer.toUnsignedLong(Kernel32.INSTANCE.GetTickCount() - last.dwTime);
                if (idle < millis)
                    throw refused("USER_INPUT_CONFLICT", "The user used the mouse or keyboard just now.");
            } else if (recovering) {
                throw refused("INPUT_UNAVAILABLE", "The input monitor is recovering and recent activity could not be checked.");
            }
        }

        private int[] resolve(InputRequest.Point point) {
            long x = point.x;
            long y = point.y;
            switch (point.space) {
                case WINDOW:
                    x += bounds.left;
                    y += bounds.top;
                    break;
                case CLIENT: {
                    POINT origin = new POINT(0, 0);
                    if (!Natives.INSTANCE.ClientToScreen(window, origin))
                        throw refused("WINDOW_NOT_FOUND", "The client area could not be read.");
                    x += origin.x;
                    y += origin.y;
                    break;
                }
                default:
                    break;
            }
            if (x < Integer.MIN_VALUE || x > Integer.MAX_VALUE || y < Integer.MIN_VALUE || y > Integer.MAX_VALUE
                    || !bounds.contains((int) x, (int) y))
                throw refused("PRECONDITION_FAILED", "The point is outside the target window.");
            int[] resolved = {(int) x, (int) y};
            normalized(resolved);
            requireUnobscured(resolved);
            return resolved;
        }

        private int[] normalized(int[] point) {
            return new int[] {InputGeometry.normalize(point[0], metric(76), metric(78)),
                    InputGeometry.normalize(point[1], metric(77), metric(79))};
        }

        private void requireUnobscured(int[] point) {
            POINT.ByValue at = new POINT.ByValue(point[0], point[1]);
            if (!belongs(Natives.INSTANCE.WindowFromPoint(at)))
                throw refused("WINDOW_OBSCURED", "Another window covers the point.");
        }

        // ------------------------------------------------------------ sending

        /** Runs the session gate once, right before the first event of the request. */
        private void dispatch() {
            if (dispatched) return;
            synchronized (job) {
                if (job.cancelled) throw refused("TIMEOUT", "The request expired before any input was sent.");
            }
            gate.run();
            owned(request.window, request.processId);
            if (request.kind != InputRequest.Kind.ACTIVATE) {
                if (monitor == null || monitor.unhealthy()) {
                    if (monitor != null) {
                        recoveryPending = true;
                        monitor.stop();
                        long previousTag = tag;
                        do tag = nextTag(); while (tag == previousTag);
                    }
                    monitor = Monitor.start(tag);
                }
                foreignBaseline = monitor.foreign.get();
                if (recoveryPending) {
                    requireDesktopQuiet(Math.max(RECOVERY_QUIET_MILLIS, request.quietMs), true);
                    recoveryPending = false;
                }
            }
            synchronized (job) {
                if (job.cancelled) throw refused("TIMEOUT", "The request expired before any input was sent.");
                if (request.textMethod != InputRequest.TextMethod.CLIPBOARD) job.dispatched = true;
            }
            dispatched = true;
            if ((request.kind == InputRequest.Kind.DRAG && (hookFault == HookFault.MOUSE_REMOVE || hookFault == HookFault.MOUSE_PARTIAL))
                    || (request.kind == InputRequest.Kind.TYPE_TEXT && (hookFault == HookFault.KEYBOARD_REMOVE
                    || hookFault == HookFault.KEYBOARD_PARTIAL || hookFault == HookFault.BOTH_REMOVE))) {
                pendingFault = hookFault;
                hookFault = null;
            }
        }

        /** Between steps: the caller gave up, or someone else used the mouse or keyboard. */
        private void checkpoint() {
            synchronized (job) {
                if (job.cancelled) throw refused("TIMEOUT", "The request expired while input was being sent.");
            }
            if (monitor != null && monitor.foreign.get() != foreignBaseline)
                throw refused("USER_INPUT_CONFLICT", "The user used the mouse or keyboard during the request.");
        }

        private void send(List<WinUser.INPUT> batch) {
            send(batch, null);
        }

        private void send(List<WinUser.INPUT> batch, Runnable beforeSend) {
            dispatch();
            requireObservations();
            HWND focus = requireForeground();
            if (textLayout != null) textLayout.verify(focus);
            if (pendingFault != null) injectHookFault();
            if (beforeSend != null) {
                beforeSend.run();
                synchronized (job) {
                    if (job.cancelled) throw refused("TIMEOUT", "The request expired before any input was sent.");
                    job.dispatched = true;
                }
            }
            int sent = sendUnchecked(batch);
            events += sent;
            if (sent == 0 && events == 0)
                throw new InputException("INPUT_BLOCKED", "The system did not accept the input.", false, false);
            if (sent < batch.size()) {
                if (request.kind == InputRequest.Kind.TYPE_TEXT) recordPartialTextReleases(batch, sent);
                throw refused("ACTION_OUTCOME_UNKNOWN", "Only part of the input was accepted.");
            }
        }

        private void recordPartialTextReleases(List<WinUser.INPUT> batch, int sent) {
            for (int i = 0; i < sent; i++) {
                var event = batch.get(i).input.ki;
                int flags = event.dwFlags.intValue();
                if ((flags & KEY_UP) == 0) {
                    partialTextReleases.add(0, keyboardEvent(event.wVk.intValue(), event.wScan.intValue(), flags | KEY_UP));
                } else {
                    partialTextReleases.removeIf(up -> up.input.ki.wVk.equals(event.wVk)
                            && up.input.ki.wScan.equals(event.wScan) && up.input.ki.dwFlags.equals(event.dwFlags));
                }
            }
        }

        private void injectHookFault() {
            switch (pendingFault) {
                case MOUSE_REMOVE:
                    monitor.removeMouseAt = monitor.mouseObserved.get() + 2;
                    break;
                case KEYBOARD_REMOVE:
                    monitor.removeKeyboardAt = monitor.keyboardObserved.get() + 2;
                    break;
                case BOTH_REMOVE:
                    monitor.removeMouseHook();
                    monitor.removeKeyboardHook();
                    break;
                case MOUSE_PARTIAL:
                    monitor.mouseObservationLimit = monitor.mouseObserved.get() + 2;
                    break;
                case KEYBOARD_PARTIAL:
                    monitor.keyboardObservationLimit = monitor.keyboardObserved.get() + 2;
                    break;
            }
            pendingFault = null;
        }

        /** The physical button flag for a logical button. Left and right swap with SM_SWAPBUTTON. */
        private int down(InputRequest.Button button) {
            boolean swapped = metric(23) != 0;
            switch (button) {
                case RIGHT: return swapped ? LEFT_DOWN : RIGHT_DOWN;
                case MIDDLE: return MIDDLE_DOWN;
                default: return swapped ? RIGHT_DOWN : LEFT_DOWN;
            }
        }

        private void moveTo(int[] point) {
            int[] n = normalized(point);
            send(List.of(mouse(n[0], n[1], 0, MOVE | ABSOLUTE | VIRTUALDESK)));
            long until = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(CURSOR_MILLIS);
            POINT cursor = new POINT();
            while (true) {
                if (User32.INSTANCE.GetCursorPos(cursor) && cursor.x == point[0] && cursor.y == point[1]) return;
                if (System.nanoTime() > until)
                    throw refused("PRECONDITION_FAILED", "The pointer did not reach the requested point.");
                pause(5);
            }
        }

        private ObjectNode result() {
            requireObservations();
            ObjectNode result = JsonNodeFactory.instance.objectNode().put("performed", true).put("inputSent", true)
                    .put("inputObserved", true).put("effectVerified", false).put("events", events);
            return result;
        }

        /** Do not send another batch, or report success, until every accepted event was observed. */
        private void requireObservations() {
            long until = Math.min(deadline, System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(OBSERVE_MILLIS));
            if (!monitor.awaitObserved(until, this::checkpoint, () -> pause(1))) {
                throw refused(events == 0 ? "INPUT_UNAVAILABLE" : "ACTION_OUTCOME_UNKNOWN",
                        "The input monitor could not confirm the events. Inspect the target before retrying.");
            }
        }

        private ObjectNode withPoint(ObjectNode result, String field, int[] point) {
            result.putObject(field).put("x", point[0]).put("y", point[1]);
            return result;
        }

        private ObjectNode activate() {
            dispatch();
            User32.INSTANCE.SetForegroundWindow(window);
            long until = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(OBSERVE_MILLIS);
            while (value(User32.INSTANCE.GetForegroundWindow()) != request.window) {
                if (System.nanoTime() >= until)
                    throw refused("FOREGROUND_MISMATCH", "Windows did not bring the window to the foreground.");
                pause(5);
            }
            return JsonNodeFactory.instance.objectNode().put("performed", true).put("inputSent", false)
                    .put("foreground", true).put("effectVerified", false);
        }

        private ObjectNode move() {
            int[] point = resolve(request.point);
            moveTo(point);
            return withPoint(result(), "point", point);
        }

        private ObjectNode click() {
            int[] point = resolve(request.point);
            moveTo(point);
            checkpoint();
            requireForeground();
            requireUnobscured(point);
            int down = down(request.button);
            List<WinUser.INPUT> batch = new ArrayList<>();
            for (int i = 0; i < request.clicks; i++) {
                batch.add(mouse(0, 0, 0, down));
                batch.add(mouse(0, 0, 0, down << 1));
            }
            pressedButtons.add(down);
            send(batch);
            pressedButtons.remove(down);
            return withPoint(result(), "point", point);
        }

        private ObjectNode drag() {
            int[] from = resolve(request.from);
            int[] to = resolve(request.to);
            moveTo(from);
            checkpoint();
            requireForeground();
            requireUnobscured(from);
            int down = down(request.button);
            pressedButtons.add(down);
            send(List.of(mouse(0, 0, 0, down)));
            for (int step = 1; step <= request.steps; step++) {
                pause(request.stepDelayMs);
                int[] at = {from[0] + (int) InputGeometry.round((to[0] - from[0]) * (double) step / request.steps),
                        from[1] + (int) InputGeometry.round((to[1] - from[1]) * (double) step / request.steps)};
                requireUnobscured(at);
                moveTo(at);
            }
            requireUnobscured(to);
            send(List.of(mouse(0, 0, 0, down << 1)));
            pressedButtons.remove(down);
            ObjectNode result = result();
            withPoint(result, "from", from);
            return withPoint(result, "to", to);
        }

        private ObjectNode scroll() {
            int[] point = resolve(request.point);
            moveTo(point);
            checkpoint();
            requireUnobscured(point);
            send(List.of(mouse(0, 0, request.delta * WHEEL_DELTA, request.horizontal ? HWHEEL : WHEEL)));
            return withPoint(result(), "point", point);
        }

        private ObjectNode keyPress() {
            List<InputKeys.Key> keys = new ArrayList<>();
            for (InputKeys.Key key : request.keys) {
                // A modifier the session already holds stays down. Any other held key cannot be pressed again.
                if (held.contains(key) && !key.modifier())
                    throw refused("PRECONDITION_FAILED", "This session already holds the key.");
                if (!held.contains(key)) keys.add(key);
            }
            List<WinUser.INPUT> batch = new ArrayList<>();
            for (InputKeys.Key key : keys) batch.add(key(key, false));
            for (int i = keys.size() - 1; i >= 0; i--) batch.add(key(keys.get(i), true));
            pressedKeys.addAll(keys);
            send(batch);
            pressedKeys.clear();
            return result();
        }

        private ObjectNode keyDown() {
            InputKeys.Key key = request.keys.get(0);
            pressedKeys.add(key);
            send(List.of(key(key, false)));
            pressedKeys.remove(key);
            held.add(key);
            return result();
        }

        private ObjectNode keyUp() {
            InputKeys.Key key = request.keys.get(0);
            send(List.of(key(key, true)));
            held.remove(key);
            return result();
        }

        private ObjectNode type() {
            if (request.textMethod == InputRequest.TextMethod.CLIPBOARD) return paste();
            List<InputKeys.Unit> units = request.text;
            if (request.textMethod != InputRequest.TextMethod.UNICODE) {
                if (!layoutTypingAvailable)
                    throw refused("PRECONDITION_FAILED", "Layout-based typing is unavailable on this version of Windows.");
                if (!held.isEmpty())
                    throw refused("PRECONDITION_FAILED", "Release session-held keys before layout-based typing.");
                textLayout = WindowsTextLayout.prepare(requireForeground(), units);
            }
            for (int start = 0, end; start < units.size(); start = end) {
                end = Math.min(units.size(), start + InputRequest.TEXT_CHUNK);
                // A surrogate pair goes out in one batch.
                if (end < units.size() && units.get(end - 1).key == null
                        && Character.isHighSurrogate(units.get(end - 1).character)) end++;
                if (start > 0) {
                    pause(request.intervalMs);
                    checkpoint();
                    requireForeground();
                }
                List<WinUser.INPUT> batch = new ArrayList<>();
                for (int index = start; index < end; index++) {
                    InputKeys.Unit unit = units.get(index);
                    if (textLayout != null) {
                        WindowsTextLayout.Stroke stroke = textLayout.stroke(index);
                        boolean scan = request.textMethod == InputRequest.TextMethod.SCAN_CODE;
                        if (stroke.shift) batch.add(layoutKey(textLayout.shift(), scan, false));
                        batch.add(layoutKey(stroke, scan, false));
                        batch.add(layoutKey(stroke, scan, true));
                        if (stroke.shift) batch.add(layoutKey(textLayout.shift(), scan, true));
                    } else if (unit.key != null) {
                        batch.add(key(unit.key, false));
                        batch.add(key(unit.key, true));
                    } else {
                        batch.add(unicode(unit.character, false));
                        batch.add(unicode(unit.character, true));
                    }
                }
                send(batch);
            }
            return result();
        }

        private ObjectNode paste() {
            if (!layoutTypingAvailable)
                throw refused("INPUT_UNAVAILABLE", "Clipboard text requires Windows 10 version 1607 or newer.");
            if (!held.isEmpty()) throw refused("PRECONDITION_FAILED", "Release all session-held keys before pasting.");
            HWND focus = pasteFocus();
            Runnable check = () -> {
                if (System.nanoTime() >= deadline) throw refused(events == 0 ? "TIMEOUT" : "ACTION_OUTCOME_UNKNOWN",
                        "The clipboard request deadline expired.");
                checkpoint();
                if (!focus.equals(pasteFocus())) throw refused("FOREGROUND_MISMATCH", "The paste target lost keyboard focus.");
            };
            InputKeys.Key ctrl = InputKeys.key("Ctrl");
            InputKeys.Key v = InputKeys.key("V");
            dispatch();
            WindowsClipboard clipboard = new WindowsClipboard(request.processId, check, deadline);
            try {
                clipboard.stage(request.clipboardText);
                send(List.of(key(ctrl, false), key(v, false), key(v, true), key(ctrl, true)), () -> {
                    gate.run();
                    check.run();
                    requireQuiet();
                    if (User32.INSTANCE.GetAsyncKeyState(v.vk) < 0)
                        throw refused("USER_INPUT_CONFLICT", "The paste key is held down.");
                    clipboard.arm(request.clipboardTimeoutMs);
                });
                requireObservations();
                clipboard.awaitRead();
                check.run();
            } finally {
                clipboard.close();
            }
            return result().put("clipboardRestored", true);
        }

        private HWND pasteFocus() {
            if (value(User32.INSTANCE.GetForegroundWindow()) != request.window)
                throw refused("FOREGROUND_MISMATCH", "Paste requires the exact target window in the foreground.");
            WinUser.GUITHREADINFO info = new WinUser.GUITHREADINFO();
            info.cbSize = info.size();
            int threadId = User32.INSTANCE.GetWindowThreadProcessId(window, null);
            if (!User32.INSTANCE.GetGUIThreadInfo(threadId, info) || info.hwndFocus == null
                    || processOf(info.hwndFocus) != request.processId)
                throw refused("FOREGROUND_MISMATCH", "The paste target has no verified keyboard focus.");
            return info.hwndFocus;
        }
    }

    private int sendUnchecked(List<WinUser.INPUT> batch) {
        if (batch.isEmpty()) return 0;
        WinUser.INPUT[] array = (WinUser.INPUT[]) new WinUser.INPUT().toArray(batch.size());
        for (int i = 0; i < array.length; i++) {
            WinUser.INPUT source = batch.get(i);
            array[i].type = source.type;
            if (source.type.intValue() == INPUT_MOUSE) {
                array[i].input.setType("mi");
                array[i].input.mi = source.input.mi;
                array[i].input.mi.dwExtraInfo = new ULONG_PTR(tag);
            } else {
                array[i].input.setType("ki");
                array[i].input.ki = source.input.ki;
                array[i].input.ki.dwExtraInfo = new ULONG_PTR(tag);
            }
        }
        int sent = User32.INSTANCE.SendInput(new DWORD(array.length), array, array[0].size()).intValue();
        if (monitor != null) {
            int mouse = 0;
            for (int i = 0; i < sent; i++) {
                if (array[i].type.intValue() == INPUT_MOUSE) mouse++;
            }
            monitor.expect(mouse, sent - mouse);
        }
        return sent;
    }

    private WinUser.INPUT mouse(int dx, int dy, int data, int flags) {
        WinUser.INPUT input = new WinUser.INPUT();
        input.type = new DWORD(INPUT_MOUSE);
        input.input.setType("mi");
        input.input.mi.dx = new LONG(dx);
        input.input.mi.dy = new LONG(dy);
        input.input.mi.mouseData = new DWORD(data & 0xFFFFFFFFL);
        input.input.mi.dwFlags = new DWORD(flags);
        input.input.mi.time = new DWORD(0);
        return input;
    }

    private WinUser.INPUT key(InputKeys.Key key, boolean up) {
        return keyboardEvent(key.vk, Natives.INSTANCE.MapVirtualKeyW(key.vk, 0) & 0xFFFF,
                (key.extended ? KEY_EXTENDED : 0) | (up ? KEY_UP : 0));
    }

    private WinUser.INPUT unicode(char character, boolean up) {
        return keyboardEvent(0, character, KEY_UNICODE | (up ? KEY_UP : 0));
    }

    private WinUser.INPUT layoutKey(WindowsTextLayout.Stroke stroke, boolean scan, boolean up) {
        return keyboardEvent(scan ? 0 : stroke.virtualKey, stroke.scanCode,
                (scan ? KEY_SCAN_CODE : 0) | (stroke.extended ? KEY_EXTENDED : 0) | (up ? KEY_UP : 0));
    }

    private WinUser.INPUT keyboardEvent(int virtualKey, int scanCode, int flags) {
        WinUser.INPUT input = new WinUser.INPUT();
        input.type = new DWORD(INPUT_KEYBOARD);
        input.input.setType("ki");
        input.input.ki.wVk = new WORD(virtualKey);
        input.input.ki.wScan = new WORD(scanCode);
        input.input.ki.dwFlags = new DWORD(flags);
        input.input.ki.time = new DWORD(0);
        return input;
    }

    private void releaseHeld() {
        if (held.isEmpty()) return;
        List<InputKeys.Key> reverse = new ArrayList<>(held);
        java.util.Collections.reverse(reverse);
        List<WinUser.INPUT> ups = new ArrayList<>();
        for (InputKeys.Key key : reverse) ups.add(key(key, true));
        sendUnchecked(ups);
        held.clear();
    }

    private static void pause(long millis) {
        if (millis <= 0) return;
        try {
            Thread.sleep(millis);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new AgentException("ACTION_OUTCOME_UNKNOWN", "The input thread was interrupted.");
        }
    }

    // ---------------------------------------------------------------- low-level hook

    /**
     * Low-level mouse and keyboard hooks on their own message loop. Counts this session's tagged
     * events and records every other event as the user's. The callbacks only count and pass on.
     */
    static final class Monitor {
        private final AtomicLong mouseObserved = new AtomicLong();
        private final AtomicLong keyboardObserved = new AtomicLong();
        final AtomicLong foreign = new AtomicLong();
        private long mouseExpected;
        private long keyboardExpected;
        private boolean mouseMissing;
        private boolean keyboardMissing;
        private volatile long mouseObservationLimit = Long.MAX_VALUE;
        private volatile long keyboardObservationLimit = Long.MAX_VALUE;
        private volatile long removeMouseAt = Long.MAX_VALUE;
        private volatile long removeKeyboardAt = Long.MAX_VALUE;
        private volatile long lastForeign = Long.MIN_VALUE;
        private volatile boolean stopped;
        private final long tag;
        private volatile int threadId;
        private Thread thread;
        // Strong references keep the callbacks alive while Windows holds them.
        private WinUser.LowLevelMouseProc mouseProc;
        private WinUser.LowLevelKeyboardProc keyboardProc;
        private WinUser.HHOOK mouseHandle;
        private WinUser.HHOOK keyboardHandle;

        Monitor(long tag) { this.tag = tag; }

        static Monitor start(long tag) {
            Monitor monitor = new Monitor(tag);
            CountDownLatch ready = new CountDownLatch(1);
            boolean[] installed = {false};
            monitor.thread = new Thread(() -> monitor.loop(ready, installed), "desktop-input-monitor");
            monitor.thread.setDaemon(true);
            monitor.thread.start();
            try {
                if (!ready.await(2, TimeUnit.SECONDS) || !installed[0]) {
                    monitor.stop();
                    throw InputException.refused("INPUT_UNAVAILABLE", "The input monitor could not be installed.");
                }
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                monitor.stop();
                throw InputException.refused("INPUT_UNAVAILABLE", "The input monitor could not be installed.");
            }
            return monitor;
        }

        private void loop(CountDownLatch ready, boolean[] installed) {
            threadId = Kernel32.INSTANCE.GetCurrentThreadId();
            var module = Kernel32.INSTANCE.GetModuleHandle(null);
            mouseProc = (code, wParam, info) -> {
                if (code >= 0) recordMouse((info.flags & LLMHF_INJECTED) != 0 && info.dwExtraInfo.longValue() == tag);
                return User32.INSTANCE.CallNextHookEx(null, code, wParam, new LPARAM(Pointer.nativeValue(info.getPointer())));
            };
            keyboardProc = (code, wParam, info) -> {
                if (code >= 0) recordKeyboard((info.flags & LLKHF_INJECTED) != 0 && info.dwExtraInfo.longValue() == tag);
                return User32.INSTANCE.CallNextHookEx(null, code, wParam, new LPARAM(Pointer.nativeValue(info.getPointer())));
            };
            try {
                mouseHandle = User32.INSTANCE.SetWindowsHookEx(WinUser.WH_MOUSE_LL, mouseProc, module, 0);
                keyboardHandle = User32.INSTANCE.SetWindowsHookEx(WinUser.WH_KEYBOARD_LL, keyboardProc, module, 0);
                installed[0] = mouseHandle != null && keyboardHandle != null;
                ready.countDown();
                if (!installed[0]) return;
                WinUser.MSG message = new WinUser.MSG();
                while (User32.INSTANCE.GetMessage(message, null, 0, 0) > 0) {
                    // Low-level hooks are called while this thread waits for messages.
                }
            } finally {
                stopped = true;
                removeMouseHook();
                removeKeyboardHook();
                ready.countDown();
            }
        }

        private synchronized void removeMouseHook() {
            if (mouseHandle == null) return;
            User32.INSTANCE.UnhookWindowsHookEx(mouseHandle);
            mouseHandle = null;
        }

        private synchronized void removeKeyboardHook() {
            if (keyboardHandle == null) return;
            User32.INSTANCE.UnhookWindowsHookEx(keyboardHandle);
            keyboardHandle = null;
        }

        void recordMouse(boolean ours) {
            long seen = record(mouseObserved, mouseObservationLimit, ours);
            if (seen == removeMouseAt) removeMouseHook();
        }

        void recordKeyboard(boolean ours) {
            long seen = record(keyboardObserved, keyboardObservationLimit, ours);
            if (seen == removeKeyboardAt) removeKeyboardHook();
        }

        private long record(AtomicLong observed, long limit, boolean ours) {
            if (ours) {
                if (limit == Long.MAX_VALUE || observed.get() < limit) return observed.incrementAndGet();
            } else {
                lastForeign = System.nanoTime();
                foreign.incrementAndGet();
            }
            return -1;
        }

        void expect(int mouse, int keyboard) {
            mouseExpected += mouse;
            keyboardExpected += keyboard;
        }

        boolean observationsComplete() {
            return mouseObserved.get() >= mouseExpected && keyboardObserved.get() >= keyboardExpected;
        }

        boolean unhealthy() { return stopped || mouseMissing || keyboardMissing; }

        void invalidate() {
            mouseMissing |= mouseObserved.get() < mouseExpected;
            keyboardMissing |= keyboardObserved.get() < keyboardExpected;
        }

        boolean awaitObserved(long until, Runnable checkpoint, Runnable wait) {
            while (!unhealthy() && !observationsComplete() && System.nanoTime() < until) {
                checkpoint.run();
                wait.run();
            }
            if (!observationsComplete()) invalidate();
            checkpoint.run();
            return !unhealthy();
        }

        boolean foreignWithin(int millis) {
            long last = lastForeign;
            return last != Long.MIN_VALUE && System.nanoTime() - last < TimeUnit.MILLISECONDS.toNanos(millis);
        }

        void stop() {
            int id = threadId;
            if (id != 0) User32.INSTANCE.PostThreadMessage(id, WinUser.WM_QUIT, new WPARAM(0), new LPARAM(0));
            if (thread != null) {
                try {
                    thread.join(1000);
                } catch (InterruptedException interrupted) {
                    Thread.currentThread().interrupt();
                }
            }
        }
    }
}
