# Windows-only probe. Inputs are fixed synthetic samples directed at newly launched test fixtures.
[CmdletBinding()]
param(
    [switch]$Interactive,
    [ValidateSet('AwtField','AwtArea','Swing','WinForms','Win32')]
    [string[]]$Fixture = @('AwtField','AwtArea','Swing','WinForms','Win32'),
    [ValidateSet('unicode','virtualKey','scanCode','clipboard','wmChar')]
    [string[]]$Method = @('unicode','virtualKey','scanCode','clipboard','wmChar'),
    [ValidateSet('Direct','Java','Cpp')]
    [string]$Agent = 'Direct',
    [string]$JavaExe = 'java.exe',
    [string]$Jar = 'target/desktop-agent.jar',
    [string]$CppAgent = 'target/cpp-agent/Release/cpp-agent.exe',
    [string]$FixtureJava = 'java.exe',
    [string]$JavaClasses = 'target/text-input-fixture',
    [string]$WinForms = 'target/framework-fixtures/winforms-framework.exe',
    [string]$Win32 = 'target/framework-fixtures/win32.exe',
    [string]$OutputPath = 'target/text-input-compatibility.json',
    [ValidateRange(5,600)][int]$CountdownSeconds = 30
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UiaTest.Common.ps1')
$samples = [ordered]@{
    English = ' Az19 '
    Korean = ' ' + [char]0xd55c + [char]0xae00 + ' '
    Unicode = ' ' + [char]0x03a9 + [char]::ConvertFromUtf32(0x1f600) + ' '
}
$results = New-Object 'Collections.Generic.List[object]'
$environment = Get-UiaEnvironment
$report = [ordered]@{
    schema = 1
    tool = 'Test-TextInputCompatibility.ps1'
    mode = if ($Interactive) { 'interactive' } else { 'plan' }
    agent = $Agent
    environment = $environment
    startedUtc = [DateTime]::UtcNow.ToString('o')
    cases = $results
}
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$stateRoot = [IO.Path]::GetFullPath((Split-Path -Parent $OutputPath))
if ($Agent -ne 'Direct') {
    if (!$PSBoundParameters.ContainsKey('Method')) { $Method = @('unicode','virtualKey','scanCode') }
    if ($Method -contains 'wmChar') { throw 'wmChar is available only in the direct fixture probe.' }
}

function Save-TextReport {
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    $report.summary = [ordered]@{}
    foreach ($status in 'PASS','FAIL','BLOCKED','UNREPRESENTABLE','NOT_RUN') {
        $report.summary[$status] = @($results.ToArray() | Where-Object status -eq $status).Count
    }
    [void][IO.Directory]::CreateDirectory((Split-Path -Parent $OutputPath))
    Save-UiaJson (ConvertTo-Json $report -Depth 8) $OutputPath
}

if (!$Interactive) {
    foreach ($kind in $Fixture) {
        foreach ($mode in $Method) {
            foreach ($sample in $samples.Keys) {
                $results.Add([ordered]@{ fixture = $kind; method = $mode; sample = $sample; status = 'NOT_RUN' })
            }
        }
    }
    Save-TextReport
    return
}

if ($env:OS -ne 'Windows_NT' -or ![Environment]::UserInteractive) {
    throw 'The compatibility probe requires an interactive Windows desktop.'
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class TextProbe {
    [StructLayout(LayoutKind.Sequential)] struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct LastInput { public uint Size, Time; }
    [StructLayout(LayoutKind.Sequential)] struct Mouse { public int X,Y; public uint Data, Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] struct Key { public ushort Vk, Scan; public uint Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Explicit)] struct InputData {
        [FieldOffset(0)] public Mouse Mouse;
        [FieldOffset(0)] public Key Key;
    }
    [StructLayout(LayoutKind.Sequential)] struct Input { public uint Type; public InputData Data; }
    [StructLayout(LayoutKind.Sequential)] struct HookData { public uint Vk, Scan, Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] struct MouseHookData { public Point Point; public uint Data, Flags, Time; public UIntPtr Extra; }
    [StructLayout(LayoutKind.Sequential)] struct Message {
        public IntPtr Hwnd; public uint Id; public UIntPtr Wparam; public IntPtr Lparam;
        public uint Time; public Point Point; public uint Private;
    }
    [StructLayout(LayoutKind.Sequential)] struct GuiThreadInfo {
        public uint Size, Flags; public IntPtr Active, Focus, Capture, MenuOwner, MoveSize, Caret; public Rect Rect;
    }
    delegate IntPtr Hook(int code, UIntPtr wparam, IntPtr lparam);
    delegate bool EnumWindow(IntPtr window, IntPtr data);

    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LastInput input);
    [DllImport("kernel32.dll")] static extern uint GetTickCount();
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern short GetKeyState(int vk);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint pid);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread, ref GuiThreadInfo info);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetDlgItem(IntPtr parent, int id);
    [DllImport("user32.dll")] static extern bool EnumChildWindows(IntPtr parent, EnumWindow callback, IntPtr data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder name, int size);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hwnd, out Rect rect);
    [DllImport("user32.dll")] static extern bool IsChild(IntPtr parent, IntPtr child);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool IsWindowEnabled(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(Point point);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint thread);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern short VkKeyScanEx(char character, IntPtr layout);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern uint MapVirtualKeyEx(uint code, uint type, IntPtr layout);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int ToUnicodeEx(
        uint vk, uint scan, byte[] state, StringBuilder text, int capacity, uint flags, IntPtr layout);
    [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint n, Input[] input, int size);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool PostMessage(
        IntPtr hwnd, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern IntPtr SetWindowsHookEx(
        int type, Hook hook, IntPtr module, uint thread);
    [DllImport("user32.dll")] static extern bool UnhookWindowsHookEx(IntPtr hook);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr hook, int code, UIntPtr wparam, IntPtr lparam);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetMessage(out Message message, IntPtr hwnd, uint min, uint max);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool PeekMessage(out Message message, IntPtr hwnd, uint min, uint max, uint remove);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool PostThreadMessage(uint thread, uint message, UIntPtr wparam, IntPtr lparam);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode)] static extern IntPtr GetModuleHandle(string name);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern IntPtr CreateWindowEx(uint exStyle, string cls, string title,
        uint style, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool OpenClipboard(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool CloseClipboard();
    [DllImport("user32.dll")] static extern bool EmptyClipboard();
    [DllImport("user32.dll")] static extern int CountClipboardFormats();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardOwner();
    [DllImport("user32.dll")] static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] static extern IntPtr GetClipboardData(uint format);
    [DllImport("user32.dll")] static extern uint EnumClipboardFormats(uint format);
    [DllImport("user32.dll")] static extern bool IsClipboardFormatAvailable(uint format);
    [DllImport("user32.dll")] static extern IntPtr SetClipboardData(uint format, IntPtr memory);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern uint RegisterClipboardFormat(string name);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalAlloc(uint flags, UIntPtr size);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalLock(IntPtr memory);
    [DllImport("kernel32.dll")] static extern bool GlobalUnlock(IntPtr memory);
    [DllImport("kernel32.dll")] static extern IntPtr GlobalFree(IntPtr memory);

    static readonly UIntPtr tag = (UIntPtr)0x54455854;
    static readonly Hook keyboard = KeyboardHook;
    static readonly Hook mouse = MouseHook;
    static int foreignCount;
    static int keyboardCount;
    static int mouseCount;
    static int foreignBaseline;
    static volatile bool awaitingAgent;
    static Thread monitor;
    static uint monitorThread;
    static readonly ManualResetEvent monitorReady = new ManualResetEvent(false);
    static bool monitorInstalled;

    static IntPtr KeyboardHook(int code, UIntPtr wparam, IntPtr lparam) {
        if (code >= 0) {
            var data = (HookData)Marshal.PtrToStructure(lparam, typeof(HookData));
            if ((data.Flags & 16) != 0 && data.Extra == tag) Interlocked.Increment(ref keyboardCount);
            else if (!awaitingAgent || (data.Flags & 16) == 0) Interlocked.Increment(ref foreignCount);
        }
        return CallNextHookEx(IntPtr.Zero, code, wparam, lparam);
    }

    static IntPtr MouseHook(int code, UIntPtr wparam, IntPtr lparam) {
        if (code >= 0) {
            var data = (MouseHookData)Marshal.PtrToStructure(lparam, typeof(MouseHookData));
            if ((data.Flags & 1) != 0 && data.Extra == tag) Interlocked.Increment(ref mouseCount);
            else Interlocked.Increment(ref foreignCount);
        }
        return CallNextHookEx(IntPtr.Zero, code, wparam, lparam);
    }

    public static void StartMonitor() {
        monitor = new Thread(delegate() {
            monitorThread = GetCurrentThreadId();
            Message message;
            PeekMessage(out message, IntPtr.Zero, 0, 0, 0);
            IntPtr module = GetModuleHandle(null);
            IntPtr k = SetWindowsHookEx(13, keyboard, module, 0);
            IntPtr m = SetWindowsHookEx(14, mouse, module, 0);
            try {
                monitorInstalled = k != IntPtr.Zero && m != IntPtr.Zero;
                monitorReady.Set();
                if (monitorInstalled) while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) {}
            } finally {
                if (k != IntPtr.Zero) UnhookWindowsHookEx(k);
                if (m != IntPtr.Zero) UnhookWindowsHookEx(m);
            }
        });
        monitor.IsBackground = true;
        monitor.Start();
        if (!monitorReady.WaitOne(3000) || !monitorInstalled) throw new InvalidOperationException("BLOCKED: probe hooks unavailable.");
        foreignBaseline = Volatile.Read(ref foreignCount);
    }

    public static void StopMonitor() {
        if (monitor == null) return;
        PostThreadMessage(monitorThread, 0x12, UIntPtr.Zero, IntPtr.Zero);
        monitor.Join(3000);
    }
    public static bool ForeignInput { get { return Volatile.Read(ref foreignCount) != foreignBaseline; } }
    public static void BeginAgent(IntPtr frame, uint process) { Check(frame,process); awaitingAgent = true; }
    public static void EndAgent(IntPtr frame, uint process) { awaitingAgent = false; Check(frame,process); }
    public static uint IdleMs() {
        var info = new LastInput { Size = (uint)Marshal.SizeOf(typeof(LastInput)) };
        return GetLastInputInfo(ref info) ? unchecked(GetTickCount() - info.Time) : 0;
    }
    public static bool Held() {
        foreach (int vk in new[] {1,2,4,5,6,16,17,18,91,92}) if ((GetAsyncKeyState(vk) & 0x8000) != 0) return true;
        return false;
    }
    static uint Pid(IntPtr window) { uint pid; GetWindowThreadProcessId(window, out pid); return pid; }
    static void Check(IntPtr frame, uint process) {
        if (ForeignInput || Held()) throw new InvalidOperationException("ABORT: external mouse or keyboard input detected.");
        if (Pid(frame) != process || GetForegroundWindow() != frame)
            throw new InvalidOperationException("BLOCKED: the test fixture lost the foreground.");
    }
    public static bool Activate(IntPtr frame, uint process) {
        if (ForeignInput || Held()) throw new InvalidOperationException("ABORT: external mouse or keyboard input detected.");
        if (Pid(frame) != process) return false;
        if (GetForegroundWindow() != frame) SetForegroundWindow(frame);
        return GetForegroundWindow() == frame;
    }
    public static IntPtr Editable(IntPtr frame, uint process, string kind) {
        Check(frame, process);
        if (kind == "Swing") return frame;
        if (kind == "Win32") return GetDlgItem(frame, 1002);
        IntPtr found = IntPtr.Zero;
        EnumChildWindows(frame, delegate(IntPtr child, IntPtr data) {
            var name = new StringBuilder(128);
            GetClassName(child, name, name.Capacity);
            if (Pid(child) != process || !IsWindowVisible(child) || !IsWindowEnabled(child)) return true;
            string cls = name.ToString();
            if (!cls.StartsWith("RichEdit", StringComparison.OrdinalIgnoreCase)
                && cls.IndexOf(".EDIT.", StringComparison.OrdinalIgnoreCase) < 0) return true;
            found = child;
            return false;
        }, IntPtr.Zero);
        return found;
    }
    public static IntPtr Focused(IntPtr frame, uint process) {
        Check(frame, process);
        uint ignored;
        uint thread = GetWindowThreadProcessId(frame, out ignored);
        var info = new GuiThreadInfo { Size = (uint)Marshal.SizeOf(typeof(GuiThreadInfo)) };
        if (!GetGUIThreadInfo(thread, ref info) || Pid(info.Focus) != process) return IntPtr.Zero;
        return info.Focus;
    }
    public static string ClassName(IntPtr window) {
        var name = new StringBuilder(128);
        GetClassName(window, name, name.Capacity);
        return name.ToString();
    }
    public static string Layout(IntPtr frame) {
        uint ignored;
        uint thread = GetWindowThreadProcessId(frame, out ignored);
        return ((uint)GetKeyboardLayout(thread).ToInt64()).ToString("x8");
    }
    static Input MouseEvent(int x, int y, uint flags) {
        return new Input { Data = new InputData { Mouse = new Mouse { X=x, Y=y, Flags=flags, Extra=tag } } };
    }
    static Input KeyEvent(ushort vk, ushort scan, uint flags) {
        return new Input { Type=1, Data = new InputData { Key = new Key { Vk=vk, Scan=scan, Flags=flags, Extra=tag } } };
    }
    static void Send(Input[] inputs, IntPtr frame, uint process) {
        Check(frame, process);
        int keysBefore = Volatile.Read(ref keyboardCount), mouseBefore = Volatile.Read(ref mouseCount);
        int keys = 0, mice = 0;
        foreach (var input in inputs) if (input.Type == 1) keys++; else mice++;
        uint sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf(typeof(Input)));
        if (sent != inputs.Length) {
            // Release only downs accepted by this probe. These fixed batches never hold a key intentionally.
            var held = new List<Input>();
            for (int i = 0; i < sent; i++) {
                var input = inputs[i];
                if (input.Type == 1) {
                    if ((input.Data.Key.Flags & 2) == 0) held.Add(input);
                    else held.RemoveAll(prior => prior.Type == 1 && prior.Data.Key.Vk == input.Data.Key.Vk
                        && prior.Data.Key.Scan == input.Data.Key.Scan);
                } else if (input.Data.Mouse.Flags == 2) held.Add(input);
                else if (input.Data.Mouse.Flags == 4) held.RemoveAll(prior => prior.Type == 0);
            }
            foreach (var pressed in held) {
                var release = pressed;
                if (release.Type == 1) release.Data.Key.Flags |= 2; else release.Data.Mouse.Flags = 4;
                SendInput(1, new[] { release }, Marshal.SizeOf(typeof(Input)));
            }
            throw new InvalidOperationException("ABORT: only " + sent + "/" + inputs.Length + " input events accepted.");
        }
        int until = Environment.TickCount + 300;
        while (Volatile.Read(ref keyboardCount) - keysBefore < keys || Volatile.Read(ref mouseCount) - mouseBefore < mice) {
            Check(frame, process);
            if (unchecked(Environment.TickCount - until) >= 0)
                throw new InvalidOperationException("ABORT: the probe hook did not observe every submitted event.");
            Thread.Sleep(1);
        }
        Check(frame, process);
    }
    public static void Click(IntPtr frame, uint process, IntPtr child) {
        Check(frame, process);
        if (Pid(child) != process || (child != frame && !IsChild(frame, child)))
            throw new InvalidOperationException("BLOCKED: fixture editor HWND could not be scoped.");
        IntPtr dpi = SetThreadDpiAwarenessContext(new IntPtr(-4));
        try {
            Rect rect;
            if (!GetWindowRect(child, out rect)) throw new InvalidOperationException("BLOCKED: no editor rectangle.");
            int x = (rect.Left + rect.Right) / 2, y = (rect.Top + rect.Bottom) / 2;
            // The dedicated Swing fixture contains a single editor in its entire client area.
            if (Pid(WindowFromPoint(new Point { X=x, Y=y })) != process)
                throw new InvalidOperationException("BLOCKED: fixture editor is covered.");
            long nx = ((long)(x - GetSystemMetrics(76)) * 65536 + GetSystemMetrics(78) - 1) / GetSystemMetrics(78);
            long ny = ((long)(y - GetSystemMetrics(77)) * 65536 + GetSystemMetrics(79) - 1) / GetSystemMetrics(79);
            if (nx < 0 || ny < 0 || nx > 65535 || ny > 65535)
                throw new InvalidOperationException("BLOCKED: editor outside the virtual screen.");
            Send(new[] { MouseEvent((int)nx,(int)ny,0xc001), MouseEvent(0,0,2), MouseEvent(0,0,4) }, frame, process);
        } finally { if (dpi != IntPtr.Zero) SetThreadDpiAwarenessContext(dpi); }
    }
    public static void End(IntPtr frame, uint process) {
        Send(new[] { KeyEvent(35,0,1), KeyEvent(35,0,3) }, frame, process);
    }
    static Input[] BuildText(IntPtr frame, string text, string method) {
        var events = new List<Input>();
        uint ignored;
        IntPtr layout = GetKeyboardLayout(GetWindowThreadProcessId(frame, out ignored));
        foreach (char character in text) {
            if (method == "unicode") {
                events.Add(KeyEvent(0,character,4)); events.Add(KeyEvent(0,character,6));
                continue;
            }
            short mapped = VkKeyScanEx(character, layout);
            int shift = (mapped >> 8) & 255;
            uint vk = (uint)mapped & 255;
            uint scan = MapVirtualKeyEx(vk, 4, layout);
            var state = new byte[256];
            state[0x10] = shift == 1 ? (byte)128 : (byte)0;
            state[0x14] = (byte)(GetKeyState(0x14) & 1);
            var result = new StringBuilder(8);
            int translated = (mapped == -1 || shift > 1 || scan == 0) ? 0
                : ToUnicodeEx(vk, scan & 255, state, result, result.Capacity, 4, layout);
            if (translated != 1 || result.Length != 1 || result[0] != character)
                throw new InvalidOperationException("UNREPRESENTABLE: no direct unmodified/Shift mapping for U+" + ((int)character).ToString("X4") + ".");
            if (shift == 1) events.Add(method == "scanCode" ? KeyEvent(0,42,8) : KeyEvent(16,0,0));
            uint flags = (scan & 0xff00) == 0xe000 ? 1u : 0u;
            if (method == "scanCode") { flags |= 8; vk=0; }
            else scan=0;
            events.Add(KeyEvent((ushort)vk,(ushort)(scan & 255),flags));
            events.Add(KeyEvent((ushort)vk,(ushort)(scan & 255),flags | 2));
            if (shift == 1) events.Add(method == "scanCode" ? KeyEvent(0,42,10) : KeyEvent(16,0,2));
        }
        return events.ToArray();
    }
    public static bool CanType(IntPtr frame, string text, string method) {
        try { BuildText(frame,text,method); return true; }
        catch (InvalidOperationException failure) {
            if (failure.Message.StartsWith("UNREPRESENTABLE:",StringComparison.Ordinal)) return false;
            throw;
        }
    }
    public static void Type(IntPtr frame, uint process, string text, string method) {
        Check(frame, process);
        Send(BuildText(frame,text,method), frame, process);
    }
    public static void SendChar(IntPtr frame, uint process, IntPtr child, string text) {
        Check(frame, process);
        if (Pid(child) != process || (child != frame && !IsChild(frame, child)))
            throw new InvalidOperationException("BLOCKED: character message target is outside the fixture.");
        foreach (char ch in text) {
            Check(frame, process);
            if (!PostMessage(child,0x102,(UIntPtr)ch,new IntPtr(1)))
                throw new InvalidOperationException("FAIL: fixture rejected WM_CHAR posting.");
        }
    }
    static IntPtr SetClipboardBytes(uint format, byte[] bytes) {
        IntPtr memory = GlobalAlloc(2,(UIntPtr)bytes.Length);
        if (memory == IntPtr.Zero) throw new InvalidOperationException("BLOCKED: clipboard allocation failed.");
        try {
            IntPtr data = GlobalLock(memory);
            if (data == IntPtr.Zero) throw new InvalidOperationException("BLOCKED: clipboard allocation could not be locked.");
            try { Marshal.Copy(bytes,0,data,bytes.Length); } finally { GlobalUnlock(memory); }
            if (SetClipboardData(format,memory) == IntPtr.Zero) throw new InvalidOperationException("BLOCKED: clipboard format could not be installed.");
            IntPtr installed = memory;
            memory = IntPtr.Zero;
            return installed;
        } finally { if (memory != IntPtr.Zero) GlobalFree(memory); }
    }
    // Call only with the clipboard open. Windows can synthesize text formats after CloseClipboard.
    static bool OwnsProbeClipboard(IntPtr owner, IntPtr textHandle, uint exclude, uint history, uint cloud) {
        if (GetClipboardOwner() != owner || textHandle == IntPtr.Zero || GetClipboardData(13) != textHandle
            || !IsClipboardFormatAvailable(exclude) || !IsClipboardFormatAvailable(history)
            || !IsClipboardFormatAvailable(cloud)) return false;
        for (uint f = EnumClipboardFormats(0); f != 0; f = EnumClipboardFormats(f)) {
            if (f != 1 && f != 7 && f != 13 && f != 16 && f != exclude && f != history && f != cloud) return false;
        }
        return true;
    }
    public static string Paste(IntPtr frame, uint process, string text) {
        Check(frame, process);
        IntPtr owner = CreateWindowEx(0,"Static","Text input probe clipboard",0x80000000,0,0,0,0,
            IntPtr.Zero,IntPtr.Zero,GetModuleHandle(null),IntPtr.Zero);
        if (owner == IntPtr.Zero) throw new InvalidOperationException("BLOCKED: cannot create clipboard owner.");
        uint sequence = 0;
        bool claimed = false;
        string cleanup = "restored-empty";
        uint exclude = RegisterClipboardFormat("ExcludeClipboardContentFromMonitorProcessing");
        uint history = RegisterClipboardFormat("CanIncludeInClipboardHistory");
        uint cloud = RegisterClipboardFormat("CanUploadToCloudClipboard");
        IntPtr textHandle = IntPtr.Zero;
        try {
            if (!OpenClipboard(owner)) throw new InvalidOperationException("BLOCKED: clipboard is in use.");
            try {
                // Existing data, private formats and delayed providers are never queried or changed.
                if (CountClipboardFormats() != 0)
                    throw new InvalidOperationException("BLOCKED: clipboard contains existing data; probe leaves it untouched.");
                if (!EmptyClipboard()) throw new InvalidOperationException("BLOCKED: clipboard claim failed.");
                claimed = true;
                SetClipboardBytes(exclude,new byte[] {1});
                SetClipboardBytes(history,new byte[4]);
                SetClipboardBytes(cloud,new byte[4]);
                textHandle = SetClipboardBytes(13,Encoding.Unicode.GetBytes(text + "\0"));
            } finally {
                if (claimed) sequence = GetClipboardSequenceNumber();
                CloseClipboard();
            }
            if (!OpenClipboard(owner))
                throw new InvalidOperationException("BLOCKED: clipboard is busy before paste.");
            try {
                if (!OwnsProbeClipboard(owner,textHandle,exclude,history,cloud))
                    throw new InvalidOperationException("ABORT: clipboard changed before paste.");
                sequence = GetClipboardSequenceNumber();
            } finally { CloseClipboard(); }
            if (GetClipboardSequenceNumber() != sequence || GetClipboardOwner() != owner)
                throw new InvalidOperationException("ABORT: clipboard changed after paste validation.");
            Send(new[] { KeyEvent(17,0,0), KeyEvent(86,0,0), KeyEvent(86,0,2), KeyEvent(17,0,2) },frame,process);
            Thread.Sleep(350);
        } finally {
            if (claimed) {
                bool opened = false;
                for (int attempt=0; attempt<20 && !opened; attempt++) {
                    opened = OpenClipboard(owner);
                    if (!opened) Thread.Sleep(10);
                }
                if (!opened) cleanup = "not-openable";
                else {
                    try {
                        bool own = GetClipboardOwner() == owner;
                        bool ownPartialWrite = textHandle == IntPtr.Zero && GetClipboardSequenceNumber() == sequence;
                        if (!own || (!ownPartialWrite && !OwnsProbeClipboard(owner,textHandle,exclude,history,cloud)))
                            cleanup = "external-change-preserved";
                        else if (!EmptyClipboard()) cleanup = "clear-failed";
                    } finally { CloseClipboard(); }
                }
            }
            DestroyWindow(owner);
            if (cleanup != "restored-empty") throw new InvalidOperationException("ABORT: clipboard cleanup " + cleanup + ".");
        }
        Check(frame, process);
        return cleanup;
    }
}
'@

