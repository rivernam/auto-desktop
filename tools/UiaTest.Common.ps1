# Shared only by the local Windows UIA benchmark and soak scripts.
function Get-UiaEnvironment {
    $environment = [ordered]@{
        os = [Environment]::OSVersion.VersionString
        is64BitOS = [Environment]::Is64BitOperatingSystem
        interactive = [Environment]::UserInteractive
        powerShell = $PSVersionTable.PSVersion.ToString()
        processorCount = [Environment]::ProcessorCount
    }
    if ($env:OS -eq 'Windows_NT') {
        # The registry answers without the delay of a WMI query; this runs before every report.
        try {
            $processor = Get-ItemProperty -LiteralPath 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -Name 'ProcessorNameString', '~MHz' -ErrorAction Stop
            $environment.cpu = ([string]$processor.ProcessorNameString).Trim()
            $environment.cpuNominalMhz = [int]$processor.'~MHz'
        } catch {}
    }
    return $environment
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

function Read-Diagnostic([string]$executable, [string]$arguments, [long]$timeoutMs = 10000, [switch]$Utf8) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $executable
    $start.Arguments = $arguments
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    if ($Utf8) {
        $start.StandardOutputEncoding = [Text.Encoding]::UTF8
        $start.StandardErrorEncoding = [Text.Encoding]::UTF8
    }
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
    # The commit identifies these scripts and the fixture; the JAR is identified by its hash.
    $git = Get-UiaGitInfo
    if ($git) { $environment.gitCommit = $git.commit; $environment.gitDirty = $git.dirty }
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

function Wait-State($file, $value, [int]$timeoutMs = 20000) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($fixture.HasExited) { throw "Fixture exited unexpectedly with status $($fixture.ExitCode)." }
        $actual = $null
        try { $actual = Read-State $file } catch [IO.IOException] {}
        if ($actual -ceq $value) { return }
        Start-Sleep -Milliseconds 25
    } while ($clock.Elapsed.TotalMilliseconds -lt $timeoutMs)
    throw "Fixture did not report expected $file."
}

# One GC log per JVM next to the report. The JVM expands %p to its process ID.
function Get-SoakGcLogPattern([string]$reportPath) {
    if (!$reportPath) { return $null }
    $fullPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($reportPath)
    return [IO.Path]::Combine([IO.Path]::GetDirectoryName($fullPath),
        [IO.Path]::GetFileNameWithoutExtension($fullPath) + '.gc-%p.log')
}

function Get-SoakGcLogName([string]$pattern, [int]$processId) {
    return [IO.Path]::GetFileName($pattern).Replace('%p', [string]$processId)
}

# "-JvmOptions '-XX:+UseSerialGC -Xms16m'" and the array form both give one token per option.
# powershell -File passes a comma-separated list as a single string, so commas separate options too.
function ConvertTo-UiaJvmOptions([string[]]$options) {
    return @($options | Where-Object { $_ } | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ })
}

function New-CliStartInfo([string]$backend, [switch]$TrackNativeMemory, [string]$GcLogPath, [string[]]$JvmOptions, [switch]$WithoutPid,
                          [string]$ExtraArguments) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $javaExe
    if ($TrackNativeMemory) { $start.Arguments = '-XX:NativeMemoryTracking=summary ' }
    if ($GcLogPath) {
        # Unified logging splits its option on ':' and ',', so the path is quoted inside the quoted argument.
        $start.Arguments += '"-Xlog:gc*,gc+ref=debug,gc+phases=debug,gc+age=trace,safepoint:file=\"' + $GcLogPath +
            '\":utctime,uptime,level,tags:filecount=8,filesize=32m" '
    }
    foreach ($option in $JvmOptions) {
        # One unquoted token each, so an option cannot add an argument or replace the JAR.
        if ($option -cnotmatch '^-[A-Za-z0-9:+=._-]+$') { throw "Unsupported JVM option '$option'." }
        $start.Arguments += "$option "
    }
    $start.Arguments += "-jar `"$Jar`""
    if (!$WithoutPid) { $start.Arguments += " --allow-pid $($fixture.Id)" }
    $start.Arguments += ' --allow-action invoke --allow-action setValue'
    switch ($backend) {
        'PowerShell' { $start.Arguments += ' --backend powershell' }
        'CSharp' { $start.Arguments += " --csharp-worker `"$CSharpWorker`"" }
        'JNA' { $start.Arguments += ' --backend jna' }
        'JAB' { $start.Arguments += ' --backend jab' }
        default { throw "Unknown backend $backend." }
    }
    if ($ExtraArguments) { $start.Arguments += " $ExtraArguments" }
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    return $start
}

