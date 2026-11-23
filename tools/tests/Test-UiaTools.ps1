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

$heapInfo = ConvertFrom-JvmHeapInfo @"
9668:
 garbage-first heap   total 520192K, used 225117K [0x0000000604800000, 0x0000000800000000)
  region size 4096K, 48 young (196608K), 10 survivors (40960K)
 Metaspace       used 8705K, committed 8896K, reserved 1114112K
"@
if ($heapInfo.heapCommittedBytes -ne 520192KB -or $heapInfo.heapUsedBytes -ne 225117KB -or
    $heapInfo.heapRegionBytes -ne 4096KB -or $heapInfo.heapYoungBytes -ne 196608KB -or
    $heapInfo.heapSurvivorBytes -ne 40960KB) {
    throw 'G1 heap totals and young/survivor sizes were not parsed from GC.heap_info.'
}
$serialHeap = ConvertFrom-JvmHeapInfo ' def new generation   total 157248K, used 5602K [0x1, 0x2, 0x3)'
if ($serialHeap.Contains('heapUsedBytes') -or $serialHeap.Contains('heapYoungBytes')) {
    throw 'A heap layout without G1 totals must not produce guessed figures.'
}

$gcLogPattern = 'C:\soak dir\run.gc-%p.log'
if ($env:OS -eq 'Windows_NT' -and (Get-SoakGcLogPattern 'C:\soak dir\run.json') -cne $gcLogPattern) {
    throw 'The GC log must be written next to the report.'
}
if ((Get-SoakGcLogName $gcLogPattern 9668) -cne 'run.gc-9668.log') { throw 'Each JVM must get its own GC log file.' }
if ($null -ne (Get-SoakGcLogPattern '')) { throw 'Without a report path there is no GC log.' }
$javaExe = 'java.exe'
$Jar = 'C:\agent dir\agent.jar'
$fixture = [pscustomobject]@{ Id = 4242 }
$cliTail = '-jar "C:\agent dir\agent.jar" --allow-pid 4242 --allow-action invoke --allow-action setValue --backend jna'
if ((New-CliStartInfo 'JNA' -TrackNativeMemory).Arguments -cne "-XX:NativeMemoryTracking=summary $cliTail") {
    throw 'The CLI arguments without a GC log must stay unchanged.'
}
$gcLogArgument = '"-Xlog:gc*,gc+ref=debug,gc+phases=debug,gc+age=trace,safepoint:file=\"C:\soak dir\run.gc-%p.log\"' +
    ':utctime,uptime,level,tags:filecount=8,filesize=32m"'
if ((New-CliStartInfo 'JNA' -TrackNativeMemory -GcLogPath $gcLogPattern).Arguments -cne
    "-XX:NativeMemoryTracking=summary $gcLogArgument $cliTail") {
    throw 'The GC log option must quote its path and record UTC and uptime decorations.'
}

