# Physical input (SendInput) regression for the Java and C++ agents.
#
# Without -Interactive the script sends no input and starts no window: it writes the case plan with
# every case NOT_RUN. With -Interactive it launches the fixtures in Interactive mode, which take the
# foreground, and moves the real mouse and types on the real keyboard. Do not use the PC meanwhile.
#
# Every effect is judged by the fixture's own state files, never by an Agent reply. A reply only
# tells whether input was sent. Results go to one JSON report (see docs/PHYSICAL-INPUT.md).
[CmdletBinding()]
param(
    [switch]$Interactive,
    [ValidateSet('Java', 'Cpp', 'Both')][string]$Agent = 'Both',
    [ValidateSet('AwtButtonClick', 'AwtTextInput', 'AwtUnicodePackets', 'SwingModal', 'WinFormsListBox', 'WinFormsTab', 'DataGridView',
        'CanvasMouse', 'CanvasKeyboard', 'MultiMonitor', 'FocusChange', 'WindowObscured', 'TargetReplaced',
        'PermissionMismatch', 'UserInputConflict', 'ReleaseOnFailure', 'Performance')]
    [string[]]$Case = @('AwtButtonClick', 'AwtTextInput', 'SwingModal', 'WinFormsListBox', 'WinFormsTab', 'DataGridView',
        'CanvasMouse', 'CanvasKeyboard', 'MultiMonitor', 'FocusChange', 'WindowObscured', 'TargetReplaced',
        'PermissionMismatch', 'UserInputConflict', 'ReleaseOnFailure', 'Performance'),
    [string]$Jar = 'target/desktop-agent.jar',
    [string]$CppAgent = 'target/cpp-agent/Release/cpp-agent.exe',
    # The runtime of the Java agent, for example the JDK 11 java.exe.
    [string]$JavaExe = 'java.exe',
    # The runtime of the Swing and AWT fixtures. SwingModal needs Java Access Bridge in it.
    [string]$FixtureJava = 'java.exe',
    [string]$FixtureRoot = 'target/framework-fixtures',
    [string]$WinForms = 'winforms-framework.exe',
    [string]$OutputPath = 'target/physical-input.json',
    [string[]]$JvmOptions = @('-XX:+UseSerialGC', '-Xms16m'),
    # Seconds without any keyboard or mouse input before the run starts.
    [ValidateRange(5, 600)][int]$CountdownSeconds = 30,
    # How long to wait for the PC to become idle before giving up.
    [ValidateRange(1, 240)][int]$IdleWaitMinutes = 15,
    # Starts one fixture elevated through UAC for PermissionMismatch. Someone must approve the prompt.
    [switch]$IncludeElevated,
    [ValidateRange(10, 1000)][int]$PerformanceIterations = 60
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UiaTest.Common.ps1')
. (Join-Path $PSScriptRoot 'UiaFrameworkCases.ps1')
. (Join-Path $PSScriptRoot 'JabFrameworkCases.ps1')

$schema = 1
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$Jar = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Jar)
$CppAgent = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CppAgent)
$FixtureRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FixtureRoot)
$winFormsExe = Join-Path $FixtureRoot $WinForms
$classes = Join-Path $FixtureRoot 'swing-awt'
$implementations = if ($Agent -eq 'Both') { @('Java', 'Cpp') } else { @($Agent) }
$bridgeProperty = '-Djavax.accessibility.assistive_technologies=com.sun.java.accessibility.AccessBridge'
$allowed = '--allow-action pointer --allow-action keyboard --allow-action activate --allow-action invoke'

# What each case checks, with the accessibility failure it answers where there is one.
$descriptions = [ordered]@{
    AwtButtonClick = 'AWT button: UIA invoke reaches the native peer and has no effect; a bounds click on the same UIA element increments the counter once.'
    AwtTextInput = 'AWT TextField: click its UIA bounds, verify physical End and Backspace, then set a Unicode value through UIA.'
    AwtUnicodePackets = 'AWT compatibility probe: send physical Unicode packets and check whether the TextField inserts them.'
    SwingModal = 'Swing synchronous modal: open it with a bounds click (JAB invoke blocks for 8 s there) and close it with a bounds click inside the modal.'
    WinFormsListBox = 'WinForms ListBox: a bounds click selects an item; an MSAA weak reference is refused without consent, then clicked with acceptWeakReference.'
    WinFormsTab = 'WinForms TabControl: a bounds click on a TabItem selects the page.'
    DataGridView = 'DataGridView (no UIA rows or cells): click the grid, select row and cell with keys, edit with F2, typing and Enter.'
    CanvasMouse = 'Owner-drawn canvas without accessible children: move, click, double, right and middle click, drag and both wheels in screen, window and client coordinates.'
    CanvasKeyboard = 'Canvas keyboard: Unicode text with Tab, Enter and a surrogate pair, Ctrl+Shift+K, key down and up, refusals.'
    MultiMonitor = 'Other monitors and negative coordinates: move the fixture to every other monitor and click there. NOT_RUN with one monitor.'
    FocusChange = 'Another window takes the foreground: keyboard and pointer input to the target are refused without input; activateWindow is tried once.'
    WindowObscured = 'A topmost window that takes no focus covers part of the canvas: a click there is refused, a click beside it works.'
    TargetReplaced = 'The target exits and restarts; a window of another process is named with the old PID: refused as PERMISSION_DENIED or WINDOW_NOT_FOUND.'
    PermissionMismatch = 'An elevated target (UAC prompt, -IncludeElevated): INTEGRITY_MISMATCH before any input.'
    UserInputConflict = 'Foreign input (injected by this script without the session tag) during typing and right before a request: USER_INPUT_CONFLICT.'
    ReleaseOnFailure = 'A drag and a held Shift are interrupted by foreign input: the button and the key are released; a key held at session end is released.'
    Performance = 'Latency of pointerMove, pointerClick, clickElement, keyPress and typeText against the canvas, with the recorded state checked at the end.'
}

