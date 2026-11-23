# Run on an unlocked Windows test desktop. Only the spawned WPF fixture is authorized for changes.
[CmdletBinding()]
param(
    [string]$Jar = 'target/desktop-agent.jar',
    [string]$CppAgent = 'target/cpp-agent/Release/cpp-agent.exe',
    [string]$OutputPath = 'target/java-cpp-comparison.json',
    [ValidateRange(1, 20)][int]$Pairs = 6,
    [ValidateRange(1, 500)][int]$Iterations = 20,
    [ValidateRange(0, 600)][int]$SoakSeconds = 300,
    [ValidateRange(0, 10)][int]$Warmup = 5,
    [ValidateRange(200, 3000)][int]$SoakPeriodMs = 500,
    [ValidateRange(0, 500)][int]$ActionIntervalMs = 50,
    [switch]$ParityOnly,
    [switch]$CppFirst
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UiaTest.Common.ps1')

function Verify([bool]$condition, [string]$message) {
    if (!$condition) { throw $message }
}

function Open-Agent([string]$backend, [switch]$ReadOnly) {
    $start = New-CliStartInfo JNA -JvmOptions @('-XX:+UseSerialGC', '-Xms16m')
    if ($ReadOnly) {
        $start.Arguments = "-XX:+UseSerialGC -Xms16m -jar `"$Jar`" --backend jna --allow-pid $($fixture.Id)"
    }
    if ($backend -ceq 'Cpp') {
        $start.FileName = $CppAgent
        $start.Arguments = if ($ReadOnly) { "--allow-pid $($fixture.Id)" } else {
            "--allow-pid $($fixture.Id) --allow-action invoke --allow-action setValue"
        }
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $cli = Start-Cli $start
    return @{ cli = $cli; clock = $clock; processStartMs = $clock.Elapsed.TotalMilliseconds }
}

function Exchange($cli, $command, [string]$expected, [string]$id = ([guid]::NewGuid().ToString()),
                  [byte[]]$raw, [switch]$NullId, [Diagnostics.Stopwatch]$StartupClock) {
    if (!$raw) {
        $command.id = $id
        $raw = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Depth 8 -Compress -InputObject $command) + "`n")
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $cli.StandardInput.BaseStream.Write($raw, 0, $raw.Length)
    $cli.StandardInput.BaseStream.Flush()
    $line = $cli.StandardOutput.ReadLineAsync()
    if (!$line.Wait(15000) -or $null -eq $line.Result) {
        throw "Missing protocol reply for $($command.op). A transmitted action may have taken effect."
    }
    $timer.Stop()
    $sinceStart = if ($StartupClock) { $StartupClock.Elapsed.TotalMilliseconds }
    $reply = ConvertFrom-Json -InputObject $line.Result
    $expectedId = if ($NullId) { $null } else { $id }
    if ($reply.id -cne $expectedId -or ($expected -ceq 'OK' -and $reply.ok -ne $true) -or
        ($expected -cne 'OK' -and ($reply.ok -ne $false -or $reply.error.code -cne $expected))) {
        throw "$($command.op) expected $expected with matching id, got ok=$($reply.ok), code=$($reply.error.code)."
    }
    return @{ result = $reply.result; ms = $timer.Elapsed.TotalMilliseconds; sinceStartMs = $sinceStart }
}

function Open-Window($cli) {
    $cap = (Request $cli @{ op = 'getCapabilities' }).result
    Verify ($cap.available -and $cap.backend -ceq 'UIA' -and !$cap.physicalInput -and !$cap.screenshot) 'UIA unavailable.'
    Verify ((@($cap.operations | Sort-Object) -join ',') -ceq
        'findElement,getCapabilities,getElementInfo,invoke,listWindows,setValue,snapshot') 'Capability operation mismatch.'
    return Check-Window (Request $cli @{ op = 'listWindows' }).result
}

function Canonical-Tree($snapshot) {
    $paths = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $rows = New-Object 'Collections.Generic.List[string]'
    $chrome = New-Object 'Collections.Generic.List[string]'
    foreach ($row in $snapshot.elements) {
        $identity = ConvertTo-Json -Compress -InputObject @($row.role, $row.name, $row.automationId, $row.className)
        $path = @($identity)
        $isChrome = $row.role -ceq 'TitleBar'
        if ($row.parentRef) {
            Verify ($paths.ContainsKey($row.parentRef)) 'Tree has an invalid parent ref.'
            $parent = $paths[$row.parentRef]
            $path = @($parent.path) + $path
            $isChrome = $isChrome -or $parent.chrome
        }
        Verify (!$paths.ContainsKey($row.ref)) 'Duplicate element ref.'
        $paths.Add($row.ref, @{ path = $path; chrome = $isChrome })
        Verify ($null -eq $row.PSObject.Properties['value']) 'Snapshot exposed a control value.'
        $bounds = if ($row.bounds) { @($row.bounds.x, $row.bounds.y, $row.bounds.width, $row.bounds.height) }
        $entry = ConvertTo-Json -Depth 8 -Compress -InputObject @($path, @($bounds), $row.enabled,
            $row.offscreen, @($row.actions | Sort-Object), $row.backend, ($row.processId -eq $fixture.Id))
        if ($isChrome) { $chrome.Add($entry) } else { $rows.Add($entry) }
    }
    $rows.Sort([StringComparer]::Ordinal)
    $chrome.Sort([StringComparer]::Ordinal)
    return @{ content = $rows.ToArray(); chrome = $chrome.ToArray() }
}

function Locate($cli, $snapshot, [string]$automationId, [string]$role) {
    $locator = @{ automationId = $automationId }
    if ($role) { $locator.role = $role }
    return (Request $cli @{ op = 'findElement'; snapshotId = $snapshot.snapshotId; locator = $locator }).result
}

function Cursor {
    $token = [guid]::NewGuid().ToString()
    [IO.File]::WriteAllText((Join-Path $stateDir "$token.request"), '')
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.Elapsed.TotalSeconds -lt 5) {
        try { return Read-State "$token.reply" } catch [IO.IOException] {}
        Start-Sleep -Milliseconds 10
    }
    throw 'WPF fixture did not report the physical cursor.'
}

function Test-Parity([string]$backend) {
    $run = Open-Agent $backend
    $cli = $run.cli
    $readOnly = $null
    try {
        $windowId = Open-Window $cli
        $snap = (Take-Snapshot $cli $windowId).result
        $count = Check-Snapshot $snap $windowId 0
        $tree = Canonical-Tree $snap
        $root = $snap.elements[0]
        $edit = Locate $cli $snap 'fixtureEdit' 'Edit'
        $button = Locate $cli $snap 'fixtureIncrement' 'Button'
        $disabled = Locate $cli $snap 'fixtureDisabled'
        $readOnlyEdit = Locate $cli $snap 'fixtureReadOnly'
        $info = (Request $cli @{ op = 'getElementInfo'; ref = $edit.ref }).result
        Verify ($info.ref -ceq $edit.ref -and $info.parentRef -ceq $edit.parentRef -and
                $info.automationId -ceq 'fixtureEdit' -and $info.name -ceq '' -and
                ($info.actions -ccontains 'setValue') -and $null -eq $info.PSObject.Properties['value'] -and
                @($snap.elements | Where-Object parentRef -CEQ $edit.ref).Count -eq 0) 'Edit exposure or live ref mismatch.'
        Verify (($button.actions -ccontains 'invoke') -and $button.bounds.width -gt 0 -and $button.bounds.height -gt 0) 'Invoke metadata mismatch.'
        $cursor = Cursor
        Verify ((Read-State 'value.txt') -cne '') 'Empty SetValue test requires a nonempty initial value.'
        $empty = Request $cli @{ op = 'setValue'; ref = $edit.ref; value = '' }
        Verify ($empty.result.performed -eq $true) 'Empty SetValue confirmation missing.'
        Wait-State 'value.txt' ''
        $value = "fixture-$backend-" + [char]0xAC12 + '-' + [char]::ConvertFromUtf32(0x1F680)
        Verify ((Read-State 'value.txt') -cne $value) 'SetValue test value already present.'
        $write = Request $cli @{ op = 'setValue'; ref = $edit.ref; value = $value }
        Verify ($write.result.performed -eq $true) 'SetValue confirmation missing.'
        Wait-State 'value.txt' $value
        $before = [int](Read-State 'count.txt')
        $commandId = [guid]::NewGuid().ToString()
        $invoke = Exchange $cli @{ op = 'invoke'; ref = $button.ref } 'OK' -id $commandId
        Verify ($invoke.result.performed -eq $true) 'Invoke confirmation missing.'
        Wait-State 'count.txt' ([string]($before + 1))
        Verify ((Cursor) -ceq $cursor) 'Physical cursor moved during the two actions.'
        [void](Exchange $cli @{ op = 'invoke'; ref = $button.ref } 'DUPLICATE_COMMAND' -id $commandId)
        [void](Exchange $cli @{ op = 'invoke'; ref = $disabled.ref } 'PRECONDITION_FAILED')
        [void](Exchange $cli @{ op = 'setValue'; ref = $readOnlyEdit.ref; value = 'unwritten' } 'PATTERN_UNSUPPORTED')
        Verify ((Read-State 'count.txt') -ceq [string]($before + 1) -and (Read-State 'disabled-click.txt') -ceq '0' -and
                (Read-State 'read-only.txt') -ceq 'fixed fixture value') 'Rejected action changed fixture state.'
        [void](Exchange $cli @{ op = 'findElement'; snapshotId = $snap.snapshotId; locator = @{ name = 'Duplicate label' } } 'AMBIGUOUS_ELEMENT')
        [void](Exchange $cli @{ op = 'findElement'; snapshotId = $snap.snapshotId; scopeRef = $edit.ref;
            locator = @{ automationId = 'fixtureIncrement' } } 'ELEMENT_NOT_FOUND')
        [void](Exchange $cli @{ op = 'findElement'; snapshotId = $snap.snapshotId;
            locator = @{ role = 'button'; automationId = 'fixtureIncrement' } } 'ELEMENT_NOT_FOUND')
        $limited = (Request $cli @{ op = 'snapshot'; windowId = $windowId; maxDepth = 0; maxElements = 1 }).result
        Verify ($limited.truncated -and $limited.elements.Count -eq 1) 'Root-only snapshot was not truncated.'
        [void](Exchange $cli @{ op = 'findElement'; snapshotId = $limited.snapshotId; scopeRef = $limited.elements[0].ref;
            locator = @{ role = 'Window' } } 'INCOMPLETE_SNAPSHOT')
        [void](Exchange $cli @{ op = 'getElementInfo'; ref = $root.ref } 'STALE_REFERENCE')
        $expanded = (Take-Snapshot $cli $windowId).result
        $list = Locate $cli $expanded 'fixtureList' 'List'
        $scoped = (Request $cli @{ op = 'snapshot'; windowId = $windowId; scopeRef = $list.ref }).result
        Verify (!$scoped.truncated -and $scoped.elements.Count -gt 1 -and $null -eq $scoped.elements[0].parentRef -and
                $scoped.elements[0].automationId -ceq 'fixtureList') 'Subtree was not re-captured from the requested container.'
        $item = (Request $cli @{ op = 'findElement'; snapshotId = $scoped.snapshotId; scopeRef = $scoped.elements[0].ref;
            locator = @{ role = 'ListItem'; name = 'Item one' } }).result
        Verify ($item.parentRef -ceq $scoped.elements[0].ref) 'Scoped list item has a different parent.'
        [void](Exchange $cli @{ op = 'getElementInfo'; ref = $list.ref } 'STALE_REFERENCE')
        [void](Exchange $cli @{ op = 'snapshot'; windowId = $windowId; maxElements = 2001 } 'INVALID_REQUEST')
        [void](Exchange $cli @{ op = 'unknown' } 'UNKNOWN_OPERATION')
        foreach ($line in @('{"id":"x","id":"y","op":"getCapabilities"}', ('x' * 65537), '{"op":')) {
            [void](Exchange $cli @{} 'INVALID_REQUEST' -raw ([Text.Encoding]::UTF8.GetBytes($line + "`n")) -NullId)
        }
        [void](Exchange $cli @{} 'INVALID_REQUEST' -raw ([byte[]](0xff, 0x0a)) -NullId)
        [void](Request $cli @{ op = 'getCapabilities' })
        $readOnly = (Open-Agent $backend -ReadOnly).cli
        $readSnap = (Take-Snapshot $readOnly $windowId).result
        [void](Exchange $readOnly @{ op = 'getElementInfo'; ref = $scoped.elements[0].ref } 'STALE_REFERENCE')
        $readButton = Locate $readOnly $readSnap 'fixtureIncrement'
        [void](Exchange $readOnly @{ op = 'invoke'; ref = $readButton.ref } 'PERMISSION_DENIED')
        return @{ count = $count; tree = $tree; windowId = $windowId }
    } finally {
        try { Stop-Cli $readOnly JNA } finally { Stop-Cli $cli JNA }
    }
}

function Test-ProviderLifetime([string[]]$order) {
    $agents = @()
    try {
        foreach ($backend in $order) {
            $cli = (Open-Agent $backend).cli
            $agents += @{ cli = $cli; window = $null; button = $null }
            $window = Open-Window $cli
            $snap = (Take-Snapshot $cli $window).result
            $agents[-1].window = $window
            $agents[-1].button = (Locate $cli $snap 'fixtureIncrement').ref
        }
        [IO.File]::WriteAllText((Join-Path $stateDir 'replace-control'), '')
        Wait-State 'replaced' 'ready'
        foreach ($agent in $agents) {
            [void](Exchange $agent.cli @{ op = 'invoke'; ref = $agent.button } 'STALE_REFERENCE')
            $fresh = (Take-Snapshot $agent.cli $agent.window).result
            $agent.button = (Locate $agent.cli $fresh 'fixtureIncrement').ref
        }
        [IO.File]::WriteAllText((Join-Path $stateDir 'close-fixture'), '')
        Verify ($fixture.WaitForExit(5000) -and $fixture.ExitCode -eq 0) 'Fixture failed to close.'
        foreach ($agent in $agents) {
            [void](Exchange $agent.cli @{ op = 'getElementInfo'; ref = $agent.button } 'STALE_REFERENCE')
            [void](Exchange $agent.cli @{ op = 'invoke'; ref = $agent.button } 'PERMISSION_DENIED')
            [void](Exchange $agent.cli @{ op = 'snapshot'; windowId = $agent.window } 'WINDOW_NOT_FOUND')
        }
    } finally {
        foreach ($agent in $agents) { Stop-Cli $agent.cli JNA }
    }
}

function Measure-Iteration($cli, $windowId, $expectedCount, $shape, $token, $pace) {
    $snap = Take-Snapshot $cli $windowId
    [void](Check-Snapshot $snap.result $windowId $expectedCount)
    Check-TreeShape $snap.result $shape
    $edit = Request $cli @{ op = 'findElement'; snapshotId = $snap.result.snapshotId;
        locator = @{ automationId = 'fixtureEdit'; role = 'Edit' } }
    $button = Request $cli @{ op = 'findElement'; snapshotId = $snap.result.snapshotId;
        locator = @{ automationId = 'fixtureIncrement'; role = 'Button' } }
    $info = Request $cli @{ op = 'getElementInfo'; ref = $edit.result.ref }
    Verify ($info.result.ref -ceq $edit.result.ref -and $info.result.automationId -ceq 'fixtureEdit' -and
            $info.result.processId -eq $fixture.Id) 'Live edit metadata changed.'
    Wait-ActionSpacing $pace
    $set = Request $cli @{ op = 'setValue'; ref = $edit.result.ref; value = $token }
    Verify ($set.result.performed -eq $true) 'SetValue confirmation missing.'
    Wait-State 'value.txt' $token
    $before = [int](Read-State 'count.txt')
    Wait-ActionSpacing $pace
    $invoke = Request $cli @{ op = 'invoke'; ref = $button.result.ref }
    Verify ($invoke.result.performed -eq $true) 'Invoke confirmation missing.'
    Wait-State 'count.txt' ([string]($before + 1))
    return @($snap.ms, $edit.ms, $button.ms, $info.ms, $set.ms, $invoke.ms)
}

function Wait-ActionSpacing($pace) {
    $delay = $ActionIntervalMs - $pace.Elapsed.TotalMilliseconds
    if ($delay -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Ceiling($delay)) }
    $pace.Restart()
}