$UiaSlowRequestMs = 100.0
$UiaSlowRequestLimit = 3
$slowInterval = New-SoakInterval 0 0 1 0.0
$slowLatencies = [ordered]@{}
$slowHistograms = [ordered]@{}
$slowBase = [DateTime]::new(2026, 1, 1, 0, 0, 0, [DateTimeKind]::Utc)
$slowIteration = 0
foreach ($ms in 50.0, 150.0, 300.0, 120.0, 200.0, 110.0) {
    $slowIteration++
    $info = if ($slowIteration -eq 4) { 130.0 } else { 1.0 }
    $times = [ordered]@{ snapshot = $ms; findEdit = 0.2; findButton = 0.3; elementInfo = $info }
    $ends = @{ snapshot = $slowBase.AddSeconds($slowIteration); findEdit = $slowBase.AddSeconds($slowIteration + 0.1)
        findButton = $slowBase.AddSeconds($slowIteration + 0.2); elementInfo = $slowBase.AddSeconds($slowIteration + 0.3) }
    Add-SoakIterationTimes $slowInterval $slowLatencies $slowHistograms $times $ends $slowIteration
}
$slowClosed = Complete-SoakInterval $slowInterval $slowLatencies 6000.0 $null 'interval'
if ($slowClosed.slowRequestCount -ne 6 -or $slowClosed.slowRequestCounts.snapshot -ne 5 -or
    $slowClosed.slowRequestCounts.getElementInfo -ne 1 -or $slowClosed.slowRequests.Count -ne 3) {
    throw 'Every request at or above the threshold must be counted while only the slowest are kept.'
}
$kept = @($slowClosed.slowRequests | ForEach-Object { '{0}/{1}/{2}' -f $_.op, $_.ms, $_.iteration })
if (($kept -join ' ') -cne 'snapshot/150/2 snapshot/300/3 snapshot/200/5' -or
    $slowClosed.slowRequests[1].utc -cne $slowBase.AddSeconds(3).ToString('o')) {
    throw "The slowest requests must be kept in time order with their end time: $($kept -join ' ')"
}
$UiaSlowRequestMs = 0.0
$quietInterval = New-SoakInterval 0 0 1 0.0
Add-SoakIterationTimes $quietInterval ([ordered]@{}) ([ordered]@{}) ([ordered]@{ snapshot = 900.0 }) @{ snapshot = $slowBase } 1
if ($quietInterval.slowRequestCount -ne 0 -or $quietInterval.slowRequests.Count -ne 0) {
    throw 'A zero threshold must disable slow request tracking.'
}
$UiaSlowRequestMs = 100.0

$pointSample = [ordered]@{
    elapsedMs = 5.0
    resources = [ordered]@{ utc = 'u'; java = [ordered]@{ available = $true; pid = 1; startUtc = 's'; cpuMs = 2.0
        privateBytes = 3; workingSetBytes = 4; handles = 5; threads = 6 } }
    heapUsedBytes = 7; heapCommittedBytes = 8; heapRegionBytes = 9; heapYoungBytes = 10; heapSurvivorBytes = 11
    fixture = [ordered]@{ available = $true; cpuMs = 12.0 }
    driver = [ordered]@{ available = $true; cpuMs = 13.0 }
    host = [ordered]@{ available = $true; cpuBusyMs = 14.0 }
}
$point = ConvertTo-SoakResourcePoint $pointSample
if ($point.cpuMs -ne 2.0 -or $point.heapRegionBytes -ne 9 -or $point.heapYoungBytes -ne 10 -or
    $point.heapSurvivorBytes -ne 11 -or $point.fixture.cpuMs -ne 12.0 -or $point.driver.cpuMs -ne 13.0 -or
    $point.host.cpuBusyMs -ne 14.0) {
    throw 'An interval resource point must carry the heap generations and the fixture, driver and host samples.'
}