if (!('PiProbe' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Threading;

// Reads the desktop in physical pixels and injects deliberately foreign input. Methods that read
// coordinates switch this thread to per-monitor v2 awareness for the call only.
public static class PiProbe {
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [StructLayout(LayoutKind.Sequential)] struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    // INPUT is the size of its largest member, MOUSEINPUT, after the type field.
    [StructLayout(LayoutKind.Sequential)] struct INPUT { public uint type; public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)] struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
    [StructLayout(LayoutKind.Sequential)] struct MSG { public IntPtr hwnd; public uint message; public IntPtr wParam, lParam; public uint time; public POINT pt; }
    [StructLayout(LayoutKind.Sequential)] struct GUITHREADINFO {
        public int cbSize;
        public uint flags;
        public IntPtr active, focus, capture, menuOwner, moveSize, caret;
        public RECT caretRect;
    }
    delegate bool MonitorEnum(IntPtr monitor, IntPtr dc, ref RECT rect, IntPtr data);

    [DllImport("user32.dll")] static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint thread, ref GUITHREADINFO info);
    [DllImport("user32.dll")] static extern int GetDlgCtrlID(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr WindowFromPoint(POINT point);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr window, ref POINT point);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out RECT rect);
    [DllImport("user32.dll")] static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] static extern bool GetCursorPos(out POINT point);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int key);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("user32.dll")] static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorEnum callback, IntPtr data);
    [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr monitor, ref MONITORINFO info);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr window, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr CreateWindowEx(uint exStyle, string className, string title, uint style, int x, int y, int w, int h,
        IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] static extern bool DestroyWindow(IntPtr window);
    [DllImport("user32.dll")] static extern int GetMessage(out MSG message, IntPtr window, uint min, uint max);
    [DllImport("user32.dll")] static extern bool TranslateMessage(ref MSG message);
    [DllImport("user32.dll")] static extern IntPtr DispatchMessage(ref MSG message);
    [DllImport("user32.dll")] static extern bool PostThreadMessage(uint thread, uint msg, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("kernel32.dll")] static extern uint GetTickCount();

    static IntPtr Physical() {
        try { return SetThreadDpiAwarenessContext(new IntPtr(-4)); } catch (EntryPointNotFoundException) { return IntPtr.Zero; }
    }
    static void Restore(IntPtr previous) {
        if (previous != IntPtr.Zero) try { SetThreadDpiAwarenessContext(previous); } catch (EntryPointNotFoundException) {}
    }

    public static long Foreground() { return GetForegroundWindow().ToInt64(); }
    public static uint WindowDpi(long window) {
        try { return GetDpiForWindow(new IntPtr(window)); } catch (EntryPointNotFoundException) { return 0; }
    }
    public static uint ProcessOf(long window) { uint p; GetWindowThreadProcessId(new IntPtr(window), out p); return p; }
    public static int FocusedControlId(long window) {
        uint process, focusProcess;
        uint thread = GetWindowThreadProcessId(new IntPtr(window), out process);
        var info = new GUITHREADINFO { cbSize = Marshal.SizeOf(typeof(GUITHREADINFO)) };
        if (thread == 0 || !GetGUIThreadInfo(thread, ref info) || info.focus == IntPtr.Zero) return -1;
        GetWindowThreadProcessId(info.focus, out focusProcess);
        return focusProcess == process ? GetDlgCtrlID(info.focus) : -1;
    }
    public static int ControlUnderCursorId(uint process) {
        IntPtr previous = Physical();
        try {
            POINT point;
            if (!GetCursorPos(out point)) return -1;
            IntPtr hit = WindowFromPoint(point);
            uint hitProcess;
            GetWindowThreadProcessId(hit, out hitProcess);
            return hitProcess == process ? GetDlgCtrlID(hit) : -1;
        } finally { Restore(previous); }
    }
    public static int[] ClientOrigin(long window) {
        IntPtr previous = Physical();
        try { POINT p = new POINT(); ClientToScreen(new IntPtr(window), ref p); return new int[] { p.X, p.Y }; }
        finally { Restore(previous); }
    }
    public static int[] WindowRect(long window) {
        IntPtr previous = Physical();
        try { RECT r; GetWindowRect(new IntPtr(window), out r); return new int[] { r.Left, r.Top, r.Right, r.Bottom }; }
        finally { Restore(previous); }
    }
    public static int[] Cursor() {
        IntPtr previous = Physical();
        try { POINT p; GetCursorPos(out p); return new int[] { p.X, p.Y }; } finally { Restore(previous); }
    }
    public static bool Down(int key) { return GetAsyncKeyState(key) < 0; }
    public static uint IdleMs() {
        LASTINPUTINFO info = new LASTINPUTINFO(); info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        return GetLastInputInfo(ref info) ? unchecked(GetTickCount() - info.dwTime) : 0;
    }

    // One pixel right and back, without the agent's tag: the agent must read it as the user's input.
    public static void ForeignMove() {
        INPUT[] inputs = new INPUT[2];
        inputs[0].type = 0; inputs[0].mi.dx = 1; inputs[0].mi.dwFlags = 0x0001;
        inputs[1].type = 0; inputs[1].mi.dx = -1; inputs[1].mi.dwFlags = 0x0001;
        SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT)));
    }
    public static void ForeignMoveAfter(int milliseconds) {
        Thread thread = new Thread(() => { Thread.Sleep(milliseconds); ForeignMove(); });
        thread.IsBackground = true;
        thread.Start();
    }

    // Work areas in physical pixels: left, top, right, bottom, 1 for the primary monitor.
    public static List<int[]> Monitors() {
        IntPtr previous = Physical();
        var result = new List<int[]>();
        try {
            EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr monitor, IntPtr dc, ref RECT rect, IntPtr data) => {
                MONITORINFO info = new MONITORINFO(); info.cbSize = Marshal.SizeOf(typeof(MONITORINFO));
                GetMonitorInfo(monitor, ref info);
                result.Add(new int[] { info.rcWork.Left, info.rcWork.Top, info.rcWork.Right, info.rcWork.Bottom, (int)(info.dwFlags & 1) });
                return true;
            }, IntPtr.Zero);
        } finally { Restore(previous); }
        return result;
    }
    public static bool MoveWindow(long window, int x, int y) {
        IntPtr previous = Physical();
        // SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE
        try { return SetWindowPos(new IntPtr(window), IntPtr.Zero, x, y, 0, 0, 0x0001 | 0x0004 | 0x0010); }
        finally { Restore(previous); }
    }

    // A topmost popup that never activates, on its own thread with a message loop.
    static uint occluderThread;
    static long occluderWindow;
    public static long StartOccluder(int x, int y, int w, int h) {
        var ready = new ManualResetEvent(false);
        var thread = new Thread(() => {
            Physical();
            occluderThread = GetCurrentThreadId();
            // WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE; WS_POPUP | WS_VISIBLE | WS_BORDER
            IntPtr window = CreateWindowEx(0x00000008 | 0x00000080 | 0x08000000, "BUTTON", "Physical input occluder",
                0x80000000 | 0x10000000 | 0x00800000, x, y, w, h, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero);
            occluderWindow = window.ToInt64();
            ready.Set();
            MSG message;
            while (GetMessage(out message, IntPtr.Zero, 0, 0) > 0) { TranslateMessage(ref message); DispatchMessage(ref message); }
            if (window != IntPtr.Zero) DestroyWindow(window);
        });
        thread.IsBackground = true;
        thread.Start();
        ready.WaitOne(5000);
        return occluderWindow;
    }
    public static void StopOccluder() {
        if (occluderThread != 0) PostThreadMessage(occluderThread, 0x0012, IntPtr.Zero, IntPtr.Zero); // WM_QUIT
        occluderThread = 0;
        occluderWindow = 0;
    }
}
'@
}

# --- Report -------------------------------------------------------------------------------------

