# Windows PowerShell 5.1. One UTF-8 JSON object per line in both directions.
# Keep provider objects in this MTA process. Only explicitly projected fields leave it.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$encoding = [System.Text.UTF8Encoding]::new($false)
$reader = [System.IO.StreamReader]::new([Console]::OpenStandardInput(), $encoding)
$writer = [System.IO.StreamWriter]::new([Console]::OpenStandardOutput(), $encoding)
$writer.AutoFlush = $true
$script:held = @{}
$script:anchor = $null
$messages = @{
    BACKEND_UNAVAILABLE = 'UI Automation could not access the interactive desktop.'
    WINDOW_NOT_FOUND = 'The requested top-level window is unavailable.'
    STALE_REFERENCE = 'The captured element or its window is no longer current.'
    PATTERN_UNSUPPORTED = 'The element does not support the requested pattern.'
    PRECONDITION_FAILED = 'The request or current element state does not permit this operation.'
    ACTION_OUTCOME_UNKNOWN = 'The provider call did not complete successfully. Its effect is unknown.'
}

function Fail([string]$code) {
    $exception = [System.InvalidOperationException]::new($messages[$code])
    $exception.Data['workerError'] = $code
    throw $exception
}

function ShortText([string]$s) {
    if ($s.Length -le 256) { return $s }
    $limit = 256
    if ([char]::IsHighSurrogate($s[$limit - 1])) { $limit-- }
    return $s.Substring(0, $limit)
}

try {
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $script:walker = [System.Windows.Automation.TreeWalker]::ControlViewWalker
} catch {
    $script:walker = $null
}

function Desktop {
    if (!$script:walker -or ![Environment]::UserInteractive) { Fail 'BACKEND_UNAVAILABLE' }
    $process = [System.Diagnostics.Process]::GetCurrentProcess()
    try {
        if ($process.SessionId -eq 0) { Fail 'BACKEND_UNAVAILABLE' }
    } finally { $process.Dispose() }
    try {
        $root = [System.Windows.Automation.AutomationElement]::RootElement
        # RootElement alone can be a proxy even without a usable provider.
        $null = $root.GetRuntimeId()
        $null = $script:walker.GetFirstChild($root)
        return $root
    } catch { Fail 'BACKEND_UNAVAILABLE' }
}

function RuntimeKey($element) {
    $ids = $element.GetRuntimeId()
    if (!$ids -or !$ids.Length) { Fail 'STALE_REFERENCE' }
    return [string]::Join('.', [string[]]$ids)
}

function WindowId($current) {
    # UIA exposes HWND as a signed Int32, including in a 64-bit process.
    return (([long]$current.NativeWindowHandle) -band 4294967295L).ToString(
        [System.Globalization.CultureInfo]::InvariantCulture)
}

function WindowById([string]$id, $desktop) {
    try {
        [long]$number = 0
        if ($id -notmatch '^[1-9][0-9]{0,9}$' -or
            ![long]::TryParse($id, [ref]$number) -or $number -gt 4294967295L) {
            Fail 'WINDOW_NOT_FOUND'
        }
        if ([IntPtr]::Size -eq 4 -and $number -gt [int]::MaxValue) { $number -= 4294967296L }
        $window = [System.Windows.Automation.AutomationElement]::FromHandle([IntPtr]::new($number))
        if (!$window -or (WindowId $window.Current) -cne $id) { Fail 'WINDOW_NOT_FOUND' }
        $parent = $script:walker.GetParent($window)
        if (!$parent -or ![System.Windows.Automation.Automation]::Compare($desktop, $parent)) {
            Fail 'WINDOW_NOT_FOUND'
        }
        return $window
    } catch { Fail 'WINDOW_NOT_FOUND' }
}

function Windows($desktop) {
    for ($attempt = 0; $attempt -lt 2; $attempt++) {
        try {
            $windows = EnumerateWindows $desktop
            return ,$windows
        } catch [System.Windows.Automation.ElementNotAvailableException] {
            # A transient popup can disappear between two siblings. Restart this read once.
            if ($attempt -eq 1) { Fail 'STALE_REFERENCE' }
        }
    }
}

function EnumerateWindows($desktop) {
    $results = New-Object 'System.Collections.Generic.List[object]'
    $node = $script:walker.GetFirstChild($desktop)
    for ($i = 0; $node -and $i -lt 4096; $i++) {
        $current = $node.Current
        $id = WindowId $current
        if ($id -ne '0' -and $current.ProcessId -gt 0) {
            $name = ''
            if (!$current.IsPassword -and $current.ControlType -ne [System.Windows.Automation.ControlType]::Edit -and
                !(Pattern $node ([System.Windows.Automation.ValuePattern]::Pattern))) {
                $name = ShortText $current.Name
            }
            $results.Add(@{ windowId = $id; processId = $current.ProcessId; name = $name })
        }
        $node = $script:walker.GetNextSibling($node)
    }
    if ($node) { Fail 'PRECONDITION_FAILED' }
    return ,$results.ToArray()
}

