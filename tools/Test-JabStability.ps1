# Repeated Java Access Bridge use against one fixture JVM: request latency, Agent and JVM resources,
# references left in the JVM, Agent restarts, JVM restarts and recovery after a silent JVM.
# Run on a test desktop. Mutations are authorized only for the fixture launched by this script.
[CmdletBinding()]
param(
    [ValidateSet('Jab', 'CppJab')][string]$Backend = 'Jab',
    [ValidateSet('Swing', 'Awt')][string]$Framework = 'Swing',
    [ValidateRange(10, 86400)][int]$DurationSeconds = 300,
    [ValidateRange(5, 600)][int]$SampleSeconds = 15,
    [ValidateRange(0, 200)][int]$AgentRestarts = 10,
    [ValidateRange(0, 50)][int]$FixtureRestarts = 3,
    [string]$Jar = 'target/desktop-agent.jar',
    [string]$CppAgent = 'target/cpp-agent/Release/cpp-agent.exe',
    [string]$FixtureRoot = 'target/framework-fixtures',
    [string]$FixtureJava = 'java.exe',
    [string]$JabDll,
    [string]$OutputPath = 'target/jab-stability.json',
    [string[]]$JvmOptions = @('-XX:+UseSerialGC', '-Xms16m')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UiaTest.Common.ps1')
. (Join-Path $PSScriptRoot 'UiaFrameworkCases.ps1')
. (Join-Path $PSScriptRoot 'JabFrameworkCases.ps1')

function Get-PeArchitecture($path) {
    $stream = [IO.File]::OpenRead($path)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        $stream.Position = 60
        $stream.Position = $reader.ReadInt32() + 4
        switch ($reader.ReadUInt16()) { 0x014c { 'x86 PE' } 0x8664 { 'x64 PE' } 0xaa64 { 'ARM64 PE' } }
    } finally { $stream.Dispose() }
}

function Start-StabilityFixture {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $fixtureJavaExe
    $start.Arguments = '-Djavax.accessibility.assistive_technologies=com.sun.java.accessibility.AccessBridge ' +
        "-cp ""$classes"" FrameworkFixture $($Framework.ToLowerInvariant()) ""$stateDir"" ""$title"""
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    Remove-Item -LiteralPath (Join-Path $stateDir 'ready') -Force -ErrorAction SilentlyContinue
    $script:fixture = [Diagnostics.Process]::Start($start)
    Wait-State 'ready' ([string]$fixture.Id)
}

function Stop-StabilityFixture {
    if (!$fixture) { return }
    try {
        if (!$fixture.HasExited) {
            [IO.File]::WriteAllText((Join-Path $stateDir 'close-fixture'), '')
            if (!$fixture.WaitForExit(5000)) { $fixture.Kill(); [void]$fixture.WaitForExit(5000) }
        }
    } finally { $fixture.Dispose(); $script:fixture = $null }
}

# Accessible objects that Swing and AWT build anew for each bridge request. The bridge keeps one
# alive for every reference a client holds, so a client that does not release them makes these grow.
function Get-JvmReferences {
    if (!$jcmd) { return $null }
    $dump = Read-Diagnostic $jcmd "$($fixture.Id) GC.class_histogram" 20000
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

function Get-StabilitySample($run, [long]$iterations) {
    return [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); iterations = $iterations
        agent = Process-Sample $run.cli; fixture = Process-Sample $fixture; jvm = Get-JvmReferences }
}

