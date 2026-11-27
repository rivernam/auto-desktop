package dev.desktop;

import com.sun.jna.Native;
import com.sun.jna.Pointer;
import com.sun.jna.WString;
import com.sun.jna.platform.win32.BaseTSD.SIZE_T;
import com.sun.jna.platform.win32.Kernel32;
import com.sun.jna.platform.win32.User32;
import com.sun.jna.platform.win32.WinDef.HINSTANCE;
import com.sun.jna.platform.win32.WinDef.HWND;
import com.sun.jna.platform.win32.WinDef.LPARAM;
import com.sun.jna.platform.win32.WinDef.LRESULT;
import com.sun.jna.platform.win32.WinDef.WPARAM;
import com.sun.jna.platform.win32.WinUser;
import com.sun.jna.ptr.IntByReference;
import com.sun.jna.win32.StdCallLibrary;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.locks.LockSupport;

/** A bounded paste transaction owned and pumped by the input thread. */
final class WindowsClipboard implements AutoCloseable {
    interface ClipboardApi extends StdCallLibrary {
        ClipboardApi INSTANCE = Native.load("user32", ClipboardApi.class);
        boolean OpenClipboard(HWND owner);
        boolean CloseClipboard();
        boolean EmptyClipboard();
        HWND GetClipboardOwner();
        HWND GetOpenClipboardWindow();
        int GetClipboardSequenceNumber();
        int EnumClipboardFormats(int previous);
        Pointer GetClipboardData(int format);
        Pointer SetClipboardData(int format, Pointer memory);
        boolean IsClipboardFormatAvailable(int format);
        int RegisterClipboardFormatW(WString name);
    }

    interface GlobalMemory extends StdCallLibrary {
        GlobalMemory INSTANCE = Native.load("kernel32", GlobalMemory.class);
        Pointer GlobalAlloc(int flags, SIZE_T bytes);
        SIZE_T GlobalSize(Pointer memory);
        Pointer GlobalLock(Pointer memory);
        boolean GlobalUnlock(Pointer memory);
        Pointer GlobalFree(Pointer memory);
    }

    private static final int TEXT = 13;
    private static final int WM_RENDERFORMAT = 0x0305;
    private static final int WM_RENDERALLFORMATS = 0x0306;
    private static final int WM_DESTROYCLIPBOARD = 0x0307;
    private static final int SNAPSHOT_LIMIT = 1024 * 1024;
    private static final long OPEN_NANOS = TimeUnit.MILLISECONDS.toNanos(80);
    private static final long RESTORE_NANOS = TimeUnit.MILLISECONDS.toNanos(750);
    private static final long POLL_NANOS = TimeUnit.MILLISECONDS.toNanos(2);
    private static final String OWNER_CLASS = "DesktopAgent.ClipboardOwner";
    private static final User32 USER = User32.INSTANCE;
    private static final ClipboardApi CLIP = ClipboardApi.INSTANCE;
    private static final GlobalMemory GLOBAL = GlobalMemory.INSTANCE;

    private final WinUser.WindowProc windowProc = this::onMessage;
    private final WinUser.MSG message = new WinUser.MSG();
    private final HINSTANCE instance = Kernel32.INSTANCE.GetModuleHandle(null);
    private final List<Block> original = new ArrayList<>();
    private final List<Block> privacy = new ArrayList<>();
    private final int processId;
    private final Runnable check;
    private final long deadline;
    private final String ownerClass = OWNER_CLASS + "." + Integer.toUnsignedString(Kernel32.INSTANCE.GetCurrentThreadId());
    private HWND owner;
    private Block payload;
    private boolean staged;
    private boolean armed;
    private boolean rendered;
    private boolean lost;
    private int sequence;
    private long renderUntil;
    private AgentException renderFailure;

    WindowsClipboard(int processId, Runnable check, long deadline) {
        this.processId = processId;
        this.check = check;
        this.deadline = deadline;
        WinUser.WNDCLASSEX window = new WinUser.WNDCLASSEX();
        window.cbSize = window.size();
        window.hInstance = instance;
        window.lpfnWndProc = windowProc;
        window.lpszClassName = ownerClass;
        if (USER.RegisterClassEx(window).intValue() == 0) throw unavailable();
        // HWND_MESSAGE is a signed pointer-sized pseudo-handle.
        owner = USER.CreateWindowEx(0, ownerClass, null, 0, 0, 0, 0, 0,
                new HWND(Pointer.createConstant(-3L)), null, instance, null);
        if (owner == null) {
            USER.UnregisterClass(ownerClass, instance);
            throw unavailable();
        }
    }

    private static AgentException unavailable() {
        return new AgentException("INPUT_UNAVAILABLE", "A private clipboard owner window could not be created.");
    }

    private static AgentException changed() {
        return new AgentException("CLIPBOARD_CHANGED", "Another application changed the clipboard.");
    }

    private static AgentException unsupported() {
        return new AgentException("CLIPBOARD_UNSUPPORTED", "Existing clipboard data cannot be safely restored.");
    }