function Pattern($node, $id) {
    $instance = $null
    if ($node.TryGetCurrentPattern($id, [ref]$instance)) { return $instance }
    return $null
}

function PublicInfo($entry, [bool]$capturing = $false, [bool]$verify = $false) {
    $node = $entry.node
    $current = $node.Current
    $invoke = Pattern $node ([System.Windows.Automation.InvokePattern]::Pattern)
    $valuePattern = Pattern $node ([System.Windows.Automation.ValuePattern]::Pattern)
    $actions = New-Object 'System.Collections.Generic.List[string]'
    if ($invoke) { $actions.Add('invoke') }
    if ($valuePattern -and !$valuePattern.Current.IsReadOnly) { $actions.Add('setValue') }
    $bounds = $null
    $rect = $current.BoundingRectangle
    if (!$rect.IsEmpty) {
        $coords = @($rect.X, $rect.Y, $rect.Width, $rect.Height)
        if (!($coords | Where-Object { [double]::IsNaN($_) -or [double]::IsInfinity($_) })) {
            $bounds = @{ x = $rect.X; y = $rect.Y; width = $rect.Width; height = $rect.Height }
        }
    }
    $name = ''
    $role = $current.ControlType.ProgrammaticName.Replace('ControlType.', '')
    if (!$current.IsPassword -and !$valuePattern -and $role -ne 'Edit') {
        $name = [string]$current.Name
    }
    $automationId = [string]$current.AutomationId
    $className = [string]$current.ClassName
    if ($capturing) {
        # Clipped identifiers cannot safely distinguish virtualized items. Refuse mutations on them.
        $entry.clipped = $name.Length -gt 256 -or $role.Length -gt 256 -or
            $automationId.Length -gt 256 -or $className.Length -gt 256
        $entry.name = ShortText $name
        $entry.role = ShortText $role
        $entry.automationId = ShortText $automationId
        $entry.className = ShortText $className
        $entry.protectChildren = $current.IsPassword -or $role -eq 'Edit' -or
            [bool]$valuePattern
    } elseif ($verify -and ($entry.clipped -or !([string]::Equals($entry.name, $name)) -or
        !([string]::Equals($entry.role, $role)) -or
        !([string]::Equals($entry.automationId, $automationId)) -or
        !([string]::Equals($entry.className, $className)))) {
        Fail 'STALE_REFERENCE'
    }
    return @{
        key = $entry.key; parentKey = $entry.parentKey; name = ShortText $name
        role = ShortText $role; automationId = ShortText $automationId; className = ShortText $className
        processId = $current.ProcessId; bounds = $bounds; enabled = $current.IsEnabled
        offscreen = $current.IsOffscreen; actions = $actions.ToArray(); backend = 'UIA'
    }
}

function Visit($node, $parentKey, [int]$depth, $capture) {
    $key = [guid]::NewGuid().ToString('N')
    $entry = @{ key = $key; parentKey = $parentKey; node = $node
        identity = RuntimeKey $node; processId = $node.Current.ProcessId }
    $info = PublicInfo $entry $true
    if ($entry.clipped) {
        $capture.truncated = $true
    }
    $capture.entries[$key] = $entry
    $capture.elements.Add($info)
    # Providers may repeat an editable control's contents in descendant text nodes.
    if ($entry.protectChildren) { return }
    $child = $script:walker.GetFirstChild($node)
    while ($child) {
        if ($capture.elements.Count -ge $capture.maxElements -or $depth -ge $capture.maxDepth) {
            $capture.truncated = $true
            return
        }
        Visit $child $key ($depth + 1) $capture
        $child = $script:walker.GetNextSibling($child)
    }
}

function Capture($request, $desktop) {
    $script:held = @{}
    $script:anchor = $null
    if ($null -eq $request.maxDepth -or $request.maxDepth -lt 0 -or $request.maxDepth -gt 32 -or
        $request.maxElements -lt 1 -or $request.maxElements -gt 2000) { Fail 'PRECONDITION_FAILED' }
    $window = WindowById $request.windowId $desktop
    $anchor = @{ id = $request.windowId; identity = RuntimeKey $window
        node = $window; processId = $window.Current.ProcessId }
    $capture = @{ entries = @{}; elements = New-Object 'System.Collections.Generic.List[object]'
        maxDepth = $request.maxDepth; maxElements = $request.maxElements; truncated = $false }
    try { Visit $window $null 0 $capture } catch { Fail 'STALE_REFERENCE' }
    $script:held = $capture.entries
    $script:anchor = $anchor
    return @{ elements = $capture.elements.ToArray(); truncated = $capture.truncated }
}