function Invoke-StabilityIteration($run, $window, $times) {
    $shot = Invoke-FrameworkRequest $run @{ op = 'snapshot'; windowId = $window; maxDepth = 32; maxElements = 2000 }
    $times.snapshot = $shot.ms
    $snapshot = $shot.reply.result
    Require-Framework (!$snapshot.truncated -and $snapshot.elements.Count -eq $expectedElements) 'The snapshot workload changed.'
    $find = Invoke-FrameworkRequest $run @{ op = 'findElement'; snapshotId = $snapshot.snapshotId; locator = @{ role = 'Button'; name = 'Increment fixture counter' } }
    $times.findElement = $find.ms
    $info = Invoke-FrameworkRequest $run @{ op = 'getElementInfo'; ref = $find.reply.result.ref }
    $times.getElementInfo = $info.ms
    if ($Framework -eq 'Swing') {
        $edit = (Invoke-FrameworkRequest $run @{ op = 'findElement'; snapshotId = $snapshot.snapshotId; locator = @{ role = 'Edit'; name = 'Fixture edit' } }).reply.result
        $value = 'stability-' + [guid]::NewGuid()
        $times.setValue = (Invoke-FrameworkRequest $run @{ op = 'setValue'; ref = $edit.ref; value = $value }).ms
        Wait-FrameworkEffect $run 'value.txt' $value
    }
    $before = [int](Read-State 'count.txt')
    $times.invoke = (Invoke-FrameworkRequest $run @{ op = 'invoke'; ref = $find.reply.result.ref }).ms
    Wait-FrameworkEffect $run 'count.txt' ([string]($before + 1))
}

function Get-Growth($samples, [scriptblock]$value) {
    $series = @($samples | ForEach-Object { & $value $_ } | Where-Object { $null -ne $_ })
    if ($series.Count -lt 4) { return $null }
    # The first quarter covers class loading and JIT warm-up of both processes.
    $settled = @($series | Select-Object -Skip ([int][Math]::Ceiling($series.Count / 4)))
    return [ordered]@{ first = $series[0]; settledFirst = $settled[0]; last = $settled[$settled.Count - 1]
        settledMin = ($settled | Measure-Object -Minimum).Minimum; settledMax = ($settled | Measure-Object -Maximum).Maximum }
}

