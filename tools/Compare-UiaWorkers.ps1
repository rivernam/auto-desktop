# Run on an unlocked Windows test desktop. Emits one JSON document to stdout.
# Cold runs use fresh JVM + worker processes with ordinary OS caches. Hot timings
# cover each UTF-8 request/reply, excluding fixture readback and resource sampling.
# A longer run can use -Sessions 5 -Iterations 1500. Each session stays below the
# 4096-command mutation ledger limit, including its two warm-up mutations.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$CSharpWorker,
    [string]$Jar = (Join-Path $PSScriptRoot '../target/desktop-agent.jar'),
    [ValidateRange(1, 2000)][int]$Iterations = 10,
    [ValidateRange(1, 100)][int]$Sessions = 1,
    [ValidateRange(1, 100)][int]$ColdRuns = 3
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or ![Environment]::UserInteractive) {
    throw 'An interactive Windows test desktop is required.'
}
$Jar = (Get-Item -LiteralPath $Jar).FullName
$CSharpWorker = (Get-Item -LiteralPath $CSharpWorker).FullName
$javaExe = (Get-Command java.exe -CommandType Application | Select-Object -First 1).Source
$fixtureScript = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '../src/test/resources/windows-gui-fixture.ps1')).FullName
$fixtureExe = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'

function Request($cli, $command) {
    $command.id = [guid]::NewGuid().ToString()
    $line = ConvertTo-Json -Compress -Depth 5 $command
    $frame = [Text.Encoding]::UTF8.GetBytes($line + "`n")
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $cli.StandardInput.BaseStream.Write($frame, 0, $frame.Length)
    $cli.StandardInput.BaseStream.Flush()
    $next = $cli.StandardOutput.ReadLineAsync()
    if (!$next.Wait(30000)) { throw "Timed out waiting for $($command.op)." }
    $timer.Stop()
    $reply = $next.Result | ConvertFrom-Json
    if (!$reply.ok -or $reply.id -ne $command.id) { throw "$($command.op) failed: $($reply.error.code)" }
    return @{ ms = $timer.Elapsed.TotalMilliseconds; result = $reply.result }
}

function Wait-State($file, $value) {
    $timer = [Diagnostics.Stopwatch]::StartNew()
    do {
        $actual = $null
        try { $actual = [IO.File]::ReadAllText((Join-Path $stateDir $file)) } catch [IO.IOException] {}
        if ($actual -ceq $value) { return }
        if ($fixture.HasExited) { throw 'Fixture exited unexpectedly.' }
        Start-Sleep -Milliseconds 25
    } while ($timer.Elapsed.TotalSeconds -lt 20)
    throw "Fixture did not report expected $file."
}

function New-CliStartInfo([string]$backend) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $javaExe
    $start.Arguments = "-jar `"$Jar`" --allow-pid $($fixture.Id) --allow-action invoke --allow-action setValue"
    if ($backend -eq 'CSharp') { $start.Arguments += " --csharp-worker `"$CSharpWorker`"" }
    $start.UseShellExecute = $false
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    return $start
}

function Start-Cli($start) {
    $cli = [Diagnostics.Process]::Start($start)
    $cli.BeginErrorReadLine() # drain the per-request audit messages without retaining a soak-test log
    return $cli
}

function Worker-Process($cli, [string]$backend) {
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
        return [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); java = Process-Sample $cli
            worker = Process-Sample $worker }
    } finally { if ($worker) { $worker.Dispose() } }
}