function Resolve($request, $desktop) {
    $entry = $script:held[[string]$request.key]
    if (!$entry -or !$script:anchor -or $request.processId -ne $entry.processId) { Fail 'STALE_REFERENCE' }
    try {
        $anchor = $script:anchor
        $live = WindowById $anchor.id $desktop
        if ($live.Current.ProcessId -ne $anchor.processId -or (RuntimeKey $live) -cne $anchor.identity -or
            ![System.Windows.Automation.Automation]::Compare($live, $anchor.node) -or
            $entry.node.Current.ProcessId -ne $entry.processId -or (RuntimeKey $entry.node) -cne $entry.identity) {
            Fail 'STALE_REFERENCE'
        }
        $ancestor = $entry.node
        $expected = $entry
        while ($null -ne $expected.parentKey) {
            $expected = $script:held[$expected.parentKey]
            $ancestor = $script:walker.GetParent($ancestor)
            if (!$ancestor -or ![System.Windows.Automation.Automation]::Compare($ancestor, $expected.node) -or
                $ancestor.Current.ProcessId -ne $expected.processId -or (RuntimeKey $ancestor) -cne $expected.identity) {
                Fail 'STALE_REFERENCE'
            }
        }
        if ([System.Windows.Automation.Automation]::Compare($ancestor, $live)) { return $entry }
    } catch { Fail 'STALE_REFERENCE' }
    Fail 'STALE_REFERENCE'
}

function ActOrInspect($request, $desktop) {
    $entry = Resolve $request $desktop
    try { $info = PublicInfo $entry $false ($request.op -cne 'getElementInfo') } catch { Fail 'STALE_REFERENCE' }
    if ($request.op -ceq 'getElementInfo') { return $info }
    if (!$info.enabled -or $info.offscreen) { Fail 'PRECONDITION_FAILED' }
    if ($request.op -ceq 'invoke') {
        try { $pattern = Pattern $entry.node ([System.Windows.Automation.InvokePattern]::Pattern) }
        catch { Fail 'STALE_REFERENCE' }
        if (!$pattern) { Fail 'PATTERN_UNSUPPORTED' }
        try { $pattern.Invoke() } catch { Fail 'ACTION_OUTCOME_UNKNOWN' }
    } else {
        if ($request.value -isnot [string] -or $request.value.Length -gt 16384) { Fail 'PRECONDITION_FAILED' }
        try {
            $pattern = Pattern $entry.node ([System.Windows.Automation.ValuePattern]::Pattern)
            $readOnly = $pattern -and $pattern.Current.IsReadOnly
        } catch { Fail 'STALE_REFERENCE' }
        if (!$pattern) { Fail 'PATTERN_UNSUPPORTED' }
        if ($readOnly) { Fail 'PRECONDITION_FAILED' }
        try { $pattern.SetValue($request.value) } catch { Fail 'ACTION_OUTCOME_UNKNOWN' }
    }
    return @{ performed = $true }
}

while ($null -ne ($line = $reader.ReadLine())) {
    try {
        if ($line.Length -gt 131072) { Fail 'PRECONDITION_FAILED' }
        try { $request = ConvertFrom-Json -InputObject $line } catch { Fail 'PRECONDITION_FAILED' }
        $desktop = $null
        if ($request.op -cne 'getCapabilities') { $desktop = Desktop }
        switch -CaseSensitive ($request.op) {
            'getCapabilities' {
                $result = @{ available = $false; backend = 'UIA'; physicalInput = $false
                    screenshot = $false; operations = @() }
                try {
                    $null = Desktop
                    $result.available = $true
                    $result.operations = @('getCapabilities','listWindows','snapshot','findElement',
                        'getElementInfo','invoke','setValue')
                } catch { $result.reason = $messages['BACKEND_UNAVAILABLE'] }
            }
            'listWindows' { $result = Windows $desktop }
            'snapshot' { $result = Capture $request $desktop }
            'getElementInfo' { $result = ActOrInspect $request $desktop }
            'invoke' { $result = ActOrInspect $request $desktop }
            'setValue' { $result = ActOrInspect $request $desktop }
            default { Fail 'PRECONDITION_FAILED' }
        }
        $response = @{ ok = $true; result = $result }
    } catch {
        $code = $_.Exception.Data['workerError']
        if (!$code -or !$messages.ContainsKey($code)) { $code = 'BACKEND_UNAVAILABLE' }
        $response = @{ ok = $false; error = @{ code = $code; message = $messages[$code] } }
    }
    $writer.WriteLine((ConvertTo-Json -InputObject $response -Compress -Depth 8))
    $request = $line = $result = $response = $null
}