function New-PiReport {
    $environment = Get-UiaEnvironment
    $environment.monitors = @(foreach ($m in [PiProbe]::Monitors()) { [ordered]@{ left = $m[0]; top = $m[1]; right = $m[2]; bottom = $m[3]; primary = [bool]$m[4] } })
    $environment.userIdleMsAtStart = [PiProbe]::IdleMs()
    try { $environment.gitCommit = [string](& git rev-parse HEAD 2>$null) } catch {}
    foreach ($item in @(@('jarSha256', $Jar), @('cppAgentSha256', $CppAgent), @('winFormsFixtureSha256', $winFormsExe),
            @('swingAwtFixtureClassSha256', (Join-Path $classes 'FrameworkFixture.class')), @('runnerSha256', $PSCommandPath))) {
        if (Test-Path -LiteralPath $item[1]) { $environment[$item[0]] = (Get-FileHash -LiteralPath $item[1]).Hash }
    }
    try {
        $java = (Get-Command $JavaExe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $environment.javaAgentRuntime = $java
        # java -version writes to stderr, which Stop would turn into an exception.
        $environment.javaAgentVersion = (& { $ErrorActionPreference = 'Continue'; & $java -version 2>&1 } | ForEach-Object { "$_" }) -join ' | '
    } catch {}
    try {
        $java = (Get-Command $FixtureJava -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $environment.fixtureJavaVersion = (& { $ErrorActionPreference = 'Continue'; & $java -version 2>&1 } | ForEach-Object { "$_" }) -join ' | '
    } catch {}
    return [ordered]@{
        schema = $schema; tool = 'Test-PhysicalInput.ps1'; startedUtc = [DateTime]::UtcNow.ToString('o')
        mode = $(if ($Interactive) { 'interactive' } else { 'plan' })
        environment = $environment; agents = $implementations; cases = New-Object 'Collections.Generic.List[object]'
    }
}

function Add-PiNotRun($report, [string]$implementation, [string]$name, [string]$reason) {
    $report.cases.Add([ordered]@{ agent = $implementation; case = $name; status = 'NOT_RUN'; reason = $reason
        description = $descriptions[$name] })
}

function Save-PiReport($report) {
    $rows = $report.cases.ToArray()
    $summary = [ordered]@{}
    foreach ($status in 'PASS', 'FAIL', 'BLOCKED', 'NOT_RUN') { $summary[$status] = @($rows | Where-Object { $_.status -eq $status }).Count }
    $report.summary = $summary
    # Java and C++ agree on a case when both ran it with the same status and the same reply codes.
    $parity = New-Object 'Collections.Generic.List[object]'
    foreach ($name in @($rows | ForEach-Object { $_.case } | Select-Object -Unique)) {
        $java = @($rows | Where-Object { $_.case -eq $name -and $_.agent -eq 'Java' })
        $cpp = @($rows | Where-Object { $_.case -eq $name -and $_.agent -eq 'Cpp' })
        if ($java.Count -eq 0 -or $cpp.Count -eq 0) { continue }
        $javaCodes = @($java[0].steps | ForEach-Object { "$($_.op):$($_.code)" }) -join ','
        $cppCodes = @($cpp[0].steps | ForEach-Object { "$($_.op):$($_.code)" }) -join ','
        $parity.Add([ordered]@{ case = $name; java = $java[0].status; cpp = $cpp[0].status
            sameStatus = $java[0].status -eq $cpp[0].status; sameCodes = $javaCodes -ceq $cppCodes })
    }
    $report.parity = $parity.ToArray()
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    $directory = Split-Path -Parent $OutputPath
    if ($directory) { [void][IO.Directory]::CreateDirectory($directory) }
    Save-UiaJson (ConvertTo-Json -Depth 12 $report) $OutputPath
}

# --- Fixtures -----------------------------------------------------------------------------------

$targets = New-Object 'Collections.Generic.List[object]'

function Start-PiFixture([string]$kind, [switch]$Elevated) {
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('physical-input-' + [guid]::NewGuid())
    [void][IO.Directory]::CreateDirectory($directory)
    $title = "PI $kind fixture " + [guid]::NewGuid().ToString('N').Substring(0, 8)
    $target = @{ kind = $kind; stateDir = $directory; title = $title }
    $targets.Add($target)
    if ($Elevated) {
        $command = "set DESKTOP_FIXTURE_MODE=interactive&& ""$winFormsExe"" ""$directory"" ""$title"""
        [void](Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList "/c $command" -Verb RunAs -PassThru)
        $ready = $null
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while (!$ready -and $clock.ElapsedMilliseconds -lt 60000) { Start-Sleep -Milliseconds 200; $ready = Read-JabFile $directory 'ready' }
        if (!$ready) { throw 'BLOCKED: the elevated fixture did not start (UAC prompt declined or not answered).' }
        $target.processId = [int]$ready
        return $target
    }
    $start = New-Object Diagnostics.ProcessStartInfo
    if ($kind -eq 'WinForms') {
        $start.FileName = $winFormsExe
        $start.Arguments = """$directory"" ""$title"""
    } else {
        $start.FileName = (Get-Command $FixtureJava -CommandType Application | Select-Object -First 1).Source
        $start.Arguments = "$bridgeProperty -cp ""$classes"" FrameworkFixture $($kind.ToLowerInvariant()) ""$directory"" ""$title"""
    }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.EnvironmentVariables['DESKTOP_FIXTURE_MODE'] = 'interactive'
    $target.process = [Diagnostics.Process]::Start($start)
    $target.processId = $target.process.Id
    if (!(Wait-JabFile $directory 'ready' ([string]$target.process.Id) 30000)) { throw "BLOCKED: the $kind fixture did not become ready." }
    if ((Read-JabFile $directory 'fixture-mode.txt') -cne 'interactive') { throw "BLOCKED: the $kind fixture did not start in Interactive mode." }
    return $target
}

function Stop-PiFixture($target) {
    if (!$target -or $target.stopped) { return }
    $target.stopped = $true
    try {
        [IO.File]::WriteAllText((Join-Path $target.stateDir 'close-modal'), '')
        [IO.File]::WriteAllText((Join-Path $target.stateDir 'close-fixture'), '')
        $process = $target.process
        if (!$process -and $target.processId) { $process = Get-Process -Id $target.processId -ErrorAction SilentlyContinue }
        if ($process -and !$process.HasExited -and !$process.WaitForExit(5000)) { try { $process.Kill() } catch {} }
    } catch {} finally {
        Remove-Item -LiteralPath $target.stateDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Stop-PiFixtures { foreach ($t in $targets.ToArray()) { Stop-PiFixture $t }; $targets.Clear() }

function Read-Pi($target, [string]$file) { return Read-JabFile $target.stateDir $file }

function Wait-Pi($target, [string]$file, [scriptblock]$accept, [int]$timeoutMs = 5000) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $value = Read-Pi $target $file
        if ($null -ne $value -and (& $accept $value)) { return $value }
        Start-Sleep -Milliseconds 25
    } while ($clock.ElapsedMilliseconds -lt $timeoutMs)
    return $null
}

function Get-Lines([string]$text) { if (!$text) { return @() }; return @($text -split '\n' | Where-Object { $_ -ne '' }) }

function Last-Line($target, [string]$file) { $lines = @(Get-Lines (Read-Pi $target $file)); if ($lines.Count) { return $lines[-1] }; return '' }

# --- Agent --------------------------------------------------------------------------------------

function Start-PiAgent([string]$implementation, [int[]]$pids, [switch]$AllowSetValue) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $policy = ''
    foreach ($id in $pids) { $policy += " --allow-pid $id" }
    if ($AllowSetValue) { $policy += ' --allow-action setValue' }
    if ($implementation -eq 'Java') {
        $start.FileName = (Get-Command $JavaExe -CommandType Application | Select-Object -First 1).Source
        $start.Arguments = (($JvmOptions -join ' ') + " -jar ""$Jar"" --backend multi$policy $allowed")
    } else {
        $start.FileName = $CppAgent
        $start.Arguments = "--backend multi$policy $allowed"
    }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    return @{ cli = (Start-Cli $start); implementation = $implementation }
}

function Stop-PiAgent($run) {
    if (!$run -or !$run.cli) { return }
    try {
        if (!$run.cli.HasExited) { $run.cli.StandardInput.Close() }
        if (!$run.cli.WaitForExit(15000)) { $run.cli.Kill() }
    } catch {} finally { $run.cli.Dispose(); $run.cli = $null }
}

function Require-Pi($condition, [string]$message) { if (!$condition) { throw $message } }

# Sends one request and records it in the current case. $expect is one code or a list of codes.
function Send-Pi($run, $command, $expect = 'OK', [int]$timeoutMs = 20000) {
    $response = Send-UiaRequest $run.cli $command ([guid]::NewGuid().ToString()) $timeoutMs
    $reply = $response.reply
    $code = if ($reply.ok) { 'OK' } else { $reply.error.code }
    $step = [ordered]@{ op = $command.op; code = $code; ms = [Math]::Round($response.ms, 1) }
    if ($reply.ok -and $null -ne $reply.result.inputSent) { $step.inputSent = $reply.result.inputSent; $step.inputObserved = $reply.result.inputObserved }
    if (!$reply.ok -and $null -ne $reply.error.inputSent) { $step.inputSent = $reply.error.inputSent; $step.released = [bool]$reply.error.released }
    if ($reply.ok -and $reply.result.boundsMapping) { $step.boundsMapping = $reply.result.boundsMapping }
    if ($script:currentCase) { $script:currentCase.steps.Add($step) }
    if ($code -eq 'USER_INPUT_CONFLICT' -and !(@($expect) -contains 'USER_INPUT_CONFLICT')) {
        $script:abortReason = 'The agent reported user input during the run. The remaining cases were not run.'
        throw 'ABORT: unexpected USER_INPUT_CONFLICT'
    }
    if ($expect -and !(@($expect) -contains $code)) { throw "$($command.op) expected $(@($expect) -join '|'), received $code." }
    return $reply
}

function Measure-PiRequest($run, $command, [switch]$RecordObservation) {
    $response = Send-UiaRequest $run.cli $command ([guid]::NewGuid().ToString()) 20000
    if (!$response.reply.ok) {
        if ($response.reply.error.code -eq 'USER_INPUT_CONFLICT') {
            $script:abortReason = 'The agent reported user input during the run. The remaining cases were not run.'
        }
        throw "$($command.op) failed during measurement: $($response.reply.error.code)"
    }
    if ($RecordObservation) {
        $script:currentCase.evidence.textInputObserved += [bool]$response.reply.result.inputObserved
    }
    return [Math]::Round($response.ms, 2)
}

function Get-PiWindow($run, $target, [string]$name, [int]$timeoutMs = 10000) {
    if (!$name) { $name = $target.title }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $reply = Send-UiaRequest $run.cli @{ op = 'listWindows' }
        $rows = @($reply.reply.result | Where-Object { $_.processId -eq $target.processId -and $_.name -ceq $name })
        if ($rows.Count -eq 1) { return [string]$rows[0].windowId }
        Start-Sleep -Milliseconds 100
    } while ($clock.ElapsedMilliseconds -lt $timeoutMs)
    throw "BLOCKED: no single window named '$name' for PID $($target.processId)."
}

function Get-PiSnapshot($run, [string]$window, [string]$backend) {
    return (Send-Pi $run @{ op = 'snapshot'; windowId = $window; backend = $backend; maxDepth = 32; maxElements = 2000 }).result
}

function Find-PiRow($snapshot, [scriptblock]$match, [string]$what) {
    $rows = @($snapshot.elements | Where-Object $match)
    if ($rows.Count -lt 1) { throw "BLOCKED: the snapshot has no $what." }
    return $rows[0]
}