function Agent-Resources($cli, $measurement) {
    $sample = Process-Sample $cli
    Verify $sample.available 'Could not sample the agent process.'
    $sample.Remove('startUtc')
    $sample.peakWorkingSetBytes = $cli.PeakWorkingSet64
    $sample.elapsedMs = $measurement.Elapsed.TotalMilliseconds
    return $sample
}

function Measure-Agent([string]$backend, $row, [int]$count, [int]$periodMs) {
    $row.backend = $backend
    $row.status = 'running'
    $row.samplesMs = New-Object 'Collections.Generic.List[object]'
    $row.resources = New-Object 'Collections.Generic.List[object]'
    $run = Open-Agent $backend
    $cli = $run.cli
    try {
        $caps = Exchange $cli @{ op = 'getCapabilities' } 'OK' -StartupClock $run.clock
        $row.startup = [ordered]@{ processStartReturnMs = $run.processStartMs; firstCapabilitiesMs = $caps.sinceStartMs }
        Verify ($caps.result.available -eq $true -and $caps.result.backend -ceq 'UIA') 'Measured backend is unavailable.'
        $windows = Exchange $cli @{ op = 'listWindows' } 'OK' -StartupClock $run.clock
        $row.startup.firstListWindowsMs = $windows.sinceStartMs
        $windowId = Check-Window $windows.result
        $first = Exchange $cli @{ op = 'snapshot'; windowId = $windowId; maxDepth = 16; maxElements = 200 } 'OK' -StartupClock $run.clock
        $row.startup.firstSnapshotMs = $first.sinceStartMs
        $expectedCount = Check-Snapshot $first.result $windowId $benchmarkCount
        $tree = Canonical-Tree $first.result
        Verify (($tree.content -join "`n") -ceq ($benchmarkTree.content -join "`n") -and
                ($tree.chrome -join "`n") -ceq ($benchmarkTree.chrome -join "`n")) 'Measured fixture properties changed.'
        $shape = Get-TreeShape $first.result
        $pace = [Diagnostics.Stopwatch]::StartNew()
        for ($index = 0; $index -lt $Warmup; $index++) {
            [void](Measure-Iteration $cli $windowId $expectedCount $shape "warm-$index" $pace)
        }
        $samplePrefix = 'sample'
        if (!$Warmup -and (Read-State 'value.txt') -ceq 'sample-0') { $samplePrefix = 'repeat' }
        $elapsed = [Diagnostics.Stopwatch]::StartNew()
        $row.hostStart = Get-UiaHostSample ([long]$windowId) 0 @()
        $row.resources.Add((Agent-Resources $cli $elapsed))
        $row.scheduleOverruns = 0
        $nextResource = 15000
        for ($index = 0; $index -lt $count; $index++) {
            # Generate identical state transitions and avoid reusing the previous text value.
            $row.samplesMs.Add((Measure-Iteration $cli $windowId $expectedCount $shape "$samplePrefix-$index" $pace))
            if ($periodMs -gt 0) {
                $delay = ($index + 1) * $periodMs - $elapsed.Elapsed.TotalMilliseconds
                if ($delay -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Ceiling($delay)) }
                else { $row.scheduleOverruns++ }
            }
            if ($elapsed.Elapsed.TotalMilliseconds -ge $nextResource) {
                $row.resources.Add((Agent-Resources $cli $elapsed))
                $nextResource += 15000
            }
        }
        $row.wallMs = $elapsed.Elapsed.TotalMilliseconds
        $row.resources.Add((Agent-Resources $cli $elapsed))
        $row.hostEnd = Get-UiaHostSample ([long]$windowId) 0 @()
        $row.iterationsPerSecond = 1000.0 * $count / $row.wallMs
        $row.requestsPerSecond = 6 * $row.iterationsPerSecond
        $row.errorRate = 0.0
    } catch {
        $row.status = 'failed'
        $row.failure = $_.Exception.Message
        throw
    } finally {
        try { Stop-Cli $cli JNA }
        catch {
            $row.status = 'failed'
            $row.shutdownFailure = $_.Exception.Message
            throw
        }
    }
    $row.status = 'passed'
}

