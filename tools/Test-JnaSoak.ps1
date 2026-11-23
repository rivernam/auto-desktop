# Run on an unlocked Windows desktop using a JDK with jcmd and Native Memory Tracking.
# Only the tool's own WPF fixture is mutated. A failed iteration stops the run.
# Latencies are aggregated per -IntervalSeconds window and released when the window closes;
# whole-run quantiles come from a fixed-size histogram (see latencyStatistics in the report).
# Each resource sample also covers the fixture, this script and the host, and every JVM writes a
# GC log next to the report, so a slow interval can be attributed after the run.
# -TopProcesses N stores the names of the N busiest other processes per sample (off by default).
[CmdletBinding()]
param(
    [string]$Jar = (Join-Path $PSScriptRoot '../target/desktop-agent.jar'),
    [TimeSpan]$Duration = [TimeSpan]::FromHours(8),
    [ValidateRange(1, 3600)][int]$SampleSeconds = 60,
    [ValidateRange(1, 86400)][int]$IntervalSeconds = 60,
    [ValidateRange(0, 10000)][int]$MutateEvery = 0,
    [ValidateRange(1, 3600)][int]$MutationIntervalSeconds = 15,
    [ValidateRange(0, 1000000)][int]$MaxIterations = 0,
    [ValidateRange(0, 600000)][double]$SlowRequestMs = 100,
    [ValidateRange(0, 1000)][int]$SlowRequestLimit = 10,
    [ValidateRange(0, 50)][int]$TopProcesses = 0,
    [switch]$NoGcLog,
    [string]$OutputPath = (Join-Path $PSScriptRoot '../target/windows-uia-jna-soak.json')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UiaTest.Common.ps1')
$UiaSlowRequestMs = $SlowRequestMs
$UiaSlowRequestLimit = $SlowRequestLimit

function Sample-Jna($cli, $clock, [int]$iteration) {
    $elapsedMs = $clock.Elapsed.TotalMilliseconds
    # The process and host counters are read together, before jcmd adds its own load.
    $resources = Resources $cli 'JNA'
    if (!$resources.java.available) { throw 'Unable to sample the JVM process.' }
    $fixtureSample = Process-Sample $fixture
    $driverSample = Process-Sample $driver
    $hostSample = Get-UiaHostSample $fixtureWindow $TopProcesses @($cli.Id, $fixture.Id, $PID)
    $heap = Read-Diagnostic $jcmd "$($cli.Id) GC.heap_info"
    $native = Read-Diagnostic $jcmd "$($cli.Id) VM.native_memory summary scale=KB"
    $total = [regex]::Match($native.stdout, '(?m)^Total:\s*reserved=(\d+)KB,\s*committed=(\d+)KB')
    if ($heap.exitCode -ne 0 -or $native.exitCode -ne 0 -or !$total.Success) {
        throw "JVM diagnostics unavailable (heap=$($heap.exitCode), NMT=$($native.exitCode)): $($heap.stderr) $($native.stderr)"
    }
    $sample = [ordered]@{
        iteration = $iteration; elapsedMs = $elapsedMs; resources = $resources
        fixture = $fixtureSample; driver = $driverSample; host = $hostSample
        heap = $heap.stdout; nativeMemory = $native.stdout
        nmtReservedBytes = [long]$total.Groups[1].Value * 1KB
        nmtCommittedBytes = [long]$total.Groups[2].Value * 1KB
    }
    $heapFigures = ConvertFrom-JvmHeapInfo $heap.stdout
    foreach ($field in $heapFigures.Keys) { $sample[$field] = $heapFigures[$field] }
    # GC counters are optional: a missing jvmstat counter must not fail the soak.
    try {
        $counters = Read-Diagnostic $jcmd "$($cli.Id) PerfCounter.print"
        $sample.gc = if ($counters.exitCode -eq 0) { ConvertFrom-JvmPerfCounters $counters.stdout }
                     else { [ordered]@{ available = $false } }
    } catch { $sample.gc = [ordered]@{ available = $false; error = $_.Exception.Message } }
    return $sample
}

# Raw jcmd text is kept for the first and latest sample of a session only; numeric fields stay.
function Add-SessionSample($session, $sample) {
    $count = $session.samples.Count
    if ($count -ge 2) {
        $previous = $session.samples[$count - 1]
        foreach ($field in 'heap', 'nativeMemory') { [void]$previous.Remove($field) }
        $previous.rawDiagnosticsOmitted = $true
    }
    $session.samples.Add($sample)
}

function Get-JnaResourceChange($session) {
    $first = $session.samples[0]
    $last = $session.samples[$session.samples.Count - 1]
    $change = [ordered]@{ intervalSeconds = ($last.elapsedMs - $first.elapsedMs) / 1000 }
    foreach ($field in 'privateBytes', 'workingSetBytes', 'cpuMs', 'handles', 'threads') {
        $change[$field] = $last.resources.java[$field] - $first.resources.java[$field]
    }
    foreach ($field in 'nmtReservedBytes', 'nmtCommittedBytes', 'heapCommittedBytes', 'heapUsedBytes') {
        if ($first.Contains($field) -and $last.Contains($field)) { $change[$field] = $last[$field] - $first[$field] }
    }
    return $change
}

function Open-SoakInterval {
    $script:interval = New-SoakInterval $report.intervals.Count ($report.sessions.Count - 1) $cli.Id $clock.Elapsed.TotalMilliseconds
    $script:intervalLatencies = [ordered]@{}
}

function Close-SoakInterval([double]$endElapsedMs, $resourceSample, [string]$closedBy) {
    if (!$script:interval) { return }
    $closed = Complete-SoakInterval $script:interval $script:intervalLatencies $endElapsedMs $resourceSample $closedBy
    $report.intervals.Add($closed)
    $script:interval = $null
    $script:intervalLatencies = $null
}

function Stop-SoakSession([string]$reason) {
    $session.endReason = $reason
    try { Stop-Cli $cli 'JNA'; $session.exitedNormally = $true }
    catch {
        # A non-zero exit or a hang after EOF is an abnormal JVM termination.
        $session.exitedNormally = $false
        $session.shutdownError = $_.Exception.Message
        $report.unexpectedJvmExits++
        throw
    } finally {
        $script:cli = $null
        $session.endUtc = [DateTime]::UtcNow.ToString('o')
        $session.endElapsedMs = $clock.Elapsed.TotalMilliseconds
    }
}

$report = [ordered]@{
    # 3 adds fixture, driver and host samples, heap generations, slow requests and GC logs to 2.
    schemaVersion = 3
    utc = [DateTime]::UtcNow.ToString('o'); environment = Get-UiaEnvironment
    passed = $false; stage = 'setup'; durationLimitSeconds = $Duration.TotalSeconds
    sampleIntervalSeconds = $SampleSeconds; intervalSeconds = $IntervalSeconds
    mutateEvery = $MutateEvery; mutationIntervalSeconds = $MutationIntervalSeconds
    iterationLimit = $MaxIterations
    slowRequestThresholdMs = $SlowRequestMs; slowRequestLimit = $SlowRequestLimit
    topProcesses = $TopProcesses; gcLogging = $false
    attemptedIterations = 0; completedIterations = 0; mutationIterations = 0
    requestsCompleted = 0; requestsFailed = 0; timeouts = 0; errorCounts = [ordered]@{}
    sessionRestarts = 0; unexpectedJvmExits = 0
    comReleaseObservation = 'Indirect: JVM exit, process counters and HotSpot NMT. NMT does not count COM references or all native allocations.'
    latencyStatistics = [ordered]@{
        latencyMs = 'Whole run, fixed-memory log histogram with 1% bucket width: count, mean and max are exact; p50/p95/p99 are nearest-rank bucket upper bounds capped at max and overestimate by at most 1%.'
        intervals = 'Exact nearest-rank within each interval. Samples are released when the interval closes.'
        histogramFloorMs = $UiaHistogramFloorMs; histogramRatio = $UiaHistogramRatio
    }
    rawDiagnosticsRetention = 'heap and nativeMemory text are kept for the first and last sample of each session.'
    failures = New-Object 'Collections.Generic.List[object]'
    intervals = New-Object 'Collections.Generic.List[object]'
    latencyHistograms = [ordered]@{}
    sessions = New-Object 'Collections.Generic.List[object]'
}
$clock = [Diagnostics.Stopwatch]::StartNew()
$histograms = $report.latencyHistograms
$cli = $null
$session = $null
$interval = $null
$intervalLatencies = $null
$driver = [Diagnostics.Process]::GetCurrentProcess()
$fixtureWindow = 0
$requestEnds = @{}
try {
    Save-UiaCheckpoint $report $OutputPath
    if ($Duration -le [TimeSpan]::Zero) { throw 'Duration must be positive.' }
    Initialize-UiaTools
    $jcmd = (Get-Item -LiteralPath (Join-Path (Split-Path -Parent $javaExe) 'jcmd.exe')).FullName
    Set-UiaBuildInfo $report.environment
    # Host observations are optional: without them the samples record host.available = false.
    if (Initialize-UiaHostProbe) { Set-UiaHostInfo $report.environment }
    $gcLogPattern = if ($NoGcLog) { $null } else { Get-SoakGcLogPattern $OutputPath }
    $report.gcLogging = [bool]$gcLogPattern
    $report.stage = 'fixture'
    Save-UiaCheckpoint $report $OutputPath
    Start-UiaFixture $false
    $start = New-CliStartInfo 'JNA' -TrackNativeMemory -GcLogPath $gcLogPattern
    $clock.Restart()
    $fixtureShape = @()
    $expectedCount = 0
    $mutationCount = 0
    $nextMutationSeconds = 0.0
    while ($clock.Elapsed -lt $Duration -and (!$MaxIterations -or $report.completedIterations -lt $MaxIterations)) {
        if (!$cli) {
            $report.stage = 'session/warmup'
            $sessionStartMs = $clock.Elapsed.TotalMilliseconds
            $cli = Start-Cli $start
            $session = [ordered]@{
                index = $report.sessions.Count; pid = $cli.Id; startUtc = [DateTime]::UtcNow.ToString('o')
                startElapsedMs = $sessionStartMs; completedIterations = 0; mutationIterations = 0
                samples = New-Object 'Collections.Generic.List[object]'
            }
            # A file name relative to the report, so the pair can be moved together.
            if ($gcLogPattern) { $session.gcLog = Get-SoakGcLogName $gcLogPattern $cli.Id }
            $report.sessions.Add($session)
            if ($session.index -gt 0) { $report.sessionRestarts++ }
            if (!(Request $cli @{ op = 'getCapabilities' }).result.available) { throw 'JNA backend is unavailable.' }
            $windowId = Check-Window (Request $cli @{ op = 'listWindows' }).result
            $fixtureWindow = 0
            [void][long]::TryParse([string]$windowId, [ref]$fixtureWindow) # the window ID is the HWND
            $snapshot = (Take-Snapshot $cli $windowId).result
            $expectedCount = Check-Snapshot $snapshot $windowId $expectedCount
            Check-TreeShape $snapshot $fixtureShape
            $fixtureShape = @(Get-TreeShape $snapshot)
            [void](Run-Iteration $cli $windowId $expectedCount ([guid]::NewGuid().ToString('N')) $fixtureShape)
            $first = Sample-Jna $cli $clock 0
            $session.jvmStartUtc = $first.resources.java.startUtc
            Add-SessionSample $session $first
            Save-UiaCheckpoint $report $OutputPath
            $lastSampleSeconds = $clock.Elapsed.TotalSeconds
            $mutationCount = 1
            Open-SoakInterval
        }
        $report.stage = "iteration/$($report.completedIterations + 1)"
        $observeOnly = if ($MutateEvery) { $report.completedIterations % $MutateEvery -ne 0 }
                       else { $clock.Elapsed.TotalSeconds -lt $nextMutationSeconds }
        $report.attemptedIterations++
        $interval.attemptedIterations++
        try {
            $times = Run-Iteration $cli $windowId $expectedCount ([guid]::NewGuid().ToString('N')) $fixtureShape `
                -ObserveOnly:$observeOnly -RequestEnds $requestEnds
        } catch {
            $failure = Get-SoakFailure $_.Exception.Message
            $failure.message = $_.Exception.Message
            $failure.utc = [DateTime]::UtcNow.ToString('o')
            $failure.elapsedMs = $clock.Elapsed.TotalMilliseconds
            $failure.iteration = $report.attemptedIterations
            $failure.sessionIndex = $session.index
            $failure.intervalIndex = $interval.index
            $failure.jvmExited = $cli.HasExited
            if ($failure.jvmExited) { $failure.jvmExitCode = $cli.ExitCode }
            Add-SoakFailure $interval $failure
            if ($failure.request) { $report.requestsFailed++ }
            if ($failure.code -eq 'TIMEOUT') { $report.timeouts++ }
            if ($report.errorCounts.Contains($failure.code)) { $report.errorCounts[$failure.code]++ }
            else { $report.errorCounts[$failure.code] = 1 }
            if ($report.failures.Count -lt 100) { $report.failures.Add($failure) }
            throw
        }
        $report.completedIterations++
        $session.completedIterations++
        $interval.completedIterations++
        if (!$observeOnly) {
            $nextMutationSeconds = $clock.Elapsed.TotalSeconds + $MutationIntervalSeconds
            $mutationCount++
            $report.mutationIterations++
            $session.mutationIterations++
            $interval.mutationIterations++
        }
        Add-SoakIterationTimes $interval $intervalLatencies $histograms $times $requestEnds $report.attemptedIterations
        $report.requestsCompleted += $times.Count
        $boundaryMs = $clock.Elapsed.TotalMilliseconds
        $dueSample = $boundaryMs / 1000 - $lastSampleSeconds -ge $SampleSeconds
        $dueInterval = $boundaryMs - $interval.startElapsedMs -ge $IntervalSeconds * 1000
        if ($dueSample -or $dueInterval) {
            $sample = Sample-Jna $cli $clock $session.completedIterations
            if ($dueSample) {
                Add-SessionSample $session $sample
                $lastSampleSeconds = $clock.Elapsed.TotalSeconds
            }
            if ($dueInterval) {
                $closed = $interval
                $closed.samplingMs = $clock.Elapsed.TotalMilliseconds - $boundaryMs
                Close-SoakInterval $boundaryMs $sample 'interval'
            }
            # Checkpoint between windows so serialization time is excluded from both intervals.
            $checkpointStart = $clock.Elapsed.TotalMilliseconds
            Save-UiaCheckpoint $report $OutputPath
            if ($dueInterval) {
                $closed.checkpointMs = $clock.Elapsed.TotalMilliseconds - $checkpointStart
                Open-SoakInterval
            }
        }
        if ($mutationCount -ge 2048) {
            # Two unique action IDs per mutation iteration, including warmup.
            # EOF releases the session before the Java agent's 4096-ID limit is exceeded.
            $report.stage = 'session/action-limit'
            $boundaryMs = $clock.Elapsed.TotalMilliseconds
            $sample = Sample-Jna $cli $clock $session.completedIterations
            Add-SessionSample $session $sample
            Close-SoakInterval $boundaryMs $sample 'session-end'
            Stop-SoakSession 'action-limit'
            Save-UiaCheckpoint $report $OutputPath
        }
    }
    if ($cli) {
        $report.stage = 'session/final-sample'
        $boundaryMs = $clock.Elapsed.TotalMilliseconds
        $sample = Sample-Jna $cli $clock $session.completedIterations
        Add-SessionSample $session $sample
        Close-SoakInterval $boundaryMs $sample 'run-end'
        Stop-SoakSession 'run-end'
    }
    if (!$report.completedIterations) { throw 'No measured JNA iteration was completed.' }
    $report.elementsPerSnapshot = $expectedCount
    $report.stage = 'complete'
    $report.passed = $true
} catch {
    $report.error = $_.Exception.Message
    if ($session -and !$report.failures.Count) {
        # Failures outside a measured iteration, e.g. during session warmup or shutdown.
        $failure = Get-SoakFailure $report.error
        $failure.message = $report.error
        $failure.utc = [DateTime]::UtcNow.ToString('o')
        $failure.elapsedMs = $clock.Elapsed.TotalMilliseconds
        $failure.stage = $report.stage
        $failure.sessionIndex = $session.index
        $report.failures.Add($failure)
        if ($report.errorCounts.Contains($failure.code)) { $report.errorCounts[$failure.code]++ }
        else { $report.errorCounts[$failure.code] = 1 }
    }
} finally {
    $endMs = $clock.Elapsed.TotalMilliseconds
    if (!$report.passed -and !$report.Contains('error')) { $report.interrupted = $true }
    if ($cli) {
        $report.failureResources = Resources $cli 'JNA'
        if ($session) {
            $session.exitedNormally = $false
            $session.endReason = if ($report.interrupted) { 'interrupted' } else { 'failure' }
            if ($cli.HasExited) {
                $session.unexpectedExit = $true
                $session.exitCode = $cli.ExitCode
                $report.unexpectedJvmExits++
            }
        }
        try { Stop-Cli $cli 'JNA' } catch { $report.cliCleanupError = $_.Exception.Message }
        if ($session) {
            $session.endUtc = [DateTime]::UtcNow.ToString('o')
            $session.endElapsedMs = $clock.Elapsed.TotalMilliseconds
        }
    }
    if ($interval) {
        $closedBy = if ($report.interrupted) { 'interrupted' } else { 'failure' }
        Close-SoakInterval $endMs $report.failureResources $closedBy
    }
    try { Stop-UiaFixture $report } catch { $report.cleanupError = $_.Exception.Message; $report.passed = $false }
    try { Remove-UiaState } catch { $report.stateCleanupError = $_.Exception.Message; $report.passed = $false }
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    $report.elapsedMs = $clock.Elapsed.TotalMilliseconds
    foreach ($segment in $report.sessions) {
        if ($segment.samples.Count -ge 2) { $segment.resourceChange = Get-JnaResourceChange $segment }
    }
    $report.failedIterations = $report.attemptedIterations - $report.completedIterations
    if ($report.attemptedIterations) { $report.failureRate = $report.failedIterations / $report.attemptedIterations }
    $report.latencyMs = Get-UiaHistogramReport $histograms
    $report.operationLatencyMs = Get-UiaHistogramReport (Get-UiaOperationHistograms $histograms)
    Write-UiaReport $report $OutputPath
}
if (!$report.passed) { throw 'JNA soak did not complete. Inspect the JSON report.' }
if ($report.reportWriteError) { throw 'Could not save the soak report. JSON was emitted to stdout.' }
