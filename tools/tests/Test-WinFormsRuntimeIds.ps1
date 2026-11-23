# Assert the regression on a report from Windows with the observed empty-runtime-ID provider.
param([Parameter(Mandatory)][string]$ReportPath)
$ErrorActionPreference = 'Stop'
$report = Get-Content -Raw -LiteralPath $ReportPath | ConvertFrom-Json
$rows = @($report.results | Where-Object framework -CEQ 'WinFormsFramework')
if ($rows.Count -ne 2 -or @($rows.backend | Sort-Object -Unique).Count -ne 2) {
    throw 'A WinFormsFramework report for both backends is required.'
}
foreach ($row in $rows) {
    if (!$row.tree -or !$row.tree.truncated) {
        throw "$($row.backend): expected a partial snapshot instead of discarding the WinForms window."
    }
    $check = @($row.checks | Where-Object name -CEQ 'basicActionsInCompleteScopes')
    if ($check.Count -ne 1 -or $check[0].status -cne 'PASS' -or !$check[0].evidence.fullLocatorRejected) {
        throw "$($row.backend): the incomplete locator must be blocked and scoped action postconditions must pass."
    }
}
