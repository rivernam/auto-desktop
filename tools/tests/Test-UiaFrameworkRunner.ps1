# Exercise skip reporting and status aggregation without a desktop or fixture binaries.
$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot '../Test-UiaFrameworks.ps1'
$output = Join-Path ([IO.Path]::GetTempPath()) ('uia-framework-tests-' + [guid]::NewGuid() + '.json')
$missing = Join-Path ([IO.Path]::GetTempPath()) ('missing-fixtures-' + [guid]::NewGuid())
$noArtifacts = @{ FixtureRoot = $missing; Jar = (Join-Path $missing 'agent.jar'); CppAgent = (Join-Path $missing 'agent.exe') }
try {
    & $runner -Framework @('DelphiVcl', 'Qt') -Backend Both @noArtifacts -OutputPath $output
    $report = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
    if ($report.status -cne 'NOT_RUN' -or $report.counts.NOT_RUN -ne 4 -or $report.results.Count -ne 4) {
        throw 'Every selected framework and backend must be accounted for when no fixture can run.'
    }
    foreach ($row in $report.results) {
        if ($row.status -cne 'NOT_RUN' -or !$row.reason) { throw 'A skipped backend must have a reason.' }
    }
    & $runner -Framework DelphiVcl -Backend Cpp -Mode Performance @noArtifacts -OutputPath $output
    $report = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
    if ($report.mode -cne 'Performance' -or $report.counts.NOT_RUN -ne 1 -or $report.results[0].backend -cne 'Cpp') {
        throw 'The report must preserve the selected mode and backend.'
    }
} finally { [IO.File]::Delete($output) }

# Verify the exact command lines without spawning a process.
. (Join-Path $PSScriptRoot '../UiaTest.Common.ps1')
. (Join-Path $PSScriptRoot '../UiaFrameworkCases.ps1')
& {
    function Start-Cli($start) { return $start.Arguments }
    $fixture = @{ Id = 4242 }
    $javaExe = 'java.exe'
    $Jar = 'test-agent.jar'
    $CppAgent = 'test-agent.exe'
    foreach ($backend in 'JNA', 'Cpp') {
        $allowed = (Start-FrameworkAgent $backend).cli
        $denied = (Start-FrameworkAgent $backend -WithoutPid).cli
        if ($allowed -notmatch '(?:^| )--allow-pid 4242(?: |$)' -or
            $denied -match '(?:^| )--allow-pid(?: |$)' -or $denied -notmatch '--allow-action invoke') {
            throw "Invalid launch arguments for the $backend process permission case."
        }
    }
}