function Summarize($sessions) {
    $byBackend = [ordered]@{}
    foreach ($backend in 'JNA', 'Cpp') {
        $columns = [ordered]@{}
        $rows = @($sessions | Where-Object { $_.backend -ceq $backend -and $_.status -ceq 'passed' })
        if (!$rows.Count) { continue }
        foreach ($row in $rows) {
            Add-UiaLatencies $columns $row.startup
            foreach ($sample in $row.samplesMs) {
                $times = [ordered]@{}
                for ($i = 0; $i -lt $sampleOrder.Count; $i++) { $times[$sampleOrder[$i]] = $sample[$i] }
                Add-UiaLatencies $columns $times
            }
        }
        $byBackend[$backend] = Get-UiaLatencySummary $columns
    }
    return $byBackend
}

$CppAgent = (Get-Item -LiteralPath $CppAgent).FullName
$sampleOrder = @('snapshot', 'findEdit', 'findButton', 'getElementInfo', 'setValue', 'invoke')
Initialize-UiaTools
$environment = Get-UiaEnvironment
Set-UiaBuildInfo $environment ''
if (Initialize-UiaHostProbe) { Set-UiaHostInfo $environment }
$environment.cppSha256 = (Get-FileHash -LiteralPath $CppAgent -Algorithm SHA256).Hash
$environment.cppBytes = (Get-Item -LiteralPath $CppAgent).Length
$environment.jarBytes = (Get-Item -LiteralPath $Jar).Length
$environment.javaLauncherBytes = (Get-Item -LiteralPath $javaExe).Length
$environment.uiaDllVersion = (Get-Item -LiteralPath (Join-Path $env:SystemRoot 'System32/UIAutomationCore.dll')).VersionInfo.FileVersion
$order = if ($CppFirst) { @('Cpp', 'JNA') } else { @('JNA', 'Cpp') }
$report = [ordered]@{ schema = 1; status = 'running'; startedUtc = [DateTime]::UtcNow.ToString('o');
    environment = $environment; jvmOptions = @('-XX:+UseSerialGC', '-Xms16m');
    options = [ordered]@{ pairs = $Pairs; iterations = $Iterations; warmup = $Warmup; soakSeconds = $SoakSeconds;
        soakPeriodMs = $SoakPeriodMs; actionIntervalMs = $ActionIntervalMs; initialOrder = $order.Clone() };
    sampleOrder = $sampleOrder; percentile = 'nearest rank, ceil(p*N), 1-based';
    short = (New-Object 'Collections.Generic.List[object]'); soak = (New-Object 'Collections.Generic.List[object]') }
