param(
    [string]$FixtureJava = 'java.exe',
    [string]$Classes = (Join-Path $PSScriptRoot '../../../target/framework-fixtures/swing-awt')
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../../tools/UiaTest.Common.ps1')

$stateDir = $null
$fixture = $null
$failureMessage = $null
try {
    if (-not [Environment]::Is64BitProcess -or -not [Environment]::UserInteractive) {
        throw 'Run the action proof with 64-bit PowerShell on an interactive Windows desktop.'
    }
    $classesPath = (Resolve-Path -LiteralPath $Classes).ProviderPath
    if (-not [IO.File]::Exists((Join-Path $classesPath 'FrameworkFixture.class'))) {
        throw 'Build the Swing fixture before running the Java Access Bridge action proof.'
    }
    $java = Get-Command $FixtureJava -CommandType Application | Select-Object -First 1

    Add-Type -Path @(
        (Join-Path $PSScriptRoot 'ReadOnlyJavaAccessBridge.cs'),
        (Join-Path $PSScriptRoot 'FixtureJavaAccessBridgeAction.cs')
    )

    $stateDir = Join-Path ([IO.Path]::GetTempPath()) ('swing-bridge-proof-' + [guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($stateDir)
    $title = 'Swing bridge counter proof ' + [guid]::NewGuid().ToString('N')
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $java.Source
    $start.Arguments = '-Djavax.accessibility.assistive_technologies=com.sun.java.accessibility.AccessBridge ' +
        ('-cp "{0}" FrameworkFixture swing "{1}" "{2}"' -f $classesPath, $stateDir, $title)
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $fixture = [Diagnostics.Process]::Start($start)
    [void]$fixture.StandardOutput.ReadToEndAsync()
    [void]$fixture.StandardError.ReadToEndAsync()

    $fixturePid = $fixture.Id
    Wait-State 'ready' ([string]$fixturePid) 12000
    $fixture.Refresh()
    $hwnd = $fixture.MainWindowHandle
    if ((Read-State 'framework.txt') -cnotmatch '^Swing / ' -or
        $fixture.ProcessName -cne 'java' -or $hwnd -eq [IntPtr]::Zero -or
        $fixture.MainWindowTitle -cne $title -or $fixture.SessionId -ne (Get-Process -Id $PID).SessionId) {
        throw 'The started Swing fixture does not own the expected main window in this desktop session.'
    }
    $dll = Join-Path (Split-Path -Parent $fixture.MainModule.FileName) 'windowsaccessbridge-64.dll'
    if (-not [IO.File]::Exists($dll)) {
        throw 'Java Access Bridge DLL is missing from the fixture Java installation.'
    }

    $before = [int](Read-State 'count.txt')
    if ($before -ne 0) { throw 'The new Swing fixture counter did not start at zero.' }
    $expected = [string]($before + 1)
    $launchCommand = '"{0}" {1}' -f $start.FileName, $start.Arguments
    [ReadOnlyJavaAccessBridge]::InvokeFixtureCounter($dll, $hwnd, $fixturePid, $launchCommand, $stateDir, $title)

    Wait-State 'count.txt' $expected 3000
    $after = [int](Read-State 'count.txt')
    if ($after -ne ($before + 1)) { throw 'The Swing fixture counter changed by a value other than one.' }
} catch {
    $failureMessage = $_.Exception.GetBaseException().Message
} finally {
    if ($fixture) {
        try {
            if (!$fixture.HasExited) {
                [IO.File]::WriteAllText((Join-Path $stateDir 'close-fixture'), '')
                if (!$fixture.WaitForExit(4000)) {
                    $fixture.Kill()
                    [void]$fixture.WaitForExit(2000)
                    throw 'The Swing fixture did not exit through its close command.'
                }
            }
            if ($fixture.ExitCode -ne 0) { throw "Swing fixture exited with status $($fixture.ExitCode)." }
            if (!$failureMessage -and (Read-State 'count.txt') -cne $expected) {
                throw 'The Swing fixture counter changed again before shutdown.'
            }
        } catch {
            if (!$fixture.HasExited) {
                $fixture.Kill()
                [void]$fixture.WaitForExit(2000)
            }
            if (!$failureMessage) { $failureMessage = $_.Exception.GetBaseException().Message }
        } finally {
            $fixture.Dispose()
        }
    }
    try { Remove-UiaState }
    catch { if (!$failureMessage) { $failureMessage = $_.Exception.GetBaseException().Message } }
}

if ($failureMessage) {
    [Console]::Error.WriteLine($failureMessage)
    exit 1
}
[ordered]@{ pid = $fixturePid; hwnd = $hwnd.ToInt64(); countBefore = $before; countAfter = $after; fixtureExitCode = 0 } |
    ConvertTo-Json -Compress
