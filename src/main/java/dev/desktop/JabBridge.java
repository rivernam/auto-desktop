package dev.desktop;

import com.sun.jna.Function;
import com.sun.jna.Memory;
import com.sun.jna.Native;
import com.sun.jna.Platform;
import com.sun.jna.Pointer;
import com.sun.jna.WString;
import com.sun.jna.ptr.IntByReference;
import com.sun.jna.ptr.LongByReference;
import com.sun.jna.win32.StdCallLibrary;
import java.io.IOException;
import java.io.RandomAccessFile;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Set;

/**
 * The Windows side of Java Access Bridge (OpenJDK AccessBridgeCalls.h), in the ABI where Java object
 * handles are 64-bit. One thread loads the library, owns its message window and makes every call.
 */
final class JabBridge extends JabApi {
    /** Read by the composition root. The operator names the library instead of the default locations. */
    static final String LIBRARY_PROPERTY = "desktop.jab.dll";
    private static final boolean TRACE = "1".equals(System.getenv("AUTO_DESKTOP_NATIVE_TRACE"));
    static final int NAME_CHARS = 1024;
    static final int SHORT_CHARS = 256;
    static final int MAX_ACTIONS = 256;
    static final int MAX_ACTIONS_TO_DO = 32;
    /** setTextContents copies into a buffer of NAME_CHARS code units. One is the terminator. */
    static final int MAX_TEXT = NAME_CHARS - 1;
    private static final int CONTEXT_INFO_BYTES = 2 * NAME_CHARS * 2 + 4 * SHORT_CHARS * 2 + 11 * 4;
    private static final int ACTIONS_BYTES = 4 + MAX_ACTIONS * SHORT_CHARS * 2;
    private static final int ACTIONS_TO_DO_BYTES = 4 + MAX_ACTIONS_TO_DO * SHORT_CHARS * 2;
    private static final int VERSION_BYTES = 4 * SHORT_CHARS * 2;
    private static final String[] EXPORTS = {
        "Windows_run", "isJavaWindow", "getAccessibleContextFromHWND", "getHWNDFromAccessibleContext",
        "releaseJavaObject", "isSameObject", "getVersionInfo", "getAccessibleContextInfo",
        "getAccessibleChildFromContext", "getAccessibleParentFromContext", "getAccessibleActions",
        "doAccessibleActions", "setTextContents"
    };

    public interface Loader extends StdCallLibrary {
        Loader INSTANCE = Native.load("kernel32", Loader.class);
        Pointer LoadLibraryExW(WString file, Pointer reserved, int flags);
        Pointer GetProcAddress(Pointer module, String name);
        boolean FreeLibrary(Pointer module);
        int GetSystemDirectoryW(char[] buffer, int size);
        int GetCurrentProcessId();
        int GetCurrentThreadId();
    }

    public interface Windows extends StdCallLibrary {
        Windows INSTANCE = Native.load("user32", Windows.class);
        boolean PeekMessageW(Pointer message, Pointer window, int first, int last, int remove);
        int MsgWaitForMultipleObjectsEx(int count, Pointer handles, int milliseconds, int wakeMask, int flags);
        boolean PostThreadMessageW(int thread, int message, Pointer wParam, Pointer lParam);
        boolean TranslateMessage(Pointer message);
        Pointer DispatchMessageW(Pointer message);
        int GetWindowThreadProcessId(Pointer window, IntByReference processId);
        boolean IsWindow(Pointer window);
        boolean IsWindowVisible(Pointer window);
        int GetClassNameW(Pointer window, char[] buffer, int size);
        boolean EnumWindows(Visitor visitor, Pointer data);
        Pointer GetWindow(Pointer window, int command);
        Pointer GetAncestor(Pointer window, int flags);
        Pointer GetDesktopWindow();
        Pointer SendMessageTimeoutW(Pointer window, int message, Pointer wParam, Pointer lParam, int flags,
                                    int milliseconds, Pointer result);
    }

