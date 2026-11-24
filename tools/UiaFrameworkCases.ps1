# The fixture owns control state. An Agent reply alone cannot confirm a mutation.
function Get-FrameworkSpec($name) {
    $spec = @{ edit = 'fixtureEdit'; readOnly = 'fixtureReadOnly'; password = 'fixturePassword'; list = 'fixtureList' }
    if ($name -in 'Win32', 'Mfc') {
        $spec = @{ edit = '1002'; readOnly = '1003'; password = '1006'; list = '1012' }
    }
    if ($name -eq 'Awt') {
        # Measured control IDs of the lightweight fixture's heavyweight peer children.
        $spec = @{ edit = '1'; readOnly = '2'; password = '3'; editClass = 'RichEdit20W'; listClass = 'ListBox' }
    }
    $spec.modalClose = if ($name -in 'Win32', 'Mfc') { 'Cancel modal' } else { 'Close fixture modal' }
    return $spec
}

function Get-JabSpec {
    return @{ byName = $true; edit = 'Fixture edit'; readOnly = 'Fixture read-only edit'; password = 'Fixture password'
        list = 'Fixture list'; modalClose = 'Close fixture modal' }
}

function Require-Framework($condition, [string]$message) {
    if (!$condition) { throw $message }
}

# Ends a case with a cause that the case itself established, and the evidence for it.
function Stop-FrameworkCase([string]$classification, [string]$message, $evidence) {
    $failure = New-Object InvalidOperationException($message)
    $failure.Data['classification'] = $classification
    if ($null -ne $evidence) { $failure.Data['evidence'] = $evidence }
    throw $failure
}

# Win32 and MSAA access to the fixture that uses neither UI Automation nor an Agent.
function Initialize-FrameworkNative {
    if ('FrameworkNative' -as [type]) { return }
    Add-Type -ReferencedAssemblies Accessibility -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class FrameworkNative {
    private delegate bool EnumProc(IntPtr window, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumChildWindows(IntPtr parent, EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint owner);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SendMessageTimeoutW(IntPtr window, uint message, IntPtr w, IntPtr l, uint flags, uint ms, out IntPtr result);
    [DllImport("oleacc.dll")]
    private static extern int AccessibleObjectFromWindow(IntPtr window, uint id, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object result);

    public sealed class TopLevel { public long Handle, Owner; public string Title, ClassName; }

    private static string Text(IntPtr window) { var text = new StringBuilder(512); GetWindowTextW(window, text, text.Capacity); return text.ToString(); }
    public static string ClassName(long window) { var text = new StringBuilder(256); GetClassNameW(new IntPtr(window), text, text.Capacity); return text.ToString(); }
    private static bool Owns(IntPtr window, uint pid) { uint owner; return GetWindowThreadProcessId(window, out owner) != 0 && owner == pid; }

    // Visible top-level windows of the process, including owned ones.
    public static List<TopLevel> Windows(uint pid) {
        var rows = new List<TopLevel>();
        EnumWindows(delegate(IntPtr window, IntPtr state) {
            if (Owns(window, pid) && IsWindowVisible(window)) {
                rows.Add(new TopLevel { Handle = window.ToInt64(), Owner = GetWindow(window, 4).ToInt64(),
                    Title = Text(window), ClassName = ClassName(window.ToInt64()) });
            }
            return true;
        }, IntPtr.Zero);
        return rows;
    }

    // The only child HWND of the process with this window text, or 0.
    public static long FindChild(uint pid, string text) {
        var found = new List<long>();
        foreach (var top in Windows(pid)) {
            EnumChildWindows(new IntPtr(top.Handle), delegate(IntPtr child, IntPtr state) {
                if (Text(child) == text) found.Add(child.ToInt64());
                return true;
            }, IntPtr.Zero);
        }
        return found.Count == 1 ? found[0] : 0;
    }

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetLong(IntPtr window, int index);

    // Window styles of the process's child HWNDs of one class.
    public static List<long> ChildStyles(uint pid, string className) {
        var styles = new List<long>();
        foreach (var top in Windows(pid)) {
            EnumChildWindows(new IntPtr(top.Handle), delegate(IntPtr child, IntPtr state) {
                if (ClassName(child.ToInt64()) == className) styles.Add(GetLong(child, -16).ToInt64() & 0xffffffffL);
                return true;
            }, IntPtr.Zero);
        }
        return styles;
    }

    private static IntPtr Owned(long window, uint pid) {
        var handle = new IntPtr(window);
        if (pid == 0 || !Owns(handle, pid)) throw new InvalidOperationException("The HWND does not belong to the fixture.");
        return handle;
    }

    public static string Click(long window, uint pid) {
        IntPtr result;
        return SendMessageTimeoutW(Owned(window, pid), 0x00F5, IntPtr.Zero, IntPtr.Zero, 2, 3000, out result) == IntPtr.Zero
            ? "not delivered (" + Marshal.GetLastWin32Error() + ")" : "delivered";
    }

    public static string DefaultAction(long window, uint pid) {
        Guid iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71");
        object value;
        int status = AccessibleObjectFromWindow(Owned(window, pid), 0xFFFFFFFC, ref iid, out value);
        if (status != 0) return "AccessibleObjectFromWindow 0x" + status.ToString("X8");
        try {
            var accessible = (Accessibility.IAccessible)value;
            string action = accessible.get_accDefaultAction(0);
            accessible.accDoDefaultAction(0);
            return "returned (default action: " + action + ")";
        } catch (Exception failure) { return failure.GetType().Name; }
    }
}
'@
}

function Get-FixtureTopLevel([scriptblock]$filter, [int]$timeoutMs = 3000) {
    Initialize-FrameworkNative
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $matches = @([FrameworkNative]::Windows([uint32]$fixture.Id) | Where-Object $filter)
        if ($matches.Count -eq 1) { return $matches[0] }
        Start-Sleep -Milliseconds 25
    } while ($clock.ElapsedMilliseconds -lt $timeoutMs)
    throw "Win32 reported $($matches.Count) matching visible top-level windows for the fixture."
}

# Runs a read-only probe in a process of its own. The managed UI Automation library registers a
# process-wide proxy callback that changes what a COM client in the same process is served.
function Invoke-FrameworkProbe([string]$script, [string]$arguments) {
    $shell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $path = Join-Path $PSScriptRoot $script
    $probe = Read-Diagnostic $shell "-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File ""$path"" $arguments" 60000 -Utf8
    if ($probe.exitCode -ne 0) { throw "$script failed: $($probe.stderr)" }
    return ConvertFrom-Json -InputObject $probe.stdout
}

# Where a third client, the managed UI Automation library, places one top-level HWND of the fixture.
function Get-OwnedWindowEvidence($native) {
    $probe = Invoke-FrameworkProbe 'Probe-UiaWindows.ps1' "-ProcessId $($fixture.Id)"
    $seen = @($probe.topLevelWindows | Where-Object { $_.hwnd -eq $native.Handle })
    if ($seen.Count -ne 1) { return @{ status = 'not observed' } }
    return [ordered]@{ client = 'System.Windows.Automation (managed)'; win32Owner = $seen[0].owner
        desktopChildInControlView = $seen[0].desktopChildControlView; desktopChildInRawView = $seen[0].desktopChildRawView
        controlViewParentChain = @($seen[0].uia.controlParentChain); rawViewParentChain = @($seen[0].uia.rawParentChain) }
}

function Read-FixtureState([string]$file) {
    try { return Read-State $file } catch [IO.IOException] { return $null }
}