function Wait-ProbeState([string]$Path, [scriptblock]$Predicate, [int]$Milliseconds) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt $Milliseconds) {
        $value = Read-ProbeFile $Path
        if ($null -ne $value -and (& $Predicate $value)) { return $value }
        Start-Sleep -Milliseconds 30
    }
    return $null
}

function Read-ProbeFile([string]$Path) {
    try {
        if ([IO.File]::Exists($Path)) {
            $contents = [IO.File]::ReadAllText($Path)
            return $contents.TrimStart([char]0xfeff)
        }
    } catch [IO.IOException] {}
    return $null
}

function Start-ProbeFixture([string]$Kind, [string]$Directory) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.EnvironmentVariables['DESKTOP_FIXTURE_MODE'] = 'interactive'
    $arguments = '"' + $Directory + '" "Text input compatibility ' + $Kind + '"'
    if ($Kind -in 'WinForms','Win32') {
        $binary = if ($Kind -eq 'WinForms') { $WinForms } else { $Win32 }
        $start.FileName = (Resolve-Path -LiteralPath $binary).Path
        $start.Arguments = $arguments
    } else {
        $start.FileName = (Get-Command $FixtureJava -CommandType Application | Select-Object -First 1).Source
        $classPath = (Resolve-Path -LiteralPath $JavaClasses).Path
        $start.Arguments = '-cp "' + $classPath + '" TextInputFixture ' + $Kind + ' ' + $arguments
    }
    return [Diagnostics.Process]::Start($start)
}

