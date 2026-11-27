package dev.desktop;

import com.sun.jna.Native;
import com.sun.jna.Pointer;
import com.sun.jna.platform.win32.User32;
import com.sun.jna.platform.win32.WinDef.HKL;
import com.sun.jna.platform.win32.WinDef.HWND;
import com.sun.jna.win32.StdCallLibrary;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/** A checked plan for typing against the layout of the focused window's thread. */
final class WindowsTextLayout {
    interface Natives extends StdCallLibrary {
        Natives INSTANCE = Native.load("user32", Natives.class);
        short VkKeyScanExW(char character, HKL layout);
        int MapVirtualKeyExW(int code, int mapType, HKL layout);
        int ToUnicodeEx(int virtualKey, int scanCode, byte[] keys, char[] chars, int size, int flags, HKL layout);
        short GetKeyState(int virtualKey);
    }

    static final class Stroke {
        final int virtualKey;
        final int scanCode;
        final boolean extended;
        final boolean shift;

        Stroke(int virtualKey, int scanCode, boolean extended, boolean shift) {
            this.virtualKey = virtualKey;
            this.scanCode = scanCode;
            this.extended = extended;
            this.shift = shift;
        }
    }

    private static final int VK_CAPITAL = 0x14;
    private static final int MAPVK_VK_TO_VSC_EX = 4;
    private static final int TO_UNICODE_NO_STATE_CHANGE = 4;

    private final HKL layout;
    private final Stroke shift;
    private final List<Stroke> strokes;

    private WindowsTextLayout(HKL layout, Stroke shift, List<Stroke> strokes) {
        this.layout = layout;
        this.shift = shift;
        this.strokes = strokes;
    }

    static WindowsTextLayout prepare(HWND focus, List<InputKeys.Unit> text) {
        verifyModifierState();
        HKL layout = layoutOf(focus);
        Stroke shift = scan(InputKeys.VK_SHIFT, false, layout);
        byte[] keys = new byte[256];
        char[] converted = new char[8];
        List<Stroke> strokes = new ArrayList<>(text.size());
        Map<Character, Stroke> mapped = new HashMap<>();
        for (InputKeys.Unit unit : text) {
            if (unit.key != null) {
                strokes.add(scan(unit.key.vk, false, layout));
            } else {
                strokes.add(mapped.computeIfAbsent(unit.character, character -> printable(character, layout, keys, converted)));
            }
        }
        return new WindowsTextLayout(layout, shift, strokes);
    }

    void verify(HWND focus) {
        verifyModifierState();
        if (!layout.equals(layoutOf(focus)))
            throw InputException.refused("PRECONDITION_FAILED", "The target keyboard layout changed.");
    }

    Stroke shift() { return shift; }

    Stroke stroke(int index) { return strokes.get(index); }

    private static HKL layoutOf(HWND focus) {
        int thread = User32.INSTANCE.GetWindowThreadProcessId(focus, null);
        HKL layout = thread == 0 ? null : User32.INSTANCE.GetKeyboardLayout(thread);
        if (layout == null || Pointer.nativeValue(layout.getPointer()) == 0)
            throw InputException.refused("PRECONDITION_FAILED", "The target keyboard layout is unavailable.");
        return layout;
    }

    private static void verifyModifierState() {
        if ((Natives.INSTANCE.GetKeyState(VK_CAPITAL) & 1) != 0)
            throw InputException.refused("PRECONDITION_FAILED", "Caps Lock must be off for layout-based typing.");
        for (int key : new int[] {InputKeys.VK_SHIFT, InputKeys.VK_CONTROL, InputKeys.VK_MENU, 0x5B, 0x5C}) {
            if (User32.INSTANCE.GetAsyncKeyState(key) < 0)
                throw InputException.refused("USER_INPUT_CONFLICT", "A modifier key is held down.");
        }
    }

    private static Stroke printable(char character, HKL layout, byte[] keys, char[] converted) {
        int combination = Short.toUnsignedInt(Natives.INSTANCE.VkKeyScanExW(character, layout));
        if (combination == 0xFFFF || (combination & 0xFE00) != 0)
            throw layoutFailure();
        int virtualKey = combination & 0xFF;
        // A printable mapping may need Shift, but never authorize a shell or state-changing key.
        if (virtualKey <= InputKeys.VK_ESCAPE || virtualKey == VK_CAPITAL || virtualKey == 0x2C
                || virtualKey == 0x5B || virtualKey == 0x5C || virtualKey == 0x5D
                || virtualKey == 0x5F || virtualKey == 0x90 || virtualKey == 0x91 || virtualKey == 0xE7)
            throw layoutFailure();
        Stroke stroke = scan(virtualKey, (combination & 0x100) != 0, layout);
        keys[InputKeys.VK_SHIFT] = stroke.shift ? (byte) 0x80 : 0;
        int count = Natives.INSTANCE.ToUnicodeEx(virtualKey, stroke.scanCode, keys, converted, converted.length,
                TO_UNICODE_NO_STATE_CHANGE, layout);
        if (count != 1 || converted[0] != character) throw layoutFailure();
        return stroke;
    }

    private static Stroke scan(int virtualKey, boolean shift, HKL layout) {
        int scan = Natives.INSTANCE.MapVirtualKeyExW(virtualKey, MAPVK_VK_TO_VSC_EX, layout);
        int prefix = scan & ~0xFF;
        if (scan == 0 || (prefix != 0 && prefix != 0xE000)) throw layoutFailure();
        return new Stroke(virtualKey, scan & 0xFF, prefix == 0xE000, shift);
    }

    private static InputException layoutFailure() {
        return InputException.refused("PRECONDITION_FAILED", "The target keyboard layout cannot type the requested text directly.");
    }
}