    public interface Visitor extends StdCallLibrary.StdCallCallback {
        boolean callback(Pointer window, Pointer data);
    }

    /** The reason is safe to show to the operator. It names files, never window content. */
    static final class Unavailable extends RuntimeException {
        Unavailable(String reason) { super(reason); }
    }

    /**
     * A JVM did not answer. The library waits at least four seconds for each reply and then returns
     * whatever its buffer held, so the result of such a call carries no information.
     */
    static final class Silent extends RuntimeException {
        Silent() { super("A JVM connected to Java Access Bridge is not answering.", null, false, false); }
    }

    static final class ContextInfo {
        private final String name;
        private final String role;
        private final String states;
        private final int indexInParent;
        private final int children;
        private final int x;
        private final int y;
        private final int width;
        private final int height;
        private final boolean action;
        private final boolean text;

        ContextInfo(String name,
                    String role,
                    String states,
                    int indexInParent,
                    int children,
                    int x,
                    int y,
                    int width,
                    int height,
                    boolean action,
                    boolean text) {
            this.name = name;
            this.role = role;
            this.states = states;
            this.indexInParent = indexInParent;
            this.children = children;
            this.x = x;
            this.y = y;
            this.width = width;
            this.height = height;
            this.action = action;
            this.text = text;
        }

        public String name() { return name; }
        public String role() { return role; }
        public String states() { return states; }
        public int indexInParent() { return indexInParent; }
        public int children() { return children; }
        public int x() { return x; }
        public int y() { return y; }
        public int width() { return width; }
        public int height() { return height; }
        public boolean action() { return action; }
        public boolean text() { return text; }

        @Override public boolean equals(Object other) {
            if (this == other) return true;
            if (!(other instanceof ContextInfo)) return false;
            ContextInfo that = (ContextInfo) other;
            return Objects.equals(name, that.name)
                    && Objects.equals(role, that.role)
                    && Objects.equals(states, that.states)
                    && indexInParent == that.indexInParent
                    && children == that.children
                    && x == that.x
                    && y == that.y
                    && width == that.width
                    && height == that.height
                    && action == that.action
                    && text == that.text;
        }
        @Override public int hashCode() { return Objects.hash(name, role, states, indexInParent, children, x, y, width, height, action, text); }
        @Override public String toString() {
            return "ContextInfo[" + "name=" + name
                    + ", role=" + role
                    + ", states=" + states
                    + ", indexInParent=" + indexInParent
                    + ", children=" + children
                    + ", x=" + x
                    + ", y=" + y
                    + ", width=" + width
                    + ", height=" + height
                    + ", action=" + action
                    + ", text=" + text + "]";
        }
    }

    static final class Root {
        private final int vm;
        private final long context;

        Root(int vm, long context) {
            this.vm = vm;
            this.context = context;
        }

        public int vm() { return vm; }
        public long context() { return context; }

        @Override public boolean equals(Object other) {
            if (this == other) return true;
            if (!(other instanceof Root)) return false;
            Root that = (Root) other;
            return vm == that.vm
                    && context == that.context;
        }
        @Override public int hashCode() { return Objects.hash(vm, context); }
        @Override public String toString() {
            return "Root[" + "vm=" + vm
                    + ", context=" + context + "]";
        }
    }

    private final Thread owner = Thread.currentThread();
    // The Windows identifier of the owner thread, for waking it out of a message wait.
    private final int ownerThreadId = Loader.INSTANCE.GetCurrentThreadId();
    private final Path library;
    private final Pointer module;
    private final Function[] calls = new Function[EXPORTS.length];
    private final Memory info = new Memory(CONTEXT_INFO_BYTES);
    private final Memory actions = new Memory(ACTIONS_BYTES);
    private final Memory actionsToDo = new Memory(ACTIONS_TO_DO_BYTES);
    private final Memory version = new Memory(VERSION_BYTES);
    private final Memory message = new Memory(64);
    private final IntByReference intOut = new IntByReference();
    private final LongByReference longOut = new LongByReference();
    private final Memory reply = new Memory(8);
    // Every JVM that answered for a window. The identifier is the handle of its bridge window.
    private final Set<Integer> vms = new HashSet<>();
    // Set when the library stayed loaded because unloading would wait on a silent JVM.
    private static volatile boolean detachWouldBlock;
    private boolean closed;