if ($env:OS -ne 'Windows_NT' -or ![Environment]::UserInteractive) { throw 'An interactive Windows test desktop is required.' }
$Jar = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Jar)
$CppAgent = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CppAgent)
$classes = Join-Path ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FixtureRoot)) 'swing-awt'
if (![IO.File]::Exists((Join-Path $classes 'FrameworkFixture.class'))) { throw 'Build the Swing and AWT fixture first.' }
$javaExe = (Get-Command java.exe -CommandType Application | Select-Object -First 1).Source
$fixtureJavaExe = (Get-Command $FixtureJava -CommandType Application | Select-Object -First 1).Source
$jcmd = Join-Path (Split-Path $fixtureJavaExe) 'jcmd.exe'
if (![IO.File]::Exists($jcmd)) { $jcmd = $null }
if ($JabDll) { $JabDll = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JabDll) }
$stateDir = Join-Path ([IO.Path]::GetTempPath()) ('jab-stability-' + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($stateDir)
$title = "JAB stability $Framework " + [guid]::NewGuid()
$fixture = $null

$environment = Get-UiaEnvironment
$environment.git = Get-UiaGitInfo
$nt = Get-ItemProperty 'HKLM:/SOFTWARE/Microsoft/Windows NT/CurrentVersion' -ErrorAction SilentlyContinue
$environment.windows = @{ edition = $nt.EditionID; version = $nt.DisplayVersion; build = "$($nt.CurrentBuildNumber).$($nt.UBR)" }
$environment.agent = if ($Backend -eq 'Jab') {
    @{ kind = 'Java/JNA'; java = (Read-Diagnostic $javaExe '-version').stderr; launcher = Get-PeArchitecture $javaExe
       jarSha256 = (Get-FileHash -LiteralPath $Jar).Hash; jvmOptions = $JvmOptions }
} else { @{ kind = 'C++'; architecture = Get-PeArchitecture $CppAgent; sha256 = (Get-FileHash -LiteralPath $CppAgent).Hash } }
$launch = @{ executable = $fixtureJavaExe; version = (Read-Diagnostic $fixtureJavaExe '-version').stderr }
$environment.bridge = Get-JabEnvironment $launch
$report = [ordered]@{
    schema = 1; startedUtc = [DateTime]::UtcNow.ToString('o'); invocation = $MyInvocation.Line
    options = [ordered]@{ backend = $Backend; framework = $Framework; durationSeconds = $DurationSeconds; sampleSeconds = $SampleSeconds
        agentRestarts = $AgentRestarts; fixtureRestarts = $FixtureRestarts }
    environment = $environment; status = 'FAIL'
}
$run = $null
try {
    Start-StabilityFixture
    $report.fixtureRuntime = Read-State 'framework.txt'

    # Phase 1: one session, the same five requests in a loop.
    $run = Start-FrameworkAgent $Backend
    $first = [ordered]@{ processStartMs = $run.processStartMs }
    [void](Framework-Result $run @{ op = 'getCapabilities' })
    $first.capabilitiesSinceStartMs = $run.clock.Elapsed.TotalMilliseconds
    $first.capabilitiesMs = $run.requests[0].ms
    $window = Get-FrameworkWindow $run
    $first.listWindowsMs = $run.requests[1].ms
    $shot = Get-FrameworkSnapshot $run $window
    $first.snapshotMs = $shot.ms
    $first.snapshotSinceStartMs = $run.clock.Elapsed.TotalMilliseconds
    $expectedElements = $shot.data.elements.Count
    $first.elements = $expectedElements
    $report.firstUse = $first
    $steady = [ordered]@{ iterations = 0; failures = New-Object 'Collections.Generic.List[object]'; samples = New-Object 'Collections.Generic.List[object]' }
    $report.steady = $steady
    $latencies = [ordered]@{}
    $codes = @{}
    $mutations = 0
    $steady.sessions = 1
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $nextSample = 0
    while ($clock.Elapsed.TotalSeconds -lt $DurationSeconds) {
        # One session dispatches at most 4,096 commands. Start the next session before that limit.
        if ($mutations -ge 4000) {
            foreach ($request in $run.requests) { $codes[$request.code] = 1 + [int]$codes[$request.code] }
            Stop-Cli $run.cli JNA
            $run = Start-FrameworkAgent $Backend
            $window = Get-FrameworkWindow $run
            $mutations = 0
            $steady.sessions++
        }
        if ($clock.Elapsed.TotalSeconds -ge $nextSample) {
            $steady.samples.Add((Get-StabilitySample $run $steady.iterations))
            $nextSample += $SampleSeconds
            Save-UiaCheckpoint $report $OutputPath
        }
        $times = [ordered]@{}
        try {
            Invoke-StabilityIteration $run $window $times
            $mutations += $(if ($Framework -eq 'Swing') { 2 } else { 1 })
            Add-UiaLatencies $latencies $times
            $steady.iterations++
        } catch {
            $steady.failures.Add(@{ iteration = $steady.iterations; elapsedSeconds = $clock.Elapsed.TotalSeconds; message = $_.Exception.Message })
            if ($run.closedProtocol -or $run.uncertainAction -or $steady.failures.Count -ge 20) { throw }
        }
    }
    $steady.samples.Add((Get-StabilitySample $run $steady.iterations))
    $steady.elapsedSeconds = $clock.Elapsed.TotalSeconds
    $steady.latencyMs = Get-UiaLatencySummary $latencies
    foreach ($request in $run.requests) { $codes[$request.code] = 1 + [int]$codes[$request.code] }
    $steady.requestCodes = [ordered]@{}
    foreach ($code in $codes.Keys | Sort-Object) { $steady.requestCodes[$code] = $codes[$code] }
    $steady.requests = ($codes.Values | Measure-Object -Sum).Sum
    $run.requests.Clear()
    $steady.growth = [ordered]@{
        agentPrivateBytes = Get-Growth $steady.samples { param($s) $s.agent.privateBytes }
        agentWorkingSetBytes = Get-Growth $steady.samples { param($s) $s.agent.workingSetBytes }
        agentHandles = Get-Growth $steady.samples { param($s) $s.agent.handles }
        agentThreads = Get-Growth $steady.samples { param($s) $s.agent.threads }
        fixturePrivateBytes = Get-Growth $steady.samples { param($s) $s.fixture.privateBytes }
        fixtureHandles = Get-Growth $steady.samples { param($s) $s.fixture.handles }
        fixtureThreads = Get-Growth $steady.samples { param($s) $s.fixture.threads }
        jvmPerRequestAccessibles = Get-Growth $steady.samples { param($s) if ($s.jvm) { $s.jvm.perRequestAccessibles } }
    }

    # Phase 2: recovery after the JVM stopped answering (a Swing click that opens a modal dialog).
    if ($Framework -eq 'Swing') {
        $recovery = [ordered]@{}
        $report.silentJvmRecovery = $recovery
        $snapshot = (Get-FrameworkSnapshot $run $window).data
        $opener = Find-FrameworkElement $run $snapshot @{ role = 'Button'; name = 'Open fixture modal' }
        $reply = Send-UiaRequest $run.cli @{ op = 'invoke'; ref = $opener.ref } ([guid]::NewGuid().ToString()) 20000
        $recovery.invokeCode = if ($reply.reply.ok) { 'OK' } else { $reply.reply.error.code }
        $recovery.invokeMs = $reply.ms
        Wait-State 'modal.txt' 'open' 5000
        $busy = Send-UiaRequest $run.cli @{ op = 'listWindows' } ([guid]::NewGuid().ToString()) 20000
        $recovery.whileOpenCode = if ($busy.reply.ok) { 'OK' } else { $busy.reply.error.code }
        $recovery.whileOpenMs = $busy.ms
        [IO.File]::WriteAllText((Join-Path $stateDir 'close-modal'), '')
        Wait-State 'modal.txt' 'closed' 5000
        Start-Sleep -Milliseconds 500
        $recovery.iterationsAfter = 0
        for ($i = 0; $i -lt 10; $i++) { Invoke-StabilityIteration $run $window ([ordered]@{}); $recovery.iterationsAfter++ }
        $recovery.sample = Get-StabilitySample $run $recovery.iterationsAfter
    }
    $beforeClose = Get-JvmReferences
    Stop-Cli $run.cli JNA
    $run = $null
    Start-Sleep -Milliseconds 500
    $report.referencesInJvm = [ordered]@{ whileSessionHeldACapture = $beforeClose; afterSessionClosed = Get-JvmReferences }

    # Phase 3: start, use and end the Agent repeatedly against the same JVM.
    if ($AgentRestarts) {
        $cycles = [ordered]@{ count = 0; fixtureBefore = Process-Sample $fixture; jvmBefore = Get-JvmReferences }
        $report.agentRestarts = $cycles
        $cycleTimes = [ordered]@{}
        for ($i = 0; $i -lt $AgentRestarts; $i++) {
            $cycle = Start-FrameworkAgent $Backend
            try {
                [void](Framework-Result $cycle @{ op = 'getCapabilities' })
                $cycleWindow = Get-FrameworkWindow $cycle
                $snapshot = (Get-FrameworkSnapshot $cycle $cycleWindow).data
                $ready = $cycle.clock.Elapsed.TotalMilliseconds
                $button = Find-FrameworkElement $cycle $snapshot @{ role = 'Button'; name = 'Increment fixture counter' }
                $before = [int](Read-State 'count.txt')
                [void](Framework-Result $cycle @{ op = 'invoke'; ref = $button.ref })
                Wait-FrameworkEffect $cycle 'count.txt' ([string]($before + 1))
            } finally {
                $exit = [Diagnostics.Stopwatch]::StartNew()
                Stop-Cli $cycle.cli JNA
            }
            Add-UiaLatencies $cycleTimes ([ordered]@{ startToFirstSnapshot = $ready; exit = $exit.Elapsed.TotalMilliseconds })
            $cycles.count++
        }
        $cycles.ms = Get-UiaLatencySummary $cycleTimes
        Start-Sleep -Milliseconds 500
        $cycles.fixtureAfter = Process-Sample $fixture
        $cycles.jvmAfter = Get-JvmReferences
    }

    # Phase 4: the JVM exits and starts again while one session stays open.
    if ($FixtureRestarts) {
        $restarts = [ordered]@{ count = 0; discoveryMs = New-Object 'Collections.Generic.List[double]' }
        $report.fixtureRestarts = $restarts
        $run = Start-FrameworkAgent $Backend -WithoutPid
        [void](Get-FrameworkSnapshot $run (Get-FrameworkWindow $run))
        $restarts.agentBefore = Process-Sample $run.cli
        for ($i = 0; $i -lt $FixtureRestarts; $i++) {
            $oldPid = $fixture.Id
            Stop-StabilityFixture
            Start-StabilityFixture
            $found = [Diagnostics.Stopwatch]::StartNew()
            do {
                $rows = @(Framework-Result $run @{ op = 'listWindows' } | Where-Object { $_.processId -eq $fixture.Id -and $_.name -ceq $title })
                if (!$rows.Count) { Start-Sleep -Milliseconds 100 }
            } while (!$rows.Count -and $found.ElapsedMilliseconds -lt 10000)
            Require-Framework ($rows.Count -eq 1 -and $fixture.Id -ne $oldPid) 'The restarted JVM was not discovered.'
            $restarts.discoveryMs.Add($found.Elapsed.TotalMilliseconds)
            $snapshot = (Get-FrameworkSnapshot $run $rows[0].windowId).data
            Require-Framework ($snapshot.elements.Count -eq $expectedElements) 'The restarted JVM exposed a different tree.'
            $restarts.count++
        }
        $restarts.agentAfter = Process-Sample $run.cli
        Stop-Cli $run.cli JNA
        $run = $null
    }

    $growth = $steady.growth
    $report.verdict = [ordered]@{
        steadyFailures = $steady.failures.Count
        unexpectedRequestCodes = @($steady.requestCodes.Keys | Where-Object { $_ -cne 'OK' })
        agentHandlesStable = !$growth.agentHandles -or ($growth.agentHandles.last - $growth.agentHandles.settledFirst) -le 16
        agentThreadsStable = !$growth.agentThreads -or ($growth.agentThreads.last - $growth.agentThreads.settledFirst) -le 2
        # One capture holds at most one such object per element. A second capture may overlap it until collected.
        jvmReferencesBounded = !$growth.jvmPerRequestAccessibles -or ($growth.jvmPerRequestAccessibles.settledMax -le 2 * $expectedElements)
        jvmReferencesReleasedAtClose = !$report.referencesInJvm.afterSessionClosed -or
            ($report.referencesInJvm.afterSessionClosed.perRequestAccessibles -eq 0)
    }
    $ok = $report.verdict.steadyFailures -eq 0 -and !$report.verdict.unexpectedRequestCodes.Count -and $report.verdict.agentHandlesStable -and
        $report.verdict.agentThreadsStable -and $report.verdict.jvmReferencesBounded -and $report.verdict.jvmReferencesReleasedAtClose
    $report.status = if ($ok) { 'PASS' } else { 'FAIL' }
} catch {
    $report.failure = $_.Exception.Message
    $report.status = 'FAIL'
} finally {
    if ($run) { try { Stop-Cli $run.cli JNA } catch { $report.agentShutdownFailure = $_.Exception.Message } }
    try { Stop-StabilityFixture } catch { $report.fixtureShutdownFailure = $_.Exception.Message }
    try { Remove-UiaState } catch {}
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    Save-UiaJson (ConvertTo-Json -InputObject $report -Depth 30) $OutputPath
}
"$Backend $Framework $($report.status): $($report.steady.iterations) iterations, $($report.steady.failures.Count) failures. See $OutputPath."
if ($report.status -ne 'PASS') { exit 1 }