# Dispatches Invoke and judges the outcome by fixture state alone. When the provider accepted the call
# and the application did not react, the same HWND is activated through Win32 and MSAA. If those do
# nothing either, no accessibility client could have succeeded and the cause lies in the provider.
function Invoke-FixtureButton($run, $element, [string]$file, [string]$expected, [string]$id = ([guid]::NewGuid().ToString())) {
    $reply = (Invoke-FrameworkRequest $run @{ op = 'invoke'; ref = $element.ref } 'OK' $id).reply.result
    Require-Framework ($reply.performed -eq $true) 'Invoke did not report dispatch.'
    Require-Framework ($reply.effectVerified -eq $false) 'An Invoke reply must state that the Agent did not verify the effect.'
    try { Wait-State $file $expected 6000; return }
    catch { if ($_.Exception.Message -notmatch '^Fixture did not report') { throw } }
    Initialize-FrameworkNative
    $evidence = [ordered]@{ agentReply = @{ performed = $reply.performed; effectVerified = $reply.effectVerified }
        expectedState = "$file=$expected"; observedState = Read-FixtureState $file }
    $hwnd = [FrameworkNative]::FindChild([uint32]$fixture.Id, $element.name)
    if (!$hwnd) {
        $run.uncertainAction = $true
        Stop-FrameworkCase 'UNCLASSIFIED' "Invoke returned but the fixture did not report $file." $evidence
    }
    $evidence.nativeClass = [FrameworkNative]::ClassName($hwnd)
    $controls = [ordered]@{}
    foreach ($control in 'BM_CLICK', 'accDoDefaultAction') {
        $call = if ($control -eq 'BM_CLICK') { [FrameworkNative]::Click($hwnd, [uint32]$fixture.Id) }
            else { [FrameworkNative]::DefaultAction($hwnd, [uint32]$fixture.Id) }
        $effect = $true
        try { Wait-State $file $expected 2500 } catch { $effect = $false }
        $controls[$control] = @{ call = $call; effect = $effect }
        if ($effect) { break }
    }
    $evidence.independentControls = $controls
    $evidence.stateAfterControls = Read-FixtureState $file
    if (@($controls.Values | Where-Object { $_.effect }).Count) {
        Stop-FrameworkCase 'AGENT_BUG' "Invoke returned without effect, yet an independent activation of the same HWND changed $file." $evidence
    }
    Stop-FrameworkCase 'UIA_PROVIDER_LIMITATION' "Invoke returned but the fixture did not report $file. A direct BM_CLICK and the MSAA default action on the same HWND had no effect either." $evidence
}