    private JabBridge(Path library, Pointer module) {
        this.library = library;
        this.module = module;
    }

    /** The file name of the library for this process. The legacy 32-bit ABI has no suffix and is unsupported. */
    static String libraryName(boolean sixtyFourBit) {
        return sixtyFourBit ? "WindowsAccessBridge-64.dll" : "WindowsAccessBridge-32.dll";
    }

    /**
     * An explicit path is the only candidate when given. Otherwise the runtime of this agent, then the
     * Windows system directory. The working directory and PATH are never searched.
     */
    static List<Path> candidates(String explicit, String javaHome, String systemDirectory, boolean sixtyFourBit) {
        var result = new ArrayList<Path>();
        if (explicit != null) {
            Path path = Path.of(explicit);
            if (!path.isAbsolute()) throw new Unavailable("The Java Access Bridge library path must be absolute.");
            result.add(path);
            return result;
        }
        String name = libraryName(sixtyFourBit);
        if (javaHome != null && !javaHome.isBlank()) result.add(Path.of(javaHome, "bin", name));
        if (systemDirectory != null && !systemDirectory.isBlank()) result.add(Path.of(systemDirectory, name));
        return result;
    }

    /** IMAGE_FILE_HEADER.Machine of a PE file, or 0 when the file is not a PE image. */
    static int machine(Path file) throws IOException {
        try (var image = new RandomAccessFile(file.toFile(), "r")) {
            if (image.length() < 0x40 || image.readUnsignedShort() != 0x4d5a) return 0; // "MZ"
            image.seek(0x3c);
            long header = Integer.toUnsignedLong(Integer.reverseBytes(image.readInt()));
            if (header + 6 > image.length()) return 0;
            image.seek(header);
            if (image.readInt() != 0x50450000) return 0; // "PE\0\0"
            return Short.toUnsignedInt(Short.reverseBytes(image.readShort()));
        }
    }

    static JabBridge open(String explicit) {
        if (!Platform.isWindows()) throw new Unavailable("Java Access Bridge requires Windows.");
        boolean sixtyFourBit = Native.POINTER_SIZE == 8;
        char[] system = new char[260];
        int length = Loader.INSTANCE.GetSystemDirectoryW(system, system.length);
        String systemDirectory = length > 0 && length < system.length ? new String(system, 0, length) : null;
        Path library = null;
        for (Path candidate : candidates(explicit, System.getProperty("java.home"), systemDirectory, sixtyFourBit)) {
            if (Files.isRegularFile(candidate)) {
                library = candidate;
                break;
            }
        }
        if (library == null) throw new Unavailable(explicit != null
                ? "The specified Java Access Bridge library does not exist."
                : "No " + libraryName(sixtyFourBit) + " was found in the agent runtime or the Windows system directory.");
        if (library.getFileName().toString().toLowerCase(Locale.ROOT).equals("windowsaccessbridge.dll"))
            throw new Unavailable("The legacy WindowsAccessBridge.dll ABI is not supported.");
        int machine;
        try {
            machine = machine(library);
        } catch (IOException unreadable) {
            throw new Unavailable("The Java Access Bridge library could not be read.");
        }
        if (machine != (sixtyFourBit ? 0x8664 : 0x14c))
            throw new Unavailable("The Java Access Bridge library does not match this " + (sixtyFourBit ? 64 : 32)
                    + "-bit agent process.");
        var file = new WString(library.toString());
        // The directory of the library and System32 only. Older systems lack these flags.
        Pointer module = Loader.INSTANCE.LoadLibraryExW(file, null, 0x100 | 0x800);
        if (module == null) module = Loader.INSTANCE.LoadLibraryExW(file, null, 0x8); // LOAD_WITH_ALTERED_SEARCH_PATH
        if (module == null) throw new Unavailable("Windows could not load the Java Access Bridge library.");
        var bridge = new JabBridge(library, module);
        try {
            for (int index = 0; index < EXPORTS.length; index++) {
                Pointer address = Loader.INSTANCE.GetProcAddress(module, EXPORTS[index]);
                if (address == null) throw new Unavailable("The Java Access Bridge library lacks " + EXPORTS[index] + ".");
                bridge.calls[index] = Function.getFunction(address);
            }
            bridge.calls[0].invokeVoid(new Object[0]);
            bridge.settle();
            return bridge;
        } catch (RuntimeException | Error failure) {
            bridge.close();
            throw failure;
        }
    }

