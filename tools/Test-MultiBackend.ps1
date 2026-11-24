# Multi-backend regression: UI Automation and Java Access Bridge in one Agent process.
# Run on a test desktop. Mutations are authorized only for the fixtures launched by this script.
# Every effect is judged by the state files of a fixture, never by an Agent reply.
[CmdletBinding()]
param(
    [ValidateSet('Java', 'Cpp', 'Both')][string]$Agent = 'Both',
    [ValidateSet('Functional', 'Performance', 'Resources', 'Soak')][string]$Mode = 'Functional',
    [ValidateSet('AwtMixed', 'Safety', 'JabFault', 'UiaFault', 'Environment', 'TargetRestart', 'IsolatedJab', 'UiaContexts', 'Metadata')]
    [string[]]$Scenario = @('AwtMixed', 'Safety', 'JabFault', 'UiaFault', 'Environment', 'TargetRestart'),
    [string]$Jar = 'target/desktop-agent.jar',
    [string]$CppAgent = 'target/cpp-agent/Release/cpp-agent.exe',
    [string]$FixtureRoot = 'target/framework-fixtures',
    [string]$FixtureJava = 'java.exe',
    # A second Java runtime for the JVM that must stay reachable while another JVM is silent.
    [string]$SecondFixtureJava,
    [string]$OutputPath = 'target/multi-backend.json',
    [string[]]$JvmOptions = @('-XX:+UseSerialGC', '-Xms16m'),
    # The 181 s wait that proves each backend expires its snapshot on its own clock.
    [switch]$IncludeExpiry,
    [ValidateRange(1, 10)][int]$Pairs = 3,
    [ValidateRange(1, 200)][int]$Iterations = 20,
    [ValidateRange(0, 20)][int]$Warmup = 3,
    [ValidateRange(10, 86400)][int]$DurationSeconds = 600,
    [ValidateRange(5, 600)][int]$SampleSeconds = 15
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UiaTest.Common.ps1')
. (Join-Path $PSScriptRoot 'UiaFrameworkCases.ps1')
. (Join-Path $PSScriptRoot 'JabFrameworkCases.ps1')

if ($env:OS -ne 'Windows_NT' -or ![Environment]::UserInteractive) { throw 'An interactive Windows test desktop is required.' }
$Jar = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Jar)
$CppAgent = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CppAgent)
$FixtureRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FixtureRoot)
$javaExe = (Get-Command java.exe -CommandType Application | Select-Object -First 1).Source
$fixtureJavaExe = (Get-Command $FixtureJava -CommandType Application | Select-Object -First 1).Source
$secondJavaExe = if ($SecondFixtureJava) { (Get-Command $SecondFixtureJava -CommandType Application | Select-Object -First 1).Source } else { $fixtureJavaExe }
$classes = Join-Path $FixtureRoot 'swing-awt'
$wpfScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../src/test/resources/windows-gui-fixture.ps1')).Path
$JvmOptions = ConvertTo-UiaJvmOptions $JvmOptions
$implementations = if ($Agent -eq 'Both') { @('Java', 'Cpp') } else { @($Agent) }
$bridgeProperty = '-Djavax.accessibility.assistive_technologies=com.sun.java.accessibility.AccessBridge'

if (!('MbProcessControl' -as [type])) {
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class MbProcessControl {
    [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr process);
    [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr process);
    [DllImport("user32.dll")] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder name, int bytes, out uint needed);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr window);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);

    // "Default" while the user's desktop receives input. Null on the lock screen or a secure desktop.
    public static string InputDesktop() {
        IntPtr desktop = OpenInputDesktop(0, false, 0x0001);
        if (desktop == IntPtr.Zero) return null;
        try {
            StringBuilder name = new StringBuilder(256);
            uint needed;
            return GetUserObjectInformation(desktop, 2, name, 512, out needed) ? name.ToString() : "";
        } finally { CloseDesktop(desktop); }
    }

    public static string WindowState(long handle) {
        IntPtr window = new IntPtr(handle);
        if (handle == 0) return "none";
        if (!IsWindowVisible(window)) return "hidden";
        // A window on another virtual desktop is cloaked: it exists, and UI Automation does not list it.
        int cloaked;
        if (DwmGetWindowAttribute(window, 14, out cloaked, 4) == 0 && cloaked != 0) return "cloaked";
        if (IsIconic(window)) return "minimized";
        return GetForegroundWindow() == window ? "foreground" : "background";
    }

    public static uint ForegroundProcess() {
        uint process;
        GetWindowThreadProcessId(GetForegroundWindow(), out process);
        return process;
    }
}
'@
}
$hostProbe = Initialize-UiaHostProbe

# What the desktop looked like: whether somebody was using the PC, whether the user's desktop
# received input at all, and how each fixture window was shown. A result is read against this.
function Get-MbHost {
    $now = [DateTimeOffset]::UtcNow
    $desktop = [MbProcessControl]::InputDesktop()
    $state = [ordered]@{ utc = $now.ToString('o'); inputDesktop = $desktop; inputDesktopAccessible = [bool]$desktop }
    if ($hostProbe) {
        $signals = Get-UiaHostSample 0 0 @()
        foreach ($key in 'userIdleMs','cpuBusyMs','cpuIdleMs','processorPerformanceRaw','processorPerformanceBase','acPower','batteryPercent') {
            if ($signals.Contains($key)) { $state[$key] = $signals[$key] }
        }
    }
    if ($null -ne $state.userIdleMs) { $state.lastInputEpochMs = $now.ToUnixTimeMilliseconds() - $state.userIdleMs }
    $foreground = [MbProcessControl]::ForegroundProcess()
    $state.foreground = if ($foreground) { 'external' } else { 'unavailable' }
    $state.fixtures = @(foreach ($target in $targets.ToArray()) {
        if (!$target.process) { continue }
        if ($target.process.Id -eq $foreground) { $state.foreground = $target.kind }
        $window = 0
        try { $target.process.Refresh(); if (!$target.process.HasExited) { $window = $target.process.MainWindowHandle.ToInt64() } } catch {}
        [ordered]@{ kind = $target.kind; processId = $target.process.Id; window = [MbProcessControl]::WindowState($window) }
    })
    return $state
}

# --- Fixtures -----------------------------------------------------------------------------------

$targets = New-Object 'Collections.Generic.List[object]'

function Start-MbTarget([string]$kind, [bool]$bridge = $true, [string]$java = $fixtureJavaExe, [string]$title) {
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('multi-backend-' + [guid]::NewGuid())
    [void][IO.Directory]::CreateDirectory($directory)
    if (!$title) { $title = "MB $kind fixture " + [guid]::NewGuid() }
    $target = @{ kind = $kind; stateDir = $directory; title = $title; bridge = $bridge }
    $start = New-Object Diagnostics.ProcessStartInfo
    if ($kind -eq 'Wpf') {
        $start.FileName = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        $start.Arguments = "-NoProfile -NonInteractive -STA -ExecutionPolicy RemoteSigned -File ""$wpfScript"" ""$directory"" ""$title"""
    } else {
        $start.FileName = $java
        $property = if ($bridge) { "$bridgeProperty " }
        if ($Mode -eq 'Functional') { $property += '-Ddesktop.fixture.events=true ' }
        $start.Arguments = "$property-cp ""$classes"" FrameworkFixture $($kind.ToLowerInvariant()) ""$directory"" ""$title"""
    }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $target.process = [Diagnostics.Process]::Start($start)
    $targets.Add($target)
    if (!(Wait-JabFile $directory 'ready' ([string]$target.process.Id) 30000)) { throw "The $kind fixture did not become ready." }
    return $target
}

function Stop-MbTarget($target) {
    if (!$target -or !$target.process) { return }
    try {
        if (!$target.process.HasExited) {
            [void][MbProcessControl]::NtResumeProcess($target.process.Handle)
            [IO.File]::WriteAllText((Join-Path $target.stateDir 'close-modal'), '')
            [IO.File]::WriteAllText((Join-Path $target.stateDir 'close-fixture'), '')
            if (!$target.process.WaitForExit(5000)) { $target.process.Kill(); [void]$target.process.WaitForExit(5000) }
        }
    } catch {} finally {
        $target.process.Dispose()
        $target.process = $null
        Remove-Item -LiteralPath $target.stateDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Stop-MbTargets {
    foreach ($target in $targets.ToArray()) { Stop-MbTarget $target }
    $targets.Clear()
}

function Read-Mb($target, [string]$file) { return Read-JabFile $target.stateDir $file }

# A state file that could be read. A reader can meet the file while it is replaced.
function Read-MbStable($target, [string]$file, [int]$timeoutMs = 3000) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $value = Read-Mb $target $file
        if ($null -ne $value) { return $value }
        Start-Sleep -Milliseconds 25
    } while ($clock.ElapsedMilliseconds -lt $timeoutMs)
    throw "The $($target.kind) fixture state $file could not be read."
}

function Wait-Mb($target, [string]$file, [string]$value, [int]$timeoutMs = 8000) {
    if (!(Wait-JabFile $target.stateDir $file $value $timeoutMs)) {
        throw "The $($target.kind) fixture did not report the expected $file state."
    }
}

function Send-MbCommand($target, [string]$command) {
    [IO.File]::WriteAllText((Join-Path $target.stateDir $command), '')
}

# --- Agent --------------------------------------------------------------------------------------

function Start-MbAgent([string]$implementation, [string]$backendMode, [int[]]$pids, [string]$extra) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $policy = ''
    foreach ($id in $pids) { $policy += " --allow-pid $id" }
    $policy += ' --allow-action invoke --allow-action setValue'
    if ($implementation -eq 'Java') {
        $name = @{ multi = 'multi'; uia = 'jna'; jab = 'jab' }[$backendMode]
        $start.FileName = $javaExe
        $start.Arguments = (($JvmOptions -join ' ') + " -jar ""$Jar""$policy --backend $name")
    } else {
        $start.FileName = $CppAgent
        $start.Arguments = "$policy --backend $backendMode".Trim()
    }
    if ($extra) { $start.Arguments += " $extra" }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    $trace = $Mode -eq 'Functional'
    if ($trace) { $start.EnvironmentVariables['AUTO_DESKTOP_NATIVE_TRACE'] = '1' }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $cli = Start-Cli $start -CaptureStderr:$trace
    return @{ cli = $cli; implementation = $implementation; mode = $backendMode; clock = $clock; processId = $cli.Id
        stderr = $(if ($trace) { $cli.StandardError.ReadToEndAsync() })
        trace = New-Object 'Collections.Generic.List[string]'
        requests = New-Object 'Collections.Generic.List[object]' }
}

# Ends the session at end of input and reports how the process left.
function Stop-MbAgent($run, [int]$timeoutMs = 30000) {
    if (!$run -or !$run.cli) { return $null }
    $result = [ordered]@{ exited = $false }
    try {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        if (!$run.cli.HasExited) { $run.cli.StandardInput.Close() }
        $result.exited = $run.cli.WaitForExit($timeoutMs)
        $result.exitMs = [Math]::Round($clock.Elapsed.TotalMilliseconds, 1)
        if ($result.exited) { $result.exitCode = $run.cli.ExitCode }
        else { $run.cli.Kill(); [void]$run.cli.WaitForExit(5000); $result.killed = $true }
        if ($run.stderr -and $run.stderr.Wait(1000)) {
            $stderr = $run.stderr.Result
            if ($run.auditSentinel) { $result.auditSentinelSeen = $stderr.Contains($run.auditSentinel) }
            foreach ($line in ($stderr -split '\r?\n')) {
                if ($line -match '^(jabNative |BACKEND_CLEANUP_FAILED: )') { $run.trace.Add($line) }
            }
        }
    } finally { $run.cli.Dispose(); $run.cli = $null }
    return $result
}

function Send-Mb($run, $command, [string]$expected = 'OK', [int]$timeoutMs = 30000, [string]$id = ([guid]::NewGuid().ToString())) {
    $entry = [ordered]@{ op = $command.op; backend = $command.backend }
    if ($Mode -eq 'Functional') {
        $entry.id = $id
        $entry.ref = $command.ref
        $entry.startedEpochMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        if ($command.op -in 'invoke','setValue') { $entry.hostBefore = Get-MbHost }
    }
    $run.requests.Add($entry)
    try { $response = Send-UiaRequest $run.cli $command $id $timeoutMs }
    catch { $entry.driverFailure = $_.Exception.Message; throw }
    $code = if ($response.reply.ok) { 'OK' } else { $response.reply.error.code }
    $entry.code = $code
    $entry.ms = [Math]::Round($response.ms, 1)
    if ($Mode -eq 'Functional') {
        $entry.finishedEpochMs = ([DateTimeOffset]$response.endUtc).ToUnixTimeMilliseconds()
        if ($response.reply.backends) { $entry.backends = $response.reply.backends }
        if ($command.op -eq 'snapshot' -and $response.reply.ok) {
            $entry.snapshot = @{ elements = @($response.reply.result.elements).Count; truncated = $response.reply.result.truncated
                edits = @($response.reply.result.elements | Where-Object role -eq 'Edit').Count }
        }
    }
    if ($expected -and $code -cne $expected) { throw "$($command.op) expected $expected, received $code." }
    return @{ code = $code; ms = $response.ms; reply = $response.reply; result = $response.reply.result }
}

