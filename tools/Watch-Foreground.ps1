<#
.SYNOPSIS
Records every change of the foreground window while a UI test runs, to show whether a test fixture took the focus.

.DESCRIPTION
Polls GetForegroundWindow until -DurationSeconds have passed or -StopFile exists, then writes a JSON report.
A change to a window of a known fixture process is counted in fixtureActivations. Changes made by the PC's user
appear as other transitions, so read them together with the time the test ran. The script only reads window state.

.EXAMPLE
$watch = Start-Job { & "$using:PWD/tools/Watch-Foreground.ps1" -StopFile "$using:PWD/target/watch.stop" -OutputPath "$using:PWD/target/foreground.json" }
& ./tools/Test-UiaFrameworks.ps1 -Framework Win32 -OutputPath target/framework-win32.json
New-Item target/watch.stop | Out-Null; Receive-Job $watch -Wait
#>
param(
    [string]$OutputPath = 'target/foreground-watch.json',
    [string]$StopFile,
    [int]$DurationSeconds = 3600,
    [int]$IntervalMs = 20
)

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class ForegroundWatch {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern IntPtr GetTopWindow(IntPtr parent);
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr window, out Rect rect);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
    public struct Rect { public int Left, Top, Right, Bottom; }
    // Visible, uncloaked top-level windows drawn above the foreground window that overlap it.
    public static IntPtr[] Above(IntPtr foreground) {
        var result = new System.Collections.Generic.List<IntPtr>();
        Rect target;
        if (foreground == IntPtr.Zero || !GetWindowRect(foreground, out target)) return result.ToArray();
        for (var window = GetTopWindow(IntPtr.Zero); window != IntPtr.Zero && window != foreground; window = GetWindow(window, 2)) {
            int cloaked;
            if (!IsWindowVisible(window) || IsIconic(window)) continue;
            if (DwmGetWindowAttribute(window, 14, out cloaked, 4) == 0 && cloaked != 0) continue;
            Rect rect;
            if (!GetWindowRect(window, out rect)) continue;
            if (rect.Right <= target.Left || rect.Left >= target.Right || rect.Bottom <= target.Top || rect.Top >= target.Bottom) continue;
            result.Add(window);
        }
        return result.ToArray();
    }
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr window, StringBuilder text, int count);
    public static uint ProcessOf(IntPtr window) { uint process; GetWindowThreadProcessId(window, out process); return process; }
    public static string TitleOf(IntPtr window) { var text = new StringBuilder(512); GetWindowText(window, text, text.Capacity); return text.ToString(); }
}
'@

# Processes the UI tests start as fixtures. powershell and java also run other things, so their window title decides.
$fixtureImages = 'win32', 'mfc', 'winforms-framework', 'WinFormsFixture', 'msaa-identity-fixture', 'delphi-vcl'
$fixtureHosts = 'powershell', 'java', 'javaw'

function Describe([IntPtr]$window) {
    $id = [ForegroundWatch]::ProcessOf($window)
    $name = $null
    try { $name = (Get-Process -Id $id -ErrorAction Stop).ProcessName } catch {}
    $title = [ForegroundWatch]::TitleOf($window)
    $fixture = ($fixtureImages -contains $name) -or (($fixtureHosts -contains $name) -and $title -match 'fixture')
    return [ordered]@{ at = (Get-Date).ToString('o'); window = [long]$window; processId = $id; process = $name; title = $title; fixture = $fixture }
}

$clock = [Diagnostics.Stopwatch]::StartNew()
$current = [ForegroundWatch]::GetForegroundWindow()
$initial = Describe $current
$transitions = New-Object 'Collections.Generic.List[object]'
# Fixture windows drawn over the user's foreground window without taking the focus.
$covering = New-Object 'Collections.Generic.List[object]'
$coveringNow = @{}
while ($clock.Elapsed.TotalSeconds -lt $DurationSeconds -and !($StopFile -and (Test-Path -LiteralPath $StopFile))) {
    Start-Sleep -Milliseconds $IntervalMs
    $window = [ForegroundWatch]::GetForegroundWindow()
    if ($window -ne $current) {
        $current = $window
        if ($window -ne [IntPtr]::Zero) { $transitions.Add((Describe $window)) }
    }
    $seen = @{}
    foreach ($above in [ForegroundWatch]::Above($window)) {
        $key = [long]$above
        $seen[$key] = $true
        if (!$coveringNow.ContainsKey($key)) {
            $entry = Describe $above
            $coveringNow[$key] = $entry
            if ($entry.fixture) { $covering.Add($entry) }
        }
    }
    foreach ($key in @($coveringNow.Keys)) { if (!$seen.ContainsKey($key)) { $coveringNow.Remove($key) } }
}

$fixtureActivations = @($transitions.ToArray() | Where-Object { $_.fixture })
$report = [ordered]@{
    startedWith = $initial
    seconds = [math]::Round($clock.Elapsed.TotalSeconds, 1)
    fixtureActivations = $fixtureActivations.Count
    fixtureWindowsOnTop = $covering.Count
    onTop = $covering.ToArray()
    transitions = $transitions.ToArray()
}
$directory = Split-Path -Parent $OutputPath
if ($directory) { [void][IO.Directory]::CreateDirectory($directory) }
[IO.File]::WriteAllText($OutputPath, ($report | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding $false))
"Foreground changes: $($transitions.Count), to fixture windows: $($fixtureActivations.Count). Report: $OutputPath"
foreach ($entry in $fixtureActivations) { "  $($entry.at) $($entry.process) [$($entry.processId)] '$($entry.title)'" }
"Fixture windows drawn over the foreground window: $($covering.Count)"
foreach ($entry in $covering) { "  $($entry.at) $($entry.process) [$($entry.processId)] '$($entry.title)'" }
