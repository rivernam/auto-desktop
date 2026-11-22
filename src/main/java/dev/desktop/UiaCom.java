package dev.desktop;

import com.sun.jna.Function;
import com.sun.jna.Memory;
import com.sun.jna.Native;
import com.sun.jna.Platform;
import com.sun.jna.Pointer;
import com.sun.jna.platform.win32.Guid.GUID;
import com.sun.jna.platform.win32.Kernel32;
import com.sun.jna.platform.win32.Ole32;
import com.sun.jna.ptr.IntByReference;
import com.sun.jna.ptr.PointerByReference;
import com.sun.jna.win32.StdCallLibrary;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

/** Base interfaces in Windows SDK UIAutomationClient.h. One owning MTA thread. */
final class UiaCom implements AutoCloseable {
    private static final GUID CLSID = new GUID("{FF48DBA4-60EF-4201-AA87-54103EEF594E}");
    private static final GUID IID = new GUID("{30CBE57D-D9D0-452A-AB13-7AC5AC4825EE}");
    private static final GUID INVOKE = new GUID("{FB377FBE-8EA6-46D5-9C73-6499642D3059}");
    private static final GUID VALUE = new GUID("{A94CD8B1-0844-4CD6-9D2D-640537AB39E9}");
    private static final int E_FAIL = 0x80004005;

    public interface DesktopApi extends StdCallLibrary {
        DesktopApi INSTANCE = Native.load("user32", DesktopApi.class);
        Pointer GetProcessWindowStation();
        Pointer GetThreadDesktop(int id);
        Pointer OpenInputDesktop(int flags, int inherit, int access);
        int CloseDesktop(Pointer desktop);
        int GetUserObjectInformationW(Pointer obj, int index, Pointer data, int bytes, IntByReference used);
    }

    public interface AutomationApi extends StdCallLibrary {
        AutomationApi INSTANCE = Native.load("oleaut32", AutomationApi.class);
        int SysStringLen(Pointer bstr);
        Pointer SysAllocStringLen(Pointer text, int chars);
        void SysFreeString(Pointer bstr);
        int SafeArrayGetDim(Pointer array);
        int SafeArrayGetElemsize(Pointer array);
        int SafeArrayGetVartype(Pointer array, Pointer type);
        int SafeArrayGetLBound(Pointer array, int dim, IntByReference result);
        int SafeArrayGetUBound(Pointer array, int dim, IntByReference result);
        int SafeArrayAccessData(Pointer array, PointerByReference data);
        int SafeArrayUnaccessData(Pointer array);
        int SafeArrayDestroy(Pointer array);
    }

    static final class ComFailure extends RuntimeException {
        final int hresult;
        ComFailure(int hr) {
            super("Windows UI Automation call failed (HRESULT 0x" + Integer.toHexString(hr) + ").");
            hresult = hr;
        }
    }

    private final Thread owner = Thread.currentThread();
    private final Set<Ref> owned = new HashSet<>();
    private Ref client, walker;
    private boolean closed;
    private UiaCom() {}

    static UiaCom open() {
        if (!Platform.isWindows()) throw new ComFailure(E_FAIL);
        UiaCom com = new UiaCom();
        com.checkDesktop();
        checked(Ole32.INSTANCE.CoInitializeEx(null, Ole32.COINIT_MULTITHREADED).intValue());
        try {
            var out = new PointerByReference();
            checked(Ole32.INSTANCE.CoCreateInstance(CLSID, null, 1, IID, out).intValue());
            com.client = com.new Ref(out.getValue());
            com.walker = com.output(com.client, 14, false); // get_ControlViewWalker
            return com;
        } catch (RuntimeException | Error ex) {
            com.close();
            throw ex;
        }
    }