# Put both frames in the pipe before reading a reply, as a client with an outstanding request can do.
function Send-MbPipelinedDuplicate($run, [string]$ref) {
    $id = 'pipelined-' + [guid]::NewGuid()
    $line = ConvertTo-Json -Compress @{ id = $id; op = 'invoke'; ref = $ref }
    $frames = [Text.Encoding]::UTF8.GetBytes("$line`n$line`n")
    $started = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $run.cli.StandardInput.BaseStream.Write($frames, 0, $frames.Length)
    $run.cli.StandardInput.BaseStream.Flush()
    foreach ($expected in 'OK','DUPLICATE_COMMAND') {
        $read = $run.cli.StandardOutput.ReadLineAsync()
        if (!$read.Wait(12000) -or !$read.Result) { throw 'The pipelined mutation received no reply.' }
        try { $reply = $read.Result | ConvertFrom-Json -ErrorAction Stop }
        catch { throw 'The pipelined mutation received invalid JSON.' }
        $code = if ($reply.ok) { 'OK' } else { $reply.error.code }
        $run.requests.Add([ordered]@{ id = $id; op = 'invoke'; ref = $ref; code = $code; pipelined = $true
            startedEpochMs = $started; finishedEpochMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() })
        Require-Mb ($reply.id -ceq $id -and $code -ceq $expected) "Pipelined mutation expected $expected, received $code."
        if ($reply.ok) { Require-Dispatch @{ result = $reply.result } }
    }
}

function Get-MbWindow($run, $target, [string]$name, [int]$timeoutMs = 10000) {
    if (!$name) { $name = $target.title }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $reply = (Send-Mb $run @{ op = 'listWindows' }).reply
        $rows = @($reply.result | Where-Object { $_.processId -eq $target.process.Id -and $_.name -ceq $name })
        if ($rows.Count -eq 1) { return @{ row = $rows[0]; id = $rows[0].windowId; status = $reply.backends } }
        Start-Sleep -Milliseconds 100
    } while ($clock.ElapsedMilliseconds -lt $timeoutMs)
    throw "Expected one window named '$name' for PID $($target.process.Id)."
}

function Get-MbSnapshot($run, [string]$window, [string]$backend, [string]$expected = 'OK') {
    $command = @{ op = 'snapshot'; windowId = $window; maxDepth = 32; maxElements = 2000 }
    if ($backend) { $command.backend = $backend }
    return Send-Mb $run $command $expected
}

function Find-Mb($run, $snapshot, $locator, [string]$expected = 'OK') {
    return (Send-Mb $run @{ op = 'findElement'; snapshotId = $snapshot.snapshotId; locator = $locator } $expected).result
}

function Get-MbInfo($run, [string]$ref, [string]$expected = 'OK', [int]$timeoutMs = 30000) {
    return Send-Mb $run @{ op = 'getElementInfo'; ref = $ref } $expected $timeoutMs
}

function Require-Mb($condition, [string]$message) { if (!$condition) { throw $message } }

function Require-Dispatch($response) {
    Require-Mb ($response.result.performed -eq $true -and $response.result.effectVerified -eq $false) 'An action reply must report dispatch without a verified effect.'
}

# The native Edit peer of the AWT text field, as UI Automation shows it.
function Get-AwtEditLocator($target) {
    $spec = Get-FrameworkSpec 'Awt'
    $id = $spec.edit
    $marker = Read-Mb $target 'edit-id.txt'
    if ($marker) { $id = $marker }
    return @{ role = 'Edit'; automationId = $id; className = $spec.editClass }
}

function Set-MbValue($run, $target, [string]$ref, [string]$value) {
    Require-Dispatch (Send-Mb $run @{ op = 'setValue'; ref = $ref; value = $value })
    Wait-Mb $target 'value.txt' $value
}

function Invoke-MbCounter($run, $target, [string]$ref) {
    $before = [int](Read-MbStable $target 'count.txt')
    Require-Dispatch (Send-Mb $run @{ op = 'invoke'; ref = $ref })
    Wait-Mb $target 'count.txt' ([string]($before + 1))
    return $before + 1
}

function Get-Backends($row) { return (@($row.backends) -join ',') }

function Get-BackendStatus($status, [string]$backend) {
    $entry = @($status | Where-Object { $_.backend -ceq $backend })[0]
    if (!$entry) { return 'ABSENT' }
    if ($entry.ok) { return 'OK' }
    return $entry.error.code
}

# --- Scenario bookkeeping -----------------------------------------------------------------------

function New-MbScenario([string]$name, [string]$implementation, [string]$method, [string]$summary) {
    return [ordered]@{ scenario = $name; agent = $implementation; method = $method; summary = $summary; status = 'NOT_RUN'
        startedUtc = [DateTime]::UtcNow.ToString('o'); checks = New-Object 'Collections.Generic.List[object]'; aborted = $false }
}

# One named check. A failure ends the scenario unless the check only records an observation.
function Step($row, [string]$name, [scriptblock]$body, [switch]$Continue) {
    $check = [ordered]@{ name = $name; status = 'NOT_RUN'; classification = 'NOT_RUN' }
    $row.checks.Add($check)
    if ($row.aborted) { $check.reason = 'An earlier step of this scenario failed.'; return }
    try {
        $evidence = & $body
        if ($null -ne $evidence) { $check.evidence = $evidence }
        $check.status = 'PASS'
        $check.classification = 'PASS'
    } catch {
        $check.status = 'FAIL'
        $check.classification = 'INCONCLUSIVE'
        $check.reason = $_.Exception.Message
        $check.host = Get-MbHost
        if (!$Continue) { $row.aborted = $true }
    }
}

function Complete-MbScenario($row, $run) {
    $states = @($row.checks | ForEach-Object status)
    $row.status = if ($states -contains 'FAIL') { 'FAIL' } elseif ($states -contains 'NOT_RUN' -or !$states.Count) { 'INCOMPLETE' } else { 'PASS' }
    $row.classification = switch ($row.status) { PASS { 'PASS' } FAIL { 'INCONCLUSIVE' } default { 'NOT_RUN' } }
    $row.hostAtEnd = Get-MbHost
    $row.fixtureTimeline = @(foreach ($target in $targets.ToArray()) {
        if (!$target.process) { continue }
        $events = Read-Mb $target 'events.tsv'
        [ordered]@{ kind = $target.kind; processId = $target.process.Id; timeline = @($events -split '\r?\n' |
            Where-Object { $_ -match '^\d+\t\d+\t(counterIncrement|modalCreated|modalOpened|modalShowReturned|modalClosed|fixtureRequestedModalClose|published:(modal|count)\.txt)\t\d+$' })
            counter = Read-Mb $target 'count.txt'; modal = Read-Mb $target 'modal.txt' }
    })
    if ($run) {
        $row.agentProcessId = $run.processId
        $row.requests = $run.requests.Count
        $row.requestLog = $run.requests
        $row.nativeTrace = $run.trace
    }
    $row.Remove('aborted')
}

