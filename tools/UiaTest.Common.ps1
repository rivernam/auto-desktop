# Shared only by the local Windows UIA benchmark and soak scripts.
function Get-UiaEnvironment {
    [ordered]@{
        os = [Environment]::OSVersion.VersionString
        is64BitOS = [Environment]::Is64BitOperatingSystem
        interactive = [Environment]::UserInteractive
        powerShell = $PSVersionTable.PSVersion.ToString()
        processorCount = [Environment]::ProcessorCount
    }
}

function Initialize-UiaTools {
    if ($env:OS -ne 'Windows_NT' -or ![Environment]::UserInteractive) {
        throw 'An interactive Windows test desktop is required.'
    }
    $script:Jar = (Get-Item -LiteralPath $Jar).FullName
    $script:javaExe = (Get-Command java.exe -CommandType Application | Select-Object -First 1).Source
    $script:fixtureScript = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../src/test/resources/windows-gui-fixture.ps1')).Path
    $script:fixtureExe = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $script:stateDir = Join-Path ([IO.Path]::GetTempPath()) ('uia-test-' + [guid]::NewGuid())
    [void][IO.Directory]::CreateDirectory($stateDir)
    $script:title = 'UIA fixture ' + [guid]::NewGuid()
}

function Read-Diagnostic([string]$executable, [string]$arguments, [long]$timeoutMs = 10000) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $executable
    $start.Arguments = $arguments
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $diagnostic = [Diagnostics.Process]::Start($start)
    try {
        $output = $diagnostic.StandardOutput.ReadToEndAsync()
        $errors = $diagnostic.StandardError.ReadToEndAsync()
        if (!$diagnostic.WaitForExit([int]$timeoutMs)) {
            $diagnostic.Kill()
            [void]$diagnostic.WaitForExit(5000)
            throw "Diagnostic '$arguments' timed out."
        }
        if (!$output.Wait(2000) -or !$errors.Wait(2000)) { throw "Diagnostic '$arguments' did not close its streams." }
        return [ordered]@{ exitCode = $diagnostic.ExitCode; stdout = $output.Result.Trim(); stderr = $errors.Result.Trim() }
    } finally { $diagnostic.Dispose() }
}

function Set-UiaBuildInfo($environment, [string]$worker) {
    $version = Read-Diagnostic $javaExe '-version'
    if ($version.exitCode -ne 0) { throw 'Cannot read the Java runtime version.' }
    $environment.java = ($version.stdout + "`n" + $version.stderr).Trim()
    $environment.jarSha256 = (Get-FileHash -LiteralPath $Jar -Algorithm SHA256).Hash
    $environment.fixtureSha256 = (Get-FileHash -LiteralPath $fixtureScript -Algorithm SHA256).Hash
    if ($worker) { $environment.csharpWorkerSha256 = (Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash }
}

function Start-UiaFixture([bool]$borderless) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $fixtureExe
    $start.Arguments = "-NoProfile -NonInteractive -STA -ExecutionPolicy RemoteSigned -File `"$fixtureScript`" `"$stateDir`" `"$title`""
    if ($borderless) { $start.Arguments += ' -Borderless' }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $script:fixture = [Diagnostics.Process]::Start($start)
    $script:fixtureOutput = $fixture.StandardOutput.ReadToEndAsync()
    $script:fixtureErrors = $fixture.StandardError.ReadToEndAsync()
    Wait-State 'ready' ([string]$fixture.Id)
}

function Stop-UiaFixture($report) {
    if ($fixture) {
        try {
            if (!$fixture.HasExited) {
                [IO.File]::WriteAllText((Join-Path $stateDir 'close-fixture'), '')
                if (!$fixture.WaitForExit(5000)) {
                    $fixture.Kill()
                    if (!$fixture.WaitForExit(5000)) { throw 'WPF fixture did not exit after termination.' }
                    throw 'WPF fixture did not close after the close marker.'
                }
            }
            if ($fixture.ExitCode -ne 0) { throw "WPF fixture exited with status $($fixture.ExitCode)." }
        } finally {
            try {
                $report.fixture = [ordered]@{}
                if ($fixture.HasExited) { $report.fixture.exitCode = $fixture.ExitCode }
                foreach ($stream in @{ stdout = $fixtureOutput; stderr = $fixtureErrors }.GetEnumerator()) {
                    if (!$stream.Value) { continue }
                    if (!$stream.Value.Wait(3000)) { throw "Fixture $($stream.Key) did not close." }
                    $contents = $stream.Value.Result
                    $report.fixture[$stream.Key] = $contents.Substring([Math]::Max(0, $contents.Length - 8192))
                }
            } finally { $fixture.Dispose() }
        }
    }
}

