# Assert the regression on a report from Windows with the observed empty-runtime-ID provider.
param([Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI and ConvertFrom-Json stops at 2 MB.
Add-Type -AssemblyName System.Web.Extensions
$serializer = New-Object Web.Script.Serialization.JavaScriptSerializer
$serializer.MaxJsonLength = [int]::MaxValue
$serializer.RecursionLimit = 200
$report = $serializer.DeserializeObject([IO.File]::ReadAllText((Resolve-Path -LiteralPath $ReportPath).Path))
$rows = @($report.results | Where-Object { $_.framework -ceq 'WinFormsFramework' })
if ($rows.Count -ne 2 -or @($rows | ForEach-Object { $_.backend } | Sort-Object -Unique).Count -ne 2) {
    throw 'A WinFormsFramework report for both backends is required.'
}
foreach ($row in $rows) {
    if (!$row.tree -or !$row.tree.truncated -or $row.tree.partialElements -lt 1) {
        throw "$($row.backend): expected a partial snapshot that names its partial elements instead of discarding the WinForms window."
    }
    $tree = @($row.checks | Where-Object { $_.name -ceq 'tree' })
    if ($tree.Count -ne 1 -or $tree[0].status -cne 'FAIL' -or $tree[0].classification -cne 'UIA_PROVIDER_LIMITATION' -or
        $tree[0].evidence.independentClient.unusableRuntimeIds -lt 1) {
        throw "$($row.backend): a partial window must never pass as a complete tree, and an independent client must show why."
    }
    $scopes = @($row.checks | Where-Object { $_.name -ceq 'partialSnapshotScopes' })
    if ($scopes.Count -ne 1 -or $scopes[0].status -cne 'PASS' -or $scopes[0].evidence.wholeWindowLookup -cne 'INCOMPLETE_SNAPSHOT' -or
        $scopes[0].evidence.wholeBranchLookup -cne 'OK' -or $scopes[0].evidence.partialBranchLookup -cne 'INCOMPLETE_SNAPSHOT' -or
        !$scopes[0].evidence.partialBranchRecaptureTruncated -or $scopes[0].evidence.wholeBranchRecapture.truncated) {
        throw "$($row.backend): lookup must be refused for the window and for a partial branch, and allowed in a branch captured whole."
    }
    $check = @($row.checks | Where-Object { $_.name -ceq 'basicActionsInCompleteScopes' })
    if ($check.Count -ne 1 -or $check[0].status -cne 'PASS' -or !$check[0].evidence.fullLocatorRejected) {
        throw "$($row.backend): the incomplete locator must be blocked and scoped action postconditions must pass."
    }
}
