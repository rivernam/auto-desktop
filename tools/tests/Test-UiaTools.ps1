# Check benchmark reporting and helper contracts without launching a desktop fixture.
$ErrorActionPreference = 'Stop'
$tools = Split-Path -Parent $PSScriptRoot
. (Join-Path $tools 'UiaTest.Common.ps1')

function Assert-SetupFailureReport([scriptblock]$invoke) {
    $path = Join-Path ([IO.Path]::GetTempPath()) ("uia-failure-test-" + [Guid]::NewGuid() + '.json')
    try {
        $raised = $false
        try { & $invoke $path | Out-Null }
        catch { $raised = $true }
        if (!$raised -or ![IO.File]::Exists($path)) {
            throw 'A setup failure must raise an error and save its report.'
        }
        $report = [IO.File]::ReadAllText($path) | ConvertFrom-Json
        if ($report.passed -or $report.stage -ne 'setup' -or !$report.environment.os -or !$report.error) {
            throw 'The failure report is missing its environment or diagnostic.'
        }
    } finally { [IO.File]::Delete($path) }
}

$missingJar = Join-Path ([IO.Path]::GetTempPath()) ([Guid]::NewGuid().ToString() + '.jar')
Assert-SetupFailureReport {
    param($path)
    & (Join-Path $tools 'Compare-UiaWorkers.ps1') -Jar $missingJar -CSharpWorker 'not-used.exe' -IncludeJna -OutputPath $path
}
Assert-SetupFailureReport {
    param($path)
    & (Join-Path $tools 'Test-JnaSoak.ps1') -Jar $missingJar -OutputPath $path
}

$checkpointPath = Join-Path ([IO.Path]::GetTempPath()) ("uia-checkpoint-" + [Guid]::NewGuid() + '.json')
try {
    $checkpoint = [ordered]@{ passed = $false; stage = 'setup'; environment = Get-UiaEnvironment }
    Save-UiaCheckpoint $checkpoint $checkpointPath
    $checkpoint.stage = 'benchmark'
    Save-UiaCheckpoint $checkpoint $checkpointPath
    $saved = [IO.File]::ReadAllText($checkpointPath) | ConvertFrom-Json
    if ($saved.passed -or $saved.stage -ne 'benchmark' -or !$saved.environment.os -or !$saved.checkpointUtc) {
        throw 'The interrupted run checkpoint is missing its last progress.'
    }
    if ($env:OS -eq 'Windows_NT') {
        $reader = [IO.File]::Open($checkpointPath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $completed = [ordered]@{ passed = $true; stage = 'complete'; environment = Get-UiaEnvironment }
            $written = Write-UiaReport $completed $checkpointPath | ConvertFrom-Json
            if (!$written.passed -or !$written.reportWriteError) {
                throw 'A report locked by a reader must preserve the successful result on stdout.'
            }
            if (([IO.File]::ReadAllText($checkpointPath) | ConvertFrom-Json).stage -ne 'benchmark') {
                throw 'Failure to replace an open report must preserve its previous checkpoint.'
            }
        } finally { $reader.Dispose() }
    }
} finally { [IO.File]::Delete($checkpointPath) }

$latencies = [ordered]@{}
100..1 | ForEach-Object { Add-UiaLatencies $latencies @{ snapshot = [double]$_ } }
$summary = (Get-UiaLatencySummary $latencies).snapshot
if ($summary.count -ne 100 -or $summary.mean -ne 50.5 -or $summary.p50 -ne 50 -or
    $summary.p95 -ne 95 -or $summary.p99 -ne 99 -or $summary.max -ne 100) {
    throw 'The latency summary does not use nearest-rank percentiles.'
}

$histogram = New-UiaLatencyHistogram
$exact = [ordered]@{}
$random = New-Object Random 7
foreach ($value in @(1000..1) + @(1..2000 | ForEach-Object { [Math]::Exp($random.NextDouble() * 9) / 100 })) {
    Add-UiaHistogramValue $histogram $value
    Add-UiaLatencies $exact @{ snapshot = [double]$value }
}
$approximate = Get-UiaHistogramSummary $histogram
$reference = (Get-UiaLatencySummary $exact).snapshot
if ($approximate.count -ne $reference.count -or [Math]::Abs($approximate.mean - $reference.mean) -gt 1e-9 -or
    $approximate.max -ne $reference.max) {
    throw 'Histogram count, mean and max must be exact.'
}
foreach ($name in 'p50', 'p95', 'p99') {
    if ($approximate[$name] -lt $reference[$name] -or $approximate[$name] -gt $reference[$name] * 1.0100001) {
        throw "Histogram $name must be within 1% above the exact nearest-rank value."
    }
}
$split = [ordered]@{ findEdit = New-UiaLatencyHistogram; findButton = New-UiaLatencyHistogram }
1..10 | ForEach-Object { Add-UiaHistogramValue $split.findEdit 1.0; Add-UiaHistogramValue $split.findButton 3.0 }
$merged = (Get-UiaHistogramReport (Get-UiaOperationHistograms $split)).findElement
if ($merged.count -ne 20 -or $merged.mean -ne 2.0 -or $merged.max -ne 3.0 -or $merged.p50 -gt 1.01 -or $merged.p95 -lt 3.0) {
    throw 'Find latencies must merge into one findElement histogram.'
}
$wide = New-UiaLatencyHistogram
$wideRandom = New-Object Random 11
1..20000 | ForEach-Object { Add-UiaHistogramValue $wide ([Math]::Pow(10, $wideRandom.NextDouble() * 7 - 2)) }
if ($wide.count -ne 20000 -or $wide.buckets.Count -gt 1700) {
    throw 'Histogram memory must stay bounded by the bucket range, not the number of observations.'
}
$serialized = ConvertTo-Json -Depth 5 $histogram | ConvertFrom-Json
if ($serialized.count -ne $histogram.count) { throw 'The histogram must serialize to JSON.' }