# An independent IUIAutomation process checks the same HWND for the specific native Edit.
function Read-MbProviderEdit([long]$window, [int]$processId, [string]$automationId) {
    if ($automationId -notmatch '^-?\d+$') { throw 'The fixture edit ID is not a numeric native ID.' }
    $probe = Join-Path $PSScriptRoot 'Probe-UiaRuntimeIds.ps1'
    $arguments = "-NoProfile -NonInteractive -MTA -ExecutionPolicy RemoteSigned -File `"$probe`" -WindowHandle $window -ProcessId $processId -EditAutomationId $automationId -MaxDepth 32"
    $result = Read-Diagnostic "$env:SystemRoot/System32/WindowsPowerShell/v1.0/powershell.exe" $arguments 7000 -Utf8
    if ($result.exitCode -ne 0 -or !$result.stdout) { return @{ status = 'PROBE_UNAVAILABLE' } }
    $observed = $result.stdout | ConvertFrom-Json
    $status = if ($observed.matchingEdits -gt 0) { 'EDIT_PRESENT' }
        elseif ($observed.propertyErrors -or $observed.elementLimitReached) { 'PROBE_INCOMPLETE' }
        else { 'EDIT_ABSENT' }
    return @{ status = $status; elements = $observed.elements; propertyErrors = $observed.propertyErrors
        unusableRuntimeIds = $observed.unusableRuntimeIds; matchingEdits = $observed.matchingEdits }
}

function Test-UiaContexts([string]$implementation) {
    $row = New-MbScenario 'UiaContexts' $implementation 'real' 'Read the same AWT provider in foreground, background, minimized and restored states.'
    $run = $null
    try {
        $awt = Start-MbTarget 'Awt'
        $wpf = Start-MbTarget 'Wpf'
        $run = Start-MbAgent $implementation 'multi' @($awt.process.Id, $wpf.process.Id)
        $window = (Get-MbWindow $run $awt).id
        $other = (Get-MbWindow $run $wpf).id
        $locator = Get-AwtEditLocator $awt
        foreach ($context in 'foreground','background','minimized','restored') {
            switch ($context) {
                foreground {
                    [void][MbProcessControl]::ShowWindowAsync([IntPtr][long]$window, 9)
                    [void][MbProcessControl]::SetForegroundWindow([IntPtr][long]$window)
                }
                background { [void][MbProcessControl]::SetForegroundWindow([IntPtr][long]$other) }
                minimized  { [void][MbProcessControl]::ShowWindowAsync([IntPtr][long]$window, 6) }
                restored   { [void][MbProcessControl]::ShowWindowAsync([IntPtr][long]$window, 9) }
            }
            Start-Sleep -Milliseconds 250
            $seen = [MbProcessControl]::WindowState([long]$window)
            $expected = if ($context -eq 'restored') { @('foreground','background') } else { @($context) }
            if ($seen -notin $expected) {
                $row.checks.Add([ordered]@{ name = $context; status = 'NOT_RUN'; classification = 'NOT_RUN'
                    reason = "The window manager reported '$seen' after requesting '$context'."; host = Get-MbHost })
                continue
            }
            Step $row $context {
                $before = Read-MbProviderEdit $window $awt.process.Id $locator.automationId
                $shot = Get-MbSnapshot $run $window 'UIA' ''
                $found = if ($shot.code -ceq 'OK') {
                    (Send-Mb $run @{ op = 'findElement'; snapshotId = $shot.result.snapshotId; locator = $locator } '').code
                } else { $shot.code }
                $after = Read-MbProviderEdit $window $awt.process.Id $locator.automationId
                return [ordered]@{ windowState = $seen; providerBefore = $before; providerAfter = $after
                    snapshotCode = $shot.code; elements = @($shot.result.elements).Count; locatorCode = $found; host = Get-MbHost }
            }
            $last = $row.checks[$row.checks.Count - 1]
            if ($last.status -ne 'PASS') { continue }
            $evidence = $last.evidence
            if ($evidence.providerBefore.status -ceq 'EDIT_PRESENT' -and $evidence.providerAfter.status -ceq 'EDIT_PRESENT' -and
                $evidence.locatorCode -ceq 'OK') { continue }
            $last.status = 'FAIL'
            $last.classification = if ($evidence.providerBefore.status -ceq 'EDIT_ABSENT' -and
                $evidence.providerAfter.status -ceq 'EDIT_ABSENT' -and $evidence.locatorCode -ne 'OK') {
                'PROVIDER_LIMITATION'
            } else { 'INCONCLUSIVE' }
        }
        foreach ($context in 'virtualDesktop','lockedDesktop','secureInputDesktop') {
            $row.checks.Add([ordered]@{ name = $context; status = 'NOT_RUN'; classification = 'NOT_RUN'
                reason = 'Requires a dedicated desktop or VM session.' })
        }
    } catch { $row.failure = $_.Exception.Message }
    finally {
        Complete-MbScenario $row $run
        if ($run) { $row.exit = Stop-MbAgent $run }
        Stop-MbTargets
    }
    return $row
}

function Test-Metadata([string]$implementation) {
    $row = New-MbScenario 'Metadata' $implementation 'real' 'Compare the text entered into a Swing fixture with the accessibility metadata and audit stream.'
    $run = $null
    try {
        $swing = Start-MbTarget 'Swing'
        $run = Start-MbAgent $implementation 'jab' @($swing.process.Id)
        Step $row 'jabValueAndMetadataBoundary' {
            $window = (Get-MbWindow $run $swing).id
            $shot = (Get-MbSnapshot $run $window 'JAB').result
            $edit = Find-Mb $run $shot @{ role = 'Edit'; name = 'Fixture edit' }
            Require-Mb ($edit.setValueSupport -ceq 'unverified') 'The editable Swing row must describe the public bridge capability accurately.'
            $password = @($shot.elements | Where-Object nativeRole -ceq 'password text')
            Require-Mb ($password.Count -eq 1 -and $password[0].name -ceq '') 'The password role must have no exposed name.'
            $secret = 'metadata-sentinel-' + [guid]::NewGuid()
            $run.auditSentinel = $secret
            Set-MbValue $run $swing $edit.ref $secret
            $live = (Get-MbInfo $run $edit.ref).result
            $normal = (Get-MbSnapshot $run $window 'JAB').result
            $published = ConvertTo-Json -Compress -Depth 12 @($live, $normal)
            Require-Mb (!$published.Contains($secret) -and !$published.Contains('fixture-description-sentinel')) 'The editable value or description was exposed.'
            Send-MbCommand $swing 'expose-edit-name'
            Wait-Mb $swing 'metadata-name.txt' 'exposed'
            $changed = (Get-MbSnapshot $run $window 'JAB').result
            $named = Find-Mb $run $changed @{ role = 'Edit'; name = $secret }
            Require-Mb ($named.name -ceq $secret) 'The provider-defined dynamic name must remain usable as a locator.'
            Send-MbCommand $swing 'restore-edit-name'
            Wait-Mb $swing 'metadata-name.txt' 'restored'
            $end = Stop-MbAgent $run
            Require-Mb ($end.exited -and $end.exitCode -eq 0 -and $end.auditSentinelSeen -eq $false) 'The audit stream included fixture text or was unavailable.'
            return [ordered]@{ passwordNameRedacted = $true; typedValueOmitted = $true; descriptionOmitted = $true
                dynamicProviderNameIsObservable = $true; auditContainsTypedValue = $false }
        }
    } catch { $row.failure = $_.Exception.Message }
    finally {
        Complete-MbScenario $row $run
        if ($run) { [void](Stop-MbAgent $run) }
        Stop-MbTargets
    }
    return $row
}

# --- Scenarios ----------------------------------------------------------------------------------

# Text through UI Automation and buttons through Java Access Bridge on one AWT window, in one process.
function Test-AwtMixed([string]$implementation) {
    $row = New-MbScenario 'AwtMixed' $implementation 'real' 'One Agent process drives one AWT fixture: text through UIA, buttons and the modal dialog through JAB.'
    $s = @{}
    $run = $null
    try {
        $awt = Start-MbTarget 'Awt'
        $run = Start-MbAgent $implementation 'multi' @($awt.process.Id)
        Step $row 'capabilities' {
            $cap = (Send-Mb $run @{ op = 'getCapabilities' }).result
            $rows = @($cap.backends)
            Require-Mb ($cap.backend -ceq 'multi' -and $cap.available -and $cap.defaultBackend -ceq 'UIA' -and $rows.Count -eq 3 -and
                $rows[0].backend -ceq 'UIA' -and $rows[0].available -and $rows[1].backend -ceq 'JAB' -and $rows[1].available -and
                $rows[2].backend -ceq 'MSAA' -and $rows[2].available -and !$cap.physicalInput -and !$cap.screenshot -and @($cap.operations).Count -eq 9) 'All three backends must be available under the multi capability.'
            return [ordered]@{ bridge = $rows[1].bridge }
        }
        Step $row 'windowListedOnceWithBothBackends' {
            $window = Get-MbWindow $run $awt
            $s.window = $window.id
            Require-Mb ((Get-Backends $window.row) -ceq 'UIA,JAB,MSAA') "The AWT window lists backends '$(Get-Backends $window.row)'."
            Require-Mb ((Get-BackendStatus $window.status 'UIA') -ceq 'OK' -and (Get-BackendStatus $window.status 'JAB') -ceq 'OK') 'Both backends must answer the window list.'
            return [ordered]@{ windowId = $window.id; backends = @($window.row.backends) }
        }
        Step $row 'uiaSetValue' {
            $s.uia = (Get-MbSnapshot $run $s.window 'UIA').result
            Require-Mb ($s.uia.backend -ceq 'UIA' -and !@($s.uia.elements | Where-Object { $_.backend -cne 'UIA' }).Count) 'The UIA snapshot must hold UIA rows only.'
            $s.uiaEdit = Find-Mb $run $s.uia (Get-AwtEditLocator $awt)
            $s.value1 = 'uia-first-' + [guid]::NewGuid()
            Set-MbValue $run $awt $s.uiaEdit.ref $s.value1
            return [ordered]@{ elements = @($s.uia.elements).Count; fixtureValueMatched = $true }
        }
        Step $row 'jabInvoke' {
            $s.jab = (Get-MbSnapshot $run $s.window 'JAB').result
            Require-Mb ($s.jab.backend -ceq 'JAB' -and !@($s.jab.elements | Where-Object { $_.backend -cne 'JAB' }).Count) 'The JAB snapshot must hold JAB rows only.'
            $s.jabButton = Find-Mb $run $s.jab @{ role = 'Button'; name = 'Increment fixture counter' }
            $count = Invoke-MbCounter $run $awt $s.jabButton.ref
            return [ordered]@{ elements = @($s.jab.elements).Count; fixtureCount = $count }
        }
        Step $row 'uiaReferenceSurvivesJabSnapshot' {
            $live = (Get-MbInfo $run $s.uiaEdit.ref).result
            Require-Mb ($live.backend -ceq 'UIA' -and $live.ref -ceq $s.uiaEdit.ref) 'The UIA reference must outlive a JAB capture.'
        }
        Step $row 'jabOpensModal' {
            $opener = Find-Mb $run $s.jab @{ role = 'Button'; name = 'Open fixture modal' }
            Require-Dispatch (Send-Mb $run @{ op = 'invoke'; ref = $opener.ref })
            Wait-Mb $awt 'modal.txt' 'open'
            $modal = Get-MbWindow $run $awt "$($awt.title) modal"
            $s.modal = $modal.id
            Require-Mb ($modal.row.ownerWindowId -ceq $s.window) 'The modal row must name the fixture window as its owner.'
            return [ordered]@{ modalWindowId = $modal.id; backends = @($modal.row.backends) }
        }
        Step $row 'jabClosesModal' {
            $dialog = (Get-MbSnapshot $run $s.modal 'JAB').result
            $close = Find-Mb $run $dialog @{ role = 'Button'; name = 'Close fixture modal' }
            Require-Dispatch (Send-Mb $run @{ op = 'invoke'; ref = $close.ref })
            Wait-Mb $awt 'modal.txt' 'closed'
            [void](Get-MbSnapshot $run $s.modal 'JAB' 'WINDOW_NOT_FOUND')
        }
        Step $row 'uiaSetValueAgainWithEarlierReference' {
            # The UIA snapshot predates three JAB captures and the modal dialog.
            $s.value2 = 'uia-second-' + [guid]::NewGuid()
            Set-MbValue $run $awt $s.uiaEdit.ref $s.value2
            return [ordered]@{ fixtureValueMatched = $true }
        }
        Step $row 'uiaSetValueAgainWithNewSnapshot' {
            $again = (Get-MbSnapshot $run $s.window 'UIA').result
            $edit = Find-Mb $run $again (Get-AwtEditLocator $awt)
            [void](Get-MbInfo $run $s.uiaEdit.ref 'STALE_REFERENCE')
            $value = 'uia-third-' + [guid]::NewGuid()
            Set-MbValue $run $awt $edit.ref $value
            $s.jab = (Get-MbSnapshot $run $s.window 'JAB').result
            $button = Find-Mb $run $s.jab @{ role = 'Button'; name = 'Increment fixture counter' }
            $count = Invoke-MbCounter $run $awt $button.ref
            return [ordered]@{ fixtureValueMatched = $true; fixtureCount = $count }
        }
        Step $row 'sameAgentProcessThroughout' {
            $run.cli.Refresh()
            Require-Mb (!$run.cli.HasExited -and $run.cli.Id -eq $run.processId) 'The Agent process changed during the scenario.'
            return [ordered]@{ agentProcessId = $run.processId; requests = $run.requests.Count }
        }
        Step $row 'agentExit' {
            $exit = Stop-MbAgent $run
            Require-Mb ($exit.exited -and $exit.exitCode -eq 0) 'The Agent did not end with status 0.'
            return $exit
        }
    } catch {
        $row.failure = $_.Exception.Message
    } finally {
        Complete-MbScenario $row $run
        if ($run) { [void](Stop-MbAgent $run) }
        Stop-MbTargets
    }
    return $row
}

# Reference ownership, duplicate command IDs and the exposure of edit content.
function Test-Safety([string]$implementation) {
    $row = New-MbScenario 'Safety' $implementation 'real' 'Reference lifetime per backend, references of another backend or session, duplicate command IDs across backends, edit content.'
    $s = @{}
    $run = $null
    $other = $null
    try {
        $awt = Start-MbTarget 'Awt'
        $run = Start-MbAgent $implementation 'multi' @($awt.process.Id)
        $s.window = (Get-MbWindow $run $awt).id
        Step $row 'snapshotDefaultsToFirstBackend' {
            $implicit = (Get-MbSnapshot $run $s.window $null).result
            Require-Mb ($implicit.backend -ceq 'UIA' -and $implicit.elements[0].backend -ceq 'UIA') 'A snapshot that names no backend must use UIA.'
        }
        Step $row 'unknownBackendRefused' {
            [void](Get-MbSnapshot $run $s.window 'NOT_CONFIGURED' 'BACKEND_UNAVAILABLE')
            [void](Send-Mb $run @{ op = 'snapshot'; windowId = $s.window; backend = 7 } 'INVALID_REQUEST')
        }
        Step $row 'latestSnapshotPerBackend' {
            $s.uia1 = (Get-MbSnapshot $run $s.window 'UIA').result
            $s.jab1 = (Get-MbSnapshot $run $s.window 'JAB').result
            $s.uiaEdit1 = Find-Mb $run $s.uia1 (Get-AwtEditLocator $awt)
            $s.jabButton1 = Find-Mb $run $s.jab1 @{ role = 'Button'; name = 'Increment fixture counter' }
            $s.uia2 = (Get-MbSnapshot $run $s.window 'UIA').result
            [void](Get-MbInfo $run $s.uiaEdit1.ref 'STALE_REFERENCE')
            [void](Find-Mb $run $s.uia1 @{ role = 'Edit' } 'STALE_REFERENCE')
            Require-Mb ((Get-MbInfo $run $s.jabButton1.ref).result.backend -ceq 'JAB') 'A new UIA snapshot must leave JAB references in force.'
            $s.jab2 = (Get-MbSnapshot $run $s.window 'JAB').result
            [void](Get-MbInfo $run $s.jabButton1.ref 'STALE_REFERENCE')
            $s.uiaEdit2 = Find-Mb $run $s.uia2 (Get-AwtEditLocator $awt)
            Require-Mb ((Get-MbInfo $run $s.uiaEdit2.ref).result.backend -ceq 'UIA') 'A new JAB snapshot must leave UIA references in force.'
            $s.jabButton2 = Find-Mb $run $s.jab2 @{ role = 'Button'; name = 'Increment fixture counter' }
        }
        Step $row 'referenceOfOtherBackendRefused' {
            [void](Send-Mb $run @{ op = 'snapshot'; windowId = $s.window; backend = 'JAB'; scopeRef = $s.uiaEdit2.ref } 'STALE_REFERENCE')
            [void](Send-Mb $run @{ op = 'snapshot'; windowId = $s.window; backend = 'UIA'; scopeRef = $s.jabButton2.ref } 'STALE_REFERENCE')
            [void](Send-Mb $run @{ op = 'findElement'; snapshotId = $s.jab2.snapshotId; scopeRef = $s.uia2.elements[0].ref; locator = @{ role = 'Button' } } 'STALE_REFERENCE')
            [void](Send-Mb $run @{ op = 'findElement'; snapshotId = $s.uia2.snapshotId; scopeRef = $s.jab2.elements[0].ref; locator = @{ role = 'Edit' } } 'STALE_REFERENCE')
            # The refused requests reached no backend: both snapshots are still current.
            [void](Get-MbInfo $run $s.uiaEdit2.ref)
            [void](Get-MbInfo $run $s.jabButton2.ref)
        }
        Step $row 'scopedSnapshotStaysInItsBackend' {
            $scoped = (Send-Mb $run @{ op = 'snapshot'; windowId = $s.window; scopeRef = $s.jab2.elements[0].ref; maxDepth = 32; maxElements = 2000 }).result
            Require-Mb ($scoped.backend -ceq 'JAB' -and $scoped.elements[0].backend -ceq 'JAB') 'A scope selects the backend that issued it.'
            $s.jab2 = $scoped
            $s.jabButton2 = Find-Mb $run $scoped @{ role = 'Button'; name = 'Increment fixture counter' }
            [void](Get-MbInfo $run $s.uiaEdit2.ref)
        }
        Step $row 'duplicateCommandIdAcrossBackends' {
            $id = 'shared-' + [guid]::NewGuid()
            $value = 'duplicate-' + [guid]::NewGuid()
            Require-Dispatch (Send-Mb $run @{ op = 'setValue'; ref = $s.uiaEdit2.ref; value = $value } 'OK' 30000 $id)
            Wait-Mb $awt 'value.txt' $value
            $before = Read-MbStable $awt 'count.txt'
            [void](Send-Mb $run @{ op = 'invoke'; ref = $s.jabButton2.ref } 'DUPLICATE_COMMAND' 30000 $id)
            Assert-MbUnchanged $awt 'count.txt' $before 'The counter changed during the duplicate observation window:'
            $id = 'shared-' + [guid]::NewGuid()
            Require-Dispatch (Send-Mb $run @{ op = 'invoke'; ref = $s.jabButton2.ref } 'OK' 30000 $id)
            Wait-Mb $awt 'count.txt' ([string]([int]$before + 1))
            [void](Send-Mb $run @{ op = 'setValue'; ref = $s.uiaEdit2.ref; value = 'must-not-arrive' } 'DUPLICATE_COMMAND' 30000 $id)
            Assert-MbUnchanged $awt 'value.txt' $value 'The text changed during the duplicate observation window:'
            $id = 'same-backend-' + [guid]::NewGuid()
            $newCount = [int](Read-MbStable $awt 'count.txt') + 1
            Require-Dispatch (Send-Mb $run @{ op = 'invoke'; ref = $s.jabButton2.ref } 'OK' 30000 $id)
            Wait-Mb $awt 'count.txt' ([string]$newCount)
            [void](Send-Mb $run @{ op = 'invoke'; ref = $s.jabButton2.ref } 'DUPLICATE_COMMAND' 30000 $id)
            $prior = $s.jabButton2.ref
            $s.jab2 = (Get-MbSnapshot $run $s.window 'JAB').result
            [void](Send-Mb $run @{ op = 'invoke'; ref = $prior } 'DUPLICATE_COMMAND' 30000 $id)
            Assert-MbUnchanged $awt 'count.txt' ([string]$newCount) 'An extra counter event was observed:'
            $s.jabButton2 = Find-Mb $run $s.jab2 @{ role = 'Button'; name = 'Increment fixture counter' }
            Send-MbPipelinedDuplicate $run $s.jabButton2.ref
            Wait-Mb $awt 'count.txt' ([string]($newCount + 1))
            Assert-MbUnchanged $awt 'count.txt' ([string]($newCount + 1)) 'The pipelined command produced an extra counter event:'
        }
        Step $row 'referenceOfOtherSessionRefused' {
            $other = Start-MbAgent $implementation 'multi' @($awt.process.Id)
            $s.other = $other
            $foreign = (Get-MbSnapshot $other $s.window 'JAB').result
            $button = Find-Mb $other $foreign @{ role = 'Button'; name = 'Increment fixture counter' }
            $before = Read-MbStable $awt 'count.txt'
            [void](Send-Mb $run @{ op = 'invoke'; ref = $button.ref } 'STALE_REFERENCE')
            [void](Send-Mb $run @{ op = 'findElement'; snapshotId = $foreign.snapshotId; locator = @{ role = 'Button' } } 'STALE_REFERENCE')
            [void](Send-Mb $other @{ op = 'getElementInfo'; ref = $s.uiaEdit2.ref } 'STALE_REFERENCE')
            Assert-MbUnchanged $awt 'count.txt' $before 'A reference of another session reached the fixture:'
        }
        Step $row 'editContentNotExposed' {
            # The text that UIA wrote must not come back in any row of either backend.
            $secret = 'SENTINEL' + ([guid]::NewGuid().ToString('N'))
            Set-MbValue $run $awt $s.uiaEdit2.ref $secret
            $rows = @((Get-MbSnapshot $run $s.window 'UIA').result.elements) + @((Get-MbSnapshot $run $s.window 'JAB').result.elements)
            $leaks = @($rows | Where-Object { (ConvertTo-Json -Compress -Depth 6 $_).Contains($secret) })
            Require-Mb (!$leaks.Count) "Edit content appeared in $($leaks.Count) snapshot row(s)."
            return [ordered]@{ rowsInspected = $rows.Count; rowsWithEditContent = 0
                jabEditNames = @($rows | Where-Object { $_.backend -ceq 'JAB' -and $_.role -ceq 'Edit' } | ForEach-Object name)
                uiaEditNames = @($rows | Where-Object { $_.backend -ceq 'UIA' -and $_.role -ceq 'Edit' } | ForEach-Object name) }
        }
        if ($IncludeExpiry) {
            Step $row 'eachBackendExpiresOnItsOwnClock' {
                $uia = (Get-MbSnapshot $run $s.window 'UIA').result
                $edit = Find-Mb $run $uia (Get-AwtEditLocator $awt)
                Start-Sleep -Seconds 61
                $jab = (Get-MbSnapshot $run $s.window 'JAB').result
                $button = Find-Mb $run $jab @{ role = 'Button'; name = 'Increment fixture counter' }
                Start-Sleep -Seconds 60
                [void](Get-MbInfo $run $edit.ref 'STALE_REFERENCE')
                [void](Send-Mb $run @{ op = 'setValue'; ref = $edit.ref; value = 'expired' } 'STALE_REFERENCE')
                [void](Get-MbInfo $run $button.ref)
                Start-Sleep -Seconds 61
                [void](Get-MbInfo $run $button.ref 'STALE_REFERENCE')
                return [ordered]@{ uiaStaleAfterSeconds = 121; jabStillValidAtAgeSeconds = 60; jabStaleAfterSeconds = 121 }
            }
        }
    } catch {
        $row.failure = $_.Exception.Message
    } finally {
        Complete-MbScenario $row $run
        if ($s.other) { [void](Stop-MbAgent $s.other) }
        if ($run) { [void](Stop-MbAgent $run) }
        Stop-MbTargets
    }
    return $row
}

# Throws when the fixture state changes within the period. A read that failed is counted, not taken
# for a change, and the state has to be read back unchanged at least once.
function Assert-MbUnchanged($target, [string]$file, [string]$value, [string]$message, [int]$milliseconds = 1200) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $same = 0
    $unreadable = 0
    do {
        $now = Read-Mb $target $file
        if ($null -eq $now) { $unreadable++ }
        elseif ($now -cne $value) { throw "$message $file changed." }
        else { $same++ }
        Start-Sleep -Milliseconds 50
    } while ($clock.ElapsedMilliseconds -lt $milliseconds)
    if (!$same) { throw "$message $file could not be read back ($unreadable failed reads)." }
}

# PoC: a separate process and PID allowlist for each JAB target, plus a standalone UIA process.
function Test-IsolatedJab([string]$implementation) {
    $row = New-MbScenario 'IsolatedJab' $implementation 'real' 'Two separate JAB clients and a standalone UIA client while JVM A is inside a Swing modal listener.'
    $workers = [ordered]@{}
    $s = @{}
    try {
        $a = Start-MbTarget 'Swing'
        $b = Start-MbTarget 'Awt' $true $secondJavaExe
        $wpf = Start-MbTarget 'Wpf'
        $workers.a = Start-MbAgent $implementation 'jab' @($a.process.Id)
        $workers.b = Start-MbAgent $implementation 'jab' @($b.process.Id)
        $workers.uia = Start-MbAgent $implementation 'uia' @($wpf.process.Id)
        Step $row 'baselineThreeProcesses' {
            $s.aWindow = (Get-MbWindow $workers.a $a).id
            $s.bWindow = (Get-MbWindow $workers.b $b).id
            $s.wpfWindow = (Get-MbWindow $workers.uia $wpf).id
            $shot = (Get-MbSnapshot $workers.a $s.aWindow 'JAB').result
            $s.opener = Find-Mb $workers.a $shot @{ role = 'Button'; name = 'Open fixture modal' }
            $s.aRef = (Find-Mb $workers.a $shot @{ role = 'Button'; name = 'Increment fixture counter' }).ref
            $shot = (Get-MbSnapshot $workers.b $s.bWindow 'JAB').result
            $s.bRef = (Find-Mb $workers.b $shot @{ role = 'Button'; name = 'Increment fixture counter' }).ref
            $shot = (Get-MbSnapshot $workers.uia $s.wpfWindow 'UIA').result
            $s.wpfRef = (Find-Mb $workers.uia $shot @{ automationId = 'fixtureIncrement'; role = 'Button' }).ref
            [void](Invoke-MbCounter $workers.b $b $s.bRef)
            [void](Invoke-MbCounter $workers.uia $wpf $s.wpfRef)
        }
        Step $row 'observeSeparateProcessesDuringModal' {
            $aReply = Send-Mb $workers.a @{ op = 'invoke'; ref = $s.opener.ref } 'ACTION_OUTCOME_UNKNOWN'
            Wait-Mb $a 'modal.txt' 'open'
            $before = [int](Read-MbStable $b 'count.txt')
            $bInfo = Get-MbInfo $workers.b $s.bRef ''
            $bInvoke = Send-Mb $workers.b @{ op = 'invoke'; ref = $s.bRef } ''
            $bSnapshot = Get-MbSnapshot $workers.b $s.bWindow 'JAB' ''
            $wpfCount = Invoke-MbCounter $workers.uia $wpf $s.wpfRef
            if ($bInvoke.code -ceq 'OK') { Wait-Mb $b 'count.txt' ([string]($before + 1)) }
            else { Assert-MbUnchanged $b 'count.txt' ([string]$before) 'B changed while its bridge reported a failure:' }
            Require-Mb ((Read-Mb $a 'modal.txt') -ceq 'open') 'A did not remain modal while the other processes were tested.'
            $s.bCountDuring = Read-MbStable $b 'count.txt'
            $s.bSnapshotCode = $bSnapshot.code
            return [ordered]@{ aCode = $aReply.code; aMs = $aReply.ms; aModal = 'open'; bInfo = $bInfo.code; bInvoke = $bInvoke.code
                bInvokeMs = $bInvoke.ms; bSnapshot = $bSnapshot.code; bSnapshotMs = $bSnapshot.ms
                bCountBefore = $before; bCountDuring = $s.bCountDuring; wpfCount = $wpfCount
                jvmIsolation = ($bInfo.code -ceq 'OK' -and $bInvoke.code -ceq 'OK' -and $bSnapshot.code -ceq 'OK') }
        } -Continue
        Step $row 'resumeRecoverAndRestartBridgeProcess' {
            Require-Mb ($null -ne $s.bCountDuring) 'The isolation observation did not complete.'
            Send-MbCommand $a 'close-modal'
            Wait-Mb $a 'modal.txt' 'closed'
            Start-Sleep -Milliseconds 350
            [void](Get-MbInfo $workers.a $s.aRef)
            if ($s.bSnapshotCode -cne 'OK') { [void](Get-MbInfo $workers.b $s.bRef 'STALE_REFERENCE') }
            Assert-MbUnchanged $b 'count.txt' $s.bCountDuring 'B received a delayed action after A recovered:' 750
            $stopped = Stop-MbAgent $workers.b
            Require-Mb ($stopped.exited -and $stopped.exitCode -eq 0) 'B did not shut down normally once A recovered.'
            $workers.restarted = Start-MbAgent $implementation 'jab' @($b.process.Id)
            [void](Get-MbInfo $workers.restarted $s.bRef 'STALE_REFERENCE')
            $shot = (Get-MbSnapshot $workers.restarted $s.bWindow 'JAB').result
            $button = Find-Mb $workers.restarted $shot @{ role = 'Button'; name = 'Increment fixture counter' }
            return [ordered]@{ previousWorkerExit = $stopped; bCountAfterRestart = (Invoke-MbCounter $workers.restarted $b $button.ref) }
        }
    } catch {
        $row.failure = $_.Exception.Message
    } finally {
        if ($a -and $a.process) { Send-MbCommand $a 'close-modal' }
        Complete-MbScenario $row $null
        $row.workers = [ordered]@{}
        foreach ($entry in $workers.GetEnumerator()) {
            $exit = Stop-MbAgent $entry.Value
            $row.workers[$entry.Key] = @{ pid = $entry.Value.processId; requests = $entry.Value.requests
                nativeTrace = $entry.Value.trace; exit = $exit }
        }
        Stop-MbTargets
    }
    return $row
}

# A Swing listener that opens a modal dialog keeps its JVM from answering the bridge. Nothing is injected.
function Test-JabFault([string]$implementation) {
    $row = New-MbScenario 'JabFault' $implementation 'real' 'A Swing button opens a modal dialog from its listener. JAB stops answering. UIA keeps working on a WPF window in the same Agent.'
    $s = @{}
    $run = $null
    try {
        $swing = Start-MbTarget 'Swing'
        $awt = Start-MbTarget 'Awt' $true $secondJavaExe
        $forms = Start-MbTarget 'Wpf'
        $run = Start-MbAgent $implementation 'multi' @($swing.process.Id, $awt.process.Id, $forms.process.Id)
        Step $row 'windowsAndBackends' {
            $s.swing = (Get-MbWindow $run $swing)
            $s.awt = (Get-MbWindow $run $awt)
            $s.forms = (Get-MbWindow $run $forms)
            Require-Mb ((Get-Backends $s.swing.row) -ceq 'UIA,JAB,MSAA' -and (Get-Backends $s.awt.row) -ceq 'UIA,JAB,MSAA' -and (Get-Backends $s.forms.row) -ceq 'UIA,MSAA') 'Java windows list all three backends, and WPF lists UIA and MSAA.'
            return [ordered]@{ swing = @($s.swing.row.backends); awt = @($s.awt.row.backends); wpf = @($s.forms.row.backends)
                awtRuntime = Read-Mb $awt 'framework.txt'; swingRuntime = Read-Mb $swing 'framework.txt' }
        }
        Step $row 'swingEditContentNotExposed' {
            $shot = (Get-MbSnapshot $run $s.swing.id 'JAB').result
            $edit = Find-Mb $run $shot @{ role = 'Edit'; name = 'Fixture edit' }
            $secret = 'SENTINEL' + ([guid]::NewGuid().ToString('N'))
            Set-MbValue $run $swing $edit.ref $secret
            $rows = @((Get-MbSnapshot $run $s.swing.id 'JAB').result.elements)
            $leaks = @($rows | Where-Object { (ConvertTo-Json -Compress -Depth 6 $_).Contains($secret) })
            Require-Mb (!$leaks.Count) "Edit content appeared in $($leaks.Count) JAB row(s)."
            return [ordered]@{ rowsInspected = $rows.Count; rowsWithEditContent = 0 }
        }
        Step $row 'baselineBeforeFault' {
            $s.jab = (Get-MbSnapshot $run $s.swing.id 'JAB').result
            $s.increment = Find-Mb $run $s.jab @{ role = 'Button'; name = 'Increment fixture counter' }
            $s.opener = Find-Mb $run $s.jab @{ role = 'Button'; name = 'Open fixture modal' }
            [void](Invoke-MbCounter $run $swing $s.increment.ref)
            $s.uia = (Get-MbSnapshot $run $s.forms.id 'UIA').result
            $s.formsEdit = Find-Mb $run $s.uia @{ automationId = 'fixtureEdit' }
            $s.formsButton = Find-Mb $run $s.uia @{ automationId = 'fixtureIncrement'; role = 'Button' }
        }
        Step $row 'jabActionOutcomeUnknown' {
            $id = 'modal-' + [guid]::NewGuid()
            $reply = Send-Mb $run @{ op = 'invoke'; ref = $s.opener.ref } 'ACTION_OUTCOME_UNKNOWN' 30000 $id
            [void](Send-Mb $run @{ op = 'invoke'; ref = $s.opener.ref } 'DUPLICATE_COMMAND' 30000 $id)
            Wait-Mb $swing 'modal.txt' 'open'
            return [ordered]@{ code = $reply.code; ms = [Math]::Round($reply.ms); fixtureModal = Read-Mb $swing 'modal.txt' }
        }
        Step $row 'jabRequestsFailWhileSilent' {
            $info = Get-MbInfo $run $s.increment.ref 'TARGET_NOT_RESPONDING'
            return [ordered]@{ code = $info.code; ms = [Math]::Round($info.ms) }
        }
        Step $row 'windowListNamesFailedBackend' {
            $reply = (Send-Mb $run @{ op = 'listWindows' }).reply
            $formsRow = @($reply.result | Where-Object { $_.windowId -ceq $s.forms.id })
            $swingRow = @($reply.result | Where-Object { $_.windowId -ceq $s.swing.id })
            Require-Mb ((Get-BackendStatus $reply.backends 'UIA') -ceq 'OK' -and (Get-BackendStatus $reply.backends 'JAB') -ceq 'TARGET_NOT_RESPONDING') 'The window list must report the failed backend.'
            Require-Mb ($formsRow.Count -eq 1 -and $swingRow.Count -eq 1 -and (Get-Backends $swingRow[0]) -ceq 'UIA,MSAA') 'UIA and MSAA rows must still be listed.'
            $cap = (Send-Mb $run @{ op = 'getCapabilities' }).result
            return [ordered]@{ backends = @($reply.backends | ForEach-Object { [ordered]@{ backend = $_.backend; status = (Get-BackendStatus $reply.backends $_.backend) } })
                capabilities = @($cap.backends | ForEach-Object { [ordered]@{ backend = $_.backend; available = $_.available } }) }
        }
        Step $row 'uiaReadsAndActsAfterJabFailure' {
            # References taken before the fault, then a new snapshot taken during it.
            [void](Invoke-MbCounter $run $forms $s.formsButton.ref)
            $shot = (Get-MbSnapshot $run $s.forms.id 'UIA').result
            $s.formsEdit = Find-Mb $run $shot @{ automationId = 'fixtureEdit' }
            $s.formsButton = Find-Mb $run $shot @{ automationId = 'fixtureIncrement'; role = 'Button' }
            $value = 'during-jab-fault-' + [guid]::NewGuid()
            Set-MbValue $run $forms $s.formsEdit.ref $value
            $count = Invoke-MbCounter $run $forms $s.formsButton.ref
            return [ordered]@{ elements = @($shot.elements).Count; fixtureValueMatched = $true; fixtureCount = $count }
        }
        Step $row 'jabRecoversWithEarlierReferences' {
            Send-MbCommand $swing 'close-modal'
            Wait-Mb $swing 'modal.txt' 'closed'
            $clock = [Diagnostics.Stopwatch]::StartNew()
            do {
                $info = Get-MbInfo $run $s.increment.ref ''
                if ($info.code -cne 'OK') { Start-Sleep -Milliseconds 100 }
            } while ($info.code -cne 'OK' -and $clock.ElapsedMilliseconds -lt 5000)
            Require-Mb ($info.code -ceq 'OK') "The reference issued before the fault answered $($info.code) after recovery."
            $count = Invoke-MbCounter $run $swing $s.increment.ref
            [void](Get-MbInfo $run $s.formsEdit.ref)
            return [ordered]@{ recoveryMs = $clock.ElapsedMilliseconds; fixtureCount = $count }
        }
        # JVM isolation is a separate question from backend isolation: the second JVM is healthy.
        Step $row 'otherJvmWhileOneJvmIsSilent' {
            # A click that opens a modal dialog cannot return before the dialog closes. Keep what happened if it does.
            $second = Send-Mb $run @{ op = 'invoke'; ref = $s.opener.ref } '' 30000
            $opened = Wait-JabFile $swing.stateDir 'modal.txt' 'open' 5000
            if ($second.code -cne 'ACTION_OUTCOME_UNKNOWN' -or !$opened) {
                $probe = Get-MbInfo $run $s.increment.ref ''
                throw "The second modal-opening click answered $($second.code) after $([Math]::Round($second.ms)) ms. Modal opened within 5 s: $opened. Fixture modal state: $(Read-Mb $swing 'modal.txt'). Next bridge request: $($probe.code) after $([Math]::Round($probe.ms)) ms."
            }
            $viaJab = Get-MbSnapshot $run $s.awt.id 'JAB' ''
            $viaUia = (Get-MbSnapshot $run $s.awt.id 'UIA').result
            $edit = Find-Mb $run $viaUia (Get-AwtEditLocator $awt)
            $value = 'awt-through-uia-' + [guid]::NewGuid()
            Set-MbValue $run $awt $edit.ref $value
            $s.otherJvmCode = $viaJab.code
            return [ordered]@{ jabSnapshotOfHealthyJvm = $viaJab.code; jabSnapshotMs = [Math]::Round($viaJab.ms)
                jvmIsolated = ($viaJab.code -ceq 'OK'); uiaTextOnHealthyJvmMatched = $true }
        } -Continue
        Step $row 'agentExitsWhileJvmIsSilent' {
            Require-Mb ((Read-Mb $swing 'modal.txt') -ceq 'open') 'The modal dialog must be open for this check.'
            $exit = Stop-MbAgent $run 30000
            Require-Mb ($exit.exited) 'The Agent did not end while a JVM was silent.'
            $swing.process.Refresh(); $awt.process.Refresh(); $forms.process.Refresh()
            Require-Mb (!$swing.process.HasExited -and !$awt.process.HasExited -and !$forms.process.HasExited) 'A fixture ended with the Agent.'
            return $exit
        }
        Step $row 'targetsUsableByNextAgent' {
            Send-MbCommand $swing 'close-modal'
            Wait-Mb $swing 'modal.txt' 'closed'
            Start-Sleep -Milliseconds 500
            $run = Start-MbAgent $implementation 'multi' @($swing.process.Id, $awt.process.Id, $forms.process.Id)
            $s.next = $run
            $shot = (Get-MbSnapshot $run (Get-MbWindow $run $swing).id 'JAB').result
            $button = Find-Mb $run $shot @{ role = 'Button'; name = 'Increment fixture counter' }
            $count = Invoke-MbCounter $run $swing $button.ref
            $second = (Get-MbSnapshot $run (Get-MbWindow $run $awt).id 'JAB').result
            return [ordered]@{ swingCount = $count; awtElements = @($second.elements).Count }
        }
    } catch {
        $row.failure = $_.Exception.Message
    } finally {
        Complete-MbScenario $row $run
        if ($s.next) { [void](Stop-MbAgent $s.next) }
        if ($run) { [void](Stop-MbAgent $run) }
        Stop-MbTargets
    }
    return $row
}

# The process of a WPF window is suspended, so its UIA provider cannot answer. This is injected.
function Test-UiaFault([string]$implementation) {
    $row = New-MbScenario 'UiaFault' $implementation 'faultInjection' 'The process of a WPF window is suspended. UIA exceeds its deadline. JAB keeps working on an AWT window in the same Agent.'
    $s = @{}
    $run = $null
    try {
        $awt = Start-MbTarget 'Awt'
        $forms = Start-MbTarget 'Wpf'
        $run = Start-MbAgent $implementation 'multi' @($awt.process.Id, $forms.process.Id)
        Step $row 'baselineBeforeFault' {
            $s.awt = (Get-MbWindow $run $awt).id
            $s.forms = (Get-MbWindow $run $forms).id
            $s.jab = (Get-MbSnapshot $run $s.awt 'JAB').result
            $s.jabButton = Find-Mb $run $s.jab @{ role = 'Button'; name = 'Increment fixture counter' }
            [void](Invoke-MbCounter $run $awt $s.jabButton.ref)
            $s.uia = (Get-MbSnapshot $run $s.forms 'UIA').result
            $s.formsEdit = Find-Mb $run $s.uia @{ automationId = 'fixtureEdit' }
            $s.previousCommand = 'before-uia-fault-' + [guid]::NewGuid()
            $value = 'before-fault-' + [guid]::NewGuid()
            Require-Dispatch (Send-Mb $run @{ op = 'setValue'; ref = $s.formsEdit.ref; value = $value } 'OK' 30000 $s.previousCommand)
            Wait-Mb $forms 'value.txt' $value
        }
        Step $row 'uiaRequestFailsOnSuspendedTarget' {
            Require-Mb ([MbProcessControl]::NtSuspendProcess($forms.process.Handle) -eq 0) 'The WPF fixture could not be suspended.'
            $s.suspended = $true
            $reply = Get-MbSnapshot $run $s.forms 'UIA' ''
            Require-Mb ($reply.code -cne 'OK') 'UIA answered for a suspended process.'
            $s.uiaFaultCode = $reply.code
            return [ordered]@{ code = $reply.code; ms = [Math]::Round($reply.ms) }
        }
        Step $row 'jabReadsAndActsAfterUiaFailure' {
            $info = Get-MbInfo $run $s.jabButton.ref
            $count = Invoke-MbCounter $run $awt $s.jabButton.ref
            $shot = (Get-MbSnapshot $run $s.awt 'JAB').result
            $s.jabButton = Find-Mb $run $shot @{ role = 'Button'; name = 'Increment fixture counter' }
            $count = Invoke-MbCounter $run $awt $s.jabButton.ref
            return [ordered]@{ earlierReferenceMs = [Math]::Round($info.ms); fixtureCount = $count; elements = @($shot.elements).Count }
        }
        Step $row 'faultedBackendIsReported' {
            $cap = (Send-Mb $run @{ op = 'getCapabilities' }).result
            $list = Send-Mb $run @{ op = 'listWindows' } ''
            $next = Get-MbSnapshot $run $s.awt 'UIA' ''
            Require-Mb (@($cap.backends)[1].available -eq $true) 'JAB must stay available.'
            return [ordered]@{ capabilities = @($cap.backends | ForEach-Object { [ordered]@{ backend = $_.backend; available = $_.available; reason = $_.reason } })
                listWindows = $list.code; listWindowsMs = [Math]::Round($list.ms)
                listBackends = @($list.reply.backends | ForEach-Object { [ordered]@{ backend = $_.backend; status = (Get-BackendStatus $list.reply.backends $_.backend) } })
                uiaSnapshotOfOtherWindow = $next.code }
        } -Continue
        Step $row 'uiaReturnsWithoutAgentRestart' {
            [void][MbProcessControl]::NtResumeProcess($forms.process.Handle)
            $s.suspended = $false
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $codes = New-Object 'Collections.Generic.List[string]'
            $attempts = New-Object 'Collections.Generic.List[object]'
            $edit = $null
            do {
                $shot = Get-MbSnapshot $run $s.awt 'UIA' ''
                $codes.Add($shot.code)
                $attempt = [ordered]@{ atMs = $clock.ElapsedMilliseconds; code = $shot.code; ms = [Math]::Round($shot.ms, 1) }
                if ($shot.code -ceq 'OK') {
                    # The first tree after the restart is kept as it came, whole or not.
                    $attempt.elements = @($shot.result.elements).Count
                    $attempt.truncated = $shot.result.truncated
                    $found = Send-Mb $run @{ op = 'findElement'; snapshotId = $shot.result.snapshotId; locator = (Get-AwtEditLocator $awt) } ''
                    $attempt.findEdit = $found.code
                    if ($found.code -ceq 'OK') { $edit = $found.result }
                }
                $attempts.Add($attempt)
                if (!$edit) { Start-Sleep -Milliseconds 500 }
            } while (!$edit -and $clock.Elapsed.TotalSeconds -lt 60)
            Require-Mb ($null -ne $edit) "UIA did not return in this Agent process: $(($attempts | ForEach-Object { "$($_.code)/$($_.elements)/$($_.findEdit)" } | Select-Object -Unique) -join ', ')."
            $first = @($attempts | Where-Object { $_.code -ceq 'OK' })[0]
            Require-Mb ($first.findEdit -ceq 'OK' -and $first.elements -eq @($shot.result.elements).Count) "The first UIA snapshot after the restart was not the whole window: $($first.elements) element(s), lookup $($first.findEdit)."
            $value = 'after-uia-restart-' + [guid]::NewGuid()
            Set-MbValue $run $awt $edit.ref $value
            # References of the retired UIA session are dead. The JAB reference predates the restart.
            [void](Get-MbInfo $run $s.formsEdit.ref 'STALE_REFERENCE')
            [void](Send-Mb $run @{ op = 'setValue'; ref = $edit.ref; value = 'duplicate' } 'DUPLICATE_COMMAND' 30000 $s.previousCommand)
            $count = Invoke-MbCounter $run $awt $s.jabButton.ref
            $run.cli.Refresh()
            Require-Mb ($run.cli.Id -eq $run.processId -and !$run.cli.HasExited) 'The Agent process changed.'
            return [ordered]@{ recoveryMs = $clock.ElapsedMilliseconds; codesWhileWaiting = @($codes | Select-Object -Unique)
                firstSnapshotElements = $first.elements; fixtureValueMatched = $true; fixtureCount = $count }
        } -Continue
        Step $row 'agentExitsWhileUiaIsFaulted' {
            Require-Mb ([MbProcessControl]::NtSuspendProcess($forms.process.Handle) -eq 0) 'The WPF fixture could not be suspended.'
            $s.suspended = $true
            $clock = [Diagnostics.Stopwatch]::StartNew()
            do {
                $reply = Get-MbSnapshot $run $s.forms 'UIA' ''
                if ($reply.code -ceq 'BACKEND_UNAVAILABLE') { Start-Sleep -Milliseconds 500 }
            } while ($reply.code -ceq 'BACKEND_UNAVAILABLE' -and $clock.Elapsed.TotalSeconds -lt 60)
            Require-Mb ($reply.code -cne 'OK') 'UIA answered for a suspended process.'
            $exit = Stop-MbAgent $run 40000
            $exit.uiaCodeBeforeExit = $reply.code
            Require-Mb ($exit.exited) 'The Agent did not end while UIA was waiting on a suspended process.'
            [void][MbProcessControl]::NtResumeProcess($forms.process.Handle)
            $s.suspended = $false
            $awt.process.Refresh()
            Require-Mb (!$awt.process.HasExited) 'The AWT fixture ended with the Agent.'
            return $exit
        }
        Step $row 'targetsUsableByNextAgent' {
            $run = Start-MbAgent $implementation 'multi' @($awt.process.Id, $forms.process.Id)
            $s.next = $run
            $shot = (Get-MbSnapshot $run (Get-MbWindow $run $awt).id 'JAB').result
            $button = Find-Mb $run $shot @{ role = 'Button'; name = 'Increment fixture counter' }
            $count = Invoke-MbCounter $run $awt $button.ref
            $uia = (Get-MbSnapshot $run (Get-MbWindow $run $forms).id 'UIA').result
            $edit = Find-Mb $run $uia @{ automationId = 'fixtureEdit' }
            Set-MbValue $run $forms $edit.ref ('next-agent-' + [guid]::NewGuid())
            return [ordered]@{ awtCount = $count; wpfValueMatched = $true }
        }
    } catch {
        $row.failure = $_.Exception.Message
    } finally {
        if ($s.suspended -and $forms.process) { [void][MbProcessControl]::NtResumeProcess($forms.process.Handle) }
        Complete-MbScenario $row $run
        if ($s.next) { [void](Stop-MbAgent $s.next) }
        if ($run) { [void](Stop-MbAgent $run) }
        Stop-MbTargets
    }
    return $row
}

# The bridge library is absent, or the target JVM did not enable the bridge.
function Test-Environment([string]$implementation) {
    $row = New-MbScenario 'Environment' $implementation 'faultInjection' 'A bridge library path that does not exist, then a JVM that did not enable the bridge. UIA stays usable in both.'
    $s = @{}
    $run = $null
    try {
        $awt = Start-MbTarget 'Awt'
        $missing = Join-Path $awt.stateDir 'WindowsAccessBridge-64.dll'
        $run = Start-MbAgent $implementation 'multi' @($awt.process.Id) "--jab-dll ""$missing"""
        Step $row 'bridgeLibraryMissing' {
            $cap = (Send-Mb $run @{ op = 'getCapabilities' }).result
            $rows = @($cap.backends)
            Require-Mb ($cap.available -and $rows[0].available -and !$rows[1].available -and $rows[1].reason) 'The session must report the missing library for JAB only.'
            $window = Get-MbWindow $run $awt
            Require-Mb ((Get-Backends $window.row) -ceq 'UIA,MSAA' -and (Get-BackendStatus $window.status 'JAB') -ceq 'BACKEND_UNAVAILABLE') 'The window list must report JAB as unavailable.'
            [void](Get-MbSnapshot $run $window.id 'JAB' 'BACKEND_UNAVAILABLE')
            $shot = (Get-MbSnapshot $run $window.id 'UIA').result
            $edit = Find-Mb $run $shot (Get-AwtEditLocator $awt)
            Set-MbValue $run $awt $edit.ref ('without-bridge-library-' + [guid]::NewGuid())
            return [ordered]@{ jabReason = $rows[1].reason; fixtureValueMatched = $true }
        } -Continue
        [void](Stop-MbAgent $run)
        $run = $null
        Stop-MbTargets
        $plain = Start-MbTarget 'Awt' $false
        $run = Start-MbAgent $implementation 'multi' @($plain.process.Id)
        Step $row 'bridgeNotEnabledInJvm' {
            $window = Get-MbWindow $run $plain
            Require-Mb ((Get-Backends $window.row) -ceq 'UIA,MSAA' -and (Get-BackendStatus $window.status 'JAB') -ceq 'OK') 'A JVM without the bridge is listed by UIA and MSAA.'
            $cap = (Send-Mb $run @{ op = 'getCapabilities' }).result
            $bridge = @($cap.backends)[1]
            Require-Mb ($bridge.available -and $bridge.bridge.javaWindows -gt $bridge.bridge.connectedWindows) 'The capability must show a Java window that no bridge answers for.'
            [void](Get-MbSnapshot $run $window.id 'JAB' 'BRIDGE_NOT_CONNECTED')
            $shot = (Get-MbSnapshot $run $window.id 'UIA').result
            $edit = Find-Mb $run $shot (Get-AwtEditLocator $plain)
            Set-MbValue $run $plain $edit.ref ('bridge-disabled-' + [guid]::NewGuid())
            return [ordered]@{ bridge = $bridge.bridge; fixtureValueMatched = $true }
        }
    } catch {
        $row.failure = $_.Exception.Message
    } finally {
        Complete-MbScenario $row $run
        if ($run) { [void](Stop-MbAgent $run) }
        Stop-MbTargets
    }
    return $row
}

# The target ends and a new one starts with the same title.
function Test-TargetRestart([string]$implementation) {
    $row = New-MbScenario 'TargetRestart' $implementation 'real' 'The AWT fixture ends and starts again. Both backends drop their references, find the new process and refuse to act on it.'
    $s = @{}
    $run = $null
    try {
        $awt = Start-MbTarget 'Awt'
        $run = Start-MbAgent $implementation 'multi' @($awt.process.Id)
        Step $row 'referencesDieWithTheProcess' {
            $s.window = (Get-MbWindow $run $awt).id
            $uia = (Get-MbSnapshot $run $s.window 'UIA').result
            $jab = (Get-MbSnapshot $run $s.window 'JAB').result
            $edit = Find-Mb $run $uia (Get-AwtEditLocator $awt)
            $button = Find-Mb $run $jab @{ role = 'Button'; name = 'Increment fixture counter' }
            $s.title = $awt.title
            $s.oldPid = $awt.process.Id
            Stop-MbTarget $awt
            [void]$targets.Remove($awt)
            Start-Sleep -Milliseconds 500
            [void](Get-MbInfo $run $edit.ref 'STALE_REFERENCE')
            [void](Get-MbInfo $run $button.ref 'STALE_REFERENCE')
            # The policy check comes first: a process that ended is no longer an allowed process.
            [void](Send-Mb $run @{ op = 'invoke'; ref = $button.ref } 'PERMISSION_DENIED')
            [void](Send-Mb $run @{ op = 'setValue'; ref = $edit.ref; value = 'gone' } 'PERMISSION_DENIED')
            [void](Get-MbSnapshot $run $s.window 'UIA' 'WINDOW_NOT_FOUND')
            [void](Get-MbSnapshot $run $s.window 'JAB' 'WINDOW_NOT_FOUND')
        }
        Step $row 'restartedProcessIsFoundAndNotAuthorized' {
            $again = Start-MbTarget 'Awt' $true $fixtureJavaExe $s.title
            Require-Mb ($again.process.Id -ne $s.oldPid) 'The restarted fixture reused the process ID.'
            $clock = [Diagnostics.Stopwatch]::StartNew()
            do {
                $window = Get-MbWindow $run $again
                if ((Get-Backends $window.row) -cne 'UIA,JAB,MSAA') { Start-Sleep -Milliseconds 100 }
            } while ((Get-Backends $window.row) -cne 'UIA,JAB,MSAA' -and $clock.ElapsedMilliseconds -lt 10000)
            Require-Mb ((Get-Backends $window.row) -ceq 'UIA,JAB,MSAA') 'Both backends must find the restarted process.'
            $uia = (Get-MbSnapshot $run $window.id 'UIA').result
            $jab = (Get-MbSnapshot $run $window.id 'JAB').result
            $edit = Find-Mb $run $uia (Get-AwtEditLocator $again)
            $button = Find-Mb $run $jab @{ role = 'Button'; name = 'Increment fixture counter' }
            $value = Read-MbStable $again 'value.txt'
            $count = Read-MbStable $again 'count.txt'
            [void](Send-Mb $run @{ op = 'setValue'; ref = $edit.ref; value = 'not-authorized' } 'PERMISSION_DENIED')
            [void](Send-Mb $run @{ op = 'invoke'; ref = $button.ref } 'PERMISSION_DENIED')
            Assert-MbUnchanged $again 'value.txt' $value 'A refused action changed the fixture:'
            Assert-MbUnchanged $again 'count.txt' $count 'A refused action changed the fixture:' 300
            return [ordered]@{ discoveryMs = $clock.ElapsedMilliseconds; newProcessId = $again.process.Id }
        }
    } catch {
        $row.failure = $_.Exception.Message
    } finally {
        Complete-MbScenario $row $run
        if ($run) { [void](Stop-MbAgent $run) }
        Stop-MbTargets
    }
    return $row
}

# --- Performance --------------------------------------------------------------------------------

function Get-Quantile($values, [double]$fraction) {
    $sorted = @($values | Sort-Object)
    if (!$sorted.Count) { return $null }
    return [Math]::Round($sorted[[int][Math]::Min($sorted.Count - 1, [Math]::Ceiling($fraction * $sorted.Count) - 1)], 2)
}

function Get-Spread($values) {
    $all = @($values)
    if (!$all.Count) { return $null }
    return [ordered]@{ count = $all.Count; min = [Math]::Round(($all | Measure-Object -Minimum).Minimum, 2); median = Get-Quantile $all 0.5
        p95 = Get-Quantile $all 0.95; max = [Math]::Round(($all | Measure-Object -Maximum).Maximum, 2) }
}

# One Agent process in one backend mode against the AWT fixture.
function Measure-MbMode([string]$implementation, [string]$backendMode, $target) {
    $run = Start-MbAgent $implementation $backendMode @($target.process.Id)
    $measure = [ordered]@{ agent = $implementation; mode = $backendMode; hostAtStart = Get-MbHost }
    try {
        $names = switch ($backendMode) { 'uia' { @('UIA') } 'jab' { @('JAB') } default { @('UIA', 'JAB', 'MSAA') } }
        $capabilities = Send-Mb $run @{ op = 'getCapabilities' }
        $measure.firstCapabilitiesSinceStartMs = [Math]::Round($run.clock.Elapsed.TotalMilliseconds, 1)
        $window = (Get-MbWindow $run $target).id
        $measure.firstListWindowsSinceStartMs = [Math]::Round($run.clock.Elapsed.TotalMilliseconds, 1)
        $measure.firstSnapshotMs = [ordered]@{}
        $measure.elements = [ordered]@{}
        foreach ($name in $names) {
            $shot = Get-MbSnapshot $run $window $(if ($backendMode -eq 'multi') { $name })
            $measure.firstSnapshotMs[$name] = [Math]::Round($shot.ms, 1)
            $measure.elements[$name] = @($shot.result.elements).Count
        }
        # Every backend of the mode has answered a snapshot.
        $measure.readySinceStartMs = [Math]::Round($run.clock.Elapsed.TotalMilliseconds, 1)
        $times = @{ listWindows = New-Object 'Collections.Generic.List[double]' }
        foreach ($name in $names) { $times[$name] = New-Object 'Collections.Generic.List[double]' }
        $before = $null
        $clock = $null
        for ($i = 0; $i -lt $Warmup + $Iterations; $i++) {
            if ($i -eq $Warmup) { $before = Process-Sample $run.cli; $clock = [Diagnostics.Stopwatch]::StartNew() }
            $list = Send-Mb $run @{ op = 'listWindows' }
            if ($i -ge $Warmup) { $times.listWindows.Add($list.ms) }
            foreach ($name in $names) {
                $shot = Get-MbSnapshot $run $window $(if ($backendMode -eq 'multi') { $name })
                if ($i -ge $Warmup) { $times[$name].Add($shot.ms) }
            }
        }
        $after = Process-Sample $run.cli
        $measure.steadySeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2)
        $measure.listWindowsMs = Get-Spread $times.listWindows
        $measure.snapshotMs = [ordered]@{}
        foreach ($name in $names) { $measure.snapshotMs[$name] = Get-Spread $times[$name] }
        $measure.cpuMsSteady = [Math]::Round($after.cpuMs - $before.cpuMs, 1)
        $measure.cpuMsPerIteration = [Math]::Round(($after.cpuMs - $before.cpuMs) / $Iterations, 2)
        $measure.cpuMsTotal = $after.cpuMs
        $measure.privateBytes = $after.privateBytes
        $measure.workingSetBytes = $after.workingSetBytes
        $measure.handles = $after.handles
        $measure.threads = $after.threads
        $exit = Stop-MbAgent $run
        $measure.exitMs = $exit.exitMs
        $measure.exitCode = $exit.exitCode
    } finally {
        $measure.hostAtEnd = Get-MbHost
        if ($run.cli) { [void](Stop-MbAgent $run) }
    }
    return $measure
}

function Get-Median($values) { return Get-Quantile @($values | Where-Object { $null -ne $_ }) 0.5 }

function Get-PerformanceSummary($runs) {
    $summary = New-Object 'Collections.Generic.List[object]'
    foreach ($implementation in $implementations) {
        foreach ($backendMode in 'uia', 'jab', 'multi') {
            $group = @($runs | Where-Object { $_.agent -eq $implementation -and $_.mode -eq $backendMode -and !$_.failure })
            if (!$group.Count) { continue }
            $entry = [ordered]@{ agent = $implementation; mode = $backendMode; runs = $group.Count
                firstCapabilitiesSinceStartMs = Get-Median ($group | ForEach-Object firstCapabilitiesSinceStartMs)
                readySinceStartMs = Get-Median ($group | ForEach-Object readySinceStartMs)
                listWindowsMedianMs = Get-Median ($group | ForEach-Object { $_.listWindowsMs.median })
                snapshotMedianMs = [ordered]@{}; snapshotP95Ms = [ordered]@{}; firstSnapshotMs = [ordered]@{}
                cpuMsPerIteration = Get-Median ($group | ForEach-Object cpuMsPerIteration)
                privateBytes = Get-Median ($group | ForEach-Object privateBytes)
                workingSetBytes = Get-Median ($group | ForEach-Object workingSetBytes)
                handles = Get-Median ($group | ForEach-Object handles); threads = Get-Median ($group | ForEach-Object threads)
                exitMs = Get-Median ($group | ForEach-Object exitMs) }
            foreach ($name in $group[0].snapshotMs.Keys) {
                $entry.snapshotMedianMs[$name] = Get-Median ($group | ForEach-Object { $_.snapshotMs[$name].median })
                $entry.snapshotP95Ms[$name] = Get-Median ($group | ForEach-Object { $_.snapshotMs[$name].p95 })
                $entry.firstSnapshotMs[$name] = Get-Median ($group | ForEach-Object { $_.firstSnapshotMs[$name] })
            }
            $summary.Add($entry)
        }
    }
    return $summary
}

# --- Soak ---------------------------------------------------------------------------------------

function Measure-MbResources([string]$implementation, [string]$workload, $awt, $wpf) {
    $row = [ordered]@{ agent = $implementation; workload = $workload; status = 'FAIL'; samples = @() }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $run = $null
    try {
        $run = Start-MbAgent $implementation 'multi' @($awt.process.Id, $wpf.process.Id)
        $window = (Get-MbWindow $run $awt).id
        $other = (Get-MbWindow $run $wpf).id
        $locator = Get-AwtEditLocator $awt
        $shot = (Get-MbSnapshot $run $window 'UIA').result
        $uiaElements = @($shot.elements).Count
        $edit = Find-Mb $run $shot $locator
        $shot = (Get-MbSnapshot $run $window 'JAB').result
        $button = Find-Mb $run $shot @{ role = 'Button'; name = 'Increment fixture counter' }
        $before = [int](Read-MbStable $awt 'count.txt')
        $state = @{ run = $run; window = $window; mutations = 0; modals = 0; editLocator = $locator
            uiaElements = $uiaElements; jabElements = @($shot.elements).Count }
        $row.samples += @{ label = 'before'; process = Process-Sample $run.cli }
        if ($workload -ceq 'idle') { Start-Sleep -Seconds 4 }
        else {
            for ($i = 0; $i -lt $Iterations; $i++) {
                switch ($workload) {
                    snapshot { [void](Get-MbSnapshot $run $window 'UIA') }
                    snapshotLocator {
                        $current = (Get-MbSnapshot $run $window 'UIA').result
                        [void](Find-Mb $run $current $locator)
                    }
                    getElementInfo { [void](Get-MbInfo $run $edit.ref) }
                    invoke { Require-Dispatch (Send-Mb $run @{ op = 'invoke'; ref = $button.ref }) }
                    setValue {
                        $value = 'resource-sample-' + [guid]::NewGuid()
                        Require-Dispatch (Send-Mb $run @{ op = 'setValue'; ref = $edit.ref; value = $value })
                    }
                    mixed { Invoke-MbSoakIteration $state $awt ([ordered]@{}) $i }
                    snapshotReplace {
                        $next = if ($i % 2) { $window } else { $other }
                        [void](Get-MbSnapshot $run $next 'UIA')
                    }
                }
            }
            if ($workload -ceq 'invoke') { Wait-Mb $awt 'count.txt' ([string]($before + $Iterations)) }
            if ($workload -ceq 'setValue') { Wait-Mb $awt 'value.txt' $value }
        }
        $row.samples += @{ label = 'after'; process = Process-Sample $run.cli }
        Start-Sleep -Milliseconds 500
        $row.samples += @{ label = 'settled'; process = Process-Sample $run.cli }
        $row.mutations = switch ($workload) { invoke { $Iterations } setValue { $Iterations } mixed { $state.mutations } default { 0 } }
        $row.requests = $run.requests.Count
        $row.exit = Stop-MbAgent $run
        Require-Mb ($row.exit.exited -and $row.exit.exitCode -eq 0) 'Agent did not exit normally.'
        Require-Mb (!@($row.samples | Where-Object { !$_.process.available }).Count) 'Resource sample unavailable.'
        $row.status = 'PASS'
    } catch {
        $row.failure = $_.Exception.Message
        $row.host = Get-MbHost
        if ($run) { $row.requestLog = @($run.requests | Select-Object -Last 15) }
    } finally {
        if ($run) { [void](Stop-MbAgent $run) }
        $row.elapsedSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2)
    }
    return $row
}

function Get-MbJvmReferences($target, [string]$jcmd) {
    if (!$jcmd) { return $null }
    try { $dump = Read-Diagnostic $jcmd "$($target.process.Id) GC.class_histogram" 20000 } catch { return $null }
    if ($dump.exitCode -ne 0) { return $null }
    $counts = [ordered]@{ perRequestAccessibles = 0; bridgeReferenceObjects = 0 }
    foreach ($line in $dump.stdout -split "`n") {
        if ($line -notmatch '^\s*\d+:\s+(\d+)\s+\d+\s+(\S+)') { continue }
        $instances = [long]$Matches[1]
        $class = $Matches[2]
        if ($class -match 'Accessible(JListChild|JTableCell|JTreeNode|AWTListChild|JTableHeaderEntry)$') {
            $counts.perRequestAccessibles += $instances
            $counts[$class] = $instances
        }
        if ($class -match 'com\.sun\.java\.accessibility\.internal\.AccessBridge\$ObjectReferences') { $counts.bridgeReferenceObjects = $instances }
    }
    return $counts
}