# The .NET Framework provider can omit items without a UIA runtime ID. MSAA can still
# expose their bounds, and the fixture's state file verifies the effect of the click.
function Select-PiWinFormsItem($c, $snapshot, [string]$role, [string]$name) {
    $rows = @($snapshot.elements | Where-Object { $_.role -ceq $role -and $_.name -ceq $name })
    $lookup = [ordered]@{ name = $name; role = $role; uiaMatches = $rows.Count; uiaTruncated = $snapshot.truncated }
    if (!$script:currentCase.evidence.itemLookups) { $script:currentCase.evidence.itemLookups = @() }
    $script:currentCase.evidence.itemLookups += $lookup
    if ($rows.Count -eq 0) {
        $lookup.uiaPeers = @($snapshot.elements | Where-Object role -CEQ $role | Select-Object -ExpandProperty name)
        $msaa = Get-PiSnapshot $c.run $c.window 'MSAA'
        $rows = @($msaa.elements | Where-Object { $_.role -ceq $role -and $_.name -ceq $name })
        $lookup.msaaMatches = $rows.Count
        $lookup.msaaTruncated = $msaa.truncated
        $lookup.msaaRootBounds = $msaa.elements[0].bounds
        $lookup.nativeWindowRect = [PiProbe]::WindowRect([long]$c.window)
    }
    if ($rows.Count -ne 1) { throw "BLOCKED: no unique $role named '$name' was found." }
    $item = $rows[0]
    $lookup.backend = $item.backend
    $lookup.referenceStrength = $item.referenceStrength
    $reply = Send-Pi $c.run @{ op = 'clickElement'; ref = $item.ref; acceptWeakReference = ($item.referenceStrength -eq 'weak') } @('OK', 'BOUNDS_UNVERIFIED')
    if (!$reply.ok) {
        Require-Pi ($reply.error.inputSent -eq $false) 'Unverified bounds allowed input.'
        throw "BLOCKED: $($item.backend) bounds for '$name' could not be mapped to the window."
    }
}

# The target must be in front before input. A fresh Interactive fixture normally is. Otherwise the
# agent tries activateWindow once; Windows may refuse, and the case is then BLOCKED, not failed.
function Use-PiForeground($run, $target, [string]$window) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.ElapsedMilliseconds -lt 3000) {
        if ([PiProbe]::ProcessOf([PiProbe]::Foreground()) -eq $target.processId) { return }
        Start-Sleep -Milliseconds 50
    }
    $reply = Send-Pi $run @{ op = 'activateWindow'; windowId = $window; processId = $target.processId } @('OK', 'FOREGROUND_MISMATCH')
    if (!$reply.ok) { throw 'BLOCKED: Windows did not bring the fixture to the foreground.' }
}

# Waits until nobody has used the keyboard or mouse for $seconds.
function Wait-PiIdle([int]$seconds, [int]$timeoutSeconds) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ([PiProbe]::IdleMs() -lt $seconds * 1000) {
        if ($clock.Elapsed.TotalSeconds -gt $timeoutSeconds) { return $false }
        Start-Sleep -Milliseconds 250
    }
    return $true
}

function Get-PiPoint($bounds, [double]$fx, [double]$fy) {
    return @([int][Math]::Floor($bounds.x + $fx * ($bounds.width - 1) + 0.5), [int][Math]::Floor($bounds.y + $fy * ($bounds.height - 1) + 0.5))
}

# A canvas log line: the words of $prefix, then numbers within 0.02 of $expected.
function Test-Near([string]$line, [string]$prefix, [double[]]$expected) {
    if (!$line -or !$line.StartsWith($prefix + ' ')) { return $false }
    $numbers = @($line.Substring($prefix.Length).Trim() -split ' ' | ForEach-Object { [double]::Parse($_, [Globalization.CultureInfo]::InvariantCulture) })
    if ($numbers.Count -ne $expected.Count) { return $false }
    for ($i = 0; $i -lt $numbers.Count; $i++) { if ([Math]::Abs($numbers[$i] - $expected[$i]) -gt 0.02) { return $false } }
    return $true
}

function Test-LastNear($target, [string]$file, [string]$prefix, [double[]]$expected) {
    return $null -ne (Wait-Pi $target $file { param($v) $lines = @(Get-Lines $v); $lines.Count -and (Test-Near $lines[-1] $prefix $expected) })
}

# A WinForms fixture and an agent for it, with the canvas row of a UIA snapshot.
function Open-PiCanvas([string]$implementation) {
    $t = Start-PiFixture 'WinForms'
    $run = Start-PiAgent $implementation @($t.processId)
    $window = Get-PiWindow $run $t
    Use-PiForeground $run $t $window
    $snapshot = Get-PiSnapshot $run $window 'UIA'
    $canvas = Find-PiRow $snapshot { $_.automationId -ceq 'fixtureCanvas' } 'fixtureCanvas'
    return @{ target = $t; run = $run; window = $window; snapshot = $snapshot; canvas = $canvas
        keys = @{ windowId = $window; processId = $t.processId } }
}

# --- Cases --------------------------------------------------------------------------------------

function Case-AwtButtonClick([string]$impl) {
    $t = Start-PiFixture 'Awt'
    $run = Start-PiAgent $impl @($t.processId)
    try {
        $window = Get-PiWindow $run $t
        Use-PiForeground $run $t $window
        $snapshot = Get-PiSnapshot $run $window 'UIA'
        $button = Find-PiRow $snapshot { $_.name -ceq 'Increment fixture counter' } 'UIA row for the AWT button'
        $before = [int](Read-Pi $t 'count.txt')
        # The accessibility failure this case answers: the provider accepts invoke and the button does not run.
        if (@($button.actions) -contains 'invoke') {
            $invoke = Send-Pi $run @{ op = 'invoke'; ref = $button.ref } @('OK', 'PATTERN_UNSUPPORTED', 'ACTION_OUTCOME_UNKNOWN')
            Start-Sleep -Milliseconds 1500
            $script:currentCase.evidence.uiaInvoke = if ($invoke.ok) { 'OK' } else { $invoke.error.code }
            $script:currentCase.evidence.uiaInvokeIncrements = [int](Read-Pi $t 'count.txt') - $before
            $before = [int](Read-Pi $t 'count.txt')
        }
        [void](Send-Pi $run @{ op = 'clickElement'; ref = $button.ref })
        [void](Wait-Pi $t 'count.txt' { param($v) [int]$v -ge $before + 1 })
        Start-Sleep -Milliseconds 700
        $after = [int](Read-Pi $t 'count.txt')
        $script:currentCase.evidence.clickIncrements = $after - $before
        Require-Pi ($after -eq $before + 1) 'The click did not increment the counter exactly once.'
    } finally { Stop-PiAgent $run }
}

function Test-PiAwtText([string]$impl, [switch]$UnicodePackets) {
    $t = Start-PiFixture 'Awt'
    $run = Start-PiAgent $impl @($t.processId) -AllowSetValue:(!$UnicodePackets)
    try {
        $window = Get-PiWindow $run $t
        Use-PiForeground $run $t $window
        $snapshot = Get-PiSnapshot $run $window 'UIA'
        $spec = Get-FrameworkSpec 'Awt'
        $edit = Find-PiRow $snapshot { $_.role -ceq 'Edit' -and $_.automationId -ceq $spec.edit -and $_.className -ceq $spec.editClass } 'UIA Edit row for the editable AWT TextField'
        $initial = [string](Read-Pi $t 'value.txt')
        $typed = ' AWT ' + [char]0xD55C + [char]0xAE00 + ' 123'
        $keys = @{ windowId = $window; processId = $t.processId }
        $click = Send-Pi $run @{ op = 'clickElement'; ref = $edit.ref }
        $script:currentCase.evidence.editBounds = $edit.bounds
        $script:currentCase.evidence.clickPoint = $click.result.point
        $script:currentCase.evidence.hitControlId = [PiProbe]::ControlUnderCursorId($t.processId)
        $focused = Wait-Pi $t 'edit-focus.txt' { param($v) $v -ceq 'true' } 1500
        $script:currentCase.evidence.focusedControlId = [PiProbe]::FocusedControlId([long]$window)
        $script:currentCase.evidence.fixtureEditFocused = $focused -ceq 'true'
        Require-Pi ($focused -ceq 'true') 'The AWT editable text field did not receive keyboard focus.'
        [void](Send-Pi $run ($keys + @{ op = 'keyPress'; keys = 'End' }))
        $expected = $initial + $typed
        if ($UnicodePackets) {
            [void](Send-Pi $run ($keys + @{ op = 'typeText'; text = $typed }))
        } else {
            Require-Pi ($initial.Length -gt 0) 'The fixture did not publish its initial text.'
            [void](Send-Pi $run ($keys + @{ op = 'keyPress'; keys = 'Backspace' }))
            $afterKey = $initial.Substring(0, $initial.Length - 1)
            $physicalValue = Wait-Pi $t 'value.txt' { param($v) $v -ceq $afterKey }
            $script:currentCase.evidence.valueAfterPhysicalKey = Read-Pi $t 'value.txt'
            Require-Pi ($null -ne $physicalValue) 'Physical Backspace did not remove the final character.'
            [void](Send-Pi $run @{ op = 'setValue'; ref = $edit.ref; value = $expected })
        }
        $value = Wait-Pi $t 'value.txt' { param($v) $v -ceq $expected }
        $script:currentCase.evidence.value = Read-Pi $t 'value.txt'
        if ($UnicodePackets -and $null -eq $value) {
            $beforeControl = $script:currentCase.evidence.value
            [void](Send-Pi $run ($keys + @{ op = 'keyPress'; keys = 'A' }))
            $control = Wait-Pi $t 'value.txt' { param($v) $v -cne $beforeControl } 1500
            $script:currentCase.evidence.virtualKeyChangedValue = $null -ne $control
        }
        Require-Pi ($null -ne $value) 'value.txt does not hold the expected Unicode text.'
    } finally { Stop-PiAgent $run }
}

