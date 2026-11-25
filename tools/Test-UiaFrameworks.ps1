# Run on a test desktop. Mutations are authorized only for the fixture launched by this script.
[CmdletBinding()]
param(
    [ValidateSet('Win32', 'Mfc', 'DelphiVcl', 'Swing', 'Awt', 'Wpf', 'WinFormsFramework', 'WinFormsModern', 'Qt', 'ChromiumElectron', 'CustomRendering')]
    [string[]]$Framework = @('Win32', 'Mfc', 'DelphiVcl', 'Swing', 'Awt', 'Wpf', 'WinFormsFramework', 'WinFormsModern'),
    # Jab and CppJab select the Java Access Bridge backend of the Java and C++ Agents. BothJab runs the two.
    [ValidateSet('JNA', 'Cpp', 'Both', 'Jab', 'CppJab', 'BothJab')][string]$Backend = 'Both',
    [ValidateSet('Functional', 'Performance')][string]$Mode = 'Functional',
    [string]$Jar = 'target/desktop-agent.jar',
    [string]$CppAgent = 'target/cpp-agent/Release/cpp-agent.exe',
    [string]$FixtureRoot = 'target/framework-fixtures',
    [string]$FixtureJava = 'java.exe',
    [string]$OutputPath = 'target/uia-frameworks.json',
    [string[]]$JvmOptions = @('-XX:+UseSerialGC', '-Xms16m'),
    [ValidateRange(1, 10)][int]$Pairs = 2,
    [ValidateRange(1, 100)][int]$Iterations = 8,
    [ValidateRange(0, 10)][int]$Warmup = 2,
    [switch]$CppFirst,
    [switch]$EnableJab,
    # Java Access Bridge runs: an explicit bridge library, a second Java runtime for the multi-JVM check,
    # and the 121 s wait that proves reference expiry.
    [string]$JabDll,
    [string]$SecondFixtureJava,
    [switch]$IncludeExpiry,
    [switch]$DiagnoseAccessibility,
    [switch]$RequirePass
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UiaTest.Common.ps1')
. (Join-Path $PSScriptRoot 'UiaFrameworkCases.ps1')
. (Join-Path $PSScriptRoot 'JabFrameworkCases.ps1')
$bridgeRun = $Backend -in 'Jab', 'CppJab', 'BothJab'

function Get-FrameworkLaunch([string]$name) {
    $wpf = Join-Path $PSScriptRoot '../src/test/resources/windows-gui-fixture.ps1'
    $location = switch ($name) {
        Win32 { 'win32.exe' }
        Mfc { 'mfc.exe' }
        DelphiVcl { 'delphi-vcl.exe' }
        { $_ -in 'Swing', 'Awt' } { 'swing-awt/FrameworkFixture.class' }
        WinFormsFramework { 'winforms-framework.exe' }
        WinFormsModern { 'winforms-modern/WinFormsFixture.exe' }
    }
    if ($name -eq 'Wpf') {
        $exe = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        return @{ executable = $exe; before = "-NoProfile -NonInteractive -STA -ExecutionPolicy RemoteSigned -File ""$wpf""";
            after = ' -Extended'; source = $wpf }
    }
    if (!$location) { return @{ reason = 'No fixture is configured for this priority group.' } }
    $binary = Join-Path $FixtureRoot $location
    if (![IO.File]::Exists($binary)) { return @{ reason = "Fixture build output missing: $location" } }
    if ($name -in 'Swing', 'Awt') {
        $java = Get-Command $FixtureJava -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (!$java) { return @{ reason = 'Fixture Java runtime missing.' } }
        $classPath = [IO.Path]::GetDirectoryName($binary)
        # The bridge is enabled for this fixture process only. No user or system setting is changed.
        $jab = if ($EnableJab -or $bridgeRun) { '-Djavax.accessibility.assistive_technologies=com.sun.java.accessibility.AccessBridge ' }
        return @{ executable = $java.Source; before = "$jab-cp ""$classPath"" FrameworkFixture $($name.ToLowerInvariant())";
            source = $binary; version = (Read-Diagnostic $java.Source '-version').stderr }
    }
    return @{ executable = $binary; source = $binary }
}

function Start-FrameworkFixture($launch) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $launch.executable
    $start.Arguments = "$($launch.before) ""$stateDir"" ""$title""$($launch.after)"
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $script:fixture = [Diagnostics.Process]::Start($start)
    $script:fixtureOutput = $fixture.StandardOutput.ReadToEndAsync()
    $script:fixtureErrors = $fixture.StandardError.ReadToEndAsync()
    Wait-State 'ready' ([string]$fixture.Id)
}

