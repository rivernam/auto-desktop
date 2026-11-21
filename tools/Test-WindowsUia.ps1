# Run from an unlocked Windows 10/11 test desktop with Maven and JDK 17+ on PATH.
[CmdletBinding()]
param(
    [string]$CSharpWorker,
    [switch]$BuildWorker,
    [switch]$IncludeJna
)
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT' -or ![Environment]::UserInteractive) {
    throw 'Run in an interactive Windows 10/11 test session.'
}
$root = (Get-Item -LiteralPath (Join-Path $PSScriptRoot '..')).FullName
Push-Location $root
try {
    if ($BuildWorker) {
        & msbuild.exe 'workers/csharp/UiaWorker.csproj' '/p:Configuration=Release'
        if ($LASTEXITCODE -ne 0) { throw 'C# worker build failed.' }
    }
    if (!$CSharpWorker) { $CSharpWorker = 'workers/csharp/bin/Release/UiaWorker.exe' }
    $workerPath = (Get-Item -LiteralPath $CSharpWorker).FullName
    $report = 'target/surefire-reports/TEST-dev.desktop.WindowsGuiTest.xml'
    $jnaEnabled = $IncludeJna.IsPresent.ToString().ToLowerInvariant()
    & mvn.cmd clean verify "-Ddesktop.jnaIT=$jnaEnabled" '-Ddesktop.windowsIT=true' '-Ddesktop.csharpIT=true' "-Ddesktop.csharpWorker=$workerPath"
    if ($LASTEXITCODE -ne 0) { throw 'Maven verification failed. See target/surefire-reports.' }
    [xml]$suite = Get-Content -Raw -LiteralPath $report
    $tests = $suite.testsuite
    $expected = @('operatesDedicatedWpfWindowWithoutMovingPhysicalCursor',
        'csharpWorkerOperatesDedicatedWpfWindowWithoutMovingPhysicalCursor')
    $jnaCase = 'jnaOperatesDedicatedWpfWindowWithoutMovingPhysicalCursor'
    if ($IncludeJna) { $expected += $jnaCase }
    $passed = @($tests.SelectNodes('testcase[not(skipped or error or failure)]') | ForEach-Object { $_.name })
    $skipped = @($tests.SelectNodes('testcase[skipped]') | ForEach-Object { $_.name })
    if ([int]$tests.failures -ne 0 -or [int]$tests.errors -ne 0 -or
        @(Compare-Object $expected $passed).Count -ne 0 -or
        ($IncludeJna -and $skipped.Count -ne 0) -or
        (!$IncludeJna -and ($skipped.Count -ne 1 -or $skipped[0] -ne $jnaCase))) {
        throw 'The GUI test report does not match the selected backends.'
    }
    [ordered]@{
        utc = [DateTime]::UtcNow.ToString('o')
        os = (Get-CimInstance Win32_OperatingSystem).Caption
        build = [Environment]::OSVersion.Version.ToString()
        os64 = [Environment]::Is64BitOperatingSystem
        powershell = $PSVersionTable.PSVersion.ToString()
        workerSha256 = (Get-FileHash -LiteralPath $workerPath -Algorithm SHA256).Hash
        java = ($tests.properties.property | Where-Object { $_.name -eq 'java.runtime.version' }).value
        guiCases = $passed
        skippedGuiCases = $skipped
    } | ConvertTo-Json | Set-Content -Encoding UTF8 'target/windows-uia-run.json'
    Write-Output "Verified $($passed.Count) Windows GUI cases. See $report and target/windows-uia-run.json."
} finally {
    Pop-Location
}