function Get-MbGrowth($samples, [scriptblock]$value) {
    $series = @($samples | ForEach-Object { & $value $_ } | Where-Object { $null -ne $_ })
    if ($series.Count -lt 4) { return $null }
    # The first quarter covers class loading and JIT warm-up of both processes.
    $settled = @($series | Select-Object -Skip ([int][Math]::Ceiling($series.Count / 4)))
    return [ordered]@{ first = $series[0]; settledFirst = $settled[0]; last = $settled[$settled.Count - 1]
        settledMin = ($settled | Measure-Object -Minimum).Minimum; settledMax = ($settled | Measure-Object -Maximum).Maximum }
}

# Text through UIA, a button through JAB and, every tenth round, the modal dialog through JAB.
function Invoke-MbSoakIteration($state, $target, $times, [long]$iteration) {
    $run = $state.run
    $uia = Get-MbSnapshot $run $state.window 'UIA'
    $times.uiaSnapshot = $uia.ms
    $edit = Find-Mb $run $uia.result $state.editLocator
    $value = 'soak-' + [guid]::NewGuid()
    $times.uiaSetValue = (Send-Mb $run @{ op = 'setValue'; ref = $edit.ref; value = $value }).ms
    Wait-Mb $target 'value.txt' $value
    $jab = Get-MbSnapshot $run $state.window 'JAB'
    $times.jabSnapshot = $jab.ms
    Require-Mb (@($jab.result.elements).Count -eq $state.jabElements -and @($uia.result.elements).Count -eq $state.uiaElements) 'The snapshot workload changed.'
    $button = Find-Mb $run $jab.result @{ role = 'Button'; name = 'Increment fixture counter' }
    $before = [int](Read-Mb $target 'count.txt')
    $times.jabInvoke = (Send-Mb $run @{ op = 'invoke'; ref = $button.ref }).ms
    Wait-Mb $target 'count.txt' ([string]($before + 1))
    $state.mutations += 2
    if ($iteration % 10 -eq 9) {
        $opener = Find-Mb $run $jab.result @{ role = 'Button'; name = 'Open fixture modal' }
        [void](Send-Mb $run @{ op = 'invoke'; ref = $opener.ref })
        Wait-Mb $target 'modal.txt' 'open'
        $modal = (Get-MbWindow $run $target "$($target.title) modal").id
        $dialog = (Get-MbSnapshot $run $modal 'JAB').result
        $close = Find-Mb $run $dialog @{ role = 'Button'; name = 'Close fixture modal' }
        [void](Send-Mb $run @{ op = 'invoke'; ref = $close.ref })
        Wait-Mb $target 'modal.txt' 'closed'
        $state.mutations += 2
        $state.modals++
        # The UIA reference predates the dialog and the two JAB captures.
        $value = 'soak-' + [guid]::NewGuid()
        [void](Send-Mb $run @{ op = 'setValue'; ref = $edit.ref; value = $value })
        Wait-Mb $target 'value.txt' $value
        $state.mutations++
    }
}