$interval = New-SoakInterval 3 1 1234 1000.0
$intervalLatencies = [ordered]@{}
$runHistograms = [ordered]@{}
$observe = [ordered]@{ snapshot = 50.0; findEdit = 0.2; findButton = 0.3; elementInfo = 1.0 }
$mutate = [ordered]@{ snapshot = 70.0; findEdit = 0.4; findButton = 0.5; elementInfo = 2.0; setValue = 9.0; invoke = 8.0 }
Add-SoakIterationTimes $interval $intervalLatencies $runHistograms $observe
Add-SoakIterationTimes $interval $intervalLatencies $runHistograms $mutate
$interval.completedIterations = 2
$failure = Get-SoakFailure 'Timed out waiting for snapshot.'
Add-SoakFailure $interval $failure
$closed = Complete-SoakInterval $interval $intervalLatencies 3000.0 $null 'interval'
if ($closed.requestsCompleted -ne 10 -or $closed.requestCounts.findElement -ne 4 -or $closed.latencyMs.findElement.count -ne 4 -or
    $closed.latencyMs.snapshot.p99 -ne 70.0 -or $closed.durationSeconds -ne 2.0 -or $closed.iterationsPerSecond -ne 1.0 -or
    $closed.timeouts -ne 1 -or $closed.requestsFailed -ne 1 -or $closed.errorCounts.TIMEOUT -ne 1) {
    throw 'The interval summary is missing request counts, latencies, throughput or failures.'
}
if ($intervalLatencies.Count -ne 0 -or $runHistograms.findEdit.count -ne 2) {
    throw 'A closed interval must release its samples while the run histogram keeps the totals.'
}
$codes = @(
    ,@('Timed out waiting for invoke.', 'TIMEOUT', 'invoke', $true)
    ,@('setValue failed: ACTION_OUTCOME_UNKNOWN', 'ACTION_OUTCOME_UNKNOWN', 'setValue', $true)
    ,@('snapshot failed: ', 'RESPONSE_MISMATCH', 'snapshot', $true)
    ,@('CLI closed before responding to findElement.', 'CLI_CLOSED', 'findElement', $true)
    ,@('The fixture snapshot shape changed.', 'CHECK_FAILED', $null, $false)
)
foreach ($case in $codes) {
    $parsed = Get-SoakFailure $case[0]
    if ($parsed.code -ne $case[1] -or $parsed.operation -ne $case[2] -or $parsed.request -ne $case[3]) {
        throw "Failure '$($case[0])' was classified as $($parsed.code)."
    }
}
$perf = @"
sun.os.hrt.frequency=10000000
sun.gc.collector.0.invocations=12
sun.gc.collector.0.name="G1 young collection pauses"
sun.gc.collector.0.time=50000000
sun.gc.collector.1.invocations=1
sun.gc.collector.1.name="G1 full collection pauses"
sun.gc.collector.1.time=2500000
"@
$gc = ConvertFrom-JvmPerfCounters $perf
if (!$gc.available -or $gc.totalInvocations -ne 13 -or $gc.totalTimeMs -ne 5250.0 -or $gc.collectors[0].name -ne 'G1 young collection pauses') {
    throw 'GC counters were not parsed from PerfCounter.print.'
}
if ((ConvertFrom-JvmPerfCounters 'no counters').available) { throw 'Missing GC counters must be reported as unavailable.' }

$first = @{ elements = @(
    @{ ref = 'first-root'; name = 'Window'; role = 'Window'; automationId = '' }
    @{ ref = 'first-child'; parentRef = 'first-root'; name = 'Open'; role = 'Button'; automationId = 'open' }
) }
$second = @{ elements = @(
    @{ ref = 'different-root'; name = 'Window'; role = 'Window'; automationId = '' }
    @{ ref = 'different-child'; parentRef = 'different-root'; name = 'Open'; role = 'Button'; automationId = 'open' }
) }
$shape = @(Get-TreeShape $first)
Check-TreeShape $second $shape
$second.elements[1].name = 'Other button'
$raised = $false
try { Check-TreeShape $second $shape } catch { $raised = $true }
if (!$raised) { throw 'Tree comparison must detect a changed accessible name.' }

Write-Output 'UIA tool failure reports, progress checkpoints, latency statistics, soak intervals and tree comparison passed.'