    void checkDesktop() {
        thread();
        var kernel = Kernel32.INSTANCE;
        var api = DesktopApi.INSTANCE;
        var session = new IntByReference();
        if (!kernel.ProcessIdToSessionId(kernel.GetCurrentProcessId(), session) || session.getValue() == 0)
            throw new ComFailure(E_FAIL);
        try (Memory flags = new Memory(12)) {
            if (api.GetUserObjectInformationW(api.GetProcessWindowStation(), 1, flags, 12, new IntByReference()) == 0
                    || (flags.getInt(8) & 1) == 0) throw new ComFailure(E_FAIL);
        }
        Pointer input = api.OpenInputDesktop(0, 0, 0x41); // DESKTOP_ENUMERATE | DESKTOP_READOBJECTS
        if (input == null) throw new ComFailure(E_FAIL);
        try {
            if (!desktopName(input).equals(desktopName(api.GetThreadDesktop(kernel.GetCurrentThreadId()))))
                throw new ComFailure(E_FAIL);
        } finally { api.CloseDesktop(input); }
    }

    private static String desktopName(Pointer desktop) {
        try (Memory buffer = new Memory(512)) {
            var used = new IntByReference();
            if (desktop == null || DesktopApi.INSTANCE.GetUserObjectInformationW(desktop, 2, buffer, 512, used) == 0)
                throw new ComFailure(E_FAIL);
            int size = used.getValue();
            if (size < 2 || size > 512 || size % 2 != 0 || buffer.getShort(size - 2) != 0)
                throw new ComFailure(E_FAIL);
            return utf16(buffer, size / 2 - 1);
        }
    }

    final class Ref implements AutoCloseable {
        private Pointer ptr;
        private Ref(Pointer ptr) {
            if (ptr == null) throw new ComFailure(E_FAIL);
            this.ptr = ptr;
            owned.add(this);
        }
        private Pointer pointer() {
            thread();
            if (ptr == null) throw new IllegalStateException("Released UI Automation reference.");
            return ptr;
        }
        @Override public void close() {
            thread();
            if (ptr != null) {
                Pointer previous = ptr;
                ptr = null;
                owned.remove(this);
                vcall(previous, 2); // IUnknown::Release returns ULONG
            }
        }
    }

    private void thread() {
        if (Thread.currentThread() != owner) throw new IllegalStateException("Wrong COM apartment thread.");
    }

    @Override public void close() {
        thread();
        if (closed) return;
        try {
            for (Ref ref : owned.toArray(Ref[]::new)) ref.close();
        } finally {
            closed = true;
            Ole32.INSTANCE.CoUninitialize();
        }
    }

    static void checked(int hr) { if (hr < 0) throw new ComFailure(hr); }

    private static int vcall(Pointer self, int slot, Object... args) {
        Pointer address = self.getPointer(0).getPointer((long) slot * Native.POINTER_SIZE);
        Object[] nativeArgs = new Object[args.length + 1];
        nativeArgs[0] = self;
        System.arraycopy(args, 0, nativeArgs, 1, args.length);
        int convention = Platform.isWindows() ? Function.ALT_CONVENTION : Function.C_CONVENTION;
        return Function.getFunction(address, convention).invokeInt(nativeArgs);
    }

    private Ref output(Ref object, int slot, boolean nullable, Object... args) {
        var out = new PointerByReference();
        Object[] call = Arrays.copyOf(args, args.length + 1);
        call[args.length] = out;
        checked(vcall(object.pointer(), slot, call));
        return nullable && out.getValue() == null ? null : new Ref(out.getValue());
    }

    Ref root() { return output(client, 5, false); }
    Ref fromHandle(long hwnd) { return output(client, 6, false, Pointer.createConstant(hwnd)); }
    Ref parent(Ref node) { return output(walker, 3, true, node.pointer()); }
    Ref firstChild(Ref node) { return output(walker, 4, true, node.pointer()); }
    Ref nextSibling(Ref node) { return output(walker, 6, true, node.pointer()); }
    boolean same(Ref a, Ref b) {
        var out = new IntByReference();
        checked(vcall(client.pointer(), 3, a.pointer(), b.pointer(), out));
        return out.getValue() != 0;
    }