function Stop-FrameworkFixture($record) {
    if (!$fixture) { return }
    try {
        if (!$fixture.HasExited) {
            [IO.File]::WriteAllText((Join-Path $stateDir 'close-fixture'), '')
            if (!$fixture.WaitForExit(5000)) {
                $fixture.Kill()
                [void]$fixture.WaitForExit(5000)
                throw 'Fixture failed to close after its close marker.'
            }
        }
        if ($fixture.ExitCode -ne 0) { throw "Fixture exited with status $($fixture.ExitCode)." }
    } finally {
        try {
            if ($fixture.HasExited) { $record.exitCode = $fixture.ExitCode }
            foreach ($stream in @{ stdout = $fixtureOutput; stderr = $fixtureErrors }.GetEnumerator()) {
                if ($stream.Value -and $stream.Value.Wait(3000)) {
                    $contents = $stream.Value.Result
                    if ($contents) { $record[$stream.Key] = $contents.Substring([Math]::Max(0, $contents.Length - 8192)) }
                }
            }
        } finally { $fixture.Dispose(); $script:fixture = $null }
    }
}

function Get-FrameworkStatus($rows) {
    $status = @($rows | ForEach-Object status)
    if ($status -contains 'PARTIAL' -or ($status -contains 'PASS' -and @($status | Where-Object { $_ -ne 'PASS' }).Count)) {
        return 'PARTIAL'
    }
    foreach ($possible in 'FAIL', 'INCONCLUSIVE', 'PASS') {
        if ($status -contains $possible) { return $possible }
    }
    return 'NOT_RUN'
}

function Get-FrameworkCounts($rows) {
    $counts = [ordered]@{ PASS = 0; PARTIAL = 0; FAIL = 0; NOT_RUN = 0; INCONCLUSIVE = 0 }
    foreach ($row in $rows) { $counts[$row.status]++ }
    return $counts
}

function Get-PeArchitecture($path) {
    $stream = [IO.File]::OpenRead($path)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        $stream.Position = 60
        $stream.Position = $reader.ReadInt32() + 4
        switch ($reader.ReadUInt16()) {
            0x014c { 'x86 PE' }
            0x8664 { 'x64 PE' }
            0xaa64 { 'ARM64 PE' }
        }
    } finally { $stream.Dispose() }
}