function Remove-UiaState {
    if ($stateDir -and [IO.Directory]::Exists($stateDir)) {
        foreach ($file in [IO.Directory]::GetFiles($stateDir)) { [IO.File]::Delete($file) }
        [IO.Directory]::Delete($stateDir)
    }
}

function Save-UiaJson([string]$json, [string]$path) {
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($path)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fullPath))
    $pending = "$fullPath.$([Guid]::NewGuid().ToString('N')).pending"
    try {
        # Flush the complete document to disk before it replaces the last good checkpoint.
        $bytes = (New-Object Text.UTF8Encoding($false)).GetBytes($json)
        $stream = New-Object IO.FileStream($pending, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write,
            [IO.FileShare]::None, 65536, [IO.FileOptions]::WriteThrough)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        for ($attempt = 0; ; $attempt++) {
            try {
                if ([IO.File]::Exists($fullPath)) { [IO.File]::Replace($pending, $fullPath, [NullString]::Value) }
                else { [IO.File]::Move($pending, $fullPath) }
                return
            } catch [IO.IOException] {
                $failure = $_.Exception
                while ($failure.InnerException) { $failure = $failure.InnerException }
                # A viewer can briefly hold a read handle that denies replacement.
                if ($attempt -ge 4 -or ($failure.HResult -band 0xffff) -notin 32, 33) { throw }
                Start-Sleep -Milliseconds 75
            }
        }
    } finally { [IO.File]::Delete($pending) }
}

function Write-UiaReport($report, [string]$path) {
    $json = ConvertTo-Json -InputObject $report -Depth 20
    if ($path) {
        try { Save-UiaJson $json $path }
        catch {
            $report.reportWriteError = $_.Exception.Message
            $json = ConvertTo-Json -InputObject $report -Depth 20
        }
    }
    return $json
}

function Save-UiaCheckpoint($report, [string]$path) {
    if (!$path) { return }
    $report.checkpointUtc = [DateTime]::UtcNow.ToString('o')
    try { Save-UiaJson (ConvertTo-Json -InputObject $report -Depth 20) $path }
    catch { $report.checkpointWriteError = $_.Exception.Message }
}

function Read-State([string]$file) {
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open((Join-Path $stateDir $file), [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    try {
        $reader = New-Object IO.StreamReader($stream)
        try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
    } finally { $stream.Dispose() }
}

function Wait-State($file, $value) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($fixture.HasExited) { throw "Fixture exited unexpectedly with status $($fixture.ExitCode)." }
        $actual = $null
        try { $actual = Read-State $file } catch [IO.IOException] {}
        if ($actual -ceq $value) { return }
        Start-Sleep -Milliseconds 25
    } while ($clock.Elapsed.TotalSeconds -lt 20)
    throw "Fixture did not report expected $file."
}

function New-CliStartInfo([string]$backend, [switch]$TrackNativeMemory) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $javaExe
    if ($TrackNativeMemory) { $start.Arguments = '-XX:NativeMemoryTracking=summary ' }
    $start.Arguments += "-jar `"$Jar`" --allow-pid $($fixture.Id) --allow-action invoke --allow-action setValue"
    switch ($backend) {
        'PowerShell' { $start.Arguments += ' --backend powershell' }
        'CSharp' { $start.Arguments += " --csharp-worker `"$CSharpWorker`"" }
        'JNA' { $start.Arguments += ' --backend jna' }
        default { throw "Unknown backend $backend." }
    }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    return $start
}

function Start-Cli($start) {
    $cli = [Diagnostics.Process]::Start($start)
    $cli.BeginErrorReadLine() # Drain per-request audit output without accumulating it.
    return $cli
}

function Request($cli, $command) {
    $command.id = [guid]::NewGuid().ToString()
    $line = ConvertTo-Json -Compress -Depth 5 $command
    $frame = [Text.Encoding]::UTF8.GetBytes($line + "`n")
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $cli.StandardInput.BaseStream.Write($frame, 0, $frame.Length)
    $cli.StandardInput.BaseStream.Flush()
    $next = $cli.StandardOutput.ReadLineAsync()
    if (!$next.Wait(30000)) { throw "Timed out waiting for $($command.op)." }
    $clock.Stop()
    if ($null -eq $next.Result) { throw "CLI closed before responding to $($command.op)." }
    $reply = $next.Result | ConvertFrom-Json
    if (!$reply.ok -or $reply.id -ne $command.id) { throw "$($command.op) failed: $($reply.error.code)" }
    return @{ ms = $clock.Elapsed.TotalMilliseconds; result = $reply.result }
}