    int[] runtimeId(Ref node) {
        var out = new PointerByReference();
        checked(vcall(node.pointer(), 4, out));
        Pointer array = out.getValue();
        if (array == null) throw new ComFailure(E_FAIL);
        var api = AutomationApi.INSTANCE;
        try (Memory type = new Memory(2)) {
            if (api.SafeArrayGetDim(array) != 1 || api.SafeArrayGetElemsize(array) != 4)
                throw new ComFailure(E_FAIL);
            checked(api.SafeArrayGetVartype(array, type));
            if (type.getShort(0) != 3) throw new ComFailure(E_FAIL); // VT_I4
            var lower = new IntByReference();
            var upper = new IntByReference();
            checked(api.SafeArrayGetLBound(array, 1, lower));
            checked(api.SafeArrayGetUBound(array, 1, upper));
            long length = (long) upper.getValue() - lower.getValue() + 1;
            if (length < 1 || length > 4096) throw new ComFailure(E_FAIL);
            var data = new PointerByReference();
            checked(api.SafeArrayAccessData(array, data));
            try {
                if (data.getValue() == null) throw new ComFailure(E_FAIL);
                return data.getValue().getIntArray(0, (int) length);
            } finally { checked(api.SafeArrayUnaccessData(array)); }
        } finally { checked(api.SafeArrayDestroy(array)); }
    }

    private int integer(Ref node, int slot) {
        var out = new IntByReference();
        checked(vcall(node.pointer(), slot, out));
        return out.getValue();
    }

    private String string(Ref node, int slot) {
        var out = new PointerByReference();
        checked(vcall(node.pointer(), slot, out));
        Pointer bstr = out.getValue();
        if (bstr == null) return "";
        var api = AutomationApi.INSTANCE;
        try {
            // The session clips at 256 units and needs one extra unit to detect truncation.
            int chars = (int) Math.min(257L, Integer.toUnsignedLong(api.SysStringLen(bstr)));
            return utf16(bstr, chars);
        } finally { api.SysFreeString(bstr); }
    }

    static String utf16(Pointer buffer, int chars) {
        char[] units = new char[chars];
        for (int i = 0; i < chars; i++) units[i] = (char) buffer.getShort(2L * i);
        return new String(units);
    }

    int pid(Ref node) { return integer(node, 20); }
    int controlType(Ref node) { return integer(node, 21); }
    String name(Ref node) { return string(node, 23); }
    boolean enabled(Ref node) { return integer(node, 28) != 0; }
    String automationId(Ref node) { return string(node, 29); }
    String className(Ref node) { return string(node, 30); }
    boolean password(Ref node) { return integer(node, 35) != 0; }
    boolean offscreen(Ref node) { return integer(node, 38) != 0; }

    long hwnd(Ref node) {
        var out = new PointerByReference(); // UIA_HWND is a void*, including on Win64
        checked(vcall(node.pointer(), 36, out));
        return Pointer.nativeValue(out.getValue()) & 0xffff_ffffL;
    }

    int[] bounds(Ref node) {
        try (Memory rect = new Memory(16)) {
            checked(vcall(node.pointer(), 43, rect));
            return rect.getIntArray(0, 4);
        }
    }

    private Ref pattern(Ref node, int id, GUID iid) {
        var out = new PointerByReference();
        int hr = vcall(node.pointer(), 14, id, iid, out); // GetCurrentPatternAs
        if (hr == 0x80040204 || hr == 0x80004002) return null; // UIA_E_NOTSUPPORTED, E_NOINTERFACE
        checked(hr);
        return out.getValue() == null ? null : new Ref(out.getValue());
    }

    Ref invokePattern(Ref node) { return pattern(node, 10000, INVOKE); }
    Ref valuePattern(Ref node) { return pattern(node, 10002, VALUE); }
    boolean readOnly(Ref pattern) { return integer(pattern, 5) != 0; }
    void invoke(Ref pattern, Runnable beforeMutation) {
        beforeMutation.run();
        checked(vcall(pattern.pointer(), 3));
    }

    void setValue(Ref pattern, String value, Runnable beforeMutation) {
        var api = AutomationApi.INSTANCE;
        try (Memory text = new Memory((value.length() + 1L) * 2)) {
            try {
                for (int i = 0; i < value.length(); i++) text.setShort(2L * i, (short) value.charAt(i));
                Pointer bstr = api.SysAllocStringLen(text, value.length());
                if (bstr == null) throw new ComFailure(0x8007000e);
                try {
                    beforeMutation.run();
                    checked(vcall(pattern.pointer(), 3, bstr));
                }
                finally { api.SysFreeString(bstr); }
            } finally { text.clear(); }
        }
    }
}
