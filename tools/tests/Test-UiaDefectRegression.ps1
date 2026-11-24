# Assert the outcome of the three defects found by the framework compatibility run, on a functional
# report from Test-UiaFrameworks.ps1. A framework that was not run is reported, never assumed.
param(
    [Parameter(Mandatory)][string]$ReportPath,
    # Both backends must have produced every row. Without it a single-backend report is accepted.
    [switch]$RequireBothBackends
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../UiaTest.Common.ps1')
$report = Read-UiaReport $ReportPath
$ran = @($report.results | Where-Object { $_.checks })
if (!$ran.Count) { throw 'The report contains no executed framework.' }

function Get-Check($row, [string]$name) {
    $found = @($row.checks | Where-Object { $_.name -ceq $name })
    if ($found.Count -gt 1) { throw "$($row.framework) $($row.backend): duplicate check $name." }
    if ($found.Count) { return $found[0] }
}

$summary = New-Object 'Collections.Generic.List[string]'
foreach ($row in $ran) {
    $label = "$($row.framework) $($row.backend)"
    $open = @($row.checks | Where-Object { $_.status -in 'FAIL', 'INCONCLUSIVE' -and $_.classification -in $null, '', 'UNCLASSIFIED', 'AGENT_BUG', 'INCONCLUSIVE', 'REQUEST_TIMEOUT', 'AFTER_REQUEST_TIMEOUT' })
    if ($open.Count) { throw "${label}: unexplained failures: $(($open | ForEach-Object { "$($_.name) [$($_.classification)]" }) -join ', ')." }

    # 1. Owned modal and popup windows.
    if ($row.framework -in 'Win32', 'Wpf', 'WinFormsFramework', 'WinFormsModern') {
        $modal = Get-Check $row 'modal'
        if (!$modal -or $modal.status -cne 'PASS' -or !$modal.evidence.listedWithOwner -or !$modal.evidence.closedThroughOwnSnapshot -or
            !$modal.evidence.staleAfterClose -or !$row.modalOpened -or !$row.modalClosed) {
            throw "${label}: the owned modal must be listed with its owner, operated through its own snapshot and invalidated when it closes."
        }
        $summary.Add("${label}: owned modal listed and operated")
    }
    if ($row.framework -ceq 'Wpf') {
        $popup = Get-Check $row 'popup'
        if (!$popup -or $popup.status -cne 'PASS' -or !$popup.evidence.listedWithOwner -or !$popup.evidence.actionObserved) {
            throw "${label}: the owned popup must be listed with its owner and its action observed in the fixture."
        }
    }

    # 2. A partial tree is never reported as complete.
    if ($row.tree.truncated) {
        $tree = Get-Check $row 'tree'
        if ($tree.status -ceq 'PASS' -or $row.tree.partialElements -lt 1) { throw "${label}: a partial window snapshot passed as a complete tree." }
        $scopes = Get-Check $row 'partialSnapshotScopes'
        if ($row.framework -ceq 'WinFormsFramework' -and (!$scopes -or $scopes.status -cne 'PASS')) {
            throw "${label}: scoped lookup rules for a partial snapshot were not verified."
        }
        $summary.Add("${label}: partial snapshot reported as partial ($($tree.classification))")
    }

    # 3. A returned Invoke without an application reaction is never counted as success.
    foreach ($name in 'invokeAndDuplicateRequest', 'modal', 'replacement') {
        $check = Get-Check $row $name
        if (!$check -or $check.classification -cne 'UIA_PROVIDER_LIMITATION' -or !$check.evidence.agentReply) { continue }
        $controls = $check.evidence.independentControls
        if ($check.status -cne 'FAIL' -or $check.evidence.agentReply.effectVerified -ne $false -or
            $controls.BM_CLICK.effect -or $controls.accDoDefaultAction.effect) {
            throw "${label}: $name must fail without an effect, with an unverified Agent reply and ineffective independent controls."
        }
        $summary.Add("${label}: $name had no effect through UIA, BM_CLICK or MSAA")
    }
}

# The same regression must give the same verdict on both Agents.
foreach ($group in $ran | Group-Object { $_.framework }) {
    $backends = @($group.Group | ForEach-Object { $_.backend } | Sort-Object -Unique)
    if ($backends.Count -lt 2) {
        if ($RequireBothBackends) { throw "$($group.Name): results for both backends are required." }
        continue
    }
    $verdicts = foreach ($row in $group.Group) {
        (($row.checks | ForEach-Object { "$($_.name)=$($_.status)/$($_.classification)" }) -join ';')
    }
    if (@($verdicts | Sort-Object -Unique).Count -ne 1) { throw "$($group.Name): the two backends disagree on a check." }
    $summary.Add("$($group.Name): both backends agree on $(@($group.Group[0].checks).Count) checks")
}
$summary
