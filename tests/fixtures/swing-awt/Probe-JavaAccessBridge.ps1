param(
    [Parameter(Mandatory)][string]$StateDirectory,
    [Parameter(Mandatory)][string]$WindowTitle
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if (-not [Environment]::Is64BitProcess) {
    throw 'Run the bridge probe with 64-bit PowerShell and a 64-bit Java fixture.'
}

$framework = [IO.File]::ReadAllText((Join-Path $StateDirectory 'framework.txt'))
if ($framework -notmatch '^(Swing|AWT) / ') {
    throw 'The state directory must belong to a Swing or AWT fixture.'
}
$fixturePid = [int][IO.File]::ReadAllText((Join-Path $StateDirectory 'ready'))
$fixture = Get-Process -Id $fixturePid
$hwnd = $fixture.MainWindowHandle
if ($fixture.ProcessName -ne 'java' -or $hwnd -eq [IntPtr]::Zero -or
    $fixture.MainWindowTitle -cne $WindowTitle) {
    throw 'The fixture PID does not own the expected main window.'
}

$dll = Join-Path (Split-Path -Parent $fixture.Path) 'windowsaccessbridge-64.dll'
if (-not [IO.File]::Exists($dll)) {
    throw "Java Access Bridge DLL missing from the fixture's Java installation: $dll"
}

Add-Type -Path (Join-Path $PSScriptRoot 'ReadOnlyJavaAccessBridge.cs')
try { $result = [ReadOnlyJavaAccessBridge]::Read($dll, $hwnd, $fixturePid) }
catch {
    [Console]::Error.WriteLine($_.Exception.GetBaseException().Message)
    exit 1
}
[ordered]@{
    framework = $framework
    pid = $fixturePid
    hwnd = $hwnd.ToInt64()
    truncated = $result.Truncated
    nodes = $result.Nodes
} | ConvertTo-Json -Depth 4