# A UTF-8 console (code page 65001) must not make the child's stdin begin with a byte order mark:
# the agent rejects a first frame that does not start with its JSON object.
$echoStart = New-Object Diagnostics.ProcessStartInfo
$echoStart.FileName = (Get-Process -Id $PID).Path
$echoStart.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String(
    [Text.Encoding]::Unicode.GetBytes(@'
$buffer = New-Object byte[] 16
$read = [Console]::OpenStandardInput().Read($buffer, 0, 16)
[Console]::Out.WriteLine([BitConverter]::ToString($buffer, 0, $read))
'@))
$echoStart.UseShellExecute = $false
$echoStart.CreateNoWindow = $true
$echoStart.RedirectStandardInput = $true
$echoStart.RedirectStandardOutput = $true
$echoStart.RedirectStandardError = $true
$consoleInput = $null
try {
    $consoleInput = [Console]::InputEncoding
    [Console]::InputEncoding = New-Object Text.UTF8Encoding($true)
} catch { $consoleInput = $null } # no console to configure: nothing to check
if ($consoleInput) {
    try {
        $echoCli = Start-Cli $echoStart
        try {
            $echoCli.StandardInput.BaseStream.Write([byte[]](0x78, 0x0A), 0, 2)
            $echoCli.StandardInput.BaseStream.Flush()
            $firstBytes = $echoCli.StandardOutput.ReadLine()
            if ($firstBytes -cne '78-0A') { throw "The child's stdin must start with the first request, not $firstBytes." }
            if ([Console]::InputEncoding.GetPreamble().Length -ne 3) { throw 'The console input encoding must be restored.' }
        } finally { Stop-Cli $echoCli 'JNA' }
    } finally { [Console]::InputEncoding = $consoleInput }
}

# A scripted agent stands in for the CLI so request timing is exercised without a desktop.
$fakeAgent = @'
$reader = New-Object IO.StreamReader([Console]::OpenStandardInput(), (New-Object Text.UTF8Encoding($false)))
$writer = New-Object IO.StreamWriter([Console]::OpenStandardOutput(), (New-Object Text.UTF8Encoding($false)))
while ($null -ne ($line = $reader.ReadLine())) {
    $request = $line | ConvertFrom-Json
    $result = @{}
    if ($request.op -eq 'snapshot') {
        if ($request.windowId -eq 'slow') { Start-Sleep -Milliseconds 150 }
        $result = @{ snapshotId = 's1'; windowId = $request.windowId; truncated = $false; elements = @(
            @{ ref = 'w'; role = 'Window'; automationId = ''; name = 'Window'; processId = 4242 }
            @{ ref = 'e'; parentRef = 'w'; role = 'Edit'; automationId = 'fixtureEdit'; name = ''; processId = 4242 }
            @{ ref = 'b'; parentRef = 'w'; role = 'Button'; automationId = 'fixtureIncrement'; name = 'Add'; processId = 4242 }) }
    } elseif ($request.op -eq 'findElement') {
        $result = @{ ref = $(if ($request.locator.role -eq 'Edit') { 'e' } else { 'b' }) }
    } elseif ($request.op -eq 'getElementInfo') {
        $result = @{ processId = 4242; automationId = 'fixtureEdit' }
    }
    $writer.WriteLine((ConvertTo-Json -Compress -Depth 6 @{ ok = $true; id = $request.id; result = $result }))
    $writer.Flush()
}
'@
$fakeStart = New-Object Diagnostics.ProcessStartInfo
$fakeStart.FileName = (Get-Process -Id $PID).Path
$fakeStart.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' +
    [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($fakeAgent))
$fakeStart.UseShellExecute = $false
$fakeStart.CreateNoWindow = $true
$fakeStart.RedirectStandardInput = $true
$fakeStart.RedirectStandardOutput = $true
$fakeStart.RedirectStandardError = $true
$fakeStart.StandardOutputEncoding = [Text.Encoding]::UTF8
$fakeCli = Start-Cli $fakeStart
try {
    $before = [DateTime]::UtcNow
    $reply = Request $fakeCli @{ op = 'getElementInfo'; ref = 'e' }
    if ($reply.endUtc -isnot [DateTime] -or $reply.endUtc -lt $before -or $reply.endUtc -gt [DateTime]::UtcNow) {
        throw 'A reply must carry the wall-clock time at which it arrived.'
    }
    $requestEnds = @{}
    $started = [DateTime]::UtcNow
    $slowTimes = Run-Iteration $fakeCli 'slow' 3 'unused' @() -ObserveOnly -RequestEnds $requestEnds
    $finished = [DateTime]::UtcNow
    if ($slowTimes.snapshot -lt 140 -or $requestEnds.Count -ne 4 -or
        $requestEnds.snapshot -lt $started.AddMilliseconds(100) -or $requestEnds.snapshot -gt $requestEnds.findEdit -or
        $requestEnds.findEdit -gt $requestEnds.findButton -or $requestEnds.findButton -gt $requestEnds.elementInfo -or
        $requestEnds.elementInfo -gt $finished) {
        throw 'An iteration must report when each of its requests completed.'
    }
    $tracked = New-SoakInterval 0 0 1 0.0
    Add-SoakIterationTimes $tracked ([ordered]@{}) ([ordered]@{}) $slowTimes $requestEnds 7
    if ($tracked.slowRequestCount -ne 1 -or $tracked.slowRequests[0].op -cne 'snapshot' -or
        $tracked.slowRequests[0].iteration -ne 7 -or $tracked.slowRequests[0].ms -ne $slowTimes.snapshot -or
        $tracked.slowRequests[0].utc -cne $requestEnds.snapshot.ToString('o')) {
        throw 'A delayed snapshot must be recorded as a slow request with its completion time.'
    }
    if ((Run-Iteration $fakeCli 'fast' 3 'unused' @() -ObserveOnly).snapshot -le 0) {
        throw 'An iteration without a completion-time collector must still return its latencies.'
    }
} finally { Stop-Cli $fakeCli 'JNA' }

if ($env:OS -eq 'Windows_NT') {
    if (!(Initialize-UiaHostProbe)) { throw 'The host probe must load on Windows.' }
    $between = [Diagnostics.Stopwatch]::StartNew()
    $hostBefore = Get-UiaHostSample 0 3 @()
    $spin = [Diagnostics.Stopwatch]::StartNew()
    while ($spin.ElapsedMilliseconds -lt 400) { }
    $betweenMs = $between.ElapsedMilliseconds
    $hostAfter = Get-UiaHostSample 0 3 @()
    if (!$hostBefore.available -or !$hostAfter.available) { throw "The host sample is unavailable: $($hostAfter.error)" }
    $capacity = ($hostAfter.cpuBusyMs + $hostAfter.cpuIdleMs) - ($hostBefore.cpuBusyMs + $hostBefore.cpuIdleMs)
    $expected = $betweenMs * [Environment]::ProcessorCount
    if ($capacity -lt 0.5 * $expected -or $capacity -gt 2.0 * $expected -or
        $hostAfter.cpuBusyMs - $hostBefore.cpuBusyMs -lt 200) {
        throw "Host CPU time must advance by the elapsed time of every logical processor: $capacity of $expected ms."
    }
    if ($hostAfter.userIdleMs -lt 0 -or $hostAfter.availableMemoryBytes -le 0 -or !$hostAfter.Contains('acPower') -or
        ($null -ne $hostAfter.acPower -and $hostAfter.acPower -isnot [bool]) -or $hostAfter.fixtureForeground -or
        $hostAfter.fixtureMinimized) {
        throw 'The host sample must report user idle time, free memory, the power source and the fixture window state.'
    }
    if ($hostAfter.Contains('processorPerformanceBase') -and
        $hostAfter.processorPerformanceBase -le $hostBefore.processorPerformanceBase) {
        throw 'The processor performance counter must be cumulative.'
    }
    $busiest = @($hostAfter.topProcesses)
    $self = @($busiest | Where-Object { $_.pid -eq $PID })
    if ($busiest.Count -gt 3 -or $self.Count -ne 1 -or $self[0].cpuMs -lt 200 -or !$self[0].name -or
        @($busiest | Where-Object { $_.pid -eq 0 }).Count) {
        throw 'The busiest processes since the previous sample must include this spinning test, not the idle process.'
    }
    $spin.Restart()
    while ($spin.ElapsedMilliseconds -lt 200) { }
    if (@((Get-UiaHostSample 0 3 @($PID)).topProcesses | Where-Object { $_.pid -eq $PID }).Count) {
        throw 'Processes that the soak reports separately must be left out of the busiest list.'
    }
    if ((Get-UiaHostSample 0 0 @()).Contains('topProcesses')) {
        throw 'Process names must not be recorded unless a count was requested.'
    }
    $environment = Get-UiaEnvironment
    if (!$environment.cpu -or $environment.cpuNominalMhz -le 0) { throw 'The environment must name the processor.' }
    $hostInfo = [ordered]@{}
    Set-UiaHostInfo $hostInfo
    if ($hostInfo.memoryBytes -le 0 -or $hostInfo.power.scheme -notmatch '^[0-9a-f]{8}-') {
        throw 'The environment must record installed memory and the active power scheme.'
    }
}
if (Get-Command git -ErrorAction SilentlyContinue) {
    $git = Get-UiaGitInfo
    if ($git.commit -notmatch '^[0-9a-f]{40}$' -or $git.dirty -isnot [bool]) {
        throw 'The report must identify the source commit and whether the tree was modified.'
    }
}

Write-Output 'UIA tool failure reports, progress checkpoints, latency statistics, soak intervals, slow requests, heap generations, GC log options, host sampling and tree comparison passed.'
