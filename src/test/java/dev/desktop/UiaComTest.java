package dev.desktop;

import static org.junit.jupiter.api.Assertions.*;

import com.sun.jna.Callback;
import com.sun.jna.CallbackReference;
import com.sun.jna.Memory;
import com.sun.jna.Native;
import com.sun.jna.Platform;
import com.sun.jna.Pointer;
import com.sun.jna.win32.StdCallLibrary.StdCallCallback;
import java.lang.ref.Reference;
import java.util.concurrent.atomic.AtomicInteger;
import org.junit.jupiter.api.Test;

class UiaComTest {
    interface Getter extends Callback { int invoke(Pointer self, Pointer out); }
    interface Release extends Callback { int invoke(Pointer self); }
    interface GetPattern extends Callback { int invoke(Pointer self, int id, Pointer iid, Pointer out); }
    interface WindowsPattern extends GetPattern, StdCallCallback {}
    interface WindowsGetter extends Getter, StdCallCallback {}
    interface WindowsRelease extends Release, StdCallCallback {}

    @Test void providerStringsPreserveEmbeddedNullAndSupplementaryCharacters() {
        String value = "한\u0000\uD83D\uDE00";
        try (Memory buffer = new Memory(value.length() * 2L)) {
            for (int i = 0; i < value.length(); i++) buffer.setShort(2L * i, (short) value.charAt(i));
            assertEquals(value, UiaCom.utf16(buffer, value.length()));
        }
    }

    @Test void onlyFailedHresultsThrow() {
        UiaCom.checked(0);
        UiaCom.checked(1);
        int hr = 0x80040201;
        assertEquals(hr, assertThrows(UiaCom.ComFailure.class, () -> UiaCom.checked(hr)).hresult);
    }

    // A native-memory object with real callable function pointers exercises slot width, the
    // implicit this pointer, signed RECT fields, and owned Release without opening a COM apartment.
    @Test void invokesMockVtableAndReleasesEachOwnedPointerOnce() throws Exception {
        var sessionCtor = UiaCom.class.getDeclaredConstructor();
        sessionCtor.setAccessible(true);
        var session = sessionCtor.newInstance();
        var refCtor = UiaCom.Ref.class.getDeclaredConstructor(UiaCom.class, Pointer.class);
        refCtor.setAccessible(true);
        try (Memory table = new Memory(44L * Native.POINTER_SIZE);
             Memory object = new Memory(Native.POINTER_SIZE)) {
            object.setPointer(0, table);
            AtomicInteger releases = new AtomicInteger();
            Getter getPid = (self, out) -> {
                if (!self.equals(object)) return 0x80004005;
                out.setInt(0, 777);
                return 0;
            };
            Getter getRect = (self, out) -> {
                out.write(0, new int[] {-100, -2, 900, 1000}, 0, 4);
                return 0;
            };
            GetPattern getPattern = (self, id, iid, out) -> {
                if (id == 10000 && iid.getInt(0) == 0xfb377fbe) {
                    out.setPointer(0, self);
                    return 0;
                }
                if (id == 10002 && iid.getInt(0) == 0xa94cd8b1) return 0x80040204;
                return 0x80004005;
            };
            Release release = self -> releases.incrementAndGet();
            Callback pidFn = Platform.isWindows() ? (WindowsGetter) getPid::invoke : getPid;
            Callback rectFn = Platform.isWindows() ? (WindowsGetter) getRect::invoke : getRect;
            Callback releaseFn = Platform.isWindows() ? (WindowsRelease) release::invoke : release;
            Callback patternFn = Platform.isWindows() ? (WindowsPattern) getPattern::invoke : getPattern;
            table.setPointer(14L * Native.POINTER_SIZE, CallbackReference.getFunctionPointer(patternFn));
            table.setPointer(20L * Native.POINTER_SIZE, CallbackReference.getFunctionPointer(pidFn));
            table.setPointer(43L * Native.POINTER_SIZE, CallbackReference.getFunctionPointer(rectFn));
            table.setPointer(2L * Native.POINTER_SIZE, CallbackReference.getFunctionPointer(releaseFn));
            UiaCom.Ref ref = refCtor.newInstance(session, object);
            try (ref) {
                assertEquals(777, session.pid(ref));
                try (UiaCom.Ref supported = session.invokePattern(ref)) { assertNotNull(supported); }
                assertNull(session.valuePattern(ref));
                assertArrayEquals(new int[] {-100, -2, 900, 1000}, session.bounds(ref));
            }
            ref.close();
            assertEquals(2, releases.get());
            assertThrows(IllegalStateException.class, () -> session.pid(ref));
            Reference.reachabilityFence(patternFn);
            Reference.reachabilityFence(pidFn);
            Reference.reachabilityFence(rectFn);
            Reference.reachabilityFence(releaseFn);
        }
    }
}