function Start-Cli($start, [switch]$CaptureStderr) {
    # Windows PowerShell opens the child's stdin writer with the console input encoding. On a UTF-8
    # console (code page 65001) that writer sends a byte order mark ahead of the first request frame.
    $consoleInput = $null
    try {
        if ($start.RedirectStandardInput -and [Console]::InputEncoding.GetPreamble().Length) {
            $consoleInput = [Console]::InputEncoding
            [Console]::InputEncoding = New-Object Text.UTF8Encoding($false)
        }
    } catch { $consoleInput = $null }
    try { $cli = [Diagnostics.Process]::Start($start) }
    finally {
        if ($consoleInput) { try { [Console]::InputEncoding = $consoleInput } catch {} }
    }
    if (!$CaptureStderr) { $cli.BeginErrorReadLine() } # Drain without accumulating per-request audit output.
    return $cli
}

function Send-UiaRequest($cli, $command, [string]$id = ([guid]::NewGuid().ToString()), [int]$timeoutMs = 30000) {
    $command.id = $id
    $line = ConvertTo-Json -Compress -Depth 5 $command
    $frame = [Text.Encoding]::UTF8.GetBytes($line + "`n")
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $cli.StandardInput.BaseStream.Write($frame, 0, $frame.Length)
    $cli.StandardInput.BaseStream.Flush()
    $next = $cli.StandardOutput.ReadLineAsync()
    if (!$next.Wait($timeoutMs)) { throw "Timed out waiting for $($command.op)." }
    $clock.Stop()
    $endUtc = [DateTime]::UtcNow # the system clock that the JVM's GC log is stamped with
    if ($null -eq $next.Result) { throw "CLI closed before responding to $($command.op)." }
    try { $reply = $next.Result | ConvertFrom-Json -ErrorAction Stop }
    catch { throw "Invalid CLI JSON for $($command.op)." }
    if ($reply.id -cne $id -or $reply.ok -isnot [bool]) { throw "Invalid CLI reply for $($command.op)." }
    return @{ ms = $clock.Elapsed.TotalMilliseconds; reply = $reply; endUtc = $endUtc }
}

function Request($cli, $command) {
    $response = Send-UiaRequest $cli $command
    if (!$response.reply.ok) { throw "$($command.op) failed: $($response.reply.error.code)" }
    return @{ ms = $response.ms; result = $response.reply.result; endUtc = $response.endUtc }
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

# -RequestEnds is an optional hashtable that receives the completion time of each request by latency key.
function Run-Iteration($cli, $windowId, $expectedCount, $token, [string[]]$expectedShape, [switch]$ObserveOnly, $RequestEnds) {
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
    if ($null -ne $RequestEnds) {
        $RequestEnds.Clear()
        $RequestEnds.snapshot = $snap.endUtc; $RequestEnds.findEdit = $edit.endUtc
        $RequestEnds.findButton = $button.endUtc; $RequestEnds.elementInfo = $info.endUtc
    }
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
        if ($null -ne $RequestEnds) { $RequestEnds.setValue = $set.endUtc; $RequestEnds.invoke = $invoke.endUtc }
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
        slowRequestCount = 0; slowRequestCounts = [ordered]@{}
        slowRequests = New-Object 'Collections.Generic.List[object]'
    }
}

# Requests at or above this latency are counted per interval; the slowest few keep their completion
# time so they can be matched against GC pauses. Zero disables the tracking.
$script:UiaSlowRequestMs = 100.0
$script:UiaSlowRequestLimit = 10

