# Multi-backend regression: UI Automation and Java Access Bridge in one Agent process.
# Run on a test desktop. Mutations are authorized only for the fixtures launched by this script.
# Every effect is judged by the state files of a fixture, never by an Agent reply.
[CmdletBinding()]
param(
    [ValidateSet('Java', 'Cpp', 'Both')][string]$Agent = 'Both',
    [ValidateSet('Functional', 'Performance', 'Soak')][string]$Mode = 'Functional',
    [ValidateSet('AwtMixed', 'Safety', 'JabFault', 'UiaFault', 'Environment', 'TargetRestart')]
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

Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class MbProcessControl {
    [DllImport("ntdll.dll")] public static extern int NtSuspendProcess(IntPtr process);
    [DllImport("ntdll.dll")] public static extern int NtResumeProcess(IntPtr process);
}
'@

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

function Wait-Mb($target, [string]$file, [string]$value, [int]$timeoutMs = 8000) {
    if (!(Wait-JabFile $target.stateDir $file $value $timeoutMs)) {
        throw "The $($target.kind) fixture did not report $file=$value (it holds '$(Read-Mb $target $file)')."
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
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $cli = Start-Cli $start
    return @{ cli = $cli; implementation = $implementation; mode = $backendMode; clock = $clock; processId = $cli.Id
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
    } finally { $run.cli.Dispose(); $run.cli = $null }
    return $result
}

function Send-Mb($run, $command, [string]$expected = 'OK', [int]$timeoutMs = 30000, [string]$id = ([guid]::NewGuid().ToString())) {
    $response = Send-UiaRequest $run.cli $command $id $timeoutMs
    $code = if ($response.reply.ok) { 'OK' } else { $response.reply.error.code }
    $run.requests.Add([ordered]@{ op = $command.op; backend = $command.backend; code = $code; ms = [Math]::Round($response.ms, 1) })
    if ($expected -and $code -cne $expected) { throw "$($command.op) expected $expected, received $code." }
    return @{ code = $code; ms = $response.ms; reply = $response.reply; result = $response.reply.result }
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
    $before = [int](Read-Mb $target 'count.txt')
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
        checks = New-Object 'Collections.Generic.List[object]'; aborted = $false }
}

# One named check. A failure ends the scenario unless the check only records an observation.
function Step($row, [string]$name, [scriptblock]$body, [switch]$Continue) {
    $check = [ordered]@{ name = $name; status = 'NOT_RUN' }
    $row.checks.Add($check)
    if ($row.aborted) { $check.reason = 'An earlier step of this scenario failed.'; return }
    try {
        $evidence = & $body
        if ($null -ne $evidence) { $check.evidence = $evidence }
        $check.status = 'PASS'
    } catch {
        $check.status = 'FAIL'
        $check.reason = $_.Exception.Message
        if (!$Continue) { $row.aborted = $true }
    }
}

function Complete-MbScenario($row, $run) {
    $states = @($row.checks | ForEach-Object status)
    $row.status = if ($states -contains 'FAIL') { 'FAIL' } elseif ($states -contains 'NOT_RUN' -or !$states.Count) { 'INCOMPLETE' } else { 'PASS' }
    if ($run) {
        $row.agentProcessId = $run.processId
        $row.requests = $run.requests.Count
        # The last requests of a scenario that did not pass, with their codes and latencies.
        if ($row.status -ne 'PASS') { $row.requestLog = @($run.requests | Select-Object -Last 60) }
    }
    $row.Remove('aborted')
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
            Require-Mb ($cap.backend -ceq 'multi' -and $cap.available -and $cap.defaultBackend -ceq 'UIA' -and $rows.Count -eq 2 -and
                $rows[0].backend -ceq 'UIA' -and $rows[0].available -and $rows[1].backend -ceq 'JAB' -and $rows[1].available -and
                !$cap.physicalInput -and !$cap.screenshot -and @($cap.operations).Count -eq 7) 'Both backends must be available under the multi capability.'
            return [ordered]@{ bridge = $rows[1].bridge }
        }
        Step $row 'windowListedOnceWithBothBackends' {
            $window = Get-MbWindow $run $awt
            $s.window = $window.id
            Require-Mb ((Get-Backends $window.row) -ceq 'UIA,JAB') "The AWT window lists backends '$(Get-Backends $window.row)'."
            Require-Mb ((Get-BackendStatus $window.status 'UIA') -ceq 'OK' -and (Get-BackendStatus $window.status 'JAB') -ceq 'OK') 'Both backends must answer the window list.'
            return [ordered]@{ windowId = $window.id; backends = @($window.row.backends) }
        }
        Step $row 'uiaSetValue' {
            $s.uia = (Get-MbSnapshot $run $s.window 'UIA').result
            Require-Mb ($s.uia.backend -ceq 'UIA' -and !@($s.uia.elements | Where-Object { $_.backend -cne 'UIA' }).Count) 'The UIA snapshot must hold UIA rows only.'
            $s.uiaEdit = Find-Mb $run $s.uia (Get-AwtEditLocator $awt)
            $s.value1 = 'uia-first-' + [guid]::NewGuid()
            Set-MbValue $run $awt $s.uiaEdit.ref $s.value1
            return [ordered]@{ elements = @($s.uia.elements).Count; fixtureValue = Read-Mb $awt 'value.txt' }
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
            return [ordered]@{ fixtureValue = Read-Mb $awt 'value.txt' }
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
            return [ordered]@{ fixtureValue = Read-Mb $awt 'value.txt'; fixtureCount = $count }
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
            [void](Get-MbSnapshot $run $s.window 'MSAA' 'BACKEND_UNAVAILABLE')
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
            $before = Read-Mb $awt 'count.txt'
            [void](Send-Mb $run @{ op = 'invoke'; ref = $s.jabButton2.ref } 'DUPLICATE_COMMAND' 30000 $id)
            Require-Mb (Test-JabStateUnchanged2 $awt 'count.txt' $before) 'A duplicate command ID reached the other backend.'
            $id = 'shared-' + [guid]::NewGuid()
            Require-Dispatch (Send-Mb $run @{ op = 'invoke'; ref = $s.jabButton2.ref } 'OK' 30000 $id)
            Wait-Mb $awt 'count.txt' ([string]([int]$before + 1))
            [void](Send-Mb $run @{ op = 'setValue'; ref = $s.uiaEdit2.ref; value = 'must-not-arrive' } 'DUPLICATE_COMMAND' 30000 $id)
            Require-Mb (Test-JabStateUnchanged2 $awt 'value.txt' $value) 'A duplicate command ID reached the other backend.'
        }
        Step $row 'referenceOfOtherSessionRefused' {
            $other = Start-MbAgent $implementation 'multi' @($awt.process.Id)
            $s.other = $other
            $foreign = (Get-MbSnapshot $other $s.window 'JAB').result
            $button = Find-Mb $other $foreign @{ role = 'Button'; name = 'Increment fixture counter' }
            $before = Read-Mb $awt 'count.txt'
            [void](Send-Mb $run @{ op = 'invoke'; ref = $button.ref } 'STALE_REFERENCE')
            [void](Send-Mb $run @{ op = 'findElement'; snapshotId = $foreign.snapshotId; locator = @{ role = 'Button' } } 'STALE_REFERENCE')
            [void](Send-Mb $other @{ op = 'getElementInfo'; ref = $s.uiaEdit2.ref } 'STALE_REFERENCE')
            Require-Mb (Test-JabStateUnchanged2 $awt 'count.txt' $before) 'A reference of another session reached the fixture.'
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

function Test-JabStateUnchanged2($target, [string]$file, [string]$value, [int]$milliseconds = 1200) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ((Read-Mb $target $file) -cne $value) { return $false }
        Start-Sleep -Milliseconds 50
    } while ($clock.ElapsedMilliseconds -lt $milliseconds)
    return $true
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
            Require-Mb ((Get-Backends $s.swing.row) -ceq 'UIA,JAB' -and (Get-Backends $s.awt.row) -ceq 'UIA,JAB' -and (Get-Backends $s.forms.row) -ceq 'UIA') 'Java windows list both backends and the WPF window lists UIA only.'
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
            $reply = Send-Mb $run @{ op = 'invoke'; ref = $s.opener.ref } 'ACTION_OUTCOME_UNKNOWN' 30000
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
            Require-Mb ($formsRow.Count -eq 1 -and $swingRow.Count -eq 1 -and (Get-Backends $swingRow[0]) -ceq 'UIA') 'UIA rows must still be listed.'
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
            return [ordered]@{ elements = @($shot.elements).Count; fixtureValue = Read-Mb $forms 'value.txt'; fixtureCount = $count }
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
                jvmIsolated = ($viaJab.code -ceq 'OK'); uiaTextOnHealthyJvm = Read-Mb $awt 'value.txt' }
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
            Set-MbValue $run $forms $s.formsEdit.ref ('before-uia-fault-' + [guid]::NewGuid())
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
            do {
                $shot = Get-MbSnapshot $run $s.awt 'UIA' ''
                $codes.Add($shot.code)
                if ($shot.code -cne 'OK') { Start-Sleep -Milliseconds 500 }
            } while ($shot.code -cne 'OK' -and $clock.Elapsed.TotalSeconds -lt 60)
            Require-Mb ($shot.code -ceq 'OK') "UIA did not return in this Agent process: $(($codes | Select-Object -Unique) -join ', ')."
            $edit = Find-Mb $run $shot.result (Get-AwtEditLocator $awt)
            $value = 'after-uia-restart-' + [guid]::NewGuid()
            Set-MbValue $run $awt $edit.ref $value
            # References of the retired UIA session are dead. The JAB reference predates the restart.
            [void](Get-MbInfo $run $s.formsEdit.ref 'STALE_REFERENCE')
            $count = Invoke-MbCounter $run $awt $s.jabButton.ref
            $run.cli.Refresh()
            Require-Mb ($run.cli.Id -eq $run.processId -and !$run.cli.HasExited) 'The Agent process changed.'
            return [ordered]@{ recoveryMs = $clock.ElapsedMilliseconds; codesWhileWaiting = @($codes | Select-Object -Unique)
                fixtureValue = Read-Mb $awt 'value.txt'; fixtureCount = $count }
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
            return [ordered]@{ awtCount = $count; wpfValue = Read-Mb $forms 'value.txt' }
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
            Require-Mb ((Get-Backends $window.row) -ceq 'UIA' -and (Get-BackendStatus $window.status 'JAB') -ceq 'BACKEND_UNAVAILABLE') 'The window list must report JAB as unavailable.'
            [void](Get-MbSnapshot $run $window.id 'JAB' 'BACKEND_UNAVAILABLE')
            $shot = (Get-MbSnapshot $run $window.id 'UIA').result
            $edit = Find-Mb $run $shot (Get-AwtEditLocator $awt)
            Set-MbValue $run $awt $edit.ref ('without-bridge-library-' + [guid]::NewGuid())
            return [ordered]@{ jabReason = $rows[1].reason; fixtureValue = Read-Mb $awt 'value.txt' }
        } -Continue
        [void](Stop-MbAgent $run)
        $run = $null
        Stop-MbTargets
        $plain = Start-MbTarget 'Awt' $false
        $run = Start-MbAgent $implementation 'multi' @($plain.process.Id)
        Step $row 'bridgeNotEnabledInJvm' {
            $window = Get-MbWindow $run $plain
            Require-Mb ((Get-Backends $window.row) -ceq 'UIA' -and (Get-BackendStatus $window.status 'JAB') -ceq 'OK') 'A JVM without the bridge is listed by UIA only.'
            $cap = (Send-Mb $run @{ op = 'getCapabilities' }).result
            $bridge = @($cap.backends)[1]
            Require-Mb ($bridge.available -and $bridge.bridge.javaWindows -gt $bridge.bridge.connectedWindows) 'The capability must show a Java window that no bridge answers for.'
            [void](Get-MbSnapshot $run $window.id 'JAB' 'BRIDGE_NOT_CONNECTED')
            $shot = (Get-MbSnapshot $run $window.id 'UIA').result
            $edit = Find-Mb $run $shot (Get-AwtEditLocator $plain)
            Set-MbValue $run $plain $edit.ref ('bridge-disabled-' + [guid]::NewGuid())
            return [ordered]@{ bridge = $bridge.bridge; fixtureValue = Read-Mb $plain 'value.txt' }
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
                if ((Get-Backends $window.row) -cne 'UIA,JAB') { Start-Sleep -Milliseconds 100 }
            } while ((Get-Backends $window.row) -cne 'UIA,JAB' -and $clock.ElapsedMilliseconds -lt 10000)
            Require-Mb ((Get-Backends $window.row) -ceq 'UIA,JAB') 'Both backends must find the restarted process.'
            $uia = (Get-MbSnapshot $run $window.id 'UIA').result
            $jab = (Get-MbSnapshot $run $window.id 'JAB').result
            $edit = Find-Mb $run $uia (Get-AwtEditLocator $again)
            $button = Find-Mb $run $jab @{ role = 'Button'; name = 'Increment fixture counter' }
            $value = Read-Mb $again 'value.txt'
            $count = Read-Mb $again 'count.txt'
            [void](Send-Mb $run @{ op = 'setValue'; ref = $edit.ref; value = 'not-authorized' } 'PERMISSION_DENIED')
            [void](Send-Mb $run @{ op = 'invoke'; ref = $button.ref } 'PERMISSION_DENIED')
            Require-Mb ((Test-JabStateUnchanged2 $again 'value.txt' $value) -and (Read-Mb $again 'count.txt') -ceq $count) 'A refused action changed the fixture.'
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
    $measure = [ordered]@{ agent = $implementation; mode = $backendMode }
    try {
        $names = switch ($backendMode) { 'uia' { @('UIA') } 'jab' { @('JAB') } default { @('UIA', 'JAB') } }
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
    } finally { if ($run.cli) { [void](Stop-MbAgent $run) } }
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
                    fixture = Process-Sample $awt.process; jvm = Get-MbJvmReferences $awt $jcmd })
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
                if ($failures.Count -ge 20) { throw }
            }
        }
        $samples.Add([ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); elapsedSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
            iterations = $iterations; session = $sessions.Count; agent = Process-Sample $state.run.cli
            fixture = Process-Sample $awt.process; jvm = Get-MbJvmReferences $awt $jcmd })
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
$environment.git = Get-UiaGitInfo
$nt = Get-ItemProperty 'HKLM:/SOFTWARE/Microsoft/Windows NT/CurrentVersion' -ErrorAction SilentlyContinue
$environment.windows = @{ edition = $nt.EditionID; version = $nt.DisplayVersion; build = "$($nt.CurrentBuildNumber).$($nt.UBR)" }
$environment.javaAgent = @{ java = (Read-Diagnostic $javaExe '-version').stderr; launcher = Get-PeArchitecture $javaExe
    jarSha256 = (Get-FileHash -LiteralPath $Jar).Hash; jvmOptions = $JvmOptions }