function Test-MbSoak([string]$implementation) {
    $soak = [ordered]@{ agent = $implementation; status = 'FAIL'; durationSeconds = $DurationSeconds }
    $jcmd = Join-Path (Split-Path $fixtureJavaExe) 'jcmd.exe'
    if (![IO.File]::Exists($jcmd)) { $jcmd = $null }
    $state = @{ mutations = 0; modals = 0 }
    try {
        $awt = Start-MbTarget 'Awt'
        $soak.fixtureRuntime = Read-Mb $awt 'framework.txt'
        $state.run = Start-MbAgent $implementation 'multi' @($awt.process.Id)
        $state.window = (Get-MbWindow $state.run $awt).id
        $state.editLocator = Get-AwtEditLocator $awt
        $state.uiaElements = @((Get-MbSnapshot $state.run $state.window 'UIA').result.elements).Count
        $state.jabElements = @((Get-MbSnapshot $state.run $state.window 'JAB').result.elements).Count
        $soak.elements = [ordered]@{ UIA = $state.uiaElements; JAB = $state.jabElements }
        $samples = New-Object 'Collections.Generic.List[object]'
        $failures = New-Object 'Collections.Generic.List[object]'
        $sessions = New-Object 'Collections.Generic.List[object]'
        $sessions.Add([ordered]@{ index = 1; agentProcessId = $state.run.processId; startedAtSeconds = 0; reason = 'start' })
        $soak.samples = $samples; $soak.failures = $failures; $soak.sessions = $sessions
        $latencies = [ordered]@{}
        $codes = @{}
        $iterations = 0
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $nextSample = 0
        while ($clock.Elapsed.TotalSeconds -lt $DurationSeconds) {
            # One session dispatches at most 4,096 commands. Start the next session before that limit.
            if ($state.mutations -ge 4000) {
                foreach ($request in $state.run.requests) { $codes[$request.code] = 1 + [int]$codes[$request.code] }
                $sessions[$sessions.Count - 1].endedAtSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
                $sessions[$sessions.Count - 1].mutations = $state.mutations
                $sessions[$sessions.Count - 1].lastSample = Process-Sample $state.run.cli
                $sessions[$sessions.Count - 1].exit = Stop-MbAgent $state.run
                $state.run = Start-MbAgent $implementation 'multi' @($awt.process.Id)
                $state.window = (Get-MbWindow $state.run $awt).id
                $state.mutations = 0
                $sessions.Add([ordered]@{ index = $sessions.Count + 1; agentProcessId = $state.run.processId
                    startedAtSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); reason = 'command limit' })
            }
            if ($clock.Elapsed.TotalSeconds -ge $nextSample) {
                $samples.Add([ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); elapsedSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
                    iterations = $iterations; session = $sessions.Count; agent = Process-Sample $state.run.cli
                    fixture = Process-Sample $awt.process; jvm = Get-MbJvmReferences $awt $jcmd; host = Get-MbHost })
                $nextSample += $SampleSeconds
                $soak.iterations = $iterations
                Save-UiaCheckpoint $report $OutputPath
            }
            $times = [ordered]@{}
            try {
                Invoke-MbSoakIteration $state $awt $times $iterations
                Add-UiaLatencies $latencies $times
                $iterations++
            } catch {
                $failures.Add([ordered]@{ iteration = $iterations; elapsedSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1); message = $_.Exception.Message })
                $failures[$failures.Count - 1].host = Get-MbHost
                $failures[$failures.Count - 1].requests = @($state.run.requests | Select-Object -Last 30)
                break
            }
        }
        $samples.Add([ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); elapsedSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
            iterations = $iterations; session = $sessions.Count; agent = Process-Sample $state.run.cli
            fixture = Process-Sample $awt.process; jvm = Get-MbJvmReferences $awt $jcmd; host = Get-MbHost })
        $soak.iterations = $iterations
        $soak.modalCycles = $state.modals
        $soak.elapsedSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
        $soak.latencyMs = Get-UiaLatencySummary $latencies
        foreach ($request in $state.run.requests) { $codes[$request.code] = 1 + [int]$codes[$request.code] }
        $soak.requestCodes = [ordered]@{}
        foreach ($code in $codes.Keys | Sort-Object) { $soak.requestCodes[$code] = $codes[$code] }
        $sessions[$sessions.Count - 1].endedAtSeconds = $soak.elapsedSeconds
        $sessions[$sessions.Count - 1].mutations = $state.mutations
        $sessions[$sessions.Count - 1].lastSample = Process-Sample $state.run.cli
        $sessions[$sessions.Count - 1].exit = Stop-MbAgent $state.run
        Start-Sleep -Milliseconds 500
        $soak.jvmReferencesAfterAgentExit = Get-MbJvmReferences $awt $jcmd
        # Growth is read within the last session, where the Agent process is the same throughout.
        $last = @($samples | Where-Object { $_.session -eq $sessions.Count })
        $whole = $samples.ToArray()
        $soak.growth = [ordered]@{
            scope = "session $($sessions.Count) of $($sessions.Count) for the Agent, the whole run for the fixture JVM"
            agentPrivateBytes = Get-MbGrowth $last { param($x) $x.agent.privateBytes }
            agentWorkingSetBytes = Get-MbGrowth $last { param($x) $x.agent.workingSetBytes }
            agentHandles = Get-MbGrowth $last { param($x) $x.agent.handles }
            agentThreads = Get-MbGrowth $last { param($x) $x.agent.threads }
            fixturePrivateBytes = Get-MbGrowth $whole { param($x) $x.fixture.privateBytes }
            fixtureWorkingSetBytes = Get-MbGrowth $whole { param($x) $x.fixture.workingSetBytes }
            fixtureHandles = Get-MbGrowth $whole { param($x) $x.fixture.handles }
            fixtureThreads = Get-MbGrowth $whole { param($x) $x.fixture.threads }
            jvmPerRequestAccessibles = Get-MbGrowth $whole { param($x) if ($x.jvm) { $x.jvm.perRequestAccessibles } }
        }
        $growth = $soak.growth
        $soak.verdict = [ordered]@{
            failures = $failures.Count
            unexpectedRequestCodes = @($soak.requestCodes.Keys | Where-Object { $_ -cne 'OK' })
            agentHandlesStable = !$growth.agentHandles -or ($growth.agentHandles.last - $growth.agentHandles.settledFirst) -le 16
            agentThreadsStable = !$growth.agentThreads -or ($growth.agentThreads.last - $growth.agentThreads.settledFirst) -le 2
            fixtureHandlesStable = !$growth.fixtureHandles -or ($growth.fixtureHandles.last - $growth.fixtureHandles.settledFirst) -le 16
            fixtureThreadsStable = !$growth.fixtureThreads -or ($growth.fixtureThreads.last - $growth.fixtureThreads.settledFirst) -le 2
            jvmReferencesBounded = !$growth.jvmPerRequestAccessibles -or ($growth.jvmPerRequestAccessibles.settledMax -le 2 * $state.jabElements)
            jvmReferencesReleasedAtExit = !$soak.jvmReferencesAfterAgentExit -or ($soak.jvmReferencesAfterAgentExit.perRequestAccessibles -eq 0)
            sessionReplacements = $sessions.Count - 1
        }
        $v = $soak.verdict
        if ($v.failures -eq 0 -and !$v.unexpectedRequestCodes.Count -and $v.agentHandlesStable -and $v.agentThreadsStable -and
            $v.fixtureHandlesStable -and $v.fixtureThreadsStable -and $v.jvmReferencesBounded -and $v.jvmReferencesReleasedAtExit) { $soak.status = 'PASS' }
    } catch {
        $soak.failure = $_.Exception.Message
    } finally {
        if ($state.run -and $state.run.cli) { [void](Stop-MbAgent $state.run) }
        Stop-MbTargets
    }
    return $soak
}

