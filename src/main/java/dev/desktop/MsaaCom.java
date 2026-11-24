package dev.desktop;

import com.sun.jna.Memory;
import com.sun.jna.Native;
import com.sun.jna.Pointer;
import com.sun.jna.platform.win32.Guid.GUID;
import com.sun.jna.platform.win32.Ole32;
import com.sun.jna.platform.win32.Variant.VARIANT;
import com.sun.jna.ptr.IntByReference;
import com.sun.jna.ptr.PointerByReference;
import com.sun.jna.win32.StdCallLibrary;
import java.util.ArrayList;
import java.util.List;

/** IAccessible ABI from oleacc.h. All objects and buffers belong to one MTA owner thread. */
final class MsaaCom implements AutoCloseable {
    static final int PAGE_SIZE = 32;
    static final int TEXT_LIMIT = 1024;
    private static final GUID ACCESSIBLE = new GUID("{618736E0-3C3D-11CF-810C-00AA00389B71}");
    private static final GUID IDENTITY = new GUID("{7852B78D-1CFD-41C1-A615-9C0C85960B5F}");
    private static final GUID PROP_SERVICES_CLASS = new GUID("{B5F8350B-0548-48B1-A6EE-88BD00B4A5E7}");
    private static final GUID PROP_SERVICES = new GUID("{6E26E776-04F0-495D-80E4-3330352E3169}");
    private static final int E_INVALIDARG = 0x80070057;
    private static final int VT_I4 = 3;
    private static final int VT_DISPATCH = 9;

    public interface Oleacc extends StdCallLibrary {
        Oleacc INSTANCE = Native.load("oleacc", Oleacc.class);
        int AccessibleObjectFromWindow(Pointer window, int objectId, GUID iid, PointerByReference result);
        int AccessibleChildren(Pointer object, int start, int count, Pointer children, IntByReference obtained);
        int WindowFromAccessibleObject(Pointer object, PointerByReference window);
    }

    public interface Oleaut extends StdCallLibrary {
        Oleaut INSTANCE = Native.load("oleaut32", Oleaut.class);
        int VariantClear(Pointer variant);
    }

    static final class Ref implements AutoCloseable {
        private Pointer pointer;
        private Ref(Pointer pointer) { this.pointer = pointer; }

        Ref copy() {
            UiaCom.vcall(pointer, 1); // AddRef
            return new Ref(pointer);
        }

        @Override public void close() {
            if (pointer != null) {
                Pointer released = pointer;
                pointer = null;
                UiaCom.vcall(released, 2); // Release
            }
        }
    }

    record Node(Ref ref, int child, int enumeratedId) implements AutoCloseable {
        Node copy() { return new Node(ref.copy(), child, enumeratedId); }
        @Override public void close() { ref.close(); }
    }

    record Children(List<Node> nodes, boolean incomplete, int obtained) implements AutoCloseable {
        @Override public void close() {
            for (Node node : nodes) if (node != null) node.close();
        }
    }

    record Name(String text, boolean clipped) {}

    private final VARIANT.ByValue childArg = new VARIANT.ByValue();
    private final int variantSize = childArg.size();
    private final Memory variantOut = new Memory(variantSize);
    private final Memory page = new Memory((long) PAGE_SIZE * variantSize);
    private final PointerByReference pointer = new PointerByReference();
    private final IntByReference integer = new IntByReference();
    private final IntByReference x = new IntByReference();
    private final IntByReference y = new IntByReference();
    private final IntByReference width = new IntByReference();
    private final IntByReference height = new IntByReference();
    private Ref propertyServices;

    MsaaCom() {
        try {
            // Load the DLLs before entering the apartment so initialization failure leaves no COM registration.
            if (Oleacc.INSTANCE == null || Oleaut.INSTANCE == null
                    || Ole32.INSTANCE.CoInitializeEx(null, Ole32.COINIT_MULTITHREADED).intValue() < 0)
                throw new AgentException("BACKEND_UNAVAILABLE", "Could not initialize Microsoft Active Accessibility.");
        } catch (RuntimeException | Error failure) {
            page.close();
            variantOut.close();
            throw failure;
        }
    }

    static boolean timeout(int hr) { return hr == 0x8001011f || hr == 0x800705b4; }

    private static boolean ok(int hr) {
        if (timeout(hr)) throw new AgentException("TIMEOUT", "The native Microsoft Active Accessibility call timed out.");
        return hr == 0;
    }

