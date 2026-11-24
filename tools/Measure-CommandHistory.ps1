# Measures the actual Java and C++ command history stores without a native provider.
[CmdletBinding()]
param(
    [string]$Jar = 'target/desktop-agent.jar',
    [string]$JavaTestClasses = 'target/test-classes',
    [string]$CppTest = 'target/cpp-agent/Release/agent-core-test.exe',
    [string]$OutputPath = 'target/command-history-memory.json'
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UiaTest.Common.ps1')
$java = (Get-Command java.exe -CommandType Application | Select-Object -First 1).Source
$classes = "$(Resolve-Path -LiteralPath $JavaTestClasses);$(Resolve-Path -LiteralPath $Jar)"
$cpp = (Resolve-Path -LiteralPath $CppTest).Path
$started = [DateTime]::UtcNow
$report = [ordered]@{ startedUtc = $started.ToString('o'); git = Get-UiaGitInfo
    environment = Get-UiaEnvironment; java = (Read-Diagnostic $java '-version').stderr
    cppTestSha256 = (Get-FileHash -LiteralPath $cpp).Hash; jarSha256 = (Get-FileHash -LiteralPath $Jar).Hash
    javaProbeSha256 = (Get-FileHash -LiteralPath (Join-Path $JavaTestClasses 'dev/desktop/HistoryMemoryProbe.class')).Hash
    runs = @(foreach ($implementation in 'Java','Cpp') {
        foreach ($length in 36,128) {
            foreach ($mode in 'control','retain') {
                $start = New-Object Diagnostics.ProcessStartInfo
                $start.UseShellExecute = $false
                $start.CreateNoWindow = $true
                $start.RedirectStandardInput = $true
                $start.RedirectStandardOutput = $true
                $start.RedirectStandardError = $true
                $start.FileName = if ($implementation -eq 'Java') { $java } else { $cpp }
                $start.Arguments = if ($implementation -eq 'Java') {
                    "-XX:+UseSerialGC -Xms16m -Xmx64m -cp `"$classes`" dev.desktop.HistoryMemoryProbe $length $mode"
                } else { "--history-memory $length $mode" }
                $probe = Start-Cli $start
                try {
                    $samples = @(foreach ($expected in 0,512,1024,2048,4096) {
                        $line = $probe.StandardOutput.ReadLineAsync()
                        if (!$line.Wait(10000) -or !$line.Result) { throw "No sample from $implementation $mode." }
                        $sample = $line.Result | ConvertFrom-Json
                        if ($sample.generated -ne $expected) { throw "Probe sample out of order." }
                        [ordered]@{ generated = $sample.generated; stored = $sample.stored
                            heapUsedBytes = $sample.heapUsedBytes; process = Process-Sample $probe }
                        $probe.StandardInput.WriteLine()
                        $probe.StandardInput.Flush()
                    })
                    if (!$probe.WaitForExit(5000) -or $probe.ExitCode -ne 0) { throw "Probe $implementation failed." }
                    [ordered]@{ agent = $implementation; idLength = $length; mode = $mode; samples = $samples }
                } finally {
                    if (!$probe.HasExited) { $probe.Kill(); [void]$probe.WaitForExit(5000) }
                    $probe.Dispose()
                }
            }
        }
    })
}
$report.finishedUtc = [DateTime]::UtcNow.ToString('o')
Save-UiaJson (ConvertTo-Json -InputObject $report -Depth 10) $OutputPath