function Start-ProbeAgent([int]$ProcessId) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $arguments = " --backend multi --allow-pid $ProcessId --allow-action keyboard"
    if ($Agent -eq 'Java') {
        $start.FileName = (Get-Command $JavaExe -CommandType Application | Select-Object -First 1).Source
        $jarPath = (Resolve-Path -LiteralPath $Jar).Path
        $start.Arguments = '-jar "' + $jarPath + '"' + $arguments
    } else {
        $start.FileName = (Resolve-Path -LiteralPath $CppAgent).Path
        $start.Arguments = $arguments
    }
    return Start-Cli $start
}

function Send-ProbeAgent($Cli, [IntPtr]$Frame, [int]$ProcessId, [string]$Text, [string]$Mode) {
    # The agent classifies injected events with its own tag. The outer probe still sees physical input.
    [TextProbe]::BeginAgent($Frame,$ProcessId)
    try {
        return Send-UiaRequest $Cli @{
            op = 'typeText'; windowId = [string]$Frame.ToInt64(); processId = $ProcessId
            text = $Text; method = $Mode; quietMs = 0
        }
    } finally { [TextProbe]::EndAgent($Frame,$ProcessId) }
}

$environment.fixtureJavaVersion = ((& { $ErrorActionPreference = 'Continue'; & $FixtureJava -version 2>&1 }) -join ' | ')
try { $environment.gitCommit = [string](& git rev-parse HEAD 2>$null) } catch {}
if ($Agent -ne 'Direct') {
    $artifact = if ($Agent -eq 'Java') { $Jar } else { $CppAgent }
    $environment.agentSha256 = (Get-FileHash -LiteralPath $artifact).Hash
}
Write-Warning 'The probe sends real input to newly launched fixture windows. Leave the keyboard and mouse idle.'
$idle = [Diagnostics.Stopwatch]::StartNew()
while ([TextProbe]::IdleMs() -lt $CountdownSeconds * 1000 -or [TextProbe]::Held()) {
    if ($idle.Elapsed.TotalMinutes -gt 15) { throw 'The desktop did not become idle.' }
    Start-Sleep -Milliseconds 200
}