    private VARIANT.ByValue arg(int child) {
        childArg.setValue(VT_I4, new com.sun.jna.platform.win32.WinDef.LONG(child));
        return childArg;
    }

    private PointerByReference pointerOut() {
        pointer.setValue(null);
        return pointer;
    }

    private IntByReference integerOut() {
        integer.setValue(0);
        return integer;
    }

    private Ref owned(int hr) {
        try {
            if (ok(hr) && pointer.getValue() != null) {
                Ref result = new Ref(pointer.getValue());
                pointer.setValue(null);
                return result;
            }
            return null;
        } finally {
            if (pointer.getValue() != null) UiaCom.vcall(pointer.getValue(), 2);
        }
    }

    private Ref query(Pointer object, GUID iid) {
        return owned(UiaCom.vcall(object, 0, iid, pointerOut())); // QueryInterface
    }

    Node fromWindow(long window) {
        var ref = owned(Oleacc.INSTANCE.AccessibleObjectFromWindow(handle(window), -4, ACCESSIBLE, pointerOut()));
        return ref == null ? null : new Node(ref, 0, 0); // OBJID_CLIENT, CHILDID_SELF
    }

    long sourceWindow(Node node) {
        return ok(Oleacc.INSTANCE.WindowFromAccessibleObject(node.ref.pointer, pointerOut()))
                ? number(pointer.getValue()) : 0;
    }

    static Pointer handle(long hwnd) { return Pointer.createConstant(hwnd); }
    static long number(Pointer hwnd) { return Pointer.nativeValue(hwnd) & 0xffff_ffffL; }

    int count(Node node) {
        if (node.child != 0) return 0;
        return ok(UiaCom.vcall(node.ref.pointer, 8, integerOut())) && integer.getValue() >= 0
                ? integer.getValue() : -1;
    }

    Children children(Node node, int start, int count) {
        return children(node, start, count, -1);
    }

    Children children(Node node, int start, int count, int selected) {
        page.clear();
        var children = new ArrayList<Node>(selected < 0 ? count : 1);
        boolean transferred = false;
        try {
            int hr = Oleacc.INSTANCE.AccessibleChildren(node.ref.pointer, start, count, page, integerOut());
            boolean complete = ok(hr);
            int obtained = integer.getValue();
            if (hr < 0 || obtained < 0 || obtained > count) return new Children(List.of(), true, 0);
            for (int i = 0; i < obtained; i++) {
                if (selected >= 0 && i != selected) continue;
                Pointer item = page.share((long) i * variantSize);
                int kind = item.getShort(0);
                // Windows VARIANT's discriminant and data union are at offsets 0 and 8 on x86/x64.
                Node child = null;
                if (kind == VT_I4 && item.getInt(8) > 0) {
                    int id = item.getInt(8);
                    try (var dispatch = owned(UiaCom.vcall(node.ref.pointer, 9, arg(id), pointerOut()))) {
                        Ref ref = dispatch == null ? null : query(dispatch.pointer, ACCESSIBLE);
                        child = ref == null ? new Node(node.ref.copy(), id, id) : new Node(ref, 0, id);
                    }
                } else if (kind == VT_DISPATCH && item.getPointer(8) != null) {
                    Ref ref = query(item.getPointer(8), ACCESSIBLE);
                    if (ref != null) child = new Node(ref, 0, 0);
                }
                children.add(child);
            }
            transferred = true;
            return new Children(children, !complete || obtained != count, obtained);
        } finally {
            for (int i = 0; i < count; i++) Oleaut.INSTANCE.VariantClear(page.share((long) i * variantSize));
            if (!transferred) new Children(children, true, 0).close();
        }
    }

    private int property(Node node, int slot) {
        variantOut.clear();
        try {
            int hr = UiaCom.vcall(node.ref.pointer, slot, arg(node.child), variantOut);
            return ok(hr) && variantOut.getShort(0) == VT_I4 && variantOut.getInt(8) >= 0
                    ? variantOut.getInt(8) : -1;
        } finally { Oleaut.INSTANCE.VariantClear(variantOut); }
    }

    int role(Node node) { return property(node, 13); }
    int state(Node node) { return property(node, 14); }

