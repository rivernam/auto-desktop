# Run on an unlocked Windows test desktop. Emits one JSON document to stdout.
# Cold runs use fresh JVMs with ordinary OS caches. Hot times exclude fixture readback
# and resource sampling. With -IncludeJna, use the borderless fixture by default.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CSharpWorker,
    [string]$Jar = (Join-Path $PSScriptRoot '../target/desktop-agent.jar'),
    [ValidateRange(1, 2000)][int]$Iterations = 10,
    [ValidateRange(1, 100)][int]$Sessions = 1,
    [ValidateRange(1, 100)][int]$ColdRuns = 3,
    [switch]$IncludeJna,
    [switch]$DecoratedWindow,
    [string]$OutputPath
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UiaTest.Common.ps1')

function Measure-Backend([string]$backend, $results) {
    $start = New-CliStartInfo $backend
    $cold = New-Object 'Collections.Generic.List[object]'
    $hot = New-Object 'Collections.Generic.List[object]'
    $result = [ordered]@{ backend = $backend; status = 'running'; stage = 'discovery'; elementsPerSnapshot = 0
        cold = $cold; sessions = $hot }
    $results.Add($result)
    $cli = $null
    try {
        # Discovery runs separately from either measurement.
        $cli = Start-Cli $start
        $windowId = Check-Window (Request $cli @{ op = 'listWindows' }).result
        $initial = (Take-Snapshot $cli $windowId).result
        $result.elementsPerSnapshot = Check-Snapshot $initial $windowId 0
        $result.snapshotShape = @(Get-TreeShape $initial)
        try { Stop-Cli $cli $backend } finally { $cli = $null }
        $coldTimes = [ordered]@{}
        for ($round = 1; $round -le $ColdRuns; $round++) {
            foreach ($op in 'getCapabilities', 'snapshot') {
                $result.stage = "cold/$round/$op"
                $command = @{ op = $op }
                if ($op -eq 'snapshot') { $command += @{ windowId = $windowId; maxDepth = 16; maxElements = 200 } }
                $clock = [Diagnostics.Stopwatch]::StartNew()
                $cli = Start-Cli $start
                $launchMs = $clock.Elapsed.TotalMilliseconds
                $reply = Request $cli $command
                $clock.Stop()
                if ($op -eq 'getCapabilities' -and !$reply.result.available) { throw 'Worker reported unavailable.' }
                if ($op -eq 'snapshot') {
                    [void](Check-Snapshot $reply.result $windowId $result.elementsPerSnapshot)
                    Check-TreeShape $reply.result $result.snapshotShape
                }
                $cold.Add([ordered]@{ round = $round; op = $op; launchMs = $launchMs; requestMs = $reply.ms
                    startToReplyMs = $clock.Elapsed.TotalMilliseconds; resources = Resources $cli $backend })
                Add-UiaLatencies $coldTimes @{ $op = $clock.Elapsed.TotalMilliseconds }
                try { Stop-Cli $cli $backend } finally { $cli = $null }
            }
        }
        $result.coldStartToReplyMs = Get-UiaLatencySummary $coldTimes
        for ($session = 1; $session -le $Sessions; $session++) {
            $result.stage = "session/$session/warmup"
            $cli = Start-Cli $start
            $caps = Request $cli @{ op = 'getCapabilities' }
            if (!$caps.result.available) { throw 'Worker reported unavailable.' }
            if ((Check-Window (Request $cli @{ op = 'listWindows' }).result) -cne $windowId) { throw 'Fixture window changed.' }
            $token = [Guid]::NewGuid().ToString('N')
            [void](Run-Iteration $cli $windowId $result.elementsPerSnapshot "$token-warmup" $result.snapshotShape)
            $samples = New-Object 'Collections.Generic.List[object]'
            $baseline = Resources $cli $backend
            $latencies = [ordered]@{}
            $run = [ordered]@{ session = $session; completedIterations = 0; elapsedMs = 0
                baseline = $baseline; samples = $samples; workerIdentity = 'unobserved' }
            $hot.Add($run)
            $clock = [Diagnostics.Stopwatch]::StartNew()
            # Keep boundary samples and at most 32 evenly spaced observations per session.
            $stride = [int][Math]::Ceiling($Iterations / 32.0)
            $workerIdentity = $baseline.worker
            if ($backend -eq 'JNA') { $run.workerIdentity = 'in-process' }
            elseif ($workerIdentity.available) { $run.workerIdentity = 'observed' }
            for ($i = 1; $i -le $Iterations; $i++) {
                $result.stage = "session/$session/iteration/$i"
                $times = Run-Iteration $cli $windowId $result.elementsPerSnapshot ("$token-{0:D4}" -f $i) $result.snapshotShape
                $run.completedIterations = $i
                $run.elapsedMs = $clock.Elapsed.TotalMilliseconds
                Add-UiaLatencies $latencies $times
                if ($i -eq 1 -or $i -eq $Iterations -or ($i % $stride) -eq 0) {
                    $resource = Resources $cli $backend
                    $samples.Add([ordered]@{ iteration = $i; elapsedMs = $run.elapsedMs; latencyMs = $times; resources = $resource })
                    if ($backend -eq 'JNA') { continue }
                    if (!$resource.worker.available) { $run.workerIdentity = 'incomplete' }
                    elseif (!$workerIdentity.available) { $workerIdentity = $resource.worker; $run.workerIdentity = 'incomplete' }
                    elseif ($resource.worker.pid -ne $workerIdentity.pid -or $resource.worker.startUtc -ne $workerIdentity.startUtc) {
                        $run.workerIdentity = 'changed'
                        throw 'Worker identity changed within a persistent session.'
                    }
                }
            }
            $run.latencyMs = Get-UiaLatencySummary $latencies
            try { Stop-Cli $cli $backend } finally { $cli = $null }
        }
        $result.stage = 'complete'
        $result.status = 'passed'
    } catch {
        $result.status = 'failed'
        $result.error = $_.Exception.Message
        if ($cli) { $result.failureResources = Resources $cli $backend }
    } finally {
        if ($cli) {
            try { Stop-Cli $cli $backend } catch { $result.cleanupError = $_.Exception.Message }
        }
    }
}