function Case-AwtTextInput([string]$impl) { Test-PiAwtText $impl }

function Case-AwtUnicodePackets([string]$impl) { Test-PiAwtText $impl -UnicodePackets }

function Case-SwingModal([string]$impl) {
    $t = Start-PiFixture 'Swing'
    $run = Start-PiAgent $impl @($t.processId)
    try {
        $window = Get-PiWindow $run $t
        Use-PiForeground $run $t $window
        $snapshot = Get-PiSnapshot $run $window 'JAB'
        $open = Find-PiRow $snapshot { $_.name -ceq 'Open fixture modal' } 'JAB row for the open-modal button'
        [void](Send-Pi $run @{ op = 'clickElement'; ref = $open.ref })
        Require-Pi ($null -ne (Wait-Pi $t 'modal.txt' { param($v) $v -ceq 'open' } 8000)) 'The modal did not open.'
        $modal = Get-PiWindow $run $t "$($t.title) modal"
        Use-PiForeground $run $t $modal
        $dialog = Get-PiSnapshot $run $modal 'JAB'
        $close = Find-PiRow $dialog { $_.name -ceq 'Close fixture modal' } 'JAB row for the close button'
        [void](Send-Pi $run @{ op = 'clickElement'; ref = $close.ref })
        Require-Pi ($null -ne (Wait-Pi $t 'modal.txt' { param($v) $v -ceq 'closed' } 8000)) 'The modal did not close.'
    } finally { Stop-PiAgent $run }
}

function Case-WinFormsListBox([string]$impl) {
    $c = Open-PiCanvas $impl
    try {
        Select-PiWinFormsItem $c $c.snapshot 'ListItem' 'Item two'
        Require-Pi ($null -ne (Wait-Pi $c.target 'list.txt' { param($v) $v -ceq 'Item two' })) 'list.txt is not Item two.'
        $msaa = Get-PiSnapshot $c.run $c.window 'MSAA'
        $third = Find-PiRow $msaa { $_.name -ceq 'Item three' } 'MSAA row Item three'
        $script:currentCase.evidence.msaaReferenceStrength = $third.referenceStrength
        if ($third.referenceStrength -eq 'weak') {
            [void](Send-Pi $c.run @{ op = 'clickElement'; ref = $third.ref } 'PRECONDITION_FAILED')
            Start-Sleep -Milliseconds 500
            Require-Pi ((Read-Pi $c.target 'list.txt') -ceq 'Item two') 'A refused weak reference changed the selection.'
        }
        $reply = Send-Pi $c.run @{ op = 'clickElement'; ref = $third.ref; acceptWeakReference = $true }
        $script:currentCase.evidence.weakClickReferenceStrength = $reply.result.referenceStrength
        Require-Pi ($null -ne (Wait-Pi $c.target 'list.txt' { param($v) $v -ceq 'Item three' })) 'list.txt is not Item three.'
    } finally { Stop-PiAgent $c.run }
}

function Select-PiTab($c, [string]$name) {
    $snapshot = Get-PiSnapshot $c.run $c.window 'UIA'
    Select-PiWinFormsItem $c $snapshot 'TabItem' $name
    Require-Pi ($null -ne (Wait-Pi $c.target 'tab.txt' { param($v) $v -ceq $name })) "tab.txt is not $name."
}

function Case-WinFormsTab([string]$impl) {
    $c = Open-PiCanvas $impl
    try {
        Select-PiTab $c 'Grid and tree'
        Select-PiTab $c 'Virtual lists'
        Select-PiTab $c 'Common controls'
    } finally { Stop-PiAgent $c.run }
}

function Case-DataGridView([string]$impl) {
    $c = Open-PiCanvas $impl
    try {
        Select-PiTab $c 'Grid and tree'
        $snapshot = Get-PiSnapshot $c.run $c.window 'UIA'
        $grid = Find-PiRow $snapshot { $_.automationId -ceq 'fixtureDataGrid' } 'fixtureDataGrid'
        $script:currentCase.evidence.gridChildrenInUia = @($snapshot.elements | Where-Object { $_.parentRef -eq $grid.ref }).Count
        $keys = $c.keys
        [void](Send-Pi $c.run @{ op = 'clickElement'; ref = $grid.ref; position = @{ x = 0.6; y = 0.3 } })
        Start-Sleep -Milliseconds 300
        foreach ($step in @(@('Ctrl+Home', '0,0'), @('Down', '1,0'), @('Right', '1,1'))) {
            [void](Send-Pi $c.run ($keys + @{ op = 'keyPress'; keys = $step[0] }))
            Require-Pi ($null -ne (Wait-Pi $c.target 'grid-cell.txt' { param($v) $v -ceq $step[1] })) "$($step[0]) did not select cell $($step[1])."
        }
        [void](Send-Pi $c.run ($keys + @{ op = 'keyPress'; keys = 'F2' }))
        [void](Send-Pi $c.run ($keys + @{ op = 'keyPress'; keys = 'End' }))
        [void](Send-Pi $c.run ($keys + @{ op = 'typeText'; text = ' Edited 1' }))
        [void](Send-Pi $c.run ($keys + @{ op = 'keyPress'; keys = 'Enter' }))
        $edits = Wait-Pi $c.target 'grid-edits.txt' { param($v) @(Get-Lines $v | Where-Object { $_ -match '^1,1,.*Edited 1$' }).Count -eq 1 }
        $script:currentCase.evidence.gridEdits = Read-Pi $c.target 'grid-edits.txt'
        Require-Pi ($null -ne $edits) 'grid-edits.txt has no committed edit of cell 1,1.'
    } finally { Stop-PiAgent $c.run }
}