    private Pointer string(Node node, int slot) {
        int hr = UiaCom.vcall(node.ref.pointer, slot, arg(node.child), pointerOut());
        Pointer bstr = pointer.getValue();
        boolean transfer = false;
        try {
            transfer = ok(hr);
            return transfer ? bstr : null;
        } finally {
            if (!transfer && bstr != null) UiaCom.AutomationApi.INSTANCE.SysFreeString(bstr);
        }
    }

    Name name(Node node) {
        Pointer bstr = string(node, 10);
        if (bstr == null) return new Name("", false);
        try {
            int size = UiaCom.AutomationApi.INSTANCE.SysStringLen(bstr);
            return new Name(UiaCom.utf16(bstr, Math.min(size, TEXT_LIMIT)), size > TEXT_LIMIT);
        } finally { UiaCom.AutomationApi.INSTANCE.SysFreeString(bstr); }
    }

    boolean hasDefaultAction(Node node) {
        Pointer bstr = string(node, 20);
        if (bstr == null) return false;
        try { return UiaCom.AutomationApi.INSTANCE.SysStringLen(bstr) != 0; }
        finally { UiaCom.AutomationApi.INSTANCE.SysFreeString(bstr); }
    }

    int[] bounds(Node node) {
        x.setValue(0);
        y.setValue(0);
        width.setValue(0);
        height.setValue(0);
        return ok(UiaCom.vcall(node.ref.pointer, 22, x, y, width, height, arg(node.child)))
                && width.getValue() > 0 && height.getValue() > 0
                ? new int[]{x.getValue(), y.getValue(), width.getValue(), height.getValue()} : null;
    }

    boolean opaqueIdentity(byte[] bytes) {
        if (propertyServices == null) {
            int hr = Ole32.INSTANCE.CoCreateInstance(PROP_SERVICES_CLASS, null, 1, PROP_SERVICES, pointerOut()).intValue();
            propertyServices = owned(hr);
            if (propertyServices == null) return false;
        }
        try (Memory buffer = new Memory(bytes.length)) {
            buffer.write(0, bytes, 0, bytes.length);
            // Classify with the system APIs. Accept neither HWND-based nor HMENU-based identities.
            int hwnd = UiaCom.vcall(propertyServices.pointer, 11, buffer, bytes.length, pointerOut(), x, y);
            if (hwnd != E_INVALIDARG) { ok(hwnd); return false; }
            int menu = UiaCom.vcall(propertyServices.pointer, 17, buffer, bytes.length, pointerOut(), x);
            if (menu != E_INVALIDARG) { ok(menu); return false; }
            return true;
        }
    }

    byte[] identityBytes(Node node) {
        try (Ref identity = query(node.ref.pointer, IDENTITY)) {
            if (identity == null) return null;
            int hr = UiaCom.vcall(identity.pointer, 3, 0, pointerOut(), integerOut());
            Pointer bytes = pointer.getValue();
            int length = integer.getValue();
            try { return ok(hr) && bytes != null && length > 0 && length <= 4096 ? bytes.getByteArray(0, length) : null; }
            finally { if (bytes != null) Ole32.INSTANCE.CoTaskMemFree(bytes); }
        }
    }

    static final class Text implements AutoCloseable {
        private final Pointer bstr;
        Text(String value) {
            try (Memory units = new Memory(Math.max(2L, 2L * value.length()))) {
                for (int i = 0; i < value.length(); i++) units.setChar(2L * i, value.charAt(i));
                bstr = UiaCom.AutomationApi.INSTANCE.SysAllocStringLen(units, value.length());
                if (bstr == null) throw new AgentException("INTERNAL_ERROR", "Could not prepare the native value.");
            }
        }
        @Override public void close() { UiaCom.AutomationApi.INSTANCE.SysFreeString(bstr); }
    }

    int mutate(Node original, DesktopAction action, Text text) {
        Pointer object = original.ref.pointer;
        return switch (action) {
            case DEFAULT_ACTION -> UiaCom.vcall(object, 25, arg(0));
            case SELECT -> UiaCom.vcall(object, 21, 2, arg(0)); // SELFLAG_TAKESELECTION
            case SET_VALUE -> UiaCom.vcall(object, 27, arg(0), text.bstr);
            default -> throw new IllegalArgumentException("Expected an MSAA action.");
        };
    }

    @Override public void close() {
        try { if (propertyServices != null) propertyServices.close(); }
        finally {
            page.close();
            variantOut.close();
            Ole32.INSTANCE.CoUninitialize();
        }
    }
}