function Worker-Process($cli, [string]$backend) {
    if ($backend -eq 'JNA') { return $null }
    $exe = if ($backend -eq 'PowerShell') { 'powershell.exe' } else { [IO.Path]::GetFileName($CSharpWorker) }
    try {
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($cli.Id)" |
            Where-Object { $_.Name -ieq $exe })
        if ($children.Count -eq 1) { return Get-Process -Id $children[0].ProcessId -ErrorAction Stop }
    } catch {}
    return $null
}

function Process-Sample($process) {
    if (!$process) { return @{ available = $false } }
    try {
        $process.Refresh()
        if ($process.HasExited) { return @{ available = $false } }
        return [ordered]@{ available = $true; pid = $process.Id; startUtc = $process.StartTime.ToUniversalTime().ToString('o')
            cpuMs = $process.TotalProcessorTime.TotalMilliseconds; privateBytes = $process.PrivateMemorySize64
            workingSetBytes = $process.WorkingSet64; handles = $process.HandleCount; threads = $process.Threads.Count }
    } catch { return @{ available = $false } }
}

function Resources($cli, $backend) {
    $worker = Worker-Process $cli $backend
    try {
        $java = Process-Sample $cli
        $nativeWorker = Process-Sample $worker
        $total = @{ available = $false }
        if ($java.available -and ($backend -eq 'JNA' -or $nativeWorker.available)) {
            $total = [ordered]@{ available = $true }
            foreach ($field in 'cpuMs', 'privateBytes', 'workingSetBytes', 'handles', 'threads') {
                $total[$field] = $java[$field] + $nativeWorker[$field]
            }
        }
        return [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); java = $java; worker = $nativeWorker; total = $total }
    } finally { if ($worker) { $worker.Dispose() } }
}

function Stop-Cli($cli, $backend) {
    if (!$cli) { return }
    try {
        if (!$cli.HasExited) { $cli.StandardInput.Close() }
        if (!$cli.WaitForExit(15000)) {
            $worker = Worker-Process $cli $backend
            try {
                if ($worker -and !$worker.HasExited) {
                    $worker.Kill()
                    [void]$worker.WaitForExit(5000)
                }
            } finally { if ($worker) { $worker.Dispose() } }
            $cli.Kill()
            [void]$cli.WaitForExit(5000)
            throw 'The CLI did not shut down after EOF.'
        }
        if ($cli.ExitCode -ne 0) { throw "The CLI exited with status $($cli.ExitCode)." }
    } finally { $cli.Dispose() }
}

function Check-Snapshot($snapshot, $windowId, [int]$expectedCount) {
    $rows = @($snapshot.elements)
    if ($snapshot.truncated -or $snapshot.windowId -cne $windowId -or $rows.Count -lt 1 -or
        ($expectedCount -gt 0 -and $rows.Count -ne $expectedCount)) {
        throw 'The fixture snapshot was incomplete or its size changed.'
    }
    foreach ($id in 'fixtureEdit', 'fixtureIncrement') {
        if (@($rows | Where-Object { $_.automationId -ceq $id -and $_.processId -eq $fixture.Id }).Count -ne 1) {
            throw "Missing or ambiguous fixture element $id."
        }
    }
    return $rows.Count
}

function Get-TreeShape($snapshot) {
    $paths = @{}
    [string[]]$shape = @(foreach ($node in $snapshot.elements) {
        $identity = ConvertTo-Json -Compress -InputObject @($node.role, $node.automationId, $node.name)
        $path = $identity
        if ($node.parentRef) {
            if (!$paths.ContainsKey($node.parentRef)) { throw 'Snapshot nodes are not in parent-before-child order.' }
            $path = $paths[$node.parentRef] + '/' + $identity
        }
        $paths.Add($node.ref, $path)
        $path
    })
    [Array]::Sort($shape, [StringComparer]::Ordinal)
    return $shape
}