function Case-CanvasMouse([string]$impl) {
    $c = Open-PiCanvas $impl
    try {
        $t = $c.target
        $r = $c.run
        $movePoint = Get-PiPoint $c.canvas.bounds 0.3 0.4
        [void](Send-Pi $r ($c.keys + @{ op = 'pointerMove'; point = @{ x = $movePoint[0]; y = $movePoint[1]; space = 'screen' } }))
        $moved = [PiProbe]::Cursor()
        $script:currentCase.evidence.pointerMoveExpected = @($movePoint)
        $script:currentCase.evidence.pointerMoveObserved = @($moved)
        Require-Pi ($moved[0] -eq $movePoint[0] -and $moved[1] -eq $movePoint[1]) 'The cursor did not reach the canvas point.'
        [void](Send-Pi $r @{ op = 'clickElement'; ref = $c.canvas.ref; position = @{ x = 0.25; y = 0.5 } })
        Require-Pi (Test-LastNear $t 'canvas-clicks.txt' 'left single' @(0.25, 0.5)) 'No left click at 0.25,0.5.'
        Start-Sleep -Milliseconds 600
        [void](Send-Pi $r @{ op = 'clickElement'; ref = $c.canvas.ref; clicks = 2; position = @{ x = 0.5; y = 0.5 } })
        Require-Pi (Test-LastNear $t 'canvas-clicks.txt' 'left double' @(0.5, 0.5)) 'No double click.'
        foreach ($button in 'right', 'middle') {
            Start-Sleep -Milliseconds 600
            [void](Send-Pi $r @{ op = 'clickElement'; ref = $c.canvas.ref; button = $button; position = @{ x = 0.75; y = 0.5 } })
            Require-Pi (Test-LastNear $t 'canvas-clicks.txt' "$button single" @(0.75, 0.5)) "No $button click."
        }
        # Screen coordinates for the drag, window coordinates for the vertical wheel, client ones for the horizontal wheel.
        $from = Get-PiPoint $c.canvas.bounds 0.1 0.2
        $to = Get-PiPoint $c.canvas.bounds 0.6 0.8
        [void](Send-Pi $r ($c.keys + @{ op = 'pointerDrag'; from = @{ x = $from[0]; y = $from[1]; space = 'screen' }; to = @{ x = $to[0]; y = $to[1]; space = 'screen' } }))
        Require-Pi (Test-LastNear $t 'canvas-drag.txt' 'left' @(0.1, 0.2, 0.6, 0.8)) 'No drag from 0.1,0.2 to 0.6,0.8.'
        $center = Get-PiPoint $c.canvas.bounds 0.5 0.5
        $frame = [PiProbe]::WindowRect([long]$c.window)
        [void](Send-Pi $r ($c.keys + @{ op = 'pointerScroll'; delta = 2; point = @{ x = $center[0] - $frame[0]; y = $center[1] - $frame[1]; space = 'window' } }))
        Require-Pi ($null -ne (Wait-Pi $t 'canvas-wheel.txt' { param($v) (Last-Line $t 'canvas-wheel.txt') -ceq 'vertical 240' })) 'No vertical wheel of 240.'
        $origin = [PiProbe]::ClientOrigin([long]$c.window)
        [void](Send-Pi $r ($c.keys + @{ op = 'pointerScroll'; delta = -1; axis = 'horizontal'; point = @{ x = $center[0] - $origin[0]; y = $center[1] - $origin[1]; space = 'client' } }))
        Require-Pi ($null -ne (Wait-Pi $t 'canvas-wheel.txt' { param($v) (Last-Line $t 'canvas-wheel.txt') -ceq 'horizontal -120' })) 'No horizontal wheel of -120.'
        $cursor = [PiProbe]::Cursor()
        $script:currentCase.evidence.cursorAfterClientScroll = "$($cursor[0]),$($cursor[1])"
        $script:currentCase.evidence.canvasCenter = "$($center[0]),$($center[1])"
        $script:currentCase.evidence.fixtureClicks = @(Get-Lines (Read-Pi $t 'canvas-clicks.txt'))
        $script:currentCase.evidence.fixtureDrags = @(Get-Lines (Read-Pi $t 'canvas-drag.txt'))
        $script:currentCase.evidence.fixtureWheels = @(Get-Lines (Read-Pi $t 'canvas-wheel.txt'))
        $dpi = [PiProbe]::WindowDpi([long]$c.window)
        if ($dpi) { $script:currentCase.evidence.fixtureWindowDpi = $dpi }
        Require-Pi ($cursor[0] -eq $center[0] -and $cursor[1] -eq $center[1]) 'The client coordinates did not resolve to the canvas center.'
        Require-Pi (!([PiProbe]::Down(1) -or [PiProbe]::Down(2) -or [PiProbe]::Down(4))) 'A mouse button is still down.'
        Require-Pi ((Last-Line $t 'canvas-buttons.txt').StartsWith('up ')) 'The last button event is not a release.'
    } finally { Stop-PiAgent $c.run }
}

function Case-CanvasKeyboard([string]$impl) {
    $c = Open-PiCanvas $impl
    try {
        $t = $c.target
        $r = $c.run
        [void](Send-Pi $r @{ op = 'clickElement'; ref = $c.canvas.ref })
        $text = 'Abc ' + [char]0xD55C + [char]0xAE00 + ' ' + [char]::ConvertFromUtf32(0x1F600) + "`tX`r`nZ"
        $expected = $text.Replace("`r`n", "`n")
        [void](Send-Pi $r ($c.keys + @{ op = 'typeText'; text = $text }))
        $typed = Wait-Pi $t 'canvas-text.txt' { param($v) $v -ceq $expected }
        $script:currentCase.evidence.canvasText = Read-Pi $t 'canvas-text.txt'
        Require-Pi ($null -ne $typed) 'canvas-text.txt does not hold the typed text.'
        [void](Send-Pi $r ($c.keys + @{ op = 'keyPress'; keys = 'Ctrl+Shift+K' }))
        Require-Pi ($null -ne (Wait-Pi $t 'shortcut.txt' { param($v) $v -ceq '1' })) 'Ctrl+Shift+K was not received once.'
        [void](Send-Pi $r ($c.keys + @{ op = 'keyDown'; key = 'Shift' }))
        Require-Pi ($null -ne (Wait-Pi $t 'canvas-keys.txt' { param($v) (Last-Line $t 'canvas-keys.txt') -ceq 'down ShiftKey' })) 'No Shift down.'
        Require-Pi ([PiProbe]::Down(0x10)) 'Shift is not down after keyDown.'
        [void](Send-Pi $r ($c.keys + @{ op = 'keyUp'; key = 'Shift' }))
        Require-Pi ($null -ne (Wait-Pi $t 'canvas-keys.txt' { param($v) (Last-Line $t 'canvas-keys.txt') -ceq 'up ShiftKey' })) 'No Shift up.'
        Require-Pi (![PiProbe]::Down(0x10)) 'Shift is still down after keyUp.'
        [void](Send-Pi $r ($c.keys + @{ op = 'keyUp'; key = 'Shift' }) 'PRECONDITION_FAILED')
        [void](Send-Pi $r ($c.keys + @{ op = 'keyPress'; keys = 'Alt+Tab' }) 'INVALID_REQUEST')
        [void](Send-Pi $r ($c.keys + @{ op = 'keyPress'; keys = 'Win+R' }) 'INVALID_REQUEST')
    } finally { Stop-PiAgent $c.run }
}

function Case-MultiMonitor([string]$impl) {
    $monitors = @([PiProbe]::Monitors())
    if ($monitors.Count -lt 2) { throw 'NOT_RUN: this PC has one monitor.' }
    $c = Open-PiCanvas $impl
    try {
        foreach ($m in @($monitors | Where-Object { !$_[4] })) {
            Require-Pi ([PiProbe]::MoveWindow([long]$c.window, $m[0] + 40, $m[1] + 40)) 'The fixture could not be moved.'
            Start-Sleep -Milliseconds 500
            $snapshot = Get-PiSnapshot $c.run $c.window 'UIA'
            $canvas = Find-PiRow $snapshot { $_.automationId -ceq 'fixtureCanvas' } 'fixtureCanvas'
            Start-Sleep -Milliseconds 600
            [void](Send-Pi $c.run @{ op = 'clickElement'; ref = $canvas.ref; position = @{ x = 0.4; y = 0.4 } })
            Require-Pi (Test-LastNear $c.target 'canvas-clicks.txt' 'left single' @(0.4, 0.4)) "No click on the monitor at $($m[0]),$($m[1])."
            $script:currentCase.evidence["monitor_$($m[0])_$($m[1])"] = "canvas at $($canvas.bounds.x),$($canvas.bounds.y)"
        }
    } finally { Stop-PiAgent $c.run }
}

function Case-FocusChange([string]$impl) {
    $c = Open-PiCanvas $impl
    try {
        $other = Start-PiFixture 'WinForms'
        $clock = [Diagnostics.Stopwatch]::StartNew()
        while ([PiProbe]::ProcessOf([PiProbe]::Foreground()) -ne $other.processId -and $clock.ElapsedMilliseconds -lt 5000) { Start-Sleep -Milliseconds 50 }
        if ([PiProbe]::ProcessOf([PiProbe]::Foreground()) -ne $other.processId) { throw 'BLOCKED: the second fixture did not take the foreground.' }
        $center = Get-PiPoint $c.canvas.bounds 0.5 0.5
        $clicks = Read-Pi $c.target 'canvas-clicks.txt'
        foreach ($command in @(@{ op = 'keyPress'; keys = 'Ctrl+Shift+K' }, @{ op = 'typeText'; text = 'not typed' },
                @{ op = 'pointerClick'; point = @{ x = $center[0]; y = $center[1]; space = 'screen' } })) {
            $reply = Send-Pi $c.run ($c.keys + $command) 'FOREGROUND_MISMATCH'
            Require-Pi ($reply.error.inputSent -eq $false) 'A refused request reported input.'
        }
        Start-Sleep -Milliseconds 800
        Require-Pi ((Read-Pi $c.target 'shortcut.txt') -ceq '0') 'The target received the shortcut.'
        Require-Pi (!(Read-Pi $other 'canvas-text.txt')) 'The foreground window received typed text.'
        Require-Pi ((Read-Pi $c.target 'canvas-clicks.txt') -ceq $clicks) 'The target received a click.'
        # activateWindow sends no input. Windows may refuse it; that is recorded, not failed.
        $activate = Send-Pi $c.run ($c.keys + @{ op = 'activateWindow' }) @('OK', 'FOREGROUND_MISMATCH')
        $script:currentCase.evidence.activateWindow = if ($activate.ok) { 'OK' } else { $activate.error.code }
        if ($activate.ok) {
            [void](Send-Pi $c.run ($c.keys + @{ op = 'keyPress'; keys = 'Ctrl+Shift+K' }))
            Require-Pi ($null -ne (Wait-Pi $c.target 'shortcut.txt' { param($v) $v -ceq '1' })) 'The shortcut did not arrive after activateWindow.'
        }
    } finally { Stop-PiAgent $c.run }
}