function Stop-Cli($cli, $backend) {
    if (!$cli) { return }
    try {
        if (!$cli.HasExited) { $cli.StandardInput.Close() }
        if (!$cli.WaitForExit(15000)) {
            $worker = Worker-Process $cli $backend
            try { if ($worker -and !$worker.HasExited) { $worker.Kill() } }
            finally { if ($worker) { $worker.Dispose() } }
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

function Check-Window($windows) {
    $matches = @($windows | Where-Object { $_.processId -eq $fixture.Id -and $_.name -ceq $title })
    if ($matches.Count -ne 1) { throw 'Cannot uniquely identify the temporary WPF window.' }
    return $matches[0].windowId
}

function Run-Iteration($cli, $windowId, $expectedCount, $token) {
    $snap = Request $cli @{ op = 'snapshot'; windowId = $windowId; maxDepth = 16; maxElements = 200 }
    [void](Check-Snapshot $snap.result $windowId $expectedCount)
    $edit = Request $cli @{ op = 'findElement'; snapshotId = $snap.result.snapshotId
        locator = @{ automationId = 'fixtureEdit'; role = 'Edit' } }
    $button = Request $cli @{ op = 'findElement'; snapshotId = $snap.result.snapshotId
        locator = @{ automationId = 'fixtureIncrement'; role = 'Button' } }
    $info = Request $cli @{ op = 'getElementInfo'; ref = $edit.result.ref }
    if ($info.result.processId -ne $fixture.Id -or $info.result.automationId -cne 'fixtureEdit') {
        throw 'Live element information did not identify the fixture editor.'
    }
    $set = Request $cli @{ op = 'setValue'; ref = $edit.result.ref; value = $token }
    Wait-State 'value.txt' $token
    $previous = [int][IO.File]::ReadAllText((Join-Path $stateDir 'count.txt'))
    $invoke = Request $cli @{ op = 'invoke'; ref = $button.result.ref }
    Wait-State 'count.txt' ([string]($previous + 1))
    return [ordered]@{ snapshot = $snap.ms; findEdit = $edit.ms; findButton = $button.ms
        elementInfo = $info.ms; setValue = $set.ms; invoke = $invoke.ms }
}

function Measure-Backend([string]$backend) {
    $start = New-CliStartInfo $backend
    $cold = New-Object 'Collections.Generic.List[object]'
    $hot = New-Object 'Collections.Generic.List[object]'
    $result = [ordered]@{ backend = $backend; status = 'running'; stage = 'discovery'; elementsPerSnapshot = 0
        cold = $cold; sessions = $hot }
    $cli = $null
    try {
        # Discovery runs in a third process separate from either measurement.
        $cli = Start-Cli $start
        $windowId = Check-Window (Request $cli @{ op = 'listWindows' }).result
        Stop-Cli $cli $backend
        $cli = $null
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
                    $result.elementsPerSnapshot = Check-Snapshot $reply.result $windowId $result.elementsPerSnapshot
                }
                $cold.Add([ordered]@{ round = $round; op = $op; launchMs = $launchMs; requestMs = $reply.ms
                    startToReplyMs = $clock.Elapsed.TotalMilliseconds; resources = Resources $cli $backend })
                Stop-Cli $cli $backend
                $cli = $null
            }
        }
        for ($session = 1; $session -le $Sessions; $session++) {
            $result.stage = "session/$session/warmup"
            $cli = Start-Cli $start
            $caps = Request $cli @{ op = 'getCapabilities' }
            if (!$caps.result.available) { throw 'Worker reported unavailable.' }
            if ((Check-Window (Request $cli @{ op = 'listWindows' }).result) -cne $windowId) { throw 'Fixture window changed.' }
            $token = "$backend-$session"
            [void](Run-Iteration $cli $windowId $result.elementsPerSnapshot "$token-warmup")
            $samples = New-Object 'Collections.Generic.List[object]'
            $baseline = Resources $cli $backend
            $metrics = [ordered]@{}
            $latencies = @{}
            $run = [ordered]@{ session = $session; completedIterations = 0; elapsedMs = 0
                baseline = $baseline; samples = $samples; latencyMs = $metrics; workerIdentity = 'unobserved' }
            $hot.Add($run)
            $clock = [Diagnostics.Stopwatch]::StartNew()
            # Keep boundary samples and at most 32 evenly spaced observations per session.
            $stride = [int][Math]::Ceiling($Iterations / 32.0)
            $workerIdentity = $baseline.worker
            if ($workerIdentity.available) { $run.workerIdentity = 'observed' }
            for ($i = 1; $i -le $Iterations; $i++) {
                $result.stage = "session/$session/iteration/$i"
                $times = Run-Iteration $cli $windowId $result.elementsPerSnapshot "$token-$i"
                $run.completedIterations = $i
                $run.elapsedMs = $clock.Elapsed.TotalMilliseconds
                foreach ($name in $times.Keys) {
                    if (!$metrics.Contains($name)) {
                        $metrics[$name] = @{ mean = 0.0; max = 0.0 }
                        $latencies[$name] = New-Object 'Collections.Generic.List[double]'
                    }
                    $latencies[$name].Add($times[$name])
                    $stat = $metrics[$name]
                    $stat.mean += ($times[$name] - $stat.mean) / $i
                    $stat.max = [Math]::Max([double]$stat.max, [double]$times[$name])
                }
                if ($i -eq 1 -or $i -eq $Iterations -or ($i % $stride) -eq 0) {
                    $resource = Resources $cli $backend
                    $samples.Add([ordered]@{ iteration = $i; elapsedMs = $run.elapsedMs; latencyMs = $times; resources = $resource })
                    if (!$resource.worker.available) { $run.workerIdentity = 'incomplete' }
                    elseif (!$workerIdentity.available) { $workerIdentity = $resource.worker; $run.workerIdentity = 'incomplete' }
                    elseif ($resource.worker.pid -ne $workerIdentity.pid -or $resource.worker.startUtc -ne $workerIdentity.startUtc) {
                        $run.workerIdentity = 'changed'
                        throw 'Worker identity changed within a persistent session.'
                    }
                }
            }
            foreach ($name in $metrics.Keys) {
                $values = $latencies[$name]
                $values.Sort()
                $metrics[$name].p50 = $values[[int][Math]::Ceiling($values.Count * 0.50) - 1]
                $metrics[$name].p95 = $values[[int][Math]::Ceiling($values.Count * 0.95) - 1]
            }
            Stop-Cli $cli $backend
            $cli = $null
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
    return $result
}

$stateDir = Join-Path ([IO.Path]::GetTempPath()) ("uia-compare-" + [guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($stateDir)
$title = 'UIA comparison ' + [guid]::NewGuid()
$fixture = $null
try {
    $fixture = Start-Process -FilePath $fixtureExe -PassThru -ArgumentList @(
        '-NoProfile', '-NonInteractive', '-STA', '-ExecutionPolicy', 'RemoteSigned',
        '-File', "`"$fixtureScript`"", "`"$stateDir`"", "`"$title`"")
    Wait-State 'ready' ([string]$fixture.Id)
    $order = @(@('PowerShell', 'CSharp') | Get-Random -Count 2)
    $results = @(foreach ($backend in $order) { Measure-Backend $backend })
    $passed = $results[0].status -eq 'passed' -and $results[1].status -eq 'passed' -and
        $results[0].elementsPerSnapshot -eq $results[1].elementsPerSnapshot
    [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); os = [Environment]::OSVersion.VersionString
        passed = $passed; iterationsPerSession = $Iterations; sessionsPerBackend = $Sessions
        coldRunsPerOperation = $ColdRuns; warmupIterationsPerSession = 1; order = $order; results = $results
    } | ConvertTo-Json -Depth 12
    if (!$passed) { throw 'Worker comparison failed. Inspect stage and resource samples in the JSON report.' }
} finally {
    if ($fixture -and !$fixture.HasExited) { $fixture.Kill(); $fixture.WaitForExit() }
    if ($fixture) { $fixture.Dispose() }
    Remove-Item -LiteralPath $stateDir -Recurse -Force
}