function Add-SoakSlowRequest($interval, [string]$operation, [double]$ms, $endUtc, $iteration) {
    $interval.slowRequestCount++
    if ($interval.slowRequestCounts.Contains($operation)) { $interval.slowRequestCounts[$operation]++ }
    else { $interval.slowRequestCounts[$operation] = 1 }
    $kept = $interval.slowRequests
    if ($kept.Count -ge $UiaSlowRequestLimit) {
        if (!$kept.Count) { return }
        $fastest = 0
        for ($i = 1; $i -lt $kept.Count; $i++) { if ($kept[$i].ms -lt $kept[$fastest].ms) { $fastest = $i } }
        if ($kept[$fastest].ms -ge $ms) { return }
        $kept.RemoveAt($fastest)
    }
    # Requests arrive in time order, so appending keeps the list chronological.
    $utc = if ($endUtc -is [DateTime]) { $endUtc.ToString('o') } else { $null }
    $kept.Add([ordered]@{ utc = $utc; op = $operation; ms = $ms; iteration = $iteration })
}

function Add-SoakIterationTimes($interval, $intervalLatencies, $histograms, $times, $ends, $iteration) {
    foreach ($name in $times.Keys) {
        $value = [double]$times[$name]
        $operation = $UiaLatencyOperation[$name]
        if (!$operation) { $operation = $name }
        if ($ends -and $UiaSlowRequestMs -gt 0 -and $value -ge $UiaSlowRequestMs) {
            Add-SoakSlowRequest $interval $operation $value $ends[$name] $iteration
        }
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
    foreach ($field in 'heapUsedBytes', 'heapCommittedBytes', 'heapRegionBytes', 'heapYoungBytes', 'heapSurvivorBytes',
        'nmtReservedBytes', 'nmtCommittedBytes', 'gc', 'fixture', 'driver', 'host') {
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

# jcmd GC.heap_info for G1 and Serial GC; any other layout yields no figures rather than guessed ones.
# G1: young is the size of the young regions, survivor regions included.
# Serial: young is the used part of the young generation, so used - young is the tenured generation exactly.
function ConvertFrom-JvmHeapInfo([string]$text) {
    $result = [ordered]@{}
    $usage = [regex]::Match($text, '(?i)heap\s+total\s+(\d+)K,\s+used\s+(\d+)K\b')
    if (!$usage.Success) {
        $young = [regex]::Match($text, '(?im)^\s*def new generation\s+total\s+\d+K,\s+used\s+(\d+)K\b')
        $old = [regex]::Match($text, '(?im)^\s*tenured generation\s+total\s+(\d+)K,\s+used\s+(\d+)K\b')
        $eden = [regex]::Match($text, '(?im)^\s*eden space\s+(\d+)K,')
        $from = [regex]::Match($text, '(?im)^\s*from space\s+(\d+)K,\s+\d+% used \[0x([0-9a-f]+),\s*0x([0-9a-f]+),')
        $to = [regex]::Match($text, '(?im)^\s*to\s+space\s+(\d+)K,')
        if ($young.Success -and $old.Success -and $eden.Success -and $from.Success -and $to.Success) {
            # The generation's own "total" leaves out the to space, which is committed as well.
            $result.heapCommittedBytes = ([long]$eden.Groups[1].Value + [long]$from.Groups[1].Value +
                [long]$to.Groups[1].Value + [long]$old.Groups[1].Value) * 1KB
            $result.heapUsedBytes = ([long]$young.Groups[1].Value + [long]$old.Groups[2].Value) * 1KB
            $result.heapYoungBytes = [long]$young.Groups[1].Value * 1KB
            $result.heapSurvivorBytes = [Convert]::ToInt64($from.Groups[3].Value, 16) - [Convert]::ToInt64($from.Groups[2].Value, 16)
        }
        return $result
    }
    $result.heapCommittedBytes = [long]$usage.Groups[1].Value * 1KB
    $result.heapUsedBytes = [long]$usage.Groups[2].Value * 1KB
    $regions = [regex]::Match($text, '(?i)region size\s+(\d+)K,\s+\d+\s+young\s+\((\d+)K\),\s+\d+\s+survivors\s+\((\d+)K\)')
    if ($regions.Success) {
        $result.heapRegionBytes = [long]$regions.Groups[1].Value * 1KB
        $result.heapYoungBytes = [long]$regions.Groups[2].Value * 1KB
        $result.heapSurvivorBytes = [long]$regions.Groups[3].Value * 1KB
    }
    return $result
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

# Host-side observations that separate provider or host delays from the agent's own work: CPU time
# of every logical processor, processor speed, free memory, power source, user input and the fixture
# window state. Every part is optional; a missing API or counter leaves its fields out.
$script:UiaHostProbeSource = @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;

public sealed class UiaProcessTime { public int Pid; public string Name; public double CpuMs; }

public static class UiaHostProbe {
    [StructLayout(LayoutKind.Sequential)] struct FILETIME { public uint Low, High; }
    [StructLayout(LayoutKind.Sequential)] struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
    [StructLayout(LayoutKind.Sequential)] struct SYSTEM_POWER_STATUS {
        public byte ACLineStatus, BatteryFlag, BatteryLifePercent, SystemStatusFlag;
        public uint BatteryLifeTime, BatteryFullLifeTime;
    }
    [StructLayout(LayoutKind.Sequential)] struct MEMORYSTATUSEX {
        public uint dwLength, dwMemoryLoad;
        public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual,
            ullAvailExtendedVirtual;
    }
    [DllImport("kernel32.dll", SetLastError = true)]
    static extern bool GetSystemTimes(out FILETIME idle, out FILETIME kernel, out FILETIME user);
    [DllImport("user32.dll", SetLastError = true)] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("kernel32.dll")] static extern uint GetTickCount();
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetSystemPowerStatus(out SYSTEM_POWER_STATUS status);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX status);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr window);
    [DllImport("powrprof.dll")] static extern uint PowerGetEffectiveOverlayScheme(out Guid scheme);
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int kind, IntPtr buffer, int length, out int needed);

    static double Ms(FILETIME value) { return ((((long)value.High) << 32) | value.Low) / 10000.0; }

    // { busy, idle } summed over all logical processors since boot. Kernel time includes idle time.
    public static double[] CpuTimesMs() {
        FILETIME idle, kernel, user;
        if (!GetSystemTimes(out idle, out kernel, out user)) throw new Win32Exception();
        double idleMs = Ms(idle);
        return new double[] { Ms(kernel) + Ms(user) - idleMs, idleMs };
    }

    // Time since the last keyboard or mouse input in this session. UI Automation patterns do not reset it.
    public static double UserIdleMs() {
        LASTINPUTINFO info = new LASTINPUTINFO();
        info.cbSize = (uint)Marshal.SizeOf(typeof(LASTINPUTINFO));
        if (!GetLastInputInfo(ref info)) throw new Win32Exception();
        return unchecked(GetTickCount() - info.dwTime);
    }

    // { AC line status (0 offline, 1 online, 255 unknown), battery percent (255 unknown) }
    public static int[] Power() {
        SYSTEM_POWER_STATUS status;
        if (!GetSystemPowerStatus(out status)) throw new Win32Exception();
        return new int[] { status.ACLineStatus, status.BatteryLifePercent };
    }

    // { installed, available } physical memory in bytes.
    public static double[] MemoryBytes() {
        MEMORYSTATUSEX status = new MEMORYSTATUSEX();
        status.dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX));
        if (!GlobalMemoryStatusEx(ref status)) throw new Win32Exception();
        return new double[] { status.ullTotalPhys, status.ullAvailPhys };
    }

    public static bool IsForeground(long window) { return window != 0 && GetForegroundWindow() == new IntPtr(window); }
    public static bool IsMinimized(long window) { return window != 0 && IsIconic(new IntPtr(window)); }

    public static string PowerOverlay() {
        Guid scheme;
        return PowerGetEffectiveOverlayScheme(out scheme) == 0 ? scheme.ToString() : null;
    }

    // Cumulative kernel + user time of every process from one system call. Unlike opening each
    // process, this also covers services that deny access to a standard user.
    public static UiaProcessTime[] ProcessTimes() {
        int size = 1 << 20;
        for (int attempt = 0; attempt < 6; attempt++) {
            IntPtr buffer = Marshal.AllocHGlobal(size);
            try {
                int needed;
                int status = NtQuerySystemInformation(5, buffer, size, out needed); // SystemProcessInformation
                if (status == unchecked((int)0xC0000004)) { size = Math.Max(size * 2, needed + 65536); continue; }
                if (status < 0) throw new InvalidOperationException("NtQuerySystemInformation 0x" + status.ToString("x8"));
                List<UiaProcessTime> result = new List<UiaProcessTime>();
                bool wide = IntPtr.Size == 8;
                long offset = 0;
                while (true) {
                    // SYSTEM_PROCESS_INFORMATION: UserTime 40, KernelTime 48, ImageName 56, UniqueProcessId 80 (x86: 68).
                    IntPtr entry = new IntPtr(buffer.ToInt64() + offset);
                    int next = Marshal.ReadInt32(entry, 0);
                    int nameBytes = (ushort)Marshal.ReadInt16(entry, 56);
                    IntPtr name = Marshal.ReadIntPtr(entry, wide ? 64 : 60);
                    UiaProcessTime row = new UiaProcessTime();
                    row.Pid = Marshal.ReadIntPtr(entry, wide ? 80 : 68).ToInt32();
                    row.Name = name == IntPtr.Zero ? "" : Marshal.PtrToStringUni(name, nameBytes / 2);
                    row.CpuMs = (Marshal.ReadInt64(entry, 40) + Marshal.ReadInt64(entry, 48)) / 10000.0;
                    result.Add(row);
                    if (next == 0) break;
                    offset += next;
                }
                return result.ToArray();
            } finally { Marshal.FreeHGlobal(buffer); }
        }
        throw new InvalidOperationException("The process list did not fit its buffer.");
    }
}
'@
$script:UiaHostPerformance = $null
$script:UiaHostProcessTimes = $null