function Case-WindowObscured([string]$impl) {
    $c = Open-PiCanvas $impl
    try {
        $center = Get-PiPoint $c.canvas.bounds 0.5 0.5
        $occluder = [PiProbe]::StartOccluder($center[0] - 60, $center[1] - 40, 120, 80)
        Require-Pi ($occluder -ne 0) 'The occluder window was not created.'
        Start-Sleep -Milliseconds 300
        Require-Pi ([PiProbe]::ProcessOf([PiProbe]::Foreground()) -eq $c.target.processId) 'The occluder took the foreground.'
        $clicks = Read-Pi $c.target 'canvas-clicks.txt'
        $reply = Send-Pi $c.run @{ op = 'clickElement'; ref = $c.canvas.ref } 'WINDOW_OBSCURED'
        Require-Pi ($reply.error.inputSent -eq $false) 'A refused click reported input.'
        Start-Sleep -Milliseconds 500
        Require-Pi ((Read-Pi $c.target 'canvas-clicks.txt') -ceq $clicks) 'The covered canvas received a click.'
        [void](Send-Pi $c.run @{ op = 'clickElement'; ref = $c.canvas.ref; position = @{ x = 0.05; y = 0.1 } })
        Require-Pi (Test-LastNear $c.target 'canvas-clicks.txt' 'left single' @(0.05, 0.1)) 'The uncovered part did not receive the click.'
    } finally { [PiProbe]::StopOccluder(); Stop-PiAgent $c.run }
}

function Case-TargetReplaced([string]$impl) {
    $first = Start-PiFixture 'WinForms'
    $second = Start-PiFixture 'WinForms'
    $run = Start-PiAgent $impl @($first.processId, $second.processId)
    try {
        $firstWindow = Get-PiWindow $run $first
        $secondWindow = Get-PiWindow $run $second
        $snapshot = Get-PiSnapshot $run $firstWindow 'UIA'
        $canvas = Find-PiRow $snapshot { $_.automationId -ceq 'fixtureCanvas' } 'fixtureCanvas'
        # A window of the second process named with the first PID: a replaced or reused handle.
        $point = @{ x = 5; y = 5; space = 'client' }
        $reply = Send-Pi $run @{ op = 'pointerClick'; windowId = $secondWindow; processId = $first.processId; point = $point } 'WINDOW_NOT_FOUND'
        Require-Pi ($reply.error.inputSent -eq $false) 'A refused click reported input.'
        Stop-PiFixture $first
        $replacement = Start-PiFixture 'WinForms'
        $replacementWindow = Get-PiWindow $run $replacement
        $clicks = Read-Pi $replacement 'canvas-clicks.txt'
        foreach ($command in @(@{ op = 'pointerClick'; windowId = $firstWindow; processId = $first.processId; point = $point },
                @{ op = 'pointerClick'; windowId = $replacementWindow; processId = $replacement.processId; point = $point },
                @{ op = 'clickElement'; ref = $canvas.ref })) {
            $reply = Send-Pi $run $command @('PERMISSION_DENIED', 'WINDOW_NOT_FOUND', 'STALE_REFERENCE')
            Require-Pi ($reply.error.inputSent -eq $false) 'A refused request reported input.'
        }
        Start-Sleep -Milliseconds 500
        Require-Pi ((Read-Pi $replacement 'canvas-clicks.txt') -ceq $clicks) 'The replacement fixture received a click.'
    } finally { Stop-PiAgent $run }
}

function Case-PermissionMismatch([string]$impl) {
    if (!$IncludeElevated) { throw 'NOT_RUN: needs -IncludeElevated and a person to approve the UAC prompt.' }
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'BLOCKED: the runner is elevated, so the agent would be too.' }
    $t = Start-PiFixture 'WinForms' -Elevated
    $run = Start-PiAgent $impl @($t.processId)
    try {
        $window = Get-PiWindow $run $t
        foreach ($command in @(@{ op = 'keyPress'; keys = 'Ctrl+Shift+K' }, @{ op = 'pointerClick'; point = @{ x = 5; y = 5; space = 'client' } })) {
            $reply = Send-Pi $run (@{ windowId = $window; processId = $t.processId } + $command) 'INTEGRITY_MISMATCH'
            Require-Pi ($reply.error.inputSent -eq $false) 'A refused request reported input.'
        }
    } finally { Stop-PiAgent $run }
}

function Case-UserInputConflict([string]$impl) {
    $c = Open-PiCanvas $impl
    try {
        [void](Send-Pi $c.run @{ op = 'clickElement'; ref = $c.canvas.ref })
        Start-Sleep -Milliseconds 600
        [PiProbe]::ForeignMoveAfter(500)
        $reply = Send-Pi $c.run ($c.keys + @{ op = 'typeText'; text = ('a' * 600); intervalMs = 40 }) 'USER_INPUT_CONFLICT'
        Require-Pi ($reply.error.inputSent -eq $true) 'An interrupted typeText did not report the input it sent.'
        $typed = [string](Wait-Pi $c.target 'canvas-text.txt' { param($v) $v.Length -gt 0 })
        $script:currentCase.evidence.typedBeforeConflict = $typed.Length
        Require-Pi ($typed.Length -gt 0 -and $typed.Length -lt 600) 'The text was not cut short by the foreign input.'
        [PiProbe]::ForeignMove()
        $center = Get-PiPoint $c.canvas.bounds 0.5 0.5
        $move = @{ op = 'pointerMove'; point = @{ x = $center[0]; y = $center[1]; space = 'screen' }; quietMs = 3000 }
        $reply = Send-Pi $c.run ($c.keys + $move) 'USER_INPUT_CONFLICT'
        Require-Pi ($reply.error.inputSent -eq $false) 'A refused move reported input.'
        Start-Sleep -Milliseconds 3200
        [void](Send-Pi $c.run ($c.keys + $move))
    } finally { Stop-PiAgent $c.run }
}

function Case-ReleaseOnFailure([string]$impl) {
    $c = Open-PiCanvas $impl
    try {
        $t = $c.target
        [void](Send-Pi $c.run @{ op = 'clickElement'; ref = $c.canvas.ref })
        Start-Sleep -Milliseconds 600
        [void](Send-Pi $c.run ($c.keys + @{ op = 'keyDown'; key = 'Shift' }))
        $from = Get-PiPoint $c.canvas.bounds 0.1 0.5
        $to = Get-PiPoint $c.canvas.bounds 0.9 0.5
        [PiProbe]::ForeignMoveAfter(700)
        $drag = @{ op = 'pointerDrag'; steps = 60; stepDelayMs = 40; from = @{ x = $from[0]; y = $from[1]; space = 'screen' }; to = @{ x = $to[0]; y = $to[1]; space = 'screen' } }
        $reply = Send-Pi $c.run ($c.keys + $drag) 'USER_INPUT_CONFLICT'
        Require-Pi ($reply.error.inputSent -eq $true -and $reply.error.released -eq $true) 'The interrupted drag did not report its release.'
        Start-Sleep -Milliseconds 300
        Require-Pi (![PiProbe]::Down(1) -and ![PiProbe]::Down(0x10)) 'The mouse button or Shift is still down.'
        Require-Pi ((Last-Line $t 'canvas-buttons.txt') -like 'up left*') 'The canvas did not see the button released.'
        Require-Pi (@(Get-Lines (Read-Pi $t 'canvas-keys.txt')) -contains 'up ShiftKey') 'The canvas did not see Shift released.'
        Start-Sleep -Milliseconds 700
        [void](Send-Pi $c.run ($c.keys + @{ op = 'keyUp'; key = 'Shift' }) 'PRECONDITION_FAILED')
        # A key held when the session ends is released by the agent on its way out.
        [void](Send-Pi $c.run ($c.keys + @{ op = 'keyDown'; key = 'Ctrl' }))
        Require-Pi ([PiProbe]::Down(0x11)) 'Ctrl is not down after keyDown.'
        Stop-PiAgent $c.run
        Start-Sleep -Milliseconds 300
        Require-Pi (![PiProbe]::Down(0x11)) 'Ctrl is still down after the agent exited.'
        Require-Pi ((Last-Line $t 'canvas-keys.txt') -ceq 'up ControlKey') 'The canvas did not see Ctrl released at session end.'
    } finally { Stop-PiAgent $c.run }
}