function Start-FrameworkAgent($implementation, [switch]$WithoutPid, [string]$ExtraArguments) {
    # Jab and CppJab are the same two Agents with the Java Access Bridge backend selected.
    $bridge = $implementation -in 'Jab', 'CppJab'
    if ($bridge -and $JabDll -and !$ExtraArguments) { $ExtraArguments = "--jab-dll ""$JabDll""" }
    if ($implementation -in 'JNA', 'Jab') {
        $start = New-CliStartInfo $(if ($bridge) { 'JAB' } else { 'JNA' }) -JvmOptions (ConvertTo-UiaJvmOptions $JvmOptions) `
            -WithoutPid:$WithoutPid -ExtraArguments $ExtraArguments
    } else {
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $CppAgent
        $start.Arguments = '--allow-action invoke --allow-action setValue'
        if (!$WithoutPid) { $start.Arguments += " --allow-pid $($fixture.Id)" }
        if ($bridge) { $start.Arguments += ' --backend jab' }
        if ($ExtraArguments) { $start.Arguments += " $ExtraArguments" }
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $cli = Start-Cli $start
    return @{ cli = $cli; clock = $clock; processStartMs = $clock.Elapsed.TotalMilliseconds;
        closedProtocol = $false; uncertainAction = $false; requests = New-Object 'Collections.Generic.List[object]' }
}

function Invoke-FrameworkRequest($run, $command, [string]$expected = 'OK', [string]$id = ([guid]::NewGuid().ToString())) {
    Require-Framework (!$run.closedProtocol) 'CLI protocol is unavailable after a transport error.'
    $action = $command.op -in 'invoke', 'setValue'
    if ($action) { Require-Framework (!$run.uncertainAction) 'A previous action outcome is uncertain.' }
    try { $response = Send-UiaRequest $run.cli $command $id 15000 }
    catch {
        $run.closedProtocol = $true
        $run.uncertainAction = $run.uncertainAction -or $action
        $run.requests.Add(@{ op = $command.op; code = 'TRANSPORT_ERROR'; actionOutcomeUncertain = $action })
        throw
    }
    $code = if ($response.reply.ok) { 'OK' } else { $response.reply.error.code }
    $run.requests.Add(@{ op = $command.op; code = $code; ms = $response.ms })
    if ($action -and $code -eq 'ACTION_OUTCOME_UNKNOWN') { $run.uncertainAction = $true }
    Require-Framework ($code -ceq $expected) "$($command.op) expected $expected, received $code."
    return $response
}

function Framework-Result($run, $command, [string]$expected = 'OK') {
    return (Invoke-FrameworkRequest $run $command $expected).reply.result
}

function Wait-FrameworkEffect($run, [string]$file, [string]$value) {
    try { Wait-State $file $value 6000 }
    catch { $run.uncertainAction = $true; throw }
}

function Get-FrameworkWindow($run, [string]$name = $title) {
    $windows = @(Framework-Result $run @{ op = 'listWindows' } | Where-Object {
        $_.processId -eq $fixture.Id -and $_.name -ceq $name
    })
    Require-Framework ($windows.Count -eq 1 -and $windows[0].windowId) 'Expected one window with the fixture PID and title.'
    return $windows[0].windowId
}

function Get-FrameworkSnapshot($run, $window, [string]$scope, [int]$depth = 32, [int]$limit = 2000) {
    $request = @{ op = 'snapshot'; windowId = $window; maxDepth = $depth; maxElements = $limit }
    if ($scope) { $request.scopeRef = $scope }
    $response = Invoke-FrameworkRequest $run $request
    $snapshot = $response.reply.result
    Require-Framework ($snapshot.windowId -ceq $window -and $snapshot.snapshotId -and $snapshot.elements.Count -gt 0 -and
        !$snapshot.elements[0].parentRef -and $snapshot.elements[0].processId -eq $fixture.Id) 'Snapshot window or root ownership mismatch.'
    return @{ data = $snapshot; ms = $response.ms }
}

function Get-FrameworkTree($snapshot) {
    $paths = [Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $content = New-Object 'Collections.Generic.List[string]'
    $chrome = New-Object 'Collections.Generic.List[string]'
    $foreign = 0
    foreach ($node in $snapshot.elements) {
        Require-Framework ($node.ref -and !$paths.ContainsKey($node.ref)) 'Missing or duplicated element reference.'
        Require-Framework ($null -eq $node.PSObject.Properties['value']) 'Snapshot exposed a value field.'
        $owned = $node.processId -eq $fixture.Id
        if (!$owned) { $foreign++ }
        # Foreign-hosted content may include text outside the fixture.
        $identity = if ($owned) { @($node.role, $node.name, $node.automationId, $node.className) } else { @('foreign') }
        if ($owned -and $node.nativeRole) { $identity += $node.nativeRole }
        $path = ,$identity
        $isChrome = $node.role -ceq 'TitleBar'
        if ($node.parentRef) {
            Require-Framework ($paths.ContainsKey($node.parentRef)) 'Parent is absent or follows its child.'
            $parent = $paths[$node.parentRef]
            $path = $parent.path + $path
            $isChrome = $isChrome -or $parent.chrome
        } else {
            Require-Framework (!$paths.Count) 'Snapshot has multiple roots.'
        }
        $paths.Add($node.ref, @{ path = $path; chrome = $isChrome })
        $bounds = if ($node.bounds) { @($node.bounds.x, $node.bounds.y, $node.bounds.width, $node.bounds.height) }
        $entry = ConvertTo-Json -Depth 20 -Compress -InputObject @($path, @($bounds), $node.enabled, $node.offscreen,
            @($node.actions | Sort-Object), $node.backend, $owned, [bool]$node.partial)
        if ($isChrome) { $chrome.Add($entry) } else { $content.Add($entry) }
    }
    $content.Sort([StringComparer]::Ordinal)
    $chrome.Sort([StringComparer]::Ordinal)
    return @{ content = $content.ToArray(); chrome = $chrome.ToArray(); foreign = $foreign; truncated = $snapshot.truncated;
        elements = $snapshot.elements.Count; partialElements = @($snapshot.elements | Where-Object partial).Count }
}

# Looks one fixture control up through the Agent. In a partial snapshot the search is confined to the
# parent of the single captured candidate, where the Agent has to prove that the branch is whole.
function Find-FixtureControl($run, $snapshot, $locator) {
    if (!$snapshot.truncated) { return Find-FrameworkElement $run $snapshot $locator }
    $candidates = @(foreach ($node in $snapshot.elements) {
        if ($node.processId -eq $fixture.Id -and !@($locator.Keys | Where-Object { $node.$_ -cne $locator[$_] }).Count) { $node }
    })
    Require-Framework ($candidates.Count -eq 1) 'The incomplete snapshot did not capture exactly one candidate.'
    # Widen the scope to the highest ancestor that holds no partial element.
    $byRef = @{}
    foreach ($node in $snapshot.elements) { $byRef[$node.ref] = $node }
    $cut = @{}
    foreach ($node in $snapshot.elements | Where-Object partial) {
        for ($cursor = $node; $cursor; $cursor = $(if ($cursor.parentRef) { $byRef[$cursor.parentRef] })) { $cut[$cursor.ref] = $true }
    }
    $scope = $candidates[0]
    Require-Framework (!$cut[$scope.ref]) 'The captured candidate has an incomplete subtree.'
    while ($scope.parentRef -and !$cut[$scope.parentRef]) { $scope = $byRef[$scope.parentRef] }
    return Find-FrameworkElement $run $snapshot $locator $scope.ref
}

# Independent evidence for a partial tree: the COM client's own view of each element's runtime ID.
function Get-RuntimeIdEvidence($window) {
    $probe = Invoke-FrameworkProbe 'Probe-UiaRuntimeIds.ps1' "-WindowHandle $window -ProcessId $($fixture.Id) -MaxDepth 32 -MaxElements 2000"
    return [ordered]@{ client = $probe.client; elements = $probe.elements; elementLimitReached = $probe.elementLimitReached
        unusableRuntimeIds = $probe.unusableRuntimeIds; duplicateRuntimeIds = $probe.duplicateRuntimeIds
        unusableRuntimeIdGroups = @($probe.unusableRuntimeIdGroups | Where-Object { $_ }) }
}

function Get-FrameworkClassification($row, $check) {
    # One read that ran into the 10 s request limit cannot tell a slow host from a slow Agent. A C++
    # session is retired by a timeout, so its later requests fail as a consequence.
    if ($check.reason -match 'received TIMEOUT') { return 'REQUEST_TIMEOUT' }
    if ($check.reason -match 'received BACKEND_UNAVAILABLE' -and @($row.requests | Where-Object { $_.code -ceq 'TIMEOUT' }).Count) {
        return 'AFTER_REQUEST_TIMEOUT'
    }
    if ($check.status -eq 'INCONCLUSIVE') { return 'INCONCLUSIVE' }
    # A lookup that the Agent refuses on a tree which an independent client also cannot identify.
    if ($row.providerOmissions -gt 0 -and $check.reason -match 'INCOMPLETE_SNAPSHOT|incomplete') { return 'UIA_PROVIDER_LIMITATION' }
    # Swing draws lightweight components. UI Automation sees the frame and nothing inside it.
    if ($row.framework -eq 'Swing' -and $row.backend -in 'JNA', 'Cpp' -and $check.reason -match 'ELEMENT_NOT_FOUND|candidate') { return 'JAB_ONLY' }
    return 'UNCLASSIFIED'
}

function Find-FrameworkElement($run, $snapshot, $locator, [string]$scope, [string]$expected = 'OK') {
    $request = @{ op = 'findElement'; snapshotId = $snapshot.snapshotId; locator = $locator }
    if ($scope) { $request.scopeRef = $scope }
    $element = Framework-Result $run $request $expected
    if ($expected -eq 'OK') {
        Require-Framework ($element.ref -and $element.processId -eq $fixture.Id) 'Locator did not return an element owned by the fixture.'
    }
    return $element
}

function Get-FixtureLocator($spec, [string]$control, [string]$role) {
    # Java Access Bridge has no identifier. The accessible name that the application set is the handle.
    if ($spec.byName) { return @{ role = $role; name = $spec[$control] } }
    $id = $spec[$control]
    $marker = if ($control -eq 'readOnly') { 'read-only-id.txt' } else { "$control-id.txt" }
    if ([IO.File]::Exists((Join-Path $stateDir $marker))) { $id = Read-State $marker }
    $locator = @{ role = $role }
    if ($id) { $locator.automationId = $id }
    $class = if ($control -eq 'list') { $spec.listClass } else { $spec.editClass }
    if ($class) { $locator.className = $class }
    return $locator
}

function Invoke-FrameworkCase($row, [string]$name, [bool]$ready, [scriptblock]$body) {
    $check = [ordered]@{ name = $name; status = 'NOT_RUN' }
    $row.checks.Add($check)
    if (!$ready) { $check.reason = 'Required fixture or element is unavailable.'; return }
    try {
        $evidence = & $body
        if ($null -ne $evidence) { $check.evidence = $evidence }
        $check.status = 'PASS'
    } catch {
        $check.reason = $_.Exception.Message
        $check.status = if ($check.reason -match 'ACTION_OUTCOME_UNKNOWN|Timed out waiting') { 'INCONCLUSIVE' } else { 'FAIL' }
        $data = $_.Exception.Data
        if ($data -and $data.Contains('evidence')) { $check.evidence = $data['evidence'] }
        $check.classification = if ($data -and $data.Contains('classification')) { $data['classification'] }
            else { Get-FrameworkClassification $row $check }
        if ($check.classification -ceq 'NOT_APPLICABLE') { $check.status = 'NOT_RUN' }
        if ($check.classification -in 'REQUEST_TIMEOUT', 'AFTER_REQUEST_TIMEOUT') { $check.status = 'INCONCLUSIVE' }
    }
}

function Invoke-FrameworkFunction($row, $spec) {
    $row.checks = New-Object 'Collections.Generic.List[object]'
    $state = @{}
    $run = $null
    try {
        $run = Start-FrameworkAgent $row.backend
        $row.requests = $run.requests
        Invoke-FrameworkCase $row 'capabilities' $true {
            $cap = Framework-Result $run @{ op = 'getCapabilities' }
            Require-Framework ($cap.available -and $cap.backend -ceq 'UIA' -and !$cap.physicalInput -and !$cap.screenshot -and
                (@($cap.operations | Sort-Object) -join ',') -ceq 'findElement,getCapabilities,getElementInfo,invoke,listWindows,setValue,snapshot') 'Invalid UIA capabilities.'
        }
        Invoke-FrameworkCase $row 'window' (!$run.closedProtocol) {
            $state.window = Get-FrameworkWindow $run
            $row.windowId = $state.window
        }
        Invoke-FrameworkCase $row 'tree' ([bool]$state.window) {
            $state.snapshot = (Get-FrameworkSnapshot $run $state.window).data
            $row.tree = Get-FrameworkTree $state.snapshot
            if ($row.tree.truncated) {
                Require-Framework ($row.tree.partialElements -gt 0) 'An incomplete snapshot did not name any partial element.'
                $row.runtimeIdProbe = Get-RuntimeIdEvidence $state.window
                $row.providerOmissions = $row.runtimeIdProbe.unusableRuntimeIds
                if ($row.providerOmissions -gt 0) {
                    Stop-FrameworkCase 'UIA_PROVIDER_LIMITATION' 'Whole-window snapshot is incomplete at maximum limits. The provider returns empty runtime IDs.' ([ordered]@{
                        agentElements = $row.tree.elements; agentPartialElements = $row.tree.partialElements
                        independentClient = $row.runtimeIdProbe })
                }
            } else {
                Require-Framework ($row.tree.partialElements -eq 0) 'A complete snapshot named a partial element.'
            }
            Require-Framework (!$row.tree.truncated) 'Whole-window snapshot is incomplete at maximum limits.'
        }
        Invoke-FrameworkCase $row 'buttonLocatorAndLiveMetadata' ([bool]$state.snapshot -and !$run.closedProtocol) {
            $locator = @{ role = 'Button'; name = 'Increment fixture counter' }
            $button = Find-FixtureControl $run $state.snapshot $locator
            $info = Framework-Result $run @{ op = 'getElementInfo'; ref = $button.ref }
            Require-Framework ($info.ref -ceq $button.ref -and $info.processId -eq $fixture.Id -and $info.parentRef -ceq $button.parentRef -and
                $info.name -ceq $locator.name -and $info.role -ceq $locator.role -and $info.enabled -and !$info.offscreen -and
                $info.bounds.width -gt 0 -and $info.bounds.height -gt 0 -and $null -eq $info.PSObject.Properties['value']) 'Unexpected live button metadata.'
            # A miss is conclusive only in a complete tree. A partial one must refuse to answer.
            $miss = if ($state.snapshot.truncated) { 'INCOMPLETE_SNAPSHOT' } else { 'ELEMENT_NOT_FOUND' }
            [void](Find-FrameworkElement $run $state.snapshot @{ name = $locator.name; role = 'button' } '' $miss)
            $state.button = $button
            @{ role = $info.role; name = $info.name; automationId = $info.automationId; actions = $info.actions; unscopedMiss = $miss }
        }
        Invoke-FrameworkCase $row 'editLocatorAndLiveMetadata' ([bool]$state.snapshot -and !$run.closedProtocol) {
            $edit = Find-FixtureControl $run $state.snapshot (Get-FixtureLocator $spec 'edit' 'Edit')
            $info = Framework-Result $run @{ op = 'getElementInfo'; ref = $edit.ref }
            Require-Framework ($info.ref -ceq $edit.ref -and $info.role -ceq 'Edit' -and $info.processId -eq $fixture.Id -and
                $info.name -ceq '' -and $null -eq $info.PSObject.Properties['value']) 'Edit live metadata was invalid or unredacted.'
            $state.edit = $edit
            @{ automationId = $info.automationId; actions = $info.actions }
        }
        Invoke-FrameworkCase $row 'ambiguousDuplicate' ([bool]$state.snapshot -and !$run.closedProtocol) {
            [void](Find-FrameworkElement $run $state.snapshot @{ role = 'Button'; name = 'Duplicate label' } '' 'AMBIGUOUS_ELEMENT')
        }
        Invoke-FrameworkCase $row 'locatorWithoutAutomationId' ([bool]$state.snapshot -and !$run.closedProtocol) {
            $candidate = @($state.snapshot.elements | Where-Object {
                $_.processId -eq $fixture.Id -and $_.parentRef -and $_.name -and !$_.automationId -and !$_.partial -and
                $_.role -notin 'TitleBar', 'Edit', 'Window' -and $_.name -cne 'Duplicate label'
            } | Select-Object -First 1)
            if (!$candidate.Count -and @($state.snapshot.elements | Where-Object {
                    $_.processId -eq $fixture.Id -and $_.role -ceq 'Button' -and $_.automationId }).Count) {
                Stop-FrameworkCase 'NOT_APPLICABLE' 'Every named element of this fixture carries an AutomationId.'
            }
            Require-Framework ($candidate.Count -eq 1) 'No scoped named candidate without AutomationId was captured.'
            $node = $candidate[0]
            $found = Find-FrameworkElement $run $state.snapshot @{ role = $node.role; name = $node.name; className = $node.className } $node.ref
            Require-Framework ($found.ref -ceq $node.ref -and !$found.automationId) 'Scoped exact lookup failed without AutomationId.'
            @{ role = $node.role; name = $node.name }
        }
        Invoke-FrameworkCase $row 'passwordMetadata' ([bool]$state.snapshot -and !$run.closedProtocol) {
            $password = Find-FixtureControl $run $state.snapshot (Get-FixtureLocator $spec 'password' 'Edit')
            $info = Framework-Result $run @{ op = 'getElementInfo'; ref = $password.ref }
            Require-Framework ($info.name -ceq '' -and $null -eq $info.PSObject.Properties['value'] -and
                @($state.snapshot.elements | Where-Object parentRef -CEQ $password.ref).Count -eq 0) 'Password metadata was not redacted.'
        }
        Test-FrameworkActions $row $spec $run $state
        Test-FrameworkScoping $row $spec $run $state
        if ($row.tree.truncated) { Test-FrameworkScopedActions $row $spec $run $state.window }
        if ($Mode -eq 'Functional') {
            Test-FrameworkPages $row $run $state.window
            Test-NativeFixtureGrid $row $run $state.window
            Test-FrameworkMinimized $row $run $state.window
        }
    } finally {
        if ($run) { Stop-Cli $run.cli JNA }
        $row.status = Get-FrameworkStatus $row.checks
    }
}

function Wait-FixtureMinimized([long]$window, [bool]$expected) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ([FrameworkInputDesktop]::Minimized($window, $fixture.Id) -eq $expected) { return }
        Start-Sleep -Milliseconds 25
    } while ($clock.ElapsedMilliseconds -lt 2000)
    throw 'Fixture did not reach the expected native window placement.'
}

function Test-FrameworkMinimized($row, $run, $window) {
    if ($row.framework -notin 'Win32', 'Wpf') { return }
    Invoke-FrameworkCase $row 'minimizedWindowDiscovery' ($window -match '^\d+$' -and !$run.closedProtocol) {
        [FrameworkInputDesktop]::SetMinimized([long]$window, $fixture.Id, $true)
        try {
            Wait-FixtureMinimized ([long]$window) $true
            Require-Framework ((Get-FrameworkWindow $run) -ceq $window) 'Minimized fixture has a different window ID.'
            $info = (Get-FrameworkSnapshot $run $window '' 0 1).data.elements[0]
            @{ nativeMinimized = $true; uiaRootOffscreen = $info.offscreen; processOwned = $true }
        } finally {
            [FrameworkInputDesktop]::SetMinimized([long]$window, $fixture.Id, $false)
            Wait-FixtureMinimized ([long]$window) $false
        }
    }
}

function Get-ScopedFixtureControl($run, $window, $locator) {
    $whole = (Get-FrameworkSnapshot $run $window).data
    Require-Framework $whole.truncated 'Expected an incomplete window snapshot.'
    # These IDs are declared once by the synthetic fixture. Validate the scope with
    # UIA again and require a complete scoped lookup before using any action ref.
    $candidate = @($whole.elements | Where-Object {
        $_.processId -eq $fixture.Id -and $_.automationId -ceq $locator.automationId -and $_.role -ceq $locator.role
    })
    Require-Framework ($candidate.Count -eq 1) 'Fixture-declared scope is missing or ambiguous.'
    $scope = (Get-FrameworkSnapshot $run $window $candidate[0].ref).data
    Require-Framework (!$scope.truncated -and $scope.elements[0].automationId -ceq $locator.automationId) 'The fresh control scope was incomplete or changed.'
    return Find-FrameworkElement $run $scope $locator $scope.elements[0].ref
}

function Test-FrameworkScopedActions($row, $spec, $run, $window) {
    # The Framework fixture has a known stable ID for each of these HWND-backed controls.
    if ($row.framework -ne 'WinFormsFramework') { return }
    Invoke-FrameworkCase $row 'partialSnapshotScopes' (!$run.closedProtocol) {
        $buttonLocator = @{ role = 'Button'; automationId = 'fixtureIncrement' }
        $listLocator = @{ role = 'List'; automationId = 'fixtureList' }
        $itemLocator = @{ role = 'ListItem'; name = 'Item one' }
        $pick = {
            param($snapshot, $locator)
            $rows = @($snapshot.elements | Where-Object { $_.processId -eq $fixture.Id -and $_.role -ceq $locator.role -and $_.automationId -ceq $locator.automationId })
            Require-Framework ($rows.Count -eq 1) "Expected one captured $($locator.automationId)."
            $rows[0]
        }
        $whole = (Get-FrameworkSnapshot $run $window).data
        $probe = Get-RuntimeIdEvidence $window
        Require-Framework ($whole.truncated -and $probe.unusableRuntimeIds -gt 0) 'Expected a provider that withholds runtime IDs and a snapshot that says so.'
        # The list's items have no runtime ID. The list is named partial and no item gets a reference.
        $list = & $pick $whole $listLocator
        Require-Framework ($list.partial -and !@($whole.elements | Where-Object parentRef -CEQ $list.ref).Count -and
            !@($whole.elements | Where-Object { $_.role -ceq 'ListItem' }).Count) 'An unidentifiable list item received a reference, or its list was not marked partial.'
        # The whole window cannot answer, for a hit or for a miss.
        [void](Find-FrameworkElement $run $whole $buttonLocator '' 'INCOMPLETE_SNAPSHOT')
        [void](Find-FrameworkElement $run $whole @{ automationId = 'fixtureAbsent' } '' 'INCOMPLETE_SNAPSHOT')
        # A branch that was captured whole answers conclusively without a new capture.
        $button = & $pick $whole $buttonLocator
        $found = Find-FrameworkElement $run $whole $buttonLocator $button.parentRef
        Require-Framework ($found.ref -ceq $button.ref -and !$found.partial) 'The whole branch returned a different element.'
        [void](Find-FrameworkElement $run $whole @{ automationId = 'fixtureAbsent' } $button.parentRef 'ELEMENT_NOT_FOUND')
        # A partial branch refuses both.
        [void](Find-FrameworkElement $run $whole $listLocator $list.ref 'INCOMPLETE_SNAPSHOT')
        [void](Find-FrameworkElement $run $whole $itemLocator $list.ref 'INCOMPLETE_SNAPSHOT')
        # Capturing the partial branch again does not turn it into a complete tree.
        $listScope = (Get-FrameworkSnapshot $run $window $list.ref).data
        Require-Framework ($listScope.truncated -and $listScope.elements[0].partial -and
            !@($listScope.elements | Where-Object { $_.role -ceq 'ListItem' }).Count) 'A fresh capture disguised the partial list as complete.'
        [void](Find-FrameworkElement $run $listScope $itemLocator '' 'INCOMPLETE_SNAPSHOT')
        [void](Framework-Result $run @{ op = 'getElementInfo'; ref = $button.ref } 'STALE_REFERENCE')
        # Capturing the whole branch again gives a complete tree in which plain lookup works.
        $again = (Get-FrameworkSnapshot $run $window).data
        $scope = (Get-FrameworkSnapshot $run $window (& $pick $again $buttonLocator).parentRef).data
        Require-Framework (!$scope.truncated -and !@($scope.elements | Where-Object partial).Count) 'The fresh branch capture was incomplete.'
        $fresh = Find-FrameworkElement $run $scope $buttonLocator
        Require-Framework ($fresh.actions -ccontains 'invoke') 'The freshly captured button lost its action.'
        [ordered]@{ independentClient = $probe; windowElements = $whole.elements.Count
            partialRoles = @($whole.elements | Where-Object partial | ForEach-Object role | Sort-Object -Unique)
            wholeWindowLookup = 'INCOMPLETE_SNAPSHOT'; wholeBranchLookup = 'OK'; wholeBranchMiss = 'ELEMENT_NOT_FOUND'
            partialBranchLookup = 'INCOMPLETE_SNAPSHOT'; partialBranchRecaptureTruncated = $true
            wholeBranchRecapture = @{ elements = $scope.elements.Count; truncated = $false } }
    }
    Invoke-FrameworkCase $row 'basicActionsInCompleteScopes' (!$run.closedProtocol -and !$run.uncertainAction) {
        $buttonLocator = @{ role = 'Button'; automationId = 'fixtureIncrement' }
        $full = (Get-FrameworkSnapshot $run $window).data
        [void](Find-FrameworkElement $run $full $buttonLocator '' 'INCOMPLETE_SNAPSHOT')
        $edit = Get-ScopedFixtureControl $run $window (Get-FixtureLocator $spec 'edit' 'Edit')
        $value = 'scoped-' + [guid]::NewGuid()
        Require-Framework ((Framework-Result $run @{ op = 'setValue'; ref = $edit.ref; value = $value }).performed) 'Scoped edit did not report dispatch.'
        Wait-FrameworkEffect $run 'value.txt' $value
        $button = Get-ScopedFixtureControl $run $window $buttonLocator
        $before = [int](Read-State 'count.txt')
        Require-Framework ((Framework-Result $run @{ op = 'invoke'; ref = $button.ref }).performed) 'Scoped button did not report dispatch.'
        Wait-FrameworkEffect $run 'count.txt' ([string]($before + 1))
        @{ fullLocatorRejected = $true; edited = $true; clicked = $true }
    }
}

function Test-FrameworkActions($row, $spec, $run, $state) {
    Invoke-FrameworkCase $row 'setValueAndEmpty' ([bool]$state.edit -and !$run.closedProtocol -and !$run.uncertainAction) {
        $prior = Read-State 'value.txt'
        $value = "fixture-$($row.backend)-" + [char]0xAC12 + '-' + [char]::ConvertFromUtf32(0x1F680)
        $values = if ($prior -ceq '') { @($value, '') } else { @('', $value) }
        foreach ($inputValue in $values) {
            $result = Framework-Result $run @{ op = 'setValue'; ref = $state.edit.ref; value = $inputValue }
            Require-Framework $result.performed 'SetValue did not report dispatch.'
            Wait-FrameworkEffect $run 'value.txt' $inputValue
        }
        @{ emptyObserved = $true; unicodeObserved = $true }
    }
    Invoke-FrameworkCase $row 'disabledAction' ([bool]$state.snapshot -and !$run.closedProtocol -and !$run.uncertainAction) {
        $disabled = Find-FixtureControl $run $state.snapshot @{ role = 'Button'; name = 'Disabled action' }
        Require-Framework (!$disabled.enabled) 'Disabled button appeared enabled.'
        [void](Framework-Result $run @{ op = 'invoke'; ref = $disabled.ref } 'PRECONDITION_FAILED')
        Require-Framework ((Read-State 'disabled-click.txt') -ceq '0') 'Disabled button was invoked.'
    }
    Invoke-FrameworkCase $row 'readOnlyAction' ([bool]$state.snapshot -and !$run.closedProtocol -and !$run.uncertainAction) {
        $edit = Find-FixtureControl $run $state.snapshot (Get-FixtureLocator $spec 'readOnly' 'Edit')
        Require-Framework ($edit.actions -cnotcontains 'setValue') 'Read-only edit advertised setValue.'
        [void](Framework-Result $run @{ op = 'setValue'; ref = $edit.ref; value = 'unexpected' } 'PATTERN_UNSUPPORTED')
        Require-Framework ((Read-State 'read-only.txt') -ceq 'fixed fixture value') 'The read-only edit changed.'
    }
    Invoke-FrameworkCase $row 'foreignPidDenied' ([bool]$state.button -and !$run.closedProtocol -and !$run.uncertainAction) {
        $denied = Start-FrameworkAgent $row.backend -WithoutPid
        try {
            $before = Read-State 'count.txt'
            $snapshot = (Get-FrameworkSnapshot $denied $state.window).data
            $button = Find-FixtureControl $denied $snapshot @{ role = 'Button'; name = 'Increment fixture counter' }
            [void](Framework-Result $denied @{ op = 'invoke'; ref = $button.ref } 'PERMISSION_DENIED')
            Require-Framework ((Read-State 'count.txt') -ceq $before) 'Denied action changed the fixture count.'
        } finally {
            $row.deniedRequests = $denied.requests
            Stop-Cli $denied.cli JNA
        }
    }
    Invoke-FrameworkCase $row 'invokeAndDuplicateRequest' ([bool]$state.button -and !$run.closedProtocol -and !$run.uncertainAction) {
        $before = [int](Read-State 'count.txt')
        $id = [guid]::NewGuid().ToString()
        $limitation = $null
        try { Invoke-FixtureButton $run $state.button 'count.txt' ([string]($before + 1)) $id }
        catch {
            if ($_.Exception.Data['classification'] -cne 'UIA_PROVIDER_LIMITATION') { throw }
            $limitation = $_.Exception
        }
        # The command ID was recorded at dispatch, whether or not the application reacted.
        $settled = Read-State 'count.txt'
        [void](Invoke-FrameworkRequest $run @{ op = 'invoke'; ref = $state.button.ref } 'DUPLICATE_COMMAND' $id)
        Start-Sleep -Milliseconds 300
        Require-Framework ((Read-State 'count.txt') -ceq $settled) 'Duplicate request changed the fixture count.'
        if ($limitation) {
            $limitation.Data['evidence'].duplicateCode = 'DUPLICATE_COMMAND'
            throw $limitation
        }
        @{ before = $before; after = $before + 1; duplicateCode = 'DUPLICATE_COMMAND'; effectVerifiedByAgent = $false }
    }
    Invoke-FrameworkCase $row 'modal' ([bool]$state.snapshot -and !$run.closedProtocol -and !$run.uncertainAction) {
        $open = Find-FixtureControl $run $state.snapshot @{ role = 'Button'; name = 'Open fixture modal' }
        $before = @(Framework-Result $run @{ op = 'listWindows' } | Where-Object { $_.processId -eq $fixture.Id })
        Require-Framework ($before.Count -eq 1 -and $before[0].windowId -ceq $state.window -and
            $null -eq $before[0].PSObject.Properties['ownerWindowId']) 'Expected only the unowned fixture window before the modal opens.'
        try {
            Invoke-FixtureButton $run $open 'modal.txt' 'open'
            $row.modalOpened = $true
            # Win32 names the modal: the visible top-level window of the fixture that the main window owns.
            $native = Get-FixtureTopLevel { [string]$_.Owner -ceq $state.window -and $_.Title -ceq "$title modal" }
            $placement = Get-OwnedWindowEvidence $native
            $listed = @(Framework-Result $run @{ op = 'listWindows' } | Where-Object { $_.processId -eq $fixture.Id })
            $entry = @($listed | Where-Object { $_.windowId -ceq [string]$native.Handle })
            Require-Framework ($entry.Count -eq 1 -and $entry[0].ownerWindowId -ceq $state.window) 'listWindows did not report the owned modal with its owner.'
            $main = @($listed | Where-Object { $_.windowId -ceq $state.window })
            Require-Framework ($listed.Count -eq 2 -and $main.Count -eq 1 -and $main[0].name -ceq $before[0].name -and
                $null -eq $main[0].PSObject.Properties['ownerWindowId']) 'The owner row changed while its modal was open.'
            # The modal is a snapshot root of its own, and its content is reachable by the same rules.
            $shot = (Get-FrameworkSnapshot $run $entry[0].windowId).data
            Require-Framework (!$shot.truncated -and $shot.elements[0].role -ceq 'Window') 'The modal snapshot was incomplete or not rooted at a window.'
            $close = Find-FrameworkElement $run $shot @{ role = 'Button'; name = $spec.modalClose }
            Invoke-FixtureButton $run $close 'modal.txt' 'closed'
            $row.modalClosed = $true
            [void](Framework-Result $run @{ op = 'getElementInfo'; ref = $close.ref } 'STALE_REFERENCE')
            [void](Framework-Result $run @{ op = 'snapshot'; windowId = $entry[0].windowId } 'WINDOW_NOT_FOUND')
            $after = @(Framework-Result $run @{ op = 'listWindows' } | Where-Object { $_.processId -eq $fixture.Id })
            Require-Framework ($after.Count -eq 1 -and $after[0].windowId -ceq $state.window) 'The closed modal was still listed.'
            [ordered]@{ win32Owner = $native.Owner; win32Class = $native.ClassName; independentUia = $placement
                listedWithOwner = $true; uiaNameMatchesTitle = $entry[0].name -ceq $native.Title
                modalElements = $shot.elements.Count; closedThroughOwnSnapshot = $true; staleAfterClose = $true }
        } finally {
            if ((Read-FixtureState 'modal.txt') -ceq 'open') {
                [IO.File]::WriteAllText((Join-Path $stateDir 'close-modal'), '')
                Wait-State 'modal.txt' 'closed'
                $row.modalClosed = $true
            }
            # The modal snapshot replaced the main one. Later cases need current references again.
            if ($state.button -and !$run.closedProtocol) {
                $state.snapshot = (Get-FrameworkSnapshot $run $state.window).data
                $state.button = Find-FixtureControl $run $state.snapshot @{ role = 'Button'; name = 'Increment fixture counter' }
            }
        }
    }
    Invoke-FrameworkCase $row 'replacement' ([bool]$state.button -and !$run.closedProtocol -and !$run.uncertainAction) {
        $before = [int](Read-State 'count.txt')
        [IO.File]::Delete((Join-Path $stateDir 'replaced'))
        [IO.File]::WriteAllText((Join-Path $stateDir 'replace-control'), '')
        Wait-State 'replaced' 'ready'
        [void](Framework-Result $run @{ op = 'invoke'; ref = $state.button.ref } 'STALE_REFERENCE')
        Require-Framework ((Read-State 'count.txt') -ceq [string]$before) 'An old reference invoked the replacement.'
        $snapshot = (Get-FrameworkSnapshot $run $state.window).data
        $state.snapshot = $snapshot
        $button = Find-FixtureControl $run $snapshot @{ role = 'Button'; name = 'Increment fixture counter' }
        Require-Framework ($button.ref -cne $state.button.ref) 'The replacement kept the retired reference.'
        Invoke-FixtureButton $run $button 'count.txt' ([string]($before + 1))
    }
}

function Test-FrameworkScoping($row, $spec, $run, $state) {
    Invoke-FrameworkCase $row 'liveSubtree' ([bool]$state.snapshot -and !$run.closedProtocol) {
        $list = Find-FixtureControl $run $state.snapshot (Get-FixtureLocator $spec 'list' 'List')
        $scope = (Get-FrameworkSnapshot $run $state.window $list.ref).data
        Require-Framework (!$scope.truncated -and $scope.elements.Count -gt 1 -and
            $scope.elements[0].role -ceq $list.role -and $scope.elements[0].automationId -ceq $list.automationId) 'List subtree missing or incomplete.'
        $state.snapshot = $scope
        $row.listSubtree = @{ elements = $scope.elements.Count; namedListItems = @($scope.elements | Where-Object { $_.role -eq 'ListItem' -and $_.name }).Count }
        $items = @($scope.elements | Where-Object { $_.role -ceq 'ListItem' })
        if ($items.Count -and !$row.listSubtree.namedListItems -and $list.className) {
            # An owner-drawn list box without LBS_HASSTRINGS keeps its item text out of reach of every client.
            Initialize-FrameworkNative
            $styles = @([FrameworkNative]::ChildStyles([uint32]$fixture.Id, $list.className))
            if ($styles.Count -eq 1 -and ($styles[0] -band 0x30) -and !($styles[0] -band 0x40)) {
                Stop-FrameworkCase 'UIA_PROVIDER_LIMITATION' 'The list items carry no name. The native list box is owner-drawn without LBS_HASSTRINGS.' ([ordered]@{
                    listItems = $items.Count; namedListItems = 0; nativeClass = $list.className
                    nativeStyle = '0x{0:X8}' -f $styles[0]; ownerDrawn = $true; hasStrings = $false })
            }
        }
        $item = Find-FrameworkElement $run $scope @{ role = 'ListItem'; name = 'Item one' } $scope.elements[0].ref
        Require-Framework ($item.parentRef -ceq $scope.elements[0].ref) 'Scoped item is not a child of the scoped root.'
        @{ elements = $scope.elements.Count }
    }
    Invoke-FrameworkCase $row 'snapshotLimitsAndExpiry' ([bool]$state.snapshot -and !$run.closedProtocol) {
        $prev = $state.snapshot
        foreach ($limit in @{ depth = 0; elements = 2000 }, @{ depth = 32; elements = 1 }) {
            $next = (Get-FrameworkSnapshot $run $state.window '' $limit.depth $limit.elements).data
            Require-Framework ($next.truncated -and $next.elements.Count -eq 1) 'Snapshot limit did not mark the root-only tree incomplete.'
            [void](Find-FrameworkElement $run $next @{ role = 'Window' } $next.elements[0].ref 'INCOMPLETE_SNAPSHOT')
            [void](Framework-Result $run @{ op = 'getElementInfo'; ref = $prev.elements[0].ref } 'STALE_REFERENCE')
            $prev = $next
        }
    }
}

function Set-FixturePage([int]$index) {
    [IO.File]::Delete((Join-Path $stateDir 'page.txt'))
    $pending = Join-Path $stateDir 'select-page.pending'
    [IO.File]::WriteAllText($pending, [string]$index)
    [IO.File]::Move($pending, (Join-Path $stateDir 'select-page'))
    Wait-State 'page.txt' ([string]$index)
}

function Read-FrameworkPage($run, $window, [string[]]$ids, [int[]]$depths) {
    # Grow shallow, bounded read-only captures to reach sibling containers without
    # walking all of the first grid's virtual rows.
    $observed = @{}
    foreach ($depth in $depths) {
        $shot = (Get-FrameworkSnapshot $run $window '' $depth 200).data
        foreach ($id in $ids) {
            if ($observed[$id].status -eq 'PASS') { continue }
            $matches = @($shot.elements | Where-Object { $_.automationId -ceq $id -and $_.processId -eq $fixture.Id })
            $observed[$id] = if ($matches.Count -eq 1) {
                @{ status = 'PASS'; depth = $depth; role = $matches[0].role; actions = $matches[0].actions; offscreen = $matches[0].offscreen }
            } else {
                @{ status = $(if ($shot.truncated) { 'INCONCLUSIVE' } else { 'FAIL' }); matches = $matches.Count }
            }
        }
        if (@($ids | Where-Object { $observed[$_].status -eq 'PASS' }).Count -eq $ids.Count) { break }
    }
    return @{ elements = $shot.elements.Count; truncated = $shot.truncated; lastDepth = $depth; controls = $observed }
}

function Test-FrameworkPages($row, $run, $window) {
    if (!$window -or $row.framework -notin 'Wpf', 'WinFormsFramework', 'WinFormsModern') { return }
    if (![IO.File]::Exists((Join-Path $stateDir 'page.txt'))) { return }
    $wpf = $row.framework -eq 'Wpf'
    $gridPage = if ($wpf) { 0 } else { 1 }
    $listPage = if ($wpf) { 1 } else { 2 }
    $discoveryDepths = if ($wpf) { @(3) } else { @(6, 7, 8) }
    $row.pages = [ordered]@{}
    try {
        Invoke-FrameworkCase $row 'dataGridAndTreeView' (!$run.closedProtocol) {
            Set-FixturePage $gridPage
            $row.pages.grid = Read-FrameworkPage $run $window @('fixtureDataGrid', 'fixtureTree') $discoveryDepths
            $grid = $row.pages.grid.controls.fixtureDataGrid
            Require-Framework ($grid.status -eq 'PASS' -and $grid.role -in 'DataGrid', 'Table') 'Data grid was not found in the bounded page snapshot.'
            # Use shallow discovery to avoid enumerating an entire WinForms virtual row provider.
            $shot = (Get-FrameworkSnapshot $run $window '' 8 100).data
            $matches = @($shot.elements | Where-Object { $_.automationId -ceq 'fixtureDataGrid' -and $_.processId -eq $fixture.Id })
            Require-Framework ($matches.Count -eq 1) 'Grid scope could not be identified.'
            $scope = (Get-FrameworkSnapshot $run $window $matches[0].ref 3 70).data
            $row.pages.grid.scope = @{ elements = $scope.elements.Count; truncated = $scope.truncated;
                rootPartial = [bool]$scope.elements[0].partial
                roles = @($scope.elements | Group-Object role | ForEach-Object { @{ role = $_.Name; count = $_.Count } }) }
            Require-Framework ($scope.elements[0].automationId -ceq 'fixtureDataGrid') 'The grid scope has a different root.'
            if (!@($scope.elements | Where-Object { $_.role -in 'DataItem', 'ListItem' }).Count) {
                # Rows that the Agent leaves out must be ones no client could identify, and the grid must say so.
                $probe = Get-RuntimeIdEvidence $window
                if ($scope.truncated -and $scope.elements[0].partial -and $probe.unusableRuntimeIds -gt 0) {
                    Stop-FrameworkCase 'UIA_PROVIDER_LIMITATION' 'No rows were observed inside the grid. The provider returns empty runtime IDs for its rows and cells, and the grid is marked partial.' ([ordered]@{
                        gridScope = $row.pages.grid.scope; independentClient = $probe })
                }
                throw 'No rows were observed inside the grid.'
            }
            Require-Framework ($row.pages.grid.controls.fixtureTree.status -eq 'PASS') 'TreeView was not identified in the bounded snapshot.'
        }
        Invoke-FrameworkCase $row 'templatedAndVirtualLists' (!$run.closedProtocol) {
            Set-FixturePage $listPage
            $ids = if ($wpf) { @('fixtureListView', 'fixtureVirtualList') } else { @('fixtureListView', 'fixtureOwnerDrawn') }
            $row.pages.lists = Read-FrameworkPage $run $window $ids $discoveryDepths
            Require-Framework (@($ids | Where-Object { $row.pages.lists.controls[$_].status -eq 'PASS' }).Count -eq $ids.Count) 'The bounded snapshot did not identify both expected lists.'
        }
        if (!$wpf) { return }
        Invoke-FrameworkCase $row 'customPeerAndHostedControls' (!$run.closedProtocol -and !$run.uncertainAction) {
            Set-FixturePage 2
            $row.pages.custom = Read-FrameworkPage $run $window @('fixturePeer', 'fixtureWithoutPeer', 'fixtureHostEdit', '4420') 10
            $snapshot = (Get-FrameworkSnapshot $run $window).data
            $button = Find-FrameworkElement $run $snapshot @{ role = 'Button'; automationId = 'fixturePeer' }
            [void](Find-FrameworkElement $run $snapshot @{ automationId = 'fixtureWithoutPeer' } '' 'ELEMENT_NOT_FOUND')
            $row.pages.custom.controls.fixtureWithoutPeer = @{ status = 'PASS'; expectedAbsence = $true }
            foreach ($id in 'fixtureHostEdit', '4420') {
                [void](Find-FrameworkElement $run $snapshot @{ role = 'Edit'; automationId = $id })
            }
            [IO.File]::Delete((Join-Path $stateDir 'custom.txt'))
            Require-Framework ((Framework-Result $run @{ op = 'invoke'; ref = $button.ref }).performed) 'Custom peer did not report dispatch.'
            Wait-FrameworkEffect $run 'custom.txt' 'activated'
        }
        Invoke-FrameworkCase $row 'popup' (!$run.closedProtocol -and !$run.uncertainAction) {
            $snapshot = (Get-FrameworkSnapshot $run $window).data
            $button = Find-FrameworkElement $run $snapshot @{ role = 'Button'; name = 'Open fixture popup' }
            try {
                Invoke-FixtureButton $run $button 'popup.txt' 'open'
                $row.popupOpened = $true
                # The popup is a separate top-level HWND that the fixture window owns.
                $native = Get-FixtureTopLevel { [string]$_.Owner -ceq $window }
                $placement = Get-OwnedWindowEvidence $native
                $entry = @(Framework-Result $run @{ op = 'listWindows' } | Where-Object {
                    $_.processId -eq $fixture.Id -and $_.windowId -ceq [string]$native.Handle })
                Require-Framework ($entry.Count -eq 1 -and $entry[0].ownerWindowId -ceq $window) 'listWindows did not report the owned popup with its owner.'
                $shot = (Get-FrameworkSnapshot $run $entry[0].windowId).data
                $action = Find-FrameworkElement $run $shot @{ role = 'Button'; automationId = 'fixturePopupAction' }
                [IO.File]::Delete((Join-Path $stateDir 'popup-click.txt'))
                Invoke-FixtureButton $run $action 'popup-click.txt' 'clicked'
                Wait-State 'popup.txt' 'closed' 6000
                [void](Framework-Result $run @{ op = 'getElementInfo'; ref = $action.ref } 'STALE_REFERENCE')
                [ordered]@{ win32Owner = $native.Owner; win32Class = $native.ClassName; independentUia = $placement
                    listedWithOwner = $true; popupElements = $shot.elements.Count; actionObserved = $true }
            } finally {
                if ((Read-State 'popup.txt') -ceq 'open') {
                    [IO.File]::WriteAllText((Join-Path $stateDir 'close-popup'), '')
                    Wait-State 'popup.txt' 'closed'
                }
            }
        }
    } finally { Set-FixturePage 0 }
}

function Test-NativeFixtureGrid($row, $run, $window) {
    if ($row.framework -notin 'Win32', 'Mfc') { return }
    Invoke-FrameworkCase $row 'ownerDrawnButton' ([bool]$window -and !$run.closedProtocol -and !$run.uncertainAction) {
        $snapshot = (Get-FrameworkSnapshot $run $window).data
        $button = Find-FrameworkElement $run $snapshot @{ role = 'Button'; name = 'Owner-drawn action'; automationId = '1015' }
        $before = [int](Read-State 'owner-draw.txt')
        Require-Framework ((Framework-Result $run @{ op = 'invoke'; ref = $button.ref }).performed) 'Owner-drawn button did not report dispatch.'
        Wait-FrameworkEffect $run 'owner-draw.txt' ([string]($before + 1))
    }
    Invoke-FrameworkCase $row 'largeVirtualReport' ([bool]$window -and !$run.closedProtocol) {
        [IO.File]::WriteAllText((Join-Path $stateDir 'large-grid'), '')
        Wait-State 'grid-rows.txt' '10000'
        try {
            $large = (Get-FrameworkSnapshot $run $window).data
            Require-Framework ($large.truncated -and $large.elements.Count -eq 2000) 'The large window did not report its actual capture limit.'
            [void](Find-FrameworkElement $run $large @{ name = 'Increment fixture counter'; role = 'Button' } '' 'INCOMPLETE_SNAPSHOT')
            $scope = @($large.elements | Where-Object { $_.processId -eq $fixture.Id -and $_.automationId -ceq '1017' })
            Require-Framework ($scope.Count -eq 1) 'The virtual report container was not uniquely captured.'
            $slice = (Get-FrameworkSnapshot $run $window $scope[0].ref 6 60).data
            Require-Framework ($slice.truncated -and $slice.elements.Count -eq 60 -and $slice.elements[0].automationId -ceq '1017') 'The virtual report scope did not preserve its size limit.'
            @{ applicationRows = 10000; windowCapture = $large.elements.Count; scopeCapture = $slice.elements.Count;
                offscreenScopeElements = @($slice.elements | Where-Object offscreen).Count }
        } finally {
            [IO.File]::WriteAllText((Join-Path $stateDir 'compact-grid'), '')
            Wait-State 'grid-rows.txt' '12'
        }
    }
}

function Read-FrameworkBaseline($row) {
    $run = $null
    try {
        $run = Start-FrameworkAgent $row.backend
        $row.baselineWindowId = Get-FrameworkWindow $run
        $row.baselineTree = Get-FrameworkTree (Get-FrameworkSnapshot $run $row.baselineWindowId).data
    } catch {
        $row.baselineFailure = $_.Exception.Message
    } finally { if ($run) { Stop-Cli $run.cli JNA } }
}

function Compare-FrameworkTrees($name, $rows) {
    $a, $b = $rows
    $comparison = [ordered]@{ framework = $name; order = @($a.backend, $b.backend); status = 'INCONCLUSIVE' }
    if (!$a.baselineTree -or !$b.baselineTree) {
        $comparison.reason = 'Two baseline trees are required.'
        return $comparison
    }
    # Partial trees are still compared. Each entry carries its partial mark, so both Agents must
    # have left out the same branches. Equality says nothing about what the provider withheld.
    $comparison.completeTrees = !($a.baselineTree.truncated -or $b.baselineTree.truncated)
    $comparison.partialElements = @($a.baselineTree.partialElements, $b.baselineTree.partialElements)
    $separator = [Environment]::NewLine
    $comparison.chromeMatches = ($a.baselineTree.chrome -join $separator) -ceq ($b.baselineTree.chrome -join $separator)
    $comparison.contentMatches = ($a.baselineTree.content -join $separator) -ceq ($b.baselineTree.content -join $separator)
    $comparison.windowIdMatches = $a.baselineWindowId -ceq $b.baselineWindowId
    $comparison.status = if ($comparison.contentMatches -and $comparison.windowIdMatches) { 'PASS' } else { 'FAIL' }
    return $comparison
}

function Get-FrameworkAccessibility($name, $rows) {
    $result = [ordered]@{}
    $window = ($rows | Where-Object { $_.windowId } | Select-Object -First 1).windowId
    $probe = Join-Path $FixtureRoot 'msaa-probe.exe'
    if (!$window -or ![IO.File]::Exists($probe)) {
        $result.msaa = @{ status = 'NOT_RUN'; reason = 'Fixture window ID or MSAA probe missing.' }
    } else {
        try {
            Require-Framework ($window -match '^\d+$') 'The Windows adapter did not report a decimal HWND.'
            $diag = Read-Diagnostic $probe "$window $($fixture.Id)" -Utf8
            $observed = ConvertFrom-Json -InputObject $diag.stdout
            $result.msaa = if ($diag.exitCode -eq 0 -and $observed.status -eq 'ok') {
                @{ status = 'PASS'; observation = $observed }
            } else { @{ status = 'INCONCLUSIVE'; reason = $observed.error; exitCode = $diag.exitCode } }
        } catch { $result.msaa = @{ status = 'INCONCLUSIVE'; reason = $_.Exception.Message } }
    }
    if ($name -in 'Swing', 'Awt') {
        $bridge = Join-Path $PSScriptRoot '../tests/fixtures/swing-awt/Probe-JavaAccessBridge.ps1'
        $shell = Join-Path $env:SystemRoot 'System32/WindowsPowerShell/v1.0/powershell.exe'
        try {
            $diag = Read-Diagnostic $shell "-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File ""$bridge"" ""$stateDir"" ""$title""" 15000 -Utf8
            $result.jab = if ($diag.exitCode -eq 0) {
                @{ status = 'PASS'; observation = (ConvertFrom-Json -InputObject $diag.stdout) }
            } else { @{ status = 'INCONCLUSIVE'; reason = $diag.stderr; exitCode = $diag.exitCode } }
        } catch { $result.jab = @{ status = 'INCONCLUSIVE'; reason = $_.Exception.Message } }
    }
    return $result
}

function Test-FrameworkLifetime($rows) {
    $agents = @{}
    try {
        foreach ($row in $rows) {
            Invoke-FrameworkCase $row 'captureBeforeExit' ([bool]$row.windowId) {
                $run = Start-FrameworkAgent $row.backend
                $agents[$row.backend] = $run
                $run.capture = (Get-FrameworkSnapshot $run $row.windowId '' 0 1).data
            }
        }
        if (!$agents.Count) { return }
        [IO.File]::WriteAllText((Join-Path $stateDir 'close-fixture'), '')
        Require-Framework ($fixture.WaitForExit(5000) -and $fixture.ExitCode -eq 0) 'Fixture failed to exit normally.'
        foreach ($row in $rows) {
            $run = $agents[$row.backend]
            Invoke-FrameworkCase $row 'processExitInvalidatesReference' ([bool]$run.capture) {
                [void](Framework-Result $run @{ op = 'getElementInfo'; ref = $run.capture.elements[0].ref } 'STALE_REFERENCE')
                $windows = @(Framework-Result $run @{ op = 'listWindows' } | Where-Object {
                    $_.processId -eq $fixture.Id -and $_.name -ceq $title
                })
                Require-Framework (!$windows.Count) 'The exited fixture still appeared in listWindows.'
            }
            if ($run) { $row.lifetimeRequests = $run.requests }
            $row.status = Get-FrameworkStatus $row.checks
        }
    } finally {
        $cleanupFailure = $null
        foreach ($run in $agents.Values) {
            try { Stop-Cli $run.cli JNA } catch { if (!$cleanupFailure) { $cleanupFailure = $_ } }
        }
        if ($cleanupFailure) { throw $cleanupFailure }
    }
}

function Measure-FrameworkSessions($rows, $spec) {
    # Only operations that already passed the functional gate enter the timing loop.
    $required = 'window', 'tree', 'buttonLocatorAndLiveMetadata', 'editLocatorAndLiveMetadata', 'invokeAndDuplicateRequest', 'setValueAndEmpty'
    $ready = @()
    foreach ($row in $rows) {
        $passed = @($row.checks | Where-Object { $_.name -in $required -and $_.status -eq 'PASS' })
        $row.performance = @{ status = 'NOT_RUN'; reason = 'Functional prerequisite did not pass.';
            sessions = New-Object 'Collections.Generic.List[object]' }
        if ($passed.Count -eq $required.Count) {
            $row.performance.reason = $null
            $ready += $row
        }
    }
    for ($pair = 1; $pair -le $Pairs; $pair++) {
        foreach ($row in $ready) {
            $sample = [ordered]@{ pair = $pair; status = 'NOT_RUN' }
            $row.performance.sessions.Add($sample)
            Measure-FrameworkAgent $row $spec $sample
            if ($sample.uncertainAction) {
                foreach ($pending in $ready) {
                    $pending.performance.status = Get-FrameworkStatus $pending.performance.sessions
                    $pending.performance.reason = 'Remaining samples were skipped because a fixture action outcome was uncertain.'
                }
                return
            }
        }
        [array]::Reverse($ready)
    }
    foreach ($row in $ready) { $row.performance.status = Get-FrameworkStatus $row.performance.sessions }
}

function Measure-FrameworkAgent($row, $spec, $sample) {
    $run = $null
    try {
        $run = Start-FrameworkAgent $row.backend
        $sample.processStartMs = $run.processStartMs
        [void](Framework-Result $run @{ op = 'getCapabilities' })
        $sample.firstCapabilitiesSinceStartMs = $run.clock.Elapsed.TotalMilliseconds
        $window = Get-FrameworkWindow $run
        $first = Get-FrameworkSnapshot $run $window
        $sample.firstSnapshotMs = $first.ms
        $sample.firstSnapshotSinceStartMs = $run.clock.Elapsed.TotalMilliseconds
        Require-Framework (!$first.data.truncated -and $first.data.elements.Count -eq $row.tree.elements) 'Benchmark baseline tree workload changed.'
        $sample.resourcesBefore = Process-Sample $run.cli
        $sample.iterations = New-Object 'Collections.Generic.List[object]'
        $latencies = [ordered]@{}
        for ($i = 0; $i -lt $Warmup + $Iterations; $i++) {
            $requestOffset = $run.requests.Count
            $shot = (Get-FrameworkSnapshot $run $window).data
            Require-Framework (!$shot.truncated -and $shot.elements.Count -eq $row.tree.elements) 'Benchmark snapshot workload changed.'
            $button = Find-FrameworkElement $run $shot @{ role = 'Button'; name = 'Increment fixture counter' }
            $edit = Find-FrameworkElement $run $shot (Get-FixtureLocator $spec 'edit' 'Edit')
            $live = Framework-Result $run @{ op = 'getElementInfo'; ref = $edit.ref }
            Require-Framework ($live.ref -ceq $edit.ref -and $live.processId -eq $fixture.Id) 'Benchmark live element changed.'
            $value = 'framework-benchmark-' + [guid]::NewGuid()
            Require-Framework ((Framework-Result $run @{ op = 'setValue'; ref = $edit.ref; value = $value }).performed) 'Benchmark SetValue did not report dispatch.'
            Wait-FrameworkEffect $run 'value.txt' $value
            $before = [int](Read-State 'count.txt')
            Require-Framework ((Framework-Result $run @{ op = 'invoke'; ref = $button.ref }).performed) 'Benchmark Invoke did not report dispatch.'
            Wait-FrameworkEffect $run 'count.txt' ([string]($before + 1))
            if ($i -lt $Warmup) { continue }
            $times = [ordered]@{}
            $keys = 'snapshot', 'findButton', 'findEdit', 'getElementInfo', 'setValue', 'invoke'
            for ($k = 0; $k -lt $keys.Count; $k++) { $times[$keys[$k]] = $run.requests[$requestOffset + $k].ms }
            $sample.iterations.Add($times)
            Add-UiaLatencies $latencies $times
        }
        $sample.latencyMs = Get-UiaLatencySummary $latencies
        $sample.resourcesAfter = Process-Sample $run.cli
        $sample.status = 'PASS'
    } catch {
        $sample.status = 'FAIL'
        $sample.reason = $_.Exception.Message
    } finally {
        if ($run) {
            $sample.uncertainAction = $run.uncertainAction
            $sample.failureCount = if ($sample.status -eq 'FAIL') { 1 } else { 0 }
            $sample.timeoutCount = @($run.requests | Where-Object { $_.code -in 'TIMEOUT', 'ACTION_OUTCOME_UNKNOWN' }).Count
            $sample.failures = @($run.requests | Where-Object code -NE 'OK')
            Stop-Cli $run.cli JNA
        }
    }
}