function Initialize-UiaHostProbe {
    if ($env:OS -ne 'Windows_NT') { return $false }
    try {
        if (!('UiaHostProbe' -as [type])) { Add-Type -TypeDefinition $UiaHostProbeSource }
        [void][UiaHostProbe]::CpuTimesMs()
    } catch { return $false }
    if ($null -eq $script:UiaHostPerformance) {
        # Opening the counter takes a few hundred milliseconds, so it is done before the first sample.
        # .NET resolves the English counter names on every display language.
        try {
            $script:UiaHostPerformance = New-Object Diagnostics.PerformanceCounter(
                'Processor Information', '% Processor Performance', '_Total')
            [void]$script:UiaHostPerformance.NextSample()
        } catch { $script:UiaHostPerformance = $false }
    }
    return $true
}

# CPU times and the processor performance counter are cumulative, so any two samples give the
# average over the time between them. topProcesses is the exception: it lists the processes that
# used the most CPU since the previous call, excluding $ownPids, and stores their names.
function Get-UiaHostSample([long]$windowHandle, [int]$topProcesses, [int[]]$ownPids) {
    if (!('UiaHostProbe' -as [type])) { return [ordered]@{ available = $false } }
    try {
        $cpu = [UiaHostProbe]::CpuTimesMs()
        $sample = [ordered]@{ available = $true; cpuBusyMs = $cpu[0]; cpuIdleMs = $cpu[1] }
    } catch { return [ordered]@{ available = $false; error = $_.Exception.Message } }
    try {
        if ($script:UiaHostPerformance) {
            # Average speed relative to the nominal frequency = delta raw / delta base between two samples.
            $counter = $script:UiaHostPerformance.NextSample()
            $sample.processorPerformanceRaw = $counter.RawValue
            $sample.processorPerformanceBase = $counter.BaseValue
        }
    } catch { $script:UiaHostPerformance = $false }
    try { $sample.availableMemoryBytes = [UiaHostProbe]::MemoryBytes()[1] } catch {}
    $sample.acPower = $null
    try {
        $power = [UiaHostProbe]::Power()
        if ($power[0] -eq 1) { $sample.acPower = $true } elseif ($power[0] -eq 0) { $sample.acPower = $false }
        if ($power[1] -le 100) { $sample.batteryPercent = $power[1] }
    } catch {}
    try { $sample.userIdleMs = [UiaHostProbe]::UserIdleMs() } catch {}
    try {
        $sample.fixtureForeground = [UiaHostProbe]::IsForeground($windowHandle)
        $sample.fixtureMinimized = [UiaHostProbe]::IsMinimized($windowHandle)
    } catch {}
    if ($topProcesses -gt 0) {
        try {
            $current = @{}
            $rows = New-Object 'Collections.Generic.List[object]'
            foreach ($row in [UiaHostProbe]::ProcessTimes()) {
                if ($row.Pid -eq 0) { continue } # idle
                $key = "$($row.Pid)|$($row.Name)"
                $current[$key] = $row.CpuMs
                if ($null -eq $script:UiaHostProcessTimes -or $ownPids -contains $row.Pid) { continue }
                # A process that appeared since the previous sample spent all of its time in this window.
                $used = $row.CpuMs
                if ($script:UiaHostProcessTimes.ContainsKey($key)) { $used -= $script:UiaHostProcessTimes[$key] }
                if ($used -gt 0) { $rows.Add([ordered]@{ name = $row.Name; pid = $row.Pid; cpuMs = $used }) }
            }
            $script:UiaHostProcessTimes = $current
            $sample.topProcesses = @($rows | Sort-Object { $_.cpuMs } -Descending | Select-Object -First $topProcesses)
        } catch {}
    }
    return $sample
}