function Get-FrameworkEnvironment {
    $info = Get-UiaEnvironment
    $info.sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $info.remoteSession = $env:SESSIONNAME -like 'RDP-*'
    $info.driverBitness = [IntPtr]::Size * 8
    $info.git = Get-UiaGitInfo
    $info.javaAgentOptions = $JvmOptions
    $info.jab = [ordered]@{ fixtureProcessOverride = [bool]($EnableJab -or $bridgeRun); registryOrUserSettingsChanged = $false }
    if ($env:OS -eq 'Windows_NT') {
        $nt = Get-ItemProperty 'HKLM:/SOFTWARE/Microsoft/Windows NT/CurrentVersion' -ErrorAction SilentlyContinue
        $info.windows = @{ edition = $nt.EditionID; version = $nt.DisplayVersion; build = "$($nt.CurrentBuildNumber).$($nt.UBR)" }
        $net = Get-ItemProperty 'HKLM:/SOFTWARE/Microsoft/NET Framework Setup/NDP/v4/Full' -ErrorAction SilentlyContinue
        $info.netFramework = @{ release = $net.Release; version = $net.Version }
        $uiaDll = Join-Path $env:SystemRoot 'System32/UIAutomationCore.dll'
        if ([IO.File]::Exists($uiaDll)) { $info.uiaDllVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($uiaDll).FileVersion }
        $accessibility = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.accessibility.properties'
        if ([IO.File]::Exists($accessibility)) {
            $info.jab.userConfigMentionsBridge = [bool]([IO.File]::ReadAllText($accessibility) -match 'com\.sun\.java\.accessibility\.AccessBridge')
        }
        $info.interactiveDesktop = Test-FrameworkDesktop
        if ($info.interactiveDesktop) { $info.monitorCount = [FrameworkInputDesktop]::MonitorCount() }
        if (Initialize-UiaHostProbe) { Set-UiaHostInfo $info }
    }
    if ($javaExe) {
        $info.java = (Read-Diagnostic $javaExe '-version').stderr
        $info.javaLauncher = Get-PeArchitecture $javaExe
    }
    if ([IO.File]::Exists($CppAgent)) {
        $info.cppAgent = @{ architecture = Get-PeArchitecture $CppAgent; sha256 = (Get-FileHash -LiteralPath $CppAgent).Hash }
        $cache = Join-Path (Split-Path (Split-Path $CppAgent)) 'CMakeCache.txt'
        if ([IO.File]::Exists($cache)) {
            # Windows PowerShell 5.1 attaches provider objects to each line that Get-Content returns, and
            # ConvertTo-Json then walks them to the full report depth. Keep plain strings.
            $info.cppAgent.build = @(Get-Content -LiteralPath $cache | Where-Object {
                $_ -match '^CMAKE_(GENERATOR|GENERATOR_PLATFORM|GENERATOR_TOOLSET|CXX_FLAGS_RELEASE):'
            } | ForEach-Object { "$_" })
        }
        $system = Join-Path (Split-Path (Split-Path $CppAgent)) 'CMakeFiles'
        if (Test-Path -LiteralPath $system -PathType Container) {
            $info.cppAgent.compiler = @(Get-ChildItem -LiteralPath $system -Filter CMakeCXXCompiler.cmake -Recurse |
                Select-String -Pattern '^set\(CMAKE_CXX_COMPILER_(ID|VERSION) ' | ForEach-Object Line | Sort-Object -Unique)
        }
    }
    if ([IO.File]::Exists($Jar)) { $info.jarSha256 = (Get-FileHash -LiteralPath $Jar).Hash }
    return $info
}

function Test-FrameworkDesktop {
    if (![Environment]::UserInteractive -or [Diagnostics.Process]::GetCurrentProcess().SessionId -eq 0) { return $false }
    try {
        if (!('FrameworkInputDesktop' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class FrameworkInputDesktop {
    [DllImport("user32.dll")] private static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] private static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern bool GetUserObjectInformation(IntPtr desktop, int index, StringBuilder name, int bytes, out uint needed);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint owner);
    [DllImport("user32.dll")] private static extern bool IsIconic(IntPtr window);
    [DllImport("user32.dll")] private static extern bool ShowWindowAsync(IntPtr window, int command);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(IntPtr window);
    [DllImport("user32.dll")] private static extern int GetSystemMetrics(int index);
    private static IntPtr OwnedWindow(long handle, uint pid) {
        var window = new IntPtr(handle);
        uint owner;
        if (pid == 0 || GetWindowThreadProcessId(window, out owner) == 0 || owner != pid)
            throw new InvalidOperationException("The HWND does not belong to the fixture.");
        return window;
    }
    public static void SetMinimized(long handle, uint pid, bool minimized) {
        if (!ShowWindowAsync(OwnedWindow(handle, pid), minimized ? 7 : 4))  // SW_SHOWMINNOACTIVE / SW_SHOWNOACTIVATE: no focus change for the PC's user
            throw new InvalidOperationException("The fixture did not receive a window visibility request.");
    }
    public static bool Minimized(long handle, uint pid) { return IsIconic(OwnedWindow(handle, pid)); }
    public static uint Dpi(long handle, uint pid) { return GetDpiForWindow(OwnedWindow(handle, pid)); }
    public static int MonitorCount() { return GetSystemMetrics(80); }
    public static bool IsDefault() {
        IntPtr desktop = OpenInputDesktop(0, false, 1);
        if (desktop == IntPtr.Zero) return false;
        try {
            var name = new StringBuilder(128);
            uint needed;
            return GetUserObjectInformation(desktop, 2, name, name.Capacity * 2, out needed) &&
                String.Equals(name.ToString(), "Default", StringComparison.OrdinalIgnoreCase);
        } finally { CloseDesktop(desktop); }
    }
}
'@
        }
        return [FrameworkInputDesktop]::IsDefault()
    } catch { return $false }
}

