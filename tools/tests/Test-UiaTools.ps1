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

Write-Output 'UIA tool failure reports, progress checkpoints, latency statistics and tree comparison passed.'
