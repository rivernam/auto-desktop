# Run on an unlocked Windows desktop using a JDK with jcmd and Native Memory Tracking.
# Only the tool's own WPF fixture is mutated. A failed iteration stops the run.
[CmdletBinding()]
param(
    [string]$Jar = (Join-Path $PSScriptRoot '../target/desktop-agent.jar'),
    [TimeSpan]$Duration = [TimeSpan]::FromHours(8),
    [ValidateRange(1, 3600)][int]$SampleSeconds = 60,
    [ValidateRange(0, 10000)][int]$MutateEvery = 0,
    [ValidateRange(1, 3600)][int]$MutationIntervalSeconds = 15,
    [ValidateRange(0, 1000000)][int]$MaxIterations = 0,
    [string]$OutputPath = (Join-Path $PSScriptRoot '../target/windows-uia-jna-soak.json')
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UiaTest.Common.ps1')

function Sample-Jna($cli, $clock, [int]$iteration) {
    $elapsedMs = $clock.Elapsed.TotalMilliseconds
    $resources = Resources $cli 'JNA'
    if (!$resources.java.available) { throw 'Unable to sample the JVM process.' }
    $heap = Read-Diagnostic $jcmd "$($cli.Id) GC.heap_info"
    $native = Read-Diagnostic $jcmd "$($cli.Id) VM.native_memory summary scale=KB"
    $total = [regex]::Match($native.stdout, '(?m)^Total:\s*reserved=(\d+)KB,\s*committed=(\d+)KB')
    if ($heap.exitCode -ne 0 -or $native.exitCode -ne 0 -or !$total.Success) {
        throw "JVM diagnostics unavailable (heap=$($heap.exitCode), NMT=$($native.exitCode)): $($heap.stderr) $($native.stderr)"
    }
    $sample = [ordered]@{
        iteration = $iteration; elapsedMs = $elapsedMs; resources = $resources
        heap = $heap.stdout; nativeMemory = $native.stdout
        nmtReservedBytes = [long]$total.Groups[1].Value * 1KB
        nmtCommittedBytes = [long]$total.Groups[2].Value * 1KB
    }
    $usage = [regex]::Match($heap.stdout, '(?i)heap\s+total\s+(\d+)K,\s+used\s+(\d+)K\b')
    if ($usage.Success) {
        $sample.heapCommittedBytes = [long]$usage.Groups[1].Value * 1KB
        $sample.heapUsedBytes = [long]$usage.Groups[2].Value * 1KB
    }
    return $sample
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

$report = [ordered]@{
    utc = [DateTime]::UtcNow.ToString('o'); environment = Get-UiaEnvironment
    passed = $false; stage = 'setup'; durationLimitSeconds = $Duration.TotalSeconds
    sampleIntervalSeconds = $SampleSeconds; mutateEvery = $MutateEvery; mutationIntervalSeconds = $MutationIntervalSeconds
    iterationLimit = $MaxIterations
    attemptedIterations = 0; completedIterations = 0; mutationIterations = 0
    comReleaseObservation = 'Indirect: JVM exit, process counters and HotSpot NMT. NMT does not count COM references or all native allocations.'
    sessions = New-Object 'Collections.Generic.List[object]'
}
$clock = [Diagnostics.Stopwatch]::StartNew()
$latencies = [ordered]@{}
$cli = $null
try {
    Save-UiaCheckpoint $report $OutputPath
    if ($Duration -le [TimeSpan]::Zero) { throw 'Duration must be positive.' }
    Initialize-UiaTools
    $jcmd = (Get-Item -LiteralPath (Join-Path (Split-Path -Parent $javaExe) 'jcmd.exe')).FullName
    Set-UiaBuildInfo $report.environment
    $report.stage = 'fixture'
    Save-UiaCheckpoint $report $OutputPath
    Start-UiaFixture $false
    $start = New-CliStartInfo 'JNA' -TrackNativeMemory
    $clock.Restart()
    $fixtureShape = @()
    $expectedCount = 0
    $mutationCount = 0
    $nextMutationSeconds = 0.0
    while ($clock.Elapsed -lt $Duration -and (!$MaxIterations -or $report.completedIterations -lt $MaxIterations)) {
        if (!$cli) {
            $report.stage = 'session/warmup'
            $cli = Start-Cli $start
            if (!(Request $cli @{ op = 'getCapabilities' }).result.available) { throw 'JNA backend is unavailable.' }
            $windowId = Check-Window (Request $cli @{ op = 'listWindows' }).result
            $snapshot = (Take-Snapshot $cli $windowId).result
            $expectedCount = Check-Snapshot $snapshot $windowId $expectedCount
            Check-TreeShape $snapshot $fixtureShape
            $fixtureShape = @(Get-TreeShape $snapshot)
            [void](Run-Iteration $cli $windowId $expectedCount ([guid]::NewGuid().ToString('N')) $fixtureShape)
            $session = [ordered]@{
                pid = $cli.Id; completedIterations = 0; mutationIterations = 0
                samples = New-Object 'Collections.Generic.List[object]'
            }
            $report.sessions.Add($session)
            $session.samples.Add((Sample-Jna $cli $clock 0))
            Save-UiaCheckpoint $report $OutputPath
            $lastSampleSeconds = $clock.Elapsed.TotalSeconds
            $mutationCount = 1
        }
        $report.stage = "iteration/$($report.completedIterations + 1)"
        $observeOnly = if ($MutateEvery) { $report.completedIterations % $MutateEvery -ne 0 }
                       else { $clock.Elapsed.TotalSeconds -lt $nextMutationSeconds }
        $report.attemptedIterations++
        $times = Run-Iteration $cli $windowId $expectedCount ([guid]::NewGuid().ToString('N')) $fixtureShape -ObserveOnly:$observeOnly
        $report.completedIterations++
        $session.completedIterations++
        if (!$observeOnly) {
            $nextMutationSeconds = $clock.Elapsed.TotalSeconds + $MutationIntervalSeconds
            $mutationCount++
            $report.mutationIterations++
            $session.mutationIterations++
        }
        Add-UiaLatencies $latencies $times
        if ($clock.Elapsed.TotalSeconds - $lastSampleSeconds -ge $SampleSeconds) {
            $session.samples.Add((Sample-Jna $cli $clock $session.completedIterations))
            Save-UiaCheckpoint $report $OutputPath
            $lastSampleSeconds = $clock.Elapsed.TotalSeconds
        }
        if ($mutationCount -ge 2048) {
            # Two unique action IDs per mutation iteration, including warmup.
            # EOF releases the session before the Java agent's 4096-ID limit is exceeded.
            $report.stage = 'session/action-limit'
            $session.samples.Add((Sample-Jna $cli $clock $session.completedIterations))
            try { Stop-Cli $cli 'JNA' } finally { $cli = $null }
            $session.exitedNormally = $true
            Save-UiaCheckpoint $report $OutputPath
        }
    }
    if ($cli) {
        $report.stage = 'session/final-sample'
        $session.samples.Add((Sample-Jna $cli $clock $session.completedIterations))
        try { Stop-Cli $cli 'JNA' } finally { $cli = $null }
        $session.exitedNormally = $true
    }
    if (!$report.completedIterations) { throw 'No measured JNA iteration was completed.' }
    $report.elementsPerSnapshot = $expectedCount
    $report.stage = 'complete'
    $report.passed = $true
} catch {
    $report.error = $_.Exception.Message
} finally {
    if ($cli) {
        $report.failureResources = Resources $cli 'JNA'
        try { Stop-Cli $cli 'JNA' } catch { $report.cliCleanupError = $_.Exception.Message }
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
    $report.latencyMs = Get-UiaLatencySummary $latencies
    Write-UiaReport $report $OutputPath
}
if (!$report.passed) { throw 'JNA soak did not complete. Inspect the JSON report.' }
if ($report.reportWriteError) { throw 'Could not save the soak report. JSON was emitted to stdout.' }