    Path library() { return library; }

    private void thread() {
        if (closed || Thread.currentThread() != owner) throw new IllegalStateException("Java Access Bridge thread.");
    }

    /** Each running JVM answers the announcement of Windows_run with a posted message. */
    private void settle() {
        long started = System.nanoTime();
        long quietSince = started;
        while (true) {
            long now = System.nanoTime();
            if (pump() > 0) quietSince = now;
            if (now - started >= 2_000_000_000L || (now - started >= 200_000_000L && now - quietSince >= 100_000_000L))
                return;
            try {
                Thread.sleep(10);
            } catch (InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }

    /** Deliver queued window messages, including the announcements of JVMs that started later. */
    int pump() {
        thread();
        int delivered = 0;
        while (delivered < 4096 && Windows.INSTANCE.PeekMessageW(message, null, 0, 0, 1)) {
            Windows.INSTANCE.TranslateMessage(message);
            Windows.INSTANCE.DispatchMessageW(message);
            delivered++;
        }
        return delivered;
    }

    /** Returns when a message for this thread arrives, sent or posted, or the time has passed. */
    @Override void await(int milliseconds) {
        thread();
        // QS_ALLINPUT, MWMO_INPUTAVAILABLE
        Windows.INSTANCE.MsgWaitForMultipleObjectsEx(0, null, milliseconds, 0x04FF, 0x0004);
    }

    /** A posted WM_NULL ends the wait of the owner thread. Any thread may call this. */
    @Override void wake() {
        if (!closed) Windows.INSTANCE.PostThreadMessageW(ownerThreadId, 0, null, null);
    }

    private static Pointer window(long hwnd) { return Pointer.createConstant(hwnd); }
    private static long handle(Pointer window) { return Pointer.nativeValue(window) & 0xffff_ffffL; }

    /** Visible top-level windows in Z order, owned ones included. */
    long[] topLevelWindows(int limit) {
        thread();
        var found = new ArrayList<Long>();
        var api = Windows.INSTANCE;
        long desktop = handle(api.GetDesktopWindow());
        api.EnumWindows((candidate, data) -> {
            if (api.IsWindowVisible(candidate) && handle(api.GetAncestor(candidate, 1)) == desktop)
                found.add(handle(candidate));
            return found.size() < limit;
        }, null);
        return found.stream().mapToLong(Long::longValue).toArray();
    }

    boolean topLevel(long hwnd) {
        var api = Windows.INSTANCE;
        Pointer target = window(hwnd);
        return api.IsWindow(target) && api.IsWindowVisible(target)
                && handle(api.GetAncestor(target, 1)) == handle(api.GetDesktopWindow());
    }

    long ownerWindow(long hwnd) { return handle(Windows.INSTANCE.GetWindow(window(hwnd), 4)); }

    boolean visible(long hwnd) { return Windows.INSTANCE.IsWindowVisible(window(hwnd)); }

    int processId(long hwnd) {
        intOut.setValue(0);
        return Windows.INSTANCE.GetWindowThreadProcessId(window(hwnd), intOut) == 0 ? 0 : intOut.getValue();
    }

    int ownProcessId() { return Loader.INSTANCE.GetCurrentProcessId(); }

    /** The class of every AWT and Swing top-level window. A diagnostic hint, never a way to select a target. */
    boolean javaWindowClass(long hwnd) {
        char[] name = new char[64];
        int length = Windows.INSTANCE.GetClassNameW(window(hwnd), name, name.length);
        return length > 0 && new String(name, 0, length).startsWith("SunAwt");
    }

    static boolean detachWouldBlock() { return detachWouldBlock; }

    /** Conservative latency guard. Timing alone cannot establish that a reply arrived. */
    private static final long ANSWER_NANOS = 3_500_000_000L;

    private static void answered(long started) {
        if (System.nanoTime() - started >= ANSWER_NANOS) throw new Silent();
    }

    private int call(int export, Object... arguments) {
        thread();
        long started = System.nanoTime();
        int result = calls[export].invokeInt(arguments);
        answered(started);
        return result;
    }

    private long callLong(int export, Object... arguments) {
        thread();
        long started = System.nanoTime();
        long result = calls[export].invokeLong(arguments);
        answered(started);
        return result;
    }

    boolean javaWindow(long hwnd) { return call(1, window(hwnd)) != 0; }

    /** The caller releases the context. Null when no connected JVM owns the window. */
    Root root(long hwnd) {
        intOut.setValue(0);
        longOut.setValue(0);
        if (call(2, window(hwnd), intOut, longOut) == 0 || longOut.getValue() == 0) return null;
        vms.add(intOut.getValue());
        return new Root(intOut.getValue(), longOut.getValue());
    }

    long windowOf(int vm, long context) {
        thread();
        long started = System.nanoTime();
        long result = handle(calls[3].invokePointer(new Object[]{vm, context}));
        answered(started);
        return result;
    }

    /** The process of the bridge window that a JVM identifier names, or 0 when it names no window. */
    int vmProcessId(int vm) { return processId(Integer.toUnsignedLong(vm)); }

    /**
     * Whether the bridge thread of the JVM handles messages right now. It does not while the event
     * thread of the application is inside a bridge request, for example a click that opened a modal dialog.
     */
    boolean answering(int vm) {
        Pointer target = window(Integer.toUnsignedLong(vm));
        if (!Windows.INSTANCE.IsWindow(target)) return false;
        return Windows.INSTANCE.SendMessageTimeoutW(target, 0, null, null, 0x2, 500, reply) != null; // SMTO_ABORTIFHUNG
    }

    /** A known JVM that still exists and does not answer. Lookups by window would wait on it. */
    boolean anySilent() {
        thread();
        vms.removeIf(vm -> !Windows.INSTANCE.IsWindow(window(Integer.toUnsignedLong(vm))));
        for (int vm : vms) {
            if (!answering(vm)) return true;
        }
        return false;
    }

    /**
     * Every handle returned by the bridge is a reference in the JVM until released. The release is an
     * untimed SendMessage. Call it only for a JVM that has just answered.
     */
    void release(int vm, long context) {
        thread();
        if (context != 0) calls[4].invokeVoid(new Object[]{vm, context});
    }

    /** Releases handles while the JVM answers. Returns how many were released, in iteration order. */
    int release(int vm, List<Long> contexts) {
        int released = 0;
        for (long context : contexts) {
            if (released % 32 == 0 && !answering(vm)) break;
            release(vm, context);
            released++;
        }
        return released;
    }

    boolean same(int vm, long first, long second) { return call(5, vm, first, second) != 0; }

    /** The VM and bridge versions the JVM reports, or null. */
    String[] versions(int vm) {
        version.clear();
        if (call(6, vm, version) == 0) return null;
        var result = new String[4];
        for (int index = 0; index < 4; index++) result[index] = text(version, (long) index * SHORT_CHARS * 2, SHORT_CHARS);
        return result;
    }

    /** Null when the bridge could not read the context. Text content is never requested. */
    ContextInfo info(int vm, long context) {
        info.clear();
        if (call(7, vm, context, info) == 0) return null;
        long numbers = 2L * NAME_CHARS * 2 + 4L * SHORT_CHARS * 2;
        return new ContextInfo(text(info, 0, NAME_CHARS), text(info, 2L * NAME_CHARS * 2 + SHORT_CHARS * 2L, SHORT_CHARS),
                text(info, 2L * NAME_CHARS * 2 + 3L * SHORT_CHARS * 2, SHORT_CHARS),
                info.getInt(numbers), info.getInt(numbers + 4), info.getInt(numbers + 8), info.getInt(numbers + 12),
                info.getInt(numbers + 16), info.getInt(numbers + 20), info.getInt(numbers + 28) != 0,
                info.getInt(numbers + 36) != 0);
    }

    long child(int vm, long context, int index) { return callLong(8, vm, context, index); }

    long parent(int vm, long context) { return callLong(9, vm, context); }

    /** The action names in provider order, or null when the bridge could not read them. */
    List<String> actions(int vm, long context) {
        actions.clear();
        if (call(10, vm, context, actions) == 0) return null;
        int count = actions.getInt(0);
        if (count < 0 || count > MAX_ACTIONS) return null;
        var names = new ArrayList<String>(count);
        for (int index = 0; index < count; index++) names.add(text(actions, 4 + (long) index * SHORT_CHARS * 2, SHORT_CHARS));
        return names;
    }

    /** One named action. False means the bridge did not confirm it. */
    boolean act(int vm, long context, String action, Runnable beforeMutation) {
        if (action.isEmpty() || action.length() >= SHORT_CHARS) return false;
        actionsToDo.clear();
        actionsToDo.setInt(0, 1);
        actionsToDo.write(4, action.toCharArray(), 0, action.length());
        intOut.setValue(0);
        int result = mutation(11, "invoke", beforeMutation, vm, context, actionsToDo, intOut);
        // OpenJDK copies the failure index only after a reply. A one-action success writes -1.
        return invokeConfirmed(result, intOut.getValue());
    }

    static boolean invokeConfirmed(int result, int failureIndex) {
        return result == 1 && failureIndex == -1;
    }

    boolean setText(int vm, long context, String value, Runnable beforeMutation) {
        if (value.length() > MAX_TEXT || value.indexOf('\0') >= 0) return false;
        try (Memory text = new Memory((value.length() + 1L) * 2)) {
            text.write(0, value.toCharArray(), 0, value.length());
            text.setChar(value.length() * 2L, '\0');
            return mutation(12, "setValue", beforeMutation, vm, context, text) == 1;
        }
    }

    private int mutation(int export, String operation, Runnable beforeMutation, Object... arguments) {
        thread();
        beforeMutation.run();
        long utc = TRACE ? System.currentTimeMillis() : 0;
        long start = System.nanoTime();
        int result = calls[export].invokeInt(arguments);
        boolean overdue = System.nanoTime() - start >= ANSWER_NANOS;
        if (TRACE) System.err.println("jabNative op=" + operation + " startedEpochMs=" + utc
                + " finishedEpochMs=" + System.currentTimeMillis() + " raw=" + result
                + (export == 11 ? " failureIndex=" + intOut.getValue() : ""));
        if (overdue) throw new Silent();
        return result;
    }

    private static String text(Memory memory, long offset, int chars) {
        char[] raw = memory.getCharArray(offset, chars);
        int length = 0;
        while (length < chars && raw[length] != 0) length++;
        return new String(raw, 0, length);
    }

    /**
     * Unloading tells every connected JVM that this client left, which lets it drop the shared mapping.
     * The library does so with untimed messages, so the host must bound this call.
     */
    @Override public void close() {
        if (closed) return;
        boolean silent = anySilent();
        closed = true;
        if (silent) detachWouldBlock = true;
        else Loader.INSTANCE.FreeLibrary(module);
        reply.close();
        info.close();
        actions.close();
        actionsToDo.close();
        version.close();
        message.close();
    }
}