# --- Run ----------------------------------------------------------------------------------------

function Get-PeArchitecture($path) {
    $stream = [IO.File]::OpenRead($path)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        $stream.Position = 60
        $stream.Position = $reader.ReadInt32() + 4
        switch ($reader.ReadUInt16()) { 0x014c { 'x86 PE' } 0x8664 { 'x64 PE' } 0xaa64 { 'ARM64 PE' } }
    } finally { $stream.Dispose() }
}

$environment = Get-UiaEnvironment
Set-UiaHostInfo $environment
$environment.git = Get-UiaGitInfo
$nt = Get-ItemProperty 'HKLM:/SOFTWARE/Microsoft/Windows NT/CurrentVersion' -ErrorAction SilentlyContinue
$environment.windows = @{ edition = $nt.EditionID; version = $nt.DisplayVersion; build = "$($nt.CurrentBuildNumber).$($nt.UBR)" }
$environment.javaAgent = @{ java = (Read-Diagnostic $javaExe '-version').stderr; launcher = Get-PeArchitecture $javaExe
    jarSha256 = (Get-FileHash -LiteralPath $Jar).Hash; jvmOptions = $JvmOptions }
$environment.cppAgent = @{ architecture = Get-PeArchitecture $CppAgent; sha256 = (Get-FileHash -LiteralPath $CppAgent).Hash }
$environment.fixtureJava = (Read-Diagnostic $fixtureJavaExe '-version').stderr
$environment.secondFixtureJava = if ($SecondFixtureJava) { (Read-Diagnostic $secondJavaExe '-version').stderr }
$environment.bridge = Get-JabEnvironment @{ executable = $fixtureJavaExe; version = $environment.fixtureJava }
if ($SecondFixtureJava) {
    $environment.bridge.secondFixtureJvm = (Get-JabEnvironment @{
        executable = $secondJavaExe; version = $environment.secondFixtureJava }).fixtureJvm
}
$environment.swingAwtFixtureSha256 = (Get-FileHash -LiteralPath (Join-Path $classes 'FrameworkFixture.class')).Hash
$environment.wpfFixtureSha256 = (Get-FileHash -LiteralPath $wpfScript).Hash
$report = [ordered]@{
    schema = 1; startedUtc = [DateTime]::UtcNow.ToString('o'); invocation = $MyInvocation.Line; mode = $Mode
    options = [ordered]@{ agent = $Agent; scenario = $Scenario; includeExpiry = [bool]$IncludeExpiry; pairs = $Pairs; iterations = $Iterations
        warmup = $Warmup; durationSeconds = $DurationSeconds; sampleSeconds = $SampleSeconds }
    environment = $environment; status = 'FAIL'
    # 'real': nothing but the Agent and the applications. 'faultInjection': the script creates the fault.
    methods = [ordered]@{ real = 'Agent calls are checked against synthetic fixture state and, where configured, independent read-only observations.'
        faultInjection = 'The script creates the fault: a suspended target process, a bridge library path that does not exist, or a JVM started without the bridge.' }
}
try {
    if ($Mode -eq 'Functional') {
        $rows = New-Object 'Collections.Generic.List[object]'
        $report.scenarios = $rows
        foreach ($name in $Scenario) {
            foreach ($implementation in $implementations) {
                $row = & "Test-$name" $implementation
                $rows.Add($row)
                "$name $implementation $($row.status)" | Write-Host
                Save-UiaCheckpoint $report $OutputPath
            }
        }
        # The two Agents must reach the same verdict on every check, and answer faults with the same codes.
        if ($implementations.Count -eq 2) {
            $differences = New-Object 'Collections.Generic.List[object]'
            foreach ($name in $Scenario) {
                $java = @($rows | Where-Object { $_.scenario -eq $name -and $_.agent -eq 'Java' })[0]
                $cpp = @($rows | Where-Object { $_.scenario -eq $name -and $_.agent -eq 'Cpp' })[0]
                $javaChecks = @($java.checks | ForEach-Object { "$($_.name)=$($_.status)" }) -join ';'
                $cppChecks = @($cpp.checks | ForEach-Object { "$($_.name)=$($_.status)" }) -join ';'
                if ($javaChecks -cne $cppChecks) { $differences.Add([ordered]@{ scenario = $name; java = $javaChecks; cpp = $cppChecks }) }
            }
            $report.parity = [ordered]@{ sameVerdicts = !$differences.Count; differences = $differences }
        }
        $counts = [ordered]@{ PASS = 0; FAIL = 0; NOT_RUN = 0 }
        foreach ($row in $rows) { foreach ($check in $row.checks) { $counts[$check.status]++ } }
        $report.checkCounts = $counts
        $report.status = if (@($rows | Where-Object { $_.status -ne 'PASS' }).Count -or ($report.parity -and !$report.parity.sameVerdicts)) { 'FAIL' } else { 'PASS' }
    } elseif ($Mode -eq 'Performance') {
        $runs = New-Object 'Collections.Generic.List[object]'
        $report.runs = $runs
        $awt = Start-MbTarget 'Awt'
        $report.fixtureRuntime = Read-Mb $awt 'framework.txt'
        for ($pair = 0; $pair -lt $Pairs; $pair++) {
            # Alternate the order so neither Agent always runs on a warmer fixture.
            $order = if ($pair % 2) { @($implementations | Sort-Object -Descending) } else { @($implementations | Sort-Object) }
            foreach ($implementation in $order) {
                foreach ($backendMode in 'uia', 'jab', 'multi') {
                    try { $measure = Measure-MbMode $implementation $backendMode $awt }
                    catch { $measure = [ordered]@{ agent = $implementation; mode = $backendMode; failure = $_.Exception.Message; host = Get-MbHost } }
                    $measure.pair = $pair
                    $runs.Add($measure)
                    Save-UiaCheckpoint $report $OutputPath
                }
            }
        }
        $report.summary = Get-PerformanceSummary $runs
        $report.status = if (@($runs | Where-Object failure).Count) { 'FAIL' } else { 'PASS' }
    } elseif ($Mode -eq 'Resources') {
        $report.runs = New-Object 'Collections.Generic.List[object]'
        $awt = Start-MbTarget 'Awt'
        $wpf = Start-MbTarget 'Wpf'
        foreach ($implementation in $implementations) {
            foreach ($workload in 'idle','snapshot','snapshotLocator','getElementInfo','invoke','setValue','mixed','snapshotReplace') {
                $resource = Measure-MbResources $implementation $workload $awt $wpf
                $report.runs.Add($resource)
                Save-UiaCheckpoint $report $OutputPath
            }
        }
        $report.status = if (@($report.runs | Where-Object status -ne 'PASS').Count) { 'FAIL' } else { 'PASS' }
    } else {
        $soaks = New-Object 'Collections.Generic.List[object]'
        $report.soak = $soaks
        foreach ($implementation in $implementations) {
            $soak = Test-MbSoak $implementation
            $soaks.Add($soak)
            "Soak $implementation $($soak.status): $($soak.iterations) iterations" | Write-Host
            Save-UiaCheckpoint $report $OutputPath
        }
        $report.status = if (@($soaks | Where-Object { $_.status -ne 'PASS' }).Count) { 'FAIL' } else { 'PASS' }
    }
} catch {
    $report.failure = $_.Exception.Message
    $report.status = 'FAIL'
} finally {
    Stop-MbTargets
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    Save-UiaJson (ConvertTo-Json -InputObject $report -Depth 30) $OutputPath
}
"$Mode $($report.status). See $OutputPath."
if ($report.status -ne 'PASS') { exit 1 }
exit 0