try {
    Start-UiaFixture $false
    try {
        $parity = @{}
        foreach ($backend in $order) { $parity[$backend] = Test-Parity $backend }
        $jna = $parity.JNA
        $cpp = $parity.Cpp
        Verify ($jna.windowId -ceq $cpp.windowId -and ($jna.tree.content -join "`n") -ceq ($cpp.tree.content -join "`n")) 'WPF content tree differs.'
        $chromeMatches = ($jna.tree.chrome -join "`n") -ceq ($cpp.tree.chrome -join "`n")
        Test-ProviderLifetime $order
        $report.parity = [ordered]@{ passed = $true; jnaElements = $jna.count; cppElements = $cpp.count;
            contentElements = $cpp.tree.content.Count; jnaChromeElements = $jna.tree.chrome.Count;
            cppChromeElements = $cpp.tree.chrome.Count; chromeMatches = $chromeMatches;
            replacedControl = 'passed'; processExit = 'passed' }
        Write-Output ('WPF parity passed with {0} content elements and title-bar match={1}.' -f $cpp.tree.content.Count, $chromeMatches)
    } finally {
        try { Stop-UiaFixture $report } finally { $script:fixture = $null; Remove-UiaState }
    }
    if (!$ParityOnly) {
        # A borderless fixture gives both agents the same provider workload, including the absence of title-bar proxies.
        Initialize-UiaTools
        Start-UiaFixture $true
        $baseline = (Open-Agent JNA).cli
        try {
            $baselineWindow = Open-Window $baseline
            $baselineSnapshot = (Take-Snapshot $baseline $baselineWindow).result
            $benchmarkTree = Canonical-Tree $baselineSnapshot
            $benchmarkCount = Check-Snapshot $baselineSnapshot $baselineWindow 0
        } finally { Stop-Cli $baseline JNA }
        $report.benchmarkFixtureElements = $benchmarkCount
        for ($pair = 0; $pair -lt $Pairs; $pair++) {
            foreach ($backend in $order) {
                $run = [ordered]@{ pair = $pair + 1 }
                $report.short.Add($run)
                Measure-Agent $backend $run $Iterations 0
                Write-Output "Short pair $($pair + 1) $backend passed."
            }
            [array]::Reverse($order)
        }
        if ($SoakSeconds) {
            $soakCount = [int][Math]::Ceiling($SoakSeconds * 1000 / $SoakPeriodMs)
            Verify (2 * ($soakCount + $Warmup) -le 4096) 'Soak workload exceeds the session mutation ID limit.'
            $soakOrder = @($report.options.initialOrder[1], $report.options.initialOrder[0])
            foreach ($backend in $soakOrder) {
                $run = [ordered]@{}
                $report.soak.Add($run)
                Write-Output "Starting $backend soak with $soakCount iterations."
                Measure-Agent $backend $run $soakCount $SoakPeriodMs
                Write-Output "$backend soak passed."
            }
        }
    }
} catch {
    $report.status = 'failed'
    $report.failure = $_.Exception.Message
    throw
} finally {
    try {
        if ($fixture) { Stop-UiaFixture $report }
        if ($report.status -ceq 'running') { $report.status = 'passed' }
    } catch {
        $report.status = 'failed'
        $report.fixtureShutdownFailure = $_.Exception.Message
        throw
    } finally {
        Remove-UiaState
        $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
        $report.shortSummary = Summarize $report.short
        $report.soakSummary = Summarize $report.soak
        Save-UiaJson (ConvertTo-Json -InputObject $report -Depth 20) $OutputPath
    }
}