$environment.cppAgent = @{ architecture = Get-PeArchitecture $CppAgent; sha256 = (Get-FileHash -LiteralPath $CppAgent).Hash }
$environment.fixtureJava = (Read-Diagnostic $fixtureJavaExe '-version').stderr
$environment.secondFixtureJava = if ($SecondFixtureJava) { (Read-Diagnostic $secondJavaExe '-version').stderr }
$environment.bridge = Get-JabEnvironment @{ executable = $fixtureJavaExe }
$environment.wpfFixtureSha256 = (Get-FileHash -LiteralPath $wpfScript).Hash
$report = [ordered]@{
    schema = 1; startedUtc = [DateTime]::UtcNow.ToString('o'); invocation = $MyInvocation.Line; mode = $Mode
    options = [ordered]@{ agent = $Agent; scenario = $Scenario; includeExpiry = [bool]$IncludeExpiry; pairs = $Pairs; iterations = $Iterations
        warmup = $Warmup; durationSeconds = $DurationSeconds; sampleSeconds = $SampleSeconds }
    environment = $environment; status = 'FAIL'
    # 'real': nothing but the Agent and the applications. 'faultInjection': the script creates the fault.
    methods = [ordered]@{ real = 'Only the Agent and unmodified fixture applications take part.'
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
                    catch { $measure = [ordered]@{ agent = $implementation; mode = $backendMode; failure = $_.Exception.Message } }
                    $measure.pair = $pair
                    $runs.Add($measure)
                    Save-UiaCheckpoint $report $OutputPath
                }
            }
        }
        $report.summary = Get-PerformanceSummary $runs
        $report.status = if (@($runs | Where-Object failure).Count) { 'FAIL' } else { 'PASS' }
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