function Has-CompleteResources($backendResult) {
    foreach ($sample in $backendResult.cold) {
        if (!$sample.resources.total.available) { return $false }
    }
    foreach ($session in $backendResult.sessions) {
        if (!$session.baseline.total.available) { return $false }
        foreach ($sample in $session.samples) {
            if (!$sample.resources.total.available) { return $false }
        }
    }
    return $true
}

$report = [ordered]@{
    utc = [DateTime]::UtcNow.ToString('o'); environment = Get-UiaEnvironment
    os = [Environment]::OSVersion.VersionString
    passed = $false; stage = 'setup'; iterationsPerSession = $Iterations; sessionsPerBackend = $Sessions
    coldRunsPerOperation = $ColdRuns; warmupIterationsPerSession = 1
    fixtureBorderless = [bool]($IncludeJna -and !$DecoratedWindow)
    results = New-Object 'Collections.Generic.List[object]'
}
try {
    Save-UiaCheckpoint $report $OutputPath
    $backends = @('PowerShell', 'CSharp')
    if ($IncludeJna) { $backends += 'JNA' }
    $report.order = @($backends | Get-Random -Count $backends.Count)
    Initialize-UiaTools
    $CSharpWorker = (Get-Item -LiteralPath $CSharpWorker).FullName
    Set-UiaBuildInfo $report.environment $CSharpWorker
    $report.stage = 'fixture'
    Save-UiaCheckpoint $report $OutputPath
    Start-UiaFixture $report.fixtureBorderless
    $report.stage = 'benchmark'
    foreach ($backend in $report.order) {
        Measure-Backend $backend $report.results
        Save-UiaCheckpoint $report $OutputPath
    }
    $failed = @($report.results | Where-Object { $_.status -ne 'passed' })
    if ($failed.Count) { throw "Benchmark failed for $($failed.backend -join ', ')." }
    $shapes = @(foreach ($result in $report.results) { $result.snapshotShape -join [char]10 })
    $report.treeParity = @($shapes | Where-Object { $_ -cne $shapes[0] }).Count -eq 0
    if (!$report.treeParity) { throw 'The backends returned different fixture snapshots.' }
    $report.completeResources = @($report.results | Where-Object { !(Has-CompleteResources $_) }).Count -eq 0
    if ($IncludeJna -and !$report.completeResources) { throw 'Process resource measurements are incomplete.' }
    $report.stage = 'complete'
    $report.passed = $true
} catch {
    $report.error = $_.Exception.Message
} finally {
    try { Stop-UiaFixture $report } catch { $report.cleanupError = $_.Exception.Message; $report.passed = $false }
    try { Remove-UiaState } catch { $report.stateCleanupError = $_.Exception.Message; $report.passed = $false }
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    Write-UiaReport $report $OutputPath
}
if (!$report.passed) { throw 'Worker comparison failed. Inspect the JSON report.' }
if ($report.reportWriteError) { throw 'Could not save the comparison report. JSON was emitted to stdout.' }