function Check-TreeShape($snapshot, [string[]]$expectedShape) {
    if ($expectedShape.Count -gt 0 -and ((Get-TreeShape $snapshot) -join "`n") -cne ($expectedShape -join "`n")) {
        throw 'The fixture snapshot shape changed.'
    }
}

function Check-Window($windows) {
    $matches = @($windows | Where-Object { $_.processId -eq $fixture.Id -and $_.name -ceq $title })
    if ($matches.Count -ne 1) { throw 'Cannot uniquely identify the temporary WPF window.' }
    return $matches[0].windowId
}

function Take-Snapshot($cli, $windowId) {
    return Request $cli @{ op = 'snapshot'; windowId = $windowId; maxDepth = 16; maxElements = 200 }
}

function Run-Iteration($cli, $windowId, $expectedCount, $token, [string[]]$expectedShape, [switch]$ObserveOnly) {
    $snap = Take-Snapshot $cli $windowId
    [void](Check-Snapshot $snap.result $windowId $expectedCount)
    Check-TreeShape $snap.result $expectedShape
    $edit = Request $cli @{ op = 'findElement'; snapshotId = $snap.result.snapshotId
        locator = @{ automationId = 'fixtureEdit'; role = 'Edit' } }
    $button = Request $cli @{ op = 'findElement'; snapshotId = $snap.result.snapshotId
        locator = @{ automationId = 'fixtureIncrement'; role = 'Button' } }
    $info = Request $cli @{ op = 'getElementInfo'; ref = $edit.result.ref }
    if ($info.result.processId -ne $fixture.Id -or $info.result.automationId -cne 'fixtureEdit') {
        throw 'Live element information did not identify the fixture editor.'
    }
    $times = [ordered]@{ snapshot = $snap.ms; findEdit = $edit.ms; findButton = $button.ms; elementInfo = $info.ms }
    if (!$ObserveOnly) {
        $set = Request $cli @{ op = 'setValue'; ref = $edit.result.ref; value = $token }
        if ($set.result.performed -isnot [bool] -or !$set.result.performed) {
            throw 'SetValue did not confirm the action.'
        }
        Wait-State 'value.txt' $token
        $previous = [int](Read-State 'count.txt')
        $invoke = Request $cli @{ op = 'invoke'; ref = $button.result.ref }
        if ($invoke.result.performed -isnot [bool] -or !$invoke.result.performed) {
            throw 'Invoke did not confirm the action.'
        }
        Wait-State 'count.txt' ([string]($previous + 1))
        $times.setValue = $set.ms
        $times.invoke = $invoke.ms
    }
    return $times
}

function Add-UiaLatencies($latencies, $times) {
    foreach ($name in $times.Keys) {
        if (!$latencies.Contains($name)) { $latencies[$name] = New-Object 'Collections.Generic.List[double]' }
        $latencies[$name].Add($times[$name])
    }
}

function Get-UiaLatencySummary($latencies) {
    $result = [ordered]@{}
    foreach ($name in $latencies.Keys) {
        $values = $latencies[$name]
        $values.Sort()
        $total = 0.0
        foreach ($value in $values) { $total += $value }
        $result[$name] = [ordered]@{
            count = $values.Count; mean = $total / $values.Count; max = $values[$values.Count - 1]
            p50 = $values[[int][Math]::Ceiling($values.Count * 0.50) - 1]
            p95 = $values[[int][Math]::Ceiling($values.Count * 0.95) - 1]
            p99 = $values[[int][Math]::Ceiling($values.Count * 0.99) - 1]
        }
    }
    return $result
}

# Long-run latency statistics without retaining every observation. Buckets have 1% relative
# width; count, mean, min and max stay exact and quantiles are bucket upper bounds capped at max.
$script:UiaHistogramFloorMs = 0.001
$script:UiaHistogramRatio = 1.01
$script:UiaLatencyOperation = @{
    snapshot = 'snapshot'; findEdit = 'findElement'; findButton = 'findElement'
    elementInfo = 'getElementInfo'; setValue = 'setValue'; invoke = 'invoke'
}

function New-UiaLatencyHistogram {
    return [ordered]@{ count = [long]0; sum = 0.0; min = $null; max = $null; buckets = @{} }
}