$script:UiaPowerSchemes = @{
    '381b4222-f694-41f0-9685-ff5bb260df2e' = 'Balanced'
    '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' = 'High performance'
    'a1841308-3541-4fab-bc81-f71556f20b4a' = 'Power saver'
}

# Installed memory and the power configuration at the start of the run. Call after Initialize-UiaHostProbe.
function Set-UiaHostInfo($environment) {
    if (!('UiaHostProbe' -as [type])) { return }
    try { $environment.memoryBytes = [UiaHostProbe]::MemoryBytes()[0] } catch {}
    $power = [ordered]@{}
    try {
        $scheme = Read-Diagnostic (Join-Path $env:SystemRoot 'System32/powercfg.exe') '/getactivescheme'
        $guid = [regex]::Match($scheme.stdout, '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}')
        if ($guid.Success) {
            $power.scheme = $guid.Value.ToLowerInvariant()
            # The localized name is not parsed; only the built-in schemes are named.
            if ($UiaPowerSchemes.ContainsKey($power.scheme)) { $power.schemeName = $UiaPowerSchemes[$power.scheme] }
        }
    } catch {}
    try {
        # The power mode slider. All zeroes is the scheme's own default.
        $overlay = [UiaHostProbe]::PowerOverlay()
        if ($overlay) { $power.overlay = $overlay }
    } catch {}
    if ($power.Count) { $environment.power = $power }
}

function Get-UiaGitInfo {
    try {
        $git = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
        $head = Read-Diagnostic $git "-C `"$PSScriptRoot`" rev-parse HEAD"
        if ($head.exitCode -ne 0 -or $head.stdout -notmatch '^[0-9a-f]{40}$') { return $null }
        $status = Read-Diagnostic $git "-C `"$PSScriptRoot`" status --porcelain --untracked-files=no"
        return [ordered]@{ commit = $head.stdout; dirty = [bool]($status.exitCode -ne 0 -or $status.stdout) }
    } catch { return $null }
}

function Read-UiaReport([string]$path) {
    $json = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $path).Path)
    if ($PSVersionTable.PSEdition -eq 'Core') { return ConvertFrom-Json -InputObject $json -AsHashtable }
    # Windows PowerShell's ConvertFrom-Json has a 2 MB limit.
    Add-Type -AssemblyName System.Web.Extensions
    $serializer = New-Object Web.Script.Serialization.JavaScriptSerializer
    $serializer.MaxJsonLength = [int]::MaxValue
    $serializer.RecursionLimit = 200
    return $serializer.DeserializeObject($json)
}