$FixtureRoot = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($FixtureRoot)
$Jar = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Jar)
$CppAgent = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($CppAgent)
$javaExe = (Get-Command java.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
$order = if ($Backend -eq 'Both') { @('JNA', 'Cpp') } elseif ($Backend -eq 'BothJab') { @('Jab', 'CppJab') } else { @($Backend) }
if ($CppFirst) { [array]::Reverse($order) }
if ($JabDll) { $JabDll = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($JabDll) }
if ($SecondFixtureJava) { $SecondFixtureJava = (Get-Command $SecondFixtureJava -CommandType Application | Select-Object -First 1).Source }
$report = [ordered]@{
    schema = 2; mode = $Mode; startedUtc = [DateTime]::UtcNow.ToString('o')
    options = @{ frameworks = $Framework; order = $order; pairs = $Pairs; iterations = $Iterations; warmup = $Warmup;
        fixtureRoot = $FixtureRoot; fixtureJava = $FixtureJava; enableJab = [bool]($EnableJab -or $bridgeRun);
        jabDll = $JabDll; secondFixtureJava = $SecondFixtureJava; includeExpiry = [bool]$IncludeExpiry;
        accessibilityDiagnostics = [bool]$DiagnoseAccessibility }
    invocation = $MyInvocation.Line
    environment = Get-FrameworkEnvironment
    results = New-Object 'Collections.Generic.List[object]'
    comparisons = New-Object 'Collections.Generic.List[object]'
}

try {
    foreach ($name in ($Framework | Select-Object -Unique)) {
        $launch = if ($env:OS -eq 'Windows_NT') { Get-FrameworkLaunch $name } else { @{ reason = 'Windows is required.' } }
        $fixtureRecord = [ordered]@{ framework = $name; source = $launch.source }
        $rows = @(
            foreach ($implementation in $order) {
                $row = [ordered]@{ framework = $name; backend = $implementation; status = 'NOT_RUN'; fixture = $fixtureRecord }
                if ($launch.reason) { $row.reason = $launch.reason }
                elseif (!$report.environment.interactiveDesktop) { $row.reason = 'An unlocked interactive Windows desktop is required.' }
                elseif ((Test-JabBackend $implementation) -and $name -notin 'Swing', 'Awt') { $row.reason = 'Java Access Bridge serves AWT and Swing windows only.' }
                elseif ($implementation -in 'JNA', 'Jab' -and (!$javaExe -or ![IO.File]::Exists($Jar))) { $row.reason = 'JNA runtime or JAR is missing.' }
                elseif ($implementation -in 'Cpp', 'CppJab' -and ![IO.File]::Exists($CppAgent)) { $row.reason = 'C++ Agent executable is missing.' }
                $report.results.Add($row)
                $row
            }
        )
        $eligible = @($rows | Where-Object { !$_.reason })
        if (!$eligible.Count) {
            foreach ($row in $rows) { Write-Output "$name $($row.backend) $($row.status): $($row.reason)" }
            continue
        }

        $script:stateDir = Join-Path ([IO.Path]::GetTempPath()) ('uia-framework-' + [guid]::NewGuid())
        $script:title = "UIA $name fixture " + [guid]::NewGuid()
        [void][IO.Directory]::CreateDirectory($stateDir)
        try {
            Start-FrameworkFixture $launch
            $fixtureRecord.pid = $fixture.Id
            $fixtureRecord.title = $title
            $fixtureRecord.launcherArchitecture = Get-PeArchitecture $launch.executable
            if ($launch.version) { $fixtureRecord.runtime = $launch.version }
            if ([IO.File]::Exists((Join-Path $stateDir 'framework.txt'))) { $fixtureRecord.runtime = Read-State 'framework.txt' }
            if ([IO.File]::Exists((Join-Path $stateDir 'runtime.txt'))) { $fixtureRecord.runtime = Read-State 'runtime.txt' }
            $fixtureRecord.sha256 = (Get-FileHash -LiteralPath $launch.source).Hash
            $spec = if ($bridgeRun) { Get-JabSpec } else { Get-FrameworkSpec $name }
            if ($bridgeRun) { $fixtureRecord.bridge = Get-JabEnvironment $launch }
            if ($eligible.Count -eq 2) {
                foreach ($row in $eligible) { Read-FrameworkBaseline $row }
                $report.comparisons.Add((Compare-FrameworkTrees $name $eligible))
            }
            foreach ($row in $eligible) {
                if ($bridgeRun) { Invoke-JabFunction $row $spec $launch } else { Invoke-FrameworkFunction $row $spec }
            }
            $observedWindow = ($eligible | Where-Object { $_.windowId } | Select-Object -First 1).windowId
            if ($observedWindow -match '^\d+$') {
                try { $fixtureRecord.effectiveDpi = [FrameworkInputDesktop]::Dpi([long]$observedWindow, $fixture.Id) } catch {}
            }
            if ($DiagnoseAccessibility) { $fixtureRecord.accessibility = Get-FrameworkAccessibility $name $eligible }
            if ($Mode -eq 'Performance') { Measure-FrameworkSessions $eligible $spec }
            if ($bridgeRun) { Test-JabLifetime $eligible $launch } else { Test-FrameworkLifetime $eligible }
        } catch {
            foreach ($row in $eligible) {
                $row.status = 'FAIL'
                $row.reason = $_.Exception.Message
            }
        } finally {
            try { Stop-FrameworkFixture $fixtureRecord }
            catch {
                foreach ($row in $eligible) { $row.status = 'FAIL'; $row.reason = $_.Exception.Message }
            } finally { Remove-UiaState }
        }
        foreach ($row in $rows) { Write-Output "$name $($row.backend) $($row.status)" }
        Save-UiaCheckpoint $report $OutputPath
    }
} finally {
    $report.functionalStatus = Get-FrameworkStatus $report.results
    $report.parityStatus = Get-FrameworkStatus $report.comparisons
    $requiredStatuses = @(@{ status = $report.functionalStatus })
    if ($report.comparisons.Count) { $requiredStatuses += @{ status = $report.parityStatus } }
    if ($Mode -eq 'Performance') {
        $measurements = foreach ($row in $report.results) {
            if ($row.performance) { $row.performance } else { @{ status = 'NOT_RUN' } }
        }
        $report.performanceStatus = Get-FrameworkStatus $measurements
        $requiredStatuses += @{ status = $report.performanceStatus }
    }
    $report.status = Get-FrameworkStatus $requiredStatuses
    $report.counts = Get-FrameworkCounts $report.results
    $checks = @($report.results | ForEach-Object { $_.checks } | Where-Object { $null -ne $_ })
    $report.checkCounts = Get-FrameworkCounts $checks
    # Every check that did not pass names its cause. UNCLASSIFIED ones are open questions about the Agent.
    $report.classificationCounts = [ordered]@{}
    foreach ($group in $checks | Where-Object { $_.classification } | Group-Object { $_.classification } | Sort-Object Name) {
        $report.classificationCounts[$group.Name] = $group.Count
    }
    $report.finishedUtc = [DateTime]::UtcNow.ToString('o')
    Save-UiaJson (ConvertTo-Json -InputObject $report -Depth 30) $OutputPath
}
if ($RequirePass -and ($report.status -ne 'PASS' -or @($report.comparisons | Where-Object status -NE 'PASS').Count -or
    ($Mode -eq 'Performance' -and @($report.results | Where-Object { $_.performance.status -ne 'PASS' }).Count))) {
    throw "Framework verification did not fully pass. See $OutputPath."
}