function Add-UiaHistogramValue($histogram, [double]$value) {
    $index = 0
    if ($value -gt $UiaHistogramFloorMs) {
        $index = [int][Math]::Ceiling([Math]::Log($value / $UiaHistogramFloorMs) / [Math]::Log($UiaHistogramRatio))
    }
    $key = [string]$index
    if ($histogram.buckets.ContainsKey($key)) { $histogram.buckets[$key]++ } else { $histogram.buckets[$key] = [long]1 }
    $histogram.count++
    $histogram.sum += $value
    if ($null -eq $histogram.min -or $value -lt $histogram.min) { $histogram.min = $value }
    if ($null -eq $histogram.max -or $value -gt $histogram.max) { $histogram.max = $value }
}

function Merge-UiaHistogram($target, $source) {
    foreach ($key in $source.buckets.Keys) {
        if ($target.buckets.ContainsKey($key)) { $target.buckets[$key] += $source.buckets[$key] }
        else { $target.buckets[$key] = [long]$source.buckets[$key] }
    }
    $target.count += $source.count
    $target.sum += $source.sum
    if ($null -ne $source.min -and ($null -eq $target.min -or $source.min -lt $target.min)) { $target.min = $source.min }
    if ($null -ne $source.max -and ($null -eq $target.max -or $source.max -gt $target.max)) { $target.max = $source.max }
}

function Get-UiaHistogramSummary($histogram) {
    if (!$histogram.count) { return $null }
    [int[]]$indexes = @($histogram.buckets.Keys | ForEach-Object { [int]$_ })
    [Array]::Sort($indexes)
    $result = [ordered]@{ count = $histogram.count; mean = $histogram.sum / $histogram.count; max = $histogram.max }
    foreach ($quantile in @(@('p50', 0.50), @('p95', 0.95), @('p99', 0.99))) {
        $rank = [long][Math]::Ceiling($histogram.count * $quantile[1])
        $seen = [long]0
        foreach ($index in $indexes) {
            $seen += $histogram.buckets[[string]$index]
            if ($seen -ge $rank) {
                $upper = $UiaHistogramFloorMs * [Math]::Pow($UiaHistogramRatio, $index)
                $result[$quantile[0]] = [Math]::Max($histogram.min, [Math]::Min($upper, $histogram.max))
                break
            }
        }
    }
    return $result
}

function Get-UiaOperationHistograms($histograms) {
    $operations = [ordered]@{}
    foreach ($name in $histograms.Keys) {
        $operation = $UiaLatencyOperation[$name]
        if (!$operation) { $operation = $name }
        if (!$operations.Contains($operation)) { $operations[$operation] = New-UiaLatencyHistogram }
        Merge-UiaHistogram $operations[$operation] $histograms[$name]
    }
    return $operations
}

function Get-UiaHistogramReport($histograms) {
    $report = [ordered]@{}
    foreach ($name in $histograms.Keys) { $report[$name] = Get-UiaHistogramSummary $histograms[$name] }
    return $report
}

# One aggregation window of a soak run. Raw latencies are kept outside the record and released
# when the window closes, so only fixed-size summaries accumulate over long runs.
function New-SoakInterval([int]$index, [int]$sessionIndex, $processId, [double]$startElapsedMs) {
    return [ordered]@{
        index = $index; sessionIndex = $sessionIndex; pid = $processId
        startUtc = [DateTime]::UtcNow.ToString('o'); startElapsedMs = $startElapsedMs
        attemptedIterations = 0; completedIterations = 0; failedIterations = 0; mutationIterations = 0
        requestsCompleted = 0; requestsFailed = 0; timeouts = 0
        requestCounts = [ordered]@{}; errorCounts = [ordered]@{}
        events = New-Object 'Collections.Generic.List[object]'
    }
}

function Add-SoakIterationTimes($interval, $intervalLatencies, $histograms, $times) {
    foreach ($name in $times.Keys) {
        $value = [double]$times[$name]
        $operation = $UiaLatencyOperation[$name]
        if (!$operation) { $operation = $name }
        if (!$intervalLatencies.Contains($operation)) {
            $intervalLatencies[$operation] = New-Object 'Collections.Generic.List[double]'
        }
        $intervalLatencies[$operation].Add($value)
        if (!$histograms.Contains($name)) { $histograms[$name] = New-UiaLatencyHistogram }
        Add-UiaHistogramValue $histograms[$name] $value
        if ($interval.requestCounts.Contains($operation)) { $interval.requestCounts[$operation]++ }
        else { $interval.requestCounts[$operation] = 1 }
        $interval.requestsCompleted++
    }
}

