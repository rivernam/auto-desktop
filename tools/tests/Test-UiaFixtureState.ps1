# Verify the fixture's file publication protocol without starting a desktop window.
$ErrorActionPreference = 'Stop'
$fixture = Join-Path $PSScriptRoot '../../src/test/resources/windows-gui-fixture.ps1'
$tokens = $parseErrors = $null
$script = [System.Management.Automation.Language.Parser]::ParseFile($fixture, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors) { throw $parseErrors[0].Message }
$writer = $script.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-State'
}, $false)
if (!$writer) { throw 'Fixture state writer was not found.' }
. ([scriptblock]::Create($writer.Extent.Text))

$StateDirectory = Join-Path ([IO.Path]::GetTempPath()) ("uia-state-test-" + [Guid]::NewGuid())
[void][IO.Directory]::CreateDirectory($StateDirectory)
$path = Join-Path $StateDirectory 'count.txt'
try {
    Write-State 'count.txt' '1'
    # The previous update opened the shared file for writing. A reader allowing
    # delete but denying writes demonstrates the Windows sharing violation.
    $share = [IO.FileShare]::Read -bor [IO.FileShare]::Delete
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
    $reader = New-Object IO.StreamReader($stream)
    try {
        Write-State 'count.txt' '2'
        if ($reader.ReadToEnd() -cne '1' -or [IO.File]::ReadAllText($path) -cne '2') {
            throw 'The active reader and the newly opened file must each see a complete version.'
        }
    } finally { $reader.Dispose() }
} finally {
    foreach ($file in [IO.Directory]::GetFiles($StateDirectory)) { [IO.File]::Delete($file) }
    [IO.Directory]::Delete($StateDirectory)
}
Write-Output 'Fixture state publication passed with a concurrent reader.'