function Get-PiStats($values) {
    $sorted = @($values | Sort-Object)
    if (!$sorted.Count) { return $null }
    $sum = 0.0; foreach ($v in $sorted) { $sum += $v }
    return [ordered]@{ count = $sorted.Count; mean = [Math]::Round($sum / $sorted.Count, 2)
        p50 = $sorted[[int][Math]::Ceiling($sorted.Count * 0.5) - 1]; p95 = $sorted[[int][Math]::Ceiling($sorted.Count * 0.95) - 1]
        max = $sorted[-1] }
}

function Case-Performance([string]$impl) {
    $c = Open-PiCanvas $impl
    try {
        $t = $c.target
        $left = Get-PiPoint $c.canvas.bounds 0.3 0.5
        $right = Get-PiPoint $c.canvas.bounds 0.7 0.5
        $times = [ordered]@{ pointerMove = @(); pointerClick = @(); clickElement = @(); keyPress = @(); typeText = @() }
        $n = $PerformanceIterations
        $half = [int][Math]::Floor($n / 2)
        # Alternating points keep two clicks apart, so none of them becomes a double click.
        for ($i = 0; $i -lt $n; $i++) {
            $p = if ($i % 2) { $left } else { $right }
            $times.pointerMove += Measure-PiRequest $c.run ($c.keys + @{ op = 'pointerMove'; quietMs = 0; point = @{ x = $p[0]; y = $p[1]; space = 'screen' } })
        }
        $clicksBefore = @(Get-Lines (Read-Pi $t 'canvas-clicks.txt')).Count
        for ($i = 0; $i -lt $half; $i++) {
            $p = if ($i % 2) { $left } else { $right }
            $times.pointerClick += Measure-PiRequest $c.run ($c.keys + @{ op = 'pointerClick'; quietMs = 0; point = @{ x = $p[0]; y = $p[1]; space = 'screen' } })
        }
        for ($i = 0; $i -lt $half; $i++) {
            $x = if ($i % 2) { 0.3 } else { 0.7 }
            $times.clickElement += Measure-PiRequest $c.run @{ op = 'clickElement'; ref = $c.canvas.ref; quietMs = 0; position = @{ x = $x; y = 0.5 } }
        }
        for ($i = 0; $i -lt $n; $i++) { $times.keyPress += Measure-PiRequest $c.run ($c.keys + @{ op = 'keyPress'; quietMs = 0; keys = 'Shift' }) }
        $textBefore = ([string](Read-Pi $t 'canvas-text.txt')).Length
        $script:currentCase.evidence.textInputObserved = @()
        for ($i = 0; $i -lt 10; $i++) {
            $times.typeText += Measure-PiRequest $c.run ($c.keys + @{ op = 'typeText'; quietMs = 0; text = ('x' * 32) }) -RecordObservation
        }
        $expectedClicks = $clicksBefore + 2 * $half
        $clicks = Wait-Pi $t 'canvas-clicks.txt' { param($v) @(Get-Lines $v).Count -ge $expectedClicks } 15000
        $text = Wait-Pi $t 'canvas-text.txt' { param($v) $v.Length -ge $textBefore + 320 } 15000
        $summary = [ordered]@{}
        foreach ($name in $times.Keys) { $summary[$name] = Get-PiStats $times[$name] }
        $script:currentCase.evidence.latencyMs = $summary
        $script:currentCase.evidence.clicksExpected = 2 * $half
        $script:currentCase.evidence.clicksRecorded = @(Get-Lines (Read-Pi $t 'canvas-clicks.txt')).Count - $clicksBefore
        $script:currentCase.evidence.charactersExpected = 320
        $script:currentCase.evidence.charactersRecorded = ([string](Read-Pi $t 'canvas-text.txt')).Length - $textBefore
        Require-Pi ($null -ne $clicks -and $null -ne $text -and
            $script:currentCase.evidence.clicksRecorded -eq 2 * $half -and
            $script:currentCase.evidence.charactersRecorded -eq 320) 'The canvas did not record exactly the expected clicks and characters.'
    } finally { Stop-PiAgent $c.run }
}

# --- Main ---------------------------------------------------------------------------------------

$report = New-PiReport
$script:abortReason = $null
$script:currentCase = $null

if (!$Interactive) {
    foreach ($impl in $implementations) {
        foreach ($name in $Case) { Add-PiNotRun $report $impl $name 'Plan only: run with -Interactive to send input.' }
    }
    Save-PiReport $report
    Write-Host "Plan written to $OutputPath. No input was sent and no window was opened."
    return
}

if ($env:OS -ne 'Windows_NT' -or ![Environment]::UserInteractive) { throw 'An interactive Windows desktop is required.' }
foreach ($path in @($Jar, $CppAgent, $winFormsExe, (Join-Path $classes 'FrameworkFixture.class'))) {
    if (!(Test-Path -LiteralPath $path)) { throw "Missing build output: $path" }
}

Write-Host ''
Write-Host '=== PHYSICAL INPUT TEST ===' -ForegroundColor Yellow
Write-Host 'This run moves the real mouse, clicks, types and brings test windows to the front.' -ForegroundColor Yellow
Write-Host 'Do not touch the keyboard or mouse until it ends. Press Ctrl+C now to cancel.' -ForegroundColor Yellow
Write-Host "It starts after $CountdownSeconds s without any input (waiting up to $IdleWaitMinutes min)."
if (!(Wait-PiIdle $CountdownSeconds ($IdleWaitMinutes * 60))) {
    foreach ($impl in $implementations) { foreach ($name in $Case) { Add-PiNotRun $report $impl $name 'The PC never stayed idle long enough to start.' } }
    Save-PiReport $report
    throw 'The PC was in use; nothing was run.'
}

try {
    foreach ($impl in $implementations) {
        foreach ($name in $Case) {
            if ($script:abortReason) { Add-PiNotRun $report $impl $name $script:abortReason; continue }
            # The previous case's own input counts as activity, so two quiet seconds are enough here.
            if (!(Wait-PiIdle 2 120)) {
                $script:abortReason = 'Somebody used the PC during the run. The remaining cases were not run.'
                Add-PiNotRun $report $impl $name $script:abortReason
                continue
            }
            $row = [ordered]@{ agent = $impl; case = $name; description = $descriptions[$name]; status = 'PASS'
                startedUtc = [DateTime]::UtcNow.ToString('o'); steps = New-Object 'Collections.Generic.List[object]'; evidence = [ordered]@{} }
            $script:currentCase = $row
            $clock = [Diagnostics.Stopwatch]::StartNew()
            Write-Host "[$impl] $name ..." -NoNewline
            try {
                & "Case-$name" $impl
            } catch {
                $message = $_.Exception.Message
                if ($message -like 'NOT_RUN:*') { $row.status = 'NOT_RUN'; $row.reason = $message.Substring(8).Trim() }
                elseif ($message -like 'BLOCKED:*') { $row.status = 'BLOCKED'; $row.reason = $message.Substring(8).Trim() }
                elseif ($message -like 'ABORT:*') { $row.status = 'FAIL'; $row.reason = $script:abortReason }
                else { $row.status = 'FAIL'; $row.reason = $message }
            } finally {
                Stop-PiFixtures
                [PiProbe]::StopOccluder()
                $row.durationMs = [Math]::Round($clock.Elapsed.TotalMilliseconds)
                $row.steps = $row.steps.ToArray()
                # Nothing may stay pressed after a case, whatever its outcome.
                $row.heldAfter = [ordered]@{ leftButton = [PiProbe]::Down(1); rightButton = [PiProbe]::Down(2); middleButton = [PiProbe]::Down(4)
                    shift = [PiProbe]::Down(0x10); ctrl = [PiProbe]::Down(0x11); alt = [PiProbe]::Down(0x12) }
                if (@($row.heldAfter.Values) -contains $true -and $row.status -eq 'PASS') { $row.status = 'FAIL'; $row.reason = 'A key or button stayed down after the case.' }
                $report.cases.Add($row)
                $script:currentCase = $null
                Write-Host " $($row.status) $(if ($row.reason) { '- ' + $row.reason })"
                Save-PiReport $report
            }
        }
    }
} finally {
    Stop-PiFixtures
    [PiProbe]::StopOccluder()
    Save-PiReport $report
}
Write-Host "Report: $OutputPath  PASS=$($report.summary.PASS) FAIL=$($report.summary.FAIL) BLOCKED=$($report.summary.BLOCKED) NOT_RUN=$($report.summary.NOT_RUN)"
if ($report.summary.FAIL) { exit 1 }