$aborted = $false
try {
    [TextProbe]::StartMonitor()
    foreach ($kind in $Fixture) {
        $process = $null
        $cli = $null
        $directory = Join-Path $stateRoot ('compat-fixture-' + [guid]::NewGuid().ToString('N'))
        $startupError = $null
        [void][IO.Directory]::CreateDirectory($directory)
        $valueFile = Join-Path $directory 'value.txt'
        $keyFile = Join-Path $directory 'key-events.txt'
        try {
            try {
                if ($aborted) { throw 'Input was interrupted in an earlier fixture.' }
                $process = Start-ProbeFixture $kind $directory
                $ready = Wait-ProbeState (Join-Path $directory 'ready') { param($v) $v.Trim() -eq [string]$process.Id } 15000
                if ($null -eq $ready) { throw 'Fixture did not start.' }
                $process.Refresh()
                [IntPtr]$frame = $process.MainWindowHandle
                if ($frame -eq [IntPtr]::Zero -or ![TextProbe]::Activate($frame,$process.Id)) { throw 'Fixture did not take the foreground.' }
                [IntPtr]$edit = [TextProbe]::Editable($frame,$process.Id,$kind)
                if ($edit -eq [IntPtr]::Zero) { throw 'Fixture editor HWND is unavailable.' }
                [TextProbe]::Click($frame,$process.Id,$edit)
                Start-Sleep -Milliseconds 100
                if ($kind -notin 'WinForms','Win32') {
                    $focus = Wait-ProbeState (Join-Path $directory 'edit-focus.txt') { param($v) $v -ceq 'true' } 1500
                    if (!$focus) { throw 'The Java fixture editor did not receive focus.' }
                } elseif ([TextProbe]::Focused($frame,$process.Id) -ne $edit) { throw 'The native fixture editor did not receive focus.' }
                if ($Agent -ne 'Direct') { $cli = Start-ProbeAgent $process.Id }
            } catch {
                $startupError = $_.Exception.GetBaseException().Message
                if ($startupError.StartsWith('ABORT:')) { $aborted = $true }
            }
            foreach ($mode in $Method) {
                foreach ($sample in $samples.Keys) {
                    $row = [ordered]@{ fixture = $kind; method = $mode; sample = $sample; status = 'BLOCKED' }
                    try {
                        if ($startupError) { throw $startupError }
                        if ($aborted) { throw 'Input was interrupted in an earlier trial.' }
                        $before = [string](Read-ProbeFile $valueFile)
                        $keysBefore = [string](Read-ProbeFile $keyFile)
                        $text = $samples[$sample]
                        $expected = $before + $text
                        $row.targetClass = [TextProbe]::ClassName($edit)
                        $row.focusClass = [TextProbe]::ClassName([TextProbe]::Focused($frame,$process.Id))
                        $row.layout = [TextProbe]::Layout($frame)
                        $row.expectedSuffix = $text
                        [TextProbe]::End($frame,$process.Id)
                        $agentStatus = $null
                        if ($Agent -eq 'Direct') {
                            switch ($mode) {
                                'clipboard' { $row.clipboardCleanup = [TextProbe]::Paste($frame,$process.Id,$text) }
                                'wmChar' { [TextProbe]::SendChar($frame,$process.Id,$edit,$text) }
                                default { [TextProbe]::Type($frame,$process.Id,$text,$mode) }
                            }
                        } else {
                            $response = Send-ProbeAgent $cli $frame $process.Id $text $mode
                            $reply = $response.reply
                            $row.agentLatencyMs = [Math]::Round($response.ms,2)
                            $row.agentCode = if ($reply.ok) { 'OK' } else { $reply.error.code }
                            $row.agentInputSent = if ($reply.ok) { $reply.result.inputSent } else { $reply.error.inputSent }
                            if ($row.agentCode -eq 'USER_INPUT_CONFLICT') { throw 'ABORT: the agent saw external input.' }
                            if ($row.agentCode -eq 'PRECONDITION_FAILED' -and $mode -in 'virtualKey','scanCode' -and
                                ![TextProbe]::CanType($frame,$text,$mode)) {
                                $agentStatus = 'UNREPRESENTABLE'
                            } elseif (!$reply.ok) { $agentStatus = 'FAIL' }
                        }
                        $value = if (!$agentStatus) { Wait-ProbeState $valueFile { param($v) $v -ceq $expected } 900 }
                        $row.fixtureValue = Read-ProbeFile $valueFile
                        $keysAfter = [string](Read-ProbeFile $keyFile)
                        if ($keysAfter.Length -gt $keysBefore.Length) { $row.fixtureKeyEvents = $keysAfter.Substring($keysBefore.Length).TrimEnd() }
                        if ([TextProbe]::ForeignInput) { throw 'ABORT: external input invalidated this trial.' }
                        $row.status = if ($agentStatus -eq 'UNREPRESENTABLE' -and
                            ($row.agentInputSent -or $row.fixtureValue -cne $before)) { 'FAIL' }
                            elseif ($agentStatus) { $agentStatus }
                            elseif ($null -ne $value) { 'PASS' } else { 'FAIL' }
                        if ($row.status -eq 'FAIL') { $row.reason = 'Fixture value did not include the exact sample.' }
                    } catch {
                        $reason = $_.Exception.GetBaseException().Message
                        $row.reason = $reason
                        if (!$startupError -and ($row.Keys -contains 'expectedSuffix')) {
                            $row.fixtureValue = Read-ProbeFile $valueFile
                        }
                        if ($reason.StartsWith('UNREPRESENTABLE:')) { $row.status = 'UNREPRESENTABLE' }
                        if ($reason.StartsWith('FAIL:')) { $row.status = 'FAIL' }
                        if ($reason.StartsWith('ABORT:')) { $aborted = $true }
                    }
                    $results.Add($row)
                    Write-Host "[$kind / $mode / $sample] $($row.status)"
                }
                Save-TextReport
            }
        } finally {
            try {
                if ($cli) { Stop-Cli $cli 'Multi' }
            } finally {
                if ($process) {
                    if (!$process.HasExited) {
                        [IO.File]::WriteAllText((Join-Path $directory 'close-fixture'),'')
                        if (!$process.WaitForExit(5000)) { $process.Kill(); [void]$process.WaitForExit(2000) }
                    }
                    $process.Dispose()
                }
                $resolved = (Resolve-Path -LiteralPath $directory).Path
                if ((Split-Path -Parent $resolved) -eq $stateRoot -and
                    (Split-Path -Leaf $resolved) -match '^compat-fixture-[a-f0-9]{32}$') {
                    Remove-Item -LiteralPath $resolved -Recurse -Force
                }
            }
        }
    }
} finally {
    [TextProbe]::StopMonitor()
    Save-TextReport
}