    private static AgentException stagingFailed() {
        return new AgentException("INPUT_UNAVAILABLE", "The clipboard could not be prepared for paste.");
    }

    private static AgentException restoreFailed() {
        return new AgentException("CLIPBOARD_RESTORE_FAILED", "The clipboard could not be restored. Inspect its state before retrying.");
    }

    private void prepare(String text) {
        addPrivacy("ExcludeClipboardContentFromMonitorProcessing", 1);
        addPrivacy("CanIncludeInClipboardHistory", 0);
        addPrivacy("CanUploadToCloudClipboard", 0);
        payload = new Block(TEXT, (text.length() + 1L) * Character.BYTES);
        Pointer data = payload.lock();
        try {
            for (int i = 0; i < text.length(); i++) data.setShort(i * 2L, (short) text.charAt(i));
        } finally {
            GLOBAL.GlobalUnlock(payload.handle);
        }
    }

    private void addPrivacy(String name, int value) {
        int format = CLIP.RegisterClipboardFormatW(new WString(name));
        if (format == 0) throw stagingFailed();
        Block block = new Block(format, 4);
        privacy.add(block);
        Pointer data = block.lock();
        try { data.setInt(0, value); } finally { GLOBAL.GlobalUnlock(block.handle); }
    }

    void stage(String text) {
        prepare(text);
        openForPaste();
        try {
            snapshot();
            check.run();
            requireRenderBudget();
            if (!CLIP.EmptyClipboard()) throw stagingFailed();
            staged = true;
            for (Block block : privacy) if (!block.publish()) throw stagingFailed();
            CLIP.SetClipboardData(TEXT, null);
            if (!CLIP.IsClipboardFormatAvailable(TEXT)) throw stagingFailed();
        } finally {
            sequence = CLIP.GetClipboardSequenceNumber();
            CLIP.CloseClipboard();
        }
    }

    private List<Integer> formats() {
        List<Integer> formats = new ArrayList<>();
        for (int previous = 0; ; ) {
            Native.setLastError(0);
            int current = CLIP.EnumClipboardFormats(previous);
            if (current == 0) {
                if (Native.getLastError() != 0) throw unsupported();
                return formats;
            }
            if (!isSupportedFormat(current) || formats.size() == 7) throw unsupported();
            formats.add(current);
            previous = current;
        }
    }

    private boolean isSupportedFormat(int format) {
        return format == TEXT || format == 1 || format == 7 || format == 16
                || privacy.stream().anyMatch(block -> block.format == format);
    }

    private void snapshot() {
        List<Integer> formats = formats();
        if (formats.isEmpty()) return;
        if (formats.get(0) != TEXT) throw unsupported();
        HWND originalOwner = CLIP.GetClipboardOwner();
        // GetClipboardData can wait for a foreign WM_RENDERFORMAT. The API has no eager-data flag.
        if (originalOwner != null && USER.IsWindow(originalOwner)) throw unsupported();
        long remaining = SNAPSHOT_LIMIT;
        for (int format : formats) {
            int before = CLIP.GetClipboardSequenceNumber();
            Pointer source = CLIP.GetClipboardData(format);
            if (source == null || !java.util.Objects.equals(originalOwner, CLIP.GetClipboardOwner())
                    || before != CLIP.GetClipboardSequenceNumber()) throw unsupported();
            long size = GLOBAL.GlobalSize(source).longValue();
            if (size <= 0 || size > remaining) throw unsupported();
            remaining -= size;
            Block copy = new Block(format, size);
            original.add(copy);
            Pointer data = GLOBAL.GlobalLock(source);
            if (data == null) throw unsupported();
            byte[] bytes = null;
            try {
                bytes = data.getByteArray(0, (int) size);
                Pointer destination = copy.lock();
                try { destination.write(0, bytes, 0, bytes.length); }
                finally { GLOBAL.GlobalUnlock(copy.handle); }
            } finally {
                if (bytes != null) Arrays.fill(bytes, (byte) 0);
                GLOBAL.GlobalUnlock(source);
            }
        }
    }

    /** Called immediately before SendInput. Delayed rendering hands out text only after this point. */
    void arm(int timeoutMs) {
        checkOwnership();
        openForPaste();
        try {
            if (!isCurrent()) throw changed();
            sequence = CLIP.GetClipboardSequenceNumber();
        } finally {
            CLIP.CloseClipboard();
        }
        check.run();
        requireRenderBudget();
        renderUntil = Math.min(deadline - RESTORE_NANOS, System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(timeoutMs));
        armed = true;
    }

    private void openForPaste() {
        long until = System.nanoTime() + OPEN_NANOS;
        int initialSequence = CLIP.GetClipboardSequenceNumber();
        while (!CLIP.OpenClipboard(owner)) {
            check.run();
            requireRenderBudget();
            if (staged) checkOwnership();
            if (System.nanoTime() >= until) throw new AgentException("CLIPBOARD_BUSY", "Another application is holding the clipboard open.");
            if (staged) pump();
            LockSupport.parkNanos(POLL_NANOS);
        }
        if (CLIP.GetClipboardSequenceNumber() != initialSequence) {
            CLIP.CloseClipboard();
            throw changed();
        }
    }