function Get-SoakFailure([string]$message) {
    if ($message -match '^Timed out waiting for (\w+)') {
        return [ordered]@{ code = 'TIMEOUT'; operation = $Matches[1]; request = $true }
    }
    if ($message -match '^CLI closed before responding to (\w+)') {
        return [ordered]@{ code = 'CLI_CLOSED'; operation = $Matches[1]; request = $true }
    }
    if ($message -match '^(\w+) failed: ?(\S*)') {
        $code = if ($Matches[2]) { $Matches[2] } else { 'RESPONSE_MISMATCH' }
        return [ordered]@{ code = $code; operation = $Matches[1]; request = $true }
    }
    return [ordered]@{ code = 'CHECK_FAILED'; operation = $null; request = $false }
}

function Add-SoakFailure($interval, $failure) {
    $interval.failedIterations++
    if ($failure.request) { $interval.requestsFailed++ }
    if ($failure.code -eq 'TIMEOUT') { $interval.timeouts++ }
    if ($interval.errorCounts.Contains($failure.code)) { $interval.errorCounts[$failure.code]++ }
    else { $interval.errorCounts[$failure.code] = 1 }
    if ($interval.events.Count -lt 20) { $interval.events.Add($failure) }
}

function ConvertTo-SoakResourcePoint($sample) {
    if (!$sample) { return $null }
    $resources = if ($sample.Contains('resources')) { $sample.resources } else { $sample }
    $point = [ordered]@{ utc = $resources.utc; available = [bool]$resources.java.available }
    if ($sample.Contains('elapsedMs')) { $point.elapsedMs = $sample.elapsedMs }
    if ($resources.java.available) {
        foreach ($field in 'pid', 'startUtc', 'cpuMs', 'privateBytes', 'workingSetBytes', 'handles', 'threads') {
            $point[$field] = $resources.java[$field]
        }
    }
    foreach ($field in 'heapUsedBytes', 'heapCommittedBytes', 'nmtReservedBytes', 'nmtCommittedBytes', 'gc') {
        if ($sample.Contains($field)) { $point[$field] = $sample[$field] }
    }
    return $point
}

function Complete-SoakInterval($interval, $intervalLatencies, [double]$endElapsedMs, $resourceSample, [string]$closedBy) {
    $interval.endUtc = [DateTime]::UtcNow.ToString('o')
    $interval.endElapsedMs = $endElapsedMs
    $interval.durationSeconds = [Math]::Max(0.0, ($endElapsedMs - $interval.startElapsedMs) / 1000)
    $interval.closedBy = $closedBy
    if ($interval.durationSeconds -gt 0) {
        $interval.iterationsPerSecond = $interval.completedIterations / $interval.durationSeconds
        $interval.requestsPerSecond = $interval.requestsCompleted / $interval.durationSeconds
    }
    $interval.latencyMs = if ($intervalLatencies -and $intervalLatencies.Count) { Get-UiaLatencySummary $intervalLatencies }
                          else { [ordered]@{} }
    $interval.resources = ConvertTo-SoakResourcePoint $resourceSample
    if ($intervalLatencies) { $intervalLatencies.Clear() }
    return $interval
}

# HotSpot jvmstat counters; collector time is reported in high-resolution ticks.
function ConvertFrom-JvmPerfCounters([string]$text) {
    $frequency = [regex]::Match($text, '(?m)^sun\.os\.hrt\.frequency=(\d+)')
    $collectors = [ordered]@{}
    foreach ($match in [regex]::Matches($text, '(?m)^sun\.gc\.collector\.(\d+)\.(name|invocations|time)=(.+?)\s*$')) {
        $id = $match.Groups[1].Value
        if (!$collectors.Contains($id)) { $collectors[$id] = [ordered]@{ id = [int]$id } }
        $collectors[$id][$match.Groups[2].Value] = $match.Groups[3].Value.Trim('"')
    }
    if (!$frequency.Success -or !$collectors.Count) { return [ordered]@{ available = $false } }
    $ticksPerMs = [double]$frequency.Groups[1].Value / 1000
    $result = [ordered]@{ available = $true; totalInvocations = [long]0; totalTimeMs = 0.0
        collectors = New-Object 'Collections.Generic.List[object]' }
    foreach ($collector in $collectors.Values) {
        $entry = [ordered]@{ name = $collector.name; invocations = [long]$collector.invocations
            timeMs = [double]$collector.time / $ticksPerMs }
        $result.totalInvocations += $entry.invocations
        $result.totalTimeMs += $entry.timeMs
        $result.collectors.Add($entry)
    }
    return $result
}
