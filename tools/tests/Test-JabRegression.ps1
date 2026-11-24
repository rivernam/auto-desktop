# Assert the outcome of a Java Access Bridge report from Test-UiaFrameworks.ps1 -Backend Jab, CppJab or
# BothJab. A check that did not pass must be one of the provider limitations that the run itself
# established with fixture state. A framework that was not run is reported, never assumed.
param(
    [Parameter(Mandatory)][string]$ReportPath,
    # Both Agents must have produced every row. Without it a single-backend report is accepted.
    [switch]$RequireBothBackends
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1 reads BOM-less UTF-8 as ANSI and ConvertFrom-Json stops at 2 MB.
Add-Type -AssemblyName System.Web.Extensions
$serializer = New-Object Web.Script.Serialization.JavaScriptSerializer
$serializer.MaxJsonLength = [int]::MaxValue
$serializer.RecursionLimit = 200
$report = $serializer.DeserializeObject([IO.File]::ReadAllText((Resolve-Path -LiteralPath $ReportPath).Path))
$ran = @($report.results | Where-Object { $_.checks -and $_.backend -in 'Jab', 'CppJab' })
if (!$ran.Count) { throw 'The report contains no executed Java Access Bridge row.' }

# What Java itself does not offer through the bridge, by framework.
$limitations = @{
    Swing = @('modalOpenedByInvoke')   # A listener that shows a modal dialog blocks the bridge request.
    Awt = @('setValueAndEmpty')        # java.awt text components do not implement AccessibleEditableText.
}
$dependents = @{ Awt = @('setValueUnicodeAndLimits', 'passwordSetValue') }
$required = 'capabilities', 'window', 'tree', 'controlInventory', 'buttonLocatorAndLiveMetadata', 'editLocatorAndLiveMetadata',
    'ambiguousDuplicate', 'unnamedElementByScope', 'passwordMetadata', 'invokeAndDuplicateRequest', 'disabledControl', 'readOnlyControl',
    'replacement', 'truncatedSnapshot', 'scopedSnapshot', 'modalOpenedByApplication', 'otherProcessDenied', 'otherSessionReference',
    'otherBackendReference', 'bridgeNotConnected', 'multipleJvms', 'bridgeLibraryMissing', 'bridgeLibraryInvalid',
    'captureBeforeExit', 'processExitInvalidatesReference', 'jvmRestart'

$summary = New-Object 'Collections.Generic.List[string]'
foreach ($row in $ran) {
    $label = "$($row.framework) $($row.backend)"
    $byName = @{}
    foreach ($check in $row.checks) {
        if ($byName.ContainsKey($check.name)) { throw "${label}: duplicate check $($check.name)." }
        $byName[$check.name] = $check
    }
    foreach ($name in $required) {
        if (!$byName.ContainsKey($name) -or $byName[$name].status -cne 'PASS') { throw "${label}: required check $name did not pass." }
    }
    if ($row.framework -ceq 'Swing') {
        foreach ($name in 'setValueAndEmpty', 'setValueUnicodeAndLimits', 'passwordSetValue', 'offscreenControl', 'customAccessibleAction',
            'optionPane', 'exitWhileTargetSilent') {
            if ($byName[$name].status -cne 'PASS') { throw "${label}: Swing check $name did not pass." }
        }
    }
    foreach ($check in $row.checks | Where-Object { $_.status -cne 'PASS' }) {
        if ($check.status -ceq 'NOT_RUN' -and $check.name -in $dependents[$row.framework]) { continue }
        if ($check.status -ceq 'FAIL' -and $check.classification -ceq 'JAB_PROVIDER_LIMITATION' -and
            $check.name -in $limitations[$row.framework] -and $check.evidence) { continue }
        throw "${label}: unexplained result for $($check.name): $($check.status) [$($check.classification)] $($check.reason)"
    }
    # An unconfirmed action is never reported as success, and the fixture state decides what happened.
    $modal = $byName['modalOpenedByInvoke']
    if ($row.framework -ceq 'Swing' -and ($modal.evidence.agentReply -cne 'ACTION_OUTCOME_UNKNOWN' -or !$modal.evidence.modalOpened -or
            $modal.evidence.whileOpen -cne 'TARGET_NOT_RESPONDING' -or !$modal.evidence.sessionUsableAfterClose)) {
        throw "${label}: the modal-opening click must end as ACTION_OUTCOME_UNKNOWN, block the JVM while open and leave the session usable."
    }
    if ($row.framework -ceq 'Awt' -and $modal.status -cne 'PASS') { throw "${label}: an AWT button must open and close the modal dialog." }
    $passed = @($row.checks | Where-Object { $_.status -ceq 'PASS' }).Count
    $summary.Add("${label}: $passed of $(@($row.checks).Count) checks passed, the rest are provider limitations with evidence")
}

foreach ($group in $ran | Group-Object { $_.framework }) {
    $backends = @($group.Group | ForEach-Object { $_.backend } | Sort-Object -Unique)
    if ($backends.Count -lt 2) {
        if ($RequireBothBackends) { throw "$($group.Name): results for both Agents are required." }
        continue
    }
    $verdicts = foreach ($row in $group.Group) {
        (($row.checks | ForEach-Object { "$($_.name)=$($_.status)/$($_.classification)" }) -join ';')
    }
    if (@($verdicts | Sort-Object -Unique).Count -ne 1) { throw "$($group.Name): the two Agents disagree on a check." }
    $comparison = @($report.comparisons | Where-Object { $_.framework -ceq $group.Name })
    if ($comparison.Count -ne 1 -or $comparison[0].status -cne 'PASS' -or !$comparison[0].contentMatches) {
        throw "$($group.Name): the two Agents did not capture the same tree."
    }
    $summary.Add("$($group.Name): both Agents agree on $(@($group.Group[0].checks).Count) checks and on the captured tree")
}
$summary