    private void requireRenderBudget() {
        if (System.nanoTime() >= deadline - RESTORE_NANOS)
            throw new AgentException("TIMEOUT", "No time remains to paste and restore the clipboard.");
    }

    void awaitRead() {
        while (true) {
            pump();
            check.run();
            checkOwnership();
            if (renderFailure != null) throw renderFailure;
            if (rendered) return;
            if (System.nanoTime() >= renderUntil) throw new AgentException("ACTION_OUTCOME_UNKNOWN",
                    "The clipboard text was not requested in time. Inspect the target before retrying.");
            LockSupport.parkNanos(POLL_NANOS);
        }
    }

    private void pump() {
        // PeekMessage dispatches sent WM_RENDERFORMAT messages even when there is nothing posted.
        while (USER.PeekMessage(message, owner, 0, 0, 1)) USER.DispatchMessage(message);
    }

    private void checkOwnership() {
        if (lost || !owner.equals(CLIP.GetClipboardOwner())) throw changed();
    }

    // Call with the clipboard open. Windows can synthesize standard text formats on close or on read.
    private boolean isCurrent() {
        if (lost || !owner.equals(CLIP.GetClipboardOwner())) return false;
        for (Block block : privacy) {
            if (block.transferred && !block.handle.equals(CLIP.GetClipboardData(block.format))) return false;
        }
        if (rendered && !payload.handle.equals(CLIP.GetClipboardData(TEXT))) return false;
        try { formats(); }
        catch (AgentException unexpected) { return false; }
        return true;
    }

    private LRESULT onMessage(HWND hwnd, int id, WPARAM wparam, LPARAM lparam) {
        if (id == WM_DESTROYCLIPBOARD) {
            if (staged) lost = true;
            return new LRESULT(0);
        }
        if (id == WM_RENDERALLFORMATS) return new LRESULT(0);
        if (id != WM_RENDERFORMAT) return USER.DefWindowProc(hwnd, id, wparam, lparam);
        if (!armed || rendered || wparam.intValue() != TEXT || renderFailure != null
                || System.nanoTime() >= renderUntil) return new LRESULT(0);
        try {
            check.run();
            checkOwnership();
            if (CLIP.GetClipboardSequenceNumber() != sequence) throw changed();
            HWND reader = CLIP.GetOpenClipboardWindow();
            if (reader == null) return new LRESULT(0);
            IntByReference pid = new IntByReference();
            USER.GetWindowThreadProcessId(reader, pid);
            if (pid.getValue() != processId) return new LRESULT(0);
            if (!payload.publish()) throw stagingFailed();
            rendered = true;
        } catch (AgentException failure) {
            renderFailure = failure;
        }
        return new LRESULT(0);
    }

    private void restore() {
        armed = false;
        long until = Math.min(deadline - TimeUnit.MILLISECONDS.toNanos(25), System.nanoTime() + RESTORE_NANOS);
        while (!CLIP.OpenClipboard(owner)) {
            checkOwnership();
            if (System.nanoTime() >= until) throw restoreFailed();
            pump();
            LockSupport.parkNanos(POLL_NANOS);
        }
        try {
            if (!isCurrent()) throw changed();
            if (!CLIP.EmptyClipboard()) throw restoreFailed();
            boolean restored = true;
            for (Block block : original) restored &= block.publish();
            if (!restored) throw restoreFailed();
        } finally {
            CLIP.CloseClipboard();
        }
    }

    @Override public void close() {
        try {
            if (staged) restore();
        } finally {
            USER.DestroyWindow(owner);
            USER.UnregisterClass(ownerClass, instance);
            for (Block block : original) block.free();
            for (Block block : privacy) block.free();
            if (payload != null) payload.free();
        }
    }

    private static final class Block {
        final int format;
        final Pointer handle;
        boolean transferred;

        Block(int format, long size) {
            this.format = format;
            handle = GLOBAL.GlobalAlloc(0x0042, new SIZE_T(size)); // GMEM_MOVEABLE | GMEM_ZEROINIT
            if (handle == null) throw stagingFailed();
        }

        Pointer lock() {
            Pointer address = GLOBAL.GlobalLock(handle);
            if (address == null) throw stagingFailed();
            return address;
        }

        boolean publish() {
            transferred = CLIP.SetClipboardData(format, handle) != null;
            return transferred;
        }

        void free() {
            if (transferred) return;
            Pointer address = GLOBAL.GlobalLock(handle);
            if (address != null) {
                address.clear(GLOBAL.GlobalSize(handle).longValue());
                GLOBAL.GlobalUnlock(handle);
            }
            GLOBAL.GlobalFree(handle);
        }
    }
}
