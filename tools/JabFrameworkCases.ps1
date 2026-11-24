# Java Access Bridge regression for the Swing and AWT fixtures. Dot-sourced by Test-UiaFrameworks.ps1
# after UiaFrameworkCases.ps1. The fixture owns control state: an Agent reply never confirms an effect.

function Test-JabBackend([string]$backend) { return $backend -in 'Jab', 'CppJab' }

# The UI Automation Agent of the same implementation, for cross-backend reference checks.
function Get-JabUiaBackend([string]$backend) { if ($backend -eq 'Jab') { 'JNA' } else { 'Cpp' } }

function Get-JabRow($snapshot, [string]$nativeRole, [string]$name) {
    return @($snapshot.elements | Where-Object { $_.nativeRole -ceq $nativeRole -and $_.name -ceq $name })
}

function Read-JabFile([string]$directory, [string]$file) {
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    try {
        $stream = [IO.File]::Open((Join-Path $directory $file), [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        try {
            $reader = New-Object IO.StreamReader($stream)
            try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
        } finally { $stream.Dispose() }
    } catch [IO.IOException] { return $null }
}

function Wait-JabFile([string]$directory, [string]$file, [string]$value, [int]$timeoutMs = 15000) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ((Read-JabFile $directory $file) -ceq $value) { return $true }
        Start-Sleep -Milliseconds 25
    } while ($clock.ElapsedMilliseconds -lt $timeoutMs)
    return $false
}

# The fixture state stays at $value for the whole period.
function Test-JabStateUnchanged([string]$file, [string]$value, [int]$milliseconds = 1200) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ((Read-FixtureState $file) -cne $value) { return $false }
        Start-Sleep -Milliseconds 50
    } while ($clock.ElapsedMilliseconds -lt $milliseconds)
    return $true
}

# A second fixture JVM with its own state directory, for multi-JVM and bridge-less checks.
function Start-JabSecondFixture($launch, [string]$mode, [string]$java, [bool]$bridge) {
    $directory = Join-Path ([IO.Path]::GetTempPath()) ('jab-second-' + [guid]::NewGuid())
    [void][IO.Directory]::CreateDirectory($directory)
    $second = @{ stateDir = $directory; title = "JAB second $mode fixture " + [guid]::NewGuid(); bridge = $bridge }
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $java
    $property = if ($bridge) { '-Djavax.accessibility.assistive_technologies=com.sun.java.accessibility.AccessBridge ' }
    $start.Arguments = "$property-cp ""$([IO.Path]::GetDirectoryName($launch.source))"" FrameworkFixture $mode ""$directory"" ""$($second.title)"""
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $second.process = [Diagnostics.Process]::Start($start)
    if (!(Wait-JabFile $directory 'ready' ([string]$second.process.Id))) {
        Stop-JabSecondFixture $second
        throw 'The second fixture JVM did not become ready.'
    }
    $second.runtime = Read-JabFile $directory 'framework.txt'
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $second.process.Refresh()
        $second.window = $second.process.MainWindowHandle.ToInt64()
        if (!$second.window) { Start-Sleep -Milliseconds 50 }
    } while (!$second.window -and $clock.ElapsedMilliseconds -lt 5000)
    return $second
}

function Stop-JabSecondFixture($second) {
    if (!$second -or !$second.process) { return }
    try {
        if (!$second.process.HasExited) {
            [IO.File]::WriteAllText((Join-Path $second.stateDir 'close-fixture'), '')
            if (!$second.process.WaitForExit(5000)) { $second.process.Kill(); [void]$second.process.WaitForExit(5000) }
        }
    } finally {
        $second.process.Dispose()
        Remove-Item -LiteralPath $second.stateDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# setValue judged by fixture state. A refusal that left the text unchanged is the provider's answer.
function Set-JabValue($run, $edit, [string]$value, [string]$file = 'value.txt', $expectedState = $value) {
    $before = Read-FixtureState $file
    $response = Send-UiaRequest $run.cli @{ op = 'setValue'; ref = $edit.ref; value = $value } ([guid]::NewGuid().ToString()) 15000
    $code = if ($response.reply.ok) { 'OK' } else { $response.reply.error.code }
    $run.requests.Add(@{ op = 'setValue'; code = $code; ms = $response.ms })
    if ($code -ceq 'OK') {
        Require-Framework ($response.reply.result.performed -eq $true -and $response.reply.result.effectVerified -eq $false) 'setValue reply must report dispatch without a verified effect.'
        Wait-FrameworkEffect $run $file $expectedState
        return
    }
    Require-Framework ($code -ceq 'ACTION_OUTCOME_UNKNOWN') "setValue expected OK, received $code."
    $evidence = [ordered]@{ agentReply = $code; stateBefore = $before; expectedState = "$file=$expectedState" }
    if (!(Test-JabStateUnchanged $file $before)) {
        $run.uncertainAction = $true
        $evidence.observedState = Read-FixtureState $file
        Stop-FrameworkCase 'UNCLASSIFIED' 'setValue was not confirmed and the fixture text changed.' $evidence
    }
    $evidence.observedState = $before
    $evidence.cause = 'java.awt.TextComponent contexts do not implement AccessibleEditableText, which setTextContents requires.'
    Stop-FrameworkCase 'JAB_PROVIDER_LIMITATION' 'The bridge did not confirm setTextContents and the fixture text did not change.' $evidence
}

function Invoke-JabButton($run, $button, [string]$file, [string]$expected) {
    $reply = (Invoke-FrameworkRequest $run @{ op = 'invoke'; ref = $button.ref }).reply.result
    Require-Framework ($reply.performed -eq $true -and $reply.effectVerified -eq $false) 'An invoke reply must report dispatch without a verified effect.'
    Wait-FrameworkEffect $run $file $expected
}

function Get-JabModalWindow($run, [string]$name, [string]$owner) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $rows = @(Framework-Result $run @{ op = 'listWindows' } | Where-Object { $_.processId -eq $fixture.Id -and $_.name -ceq $name })
        if ($rows.Count -eq 1) {
            Require-Framework ($rows[0].ownerWindowId -ceq $owner) 'The modal row did not name the fixture window as its owner.'
            return $rows[0].windowId
        }
        Start-Sleep -Milliseconds 100
    } while ($clock.ElapsedMilliseconds -lt 5000)
    throw 'The open modal dialog was not listed.'
}

# Reads the dialog through its own snapshot, closes it through its button and checks that its references die.
function Close-JabModal($run, [string]$modalWindow, [string]$buttonName, [string]$file) {
    $snapshot = (Get-FrameworkSnapshot $run $modalWindow).data
    Require-Framework (!$snapshot.truncated -and $snapshot.elements[0].nativeRole -ceq 'dialog' -and $snapshot.elements[0].role -ceq 'Window') 'The modal snapshot did not start at a complete dialog.'
    $close = Find-FrameworkElement $run $snapshot @{ role = 'Button'; name = $buttonName }
    Invoke-JabButton $run $close $file 'closed'
    [void](Framework-Result $run @{ op = 'getElementInfo'; ref = $close.ref } 'STALE_REFERENCE')
    [void](Framework-Result $run @{ op = 'snapshot'; windowId = $modalWindow } 'WINDOW_NOT_FOUND')
    return @{ elements = $snapshot.elements.Count
        content = @($snapshot.elements | ForEach-Object { [ordered]@{ nativeRole = $_.nativeRole; role = $_.role; name = $_.name; actions = @($_.actions) } }) }
}

function Get-JabInventory($snapshot, [string]$framework) {
    # nativeRole, accessible name. An empty name matches the first element of that role.
    $expected = if ($framework -eq 'Swing') {
        @(@('JButton', 'push button', 'Increment fixture counter'), @('JTextField', 'text', 'Fixture edit'),
          @('JTextArea', 'text', 'Fixture text area'), @('JPasswordField', 'password text', ''),
          @('JCheckBox', 'check box', 'Fixture check box'), @('JRadioButton', 'radio button', 'Fixture radio one'),
          @('JComboBox', 'combo box', 'Fixture combo box'), @('JList', 'list', 'Fixture list'),
          @('JTable', 'table', 'Fixture table'), @('JTree', 'tree', 'Fixture tree'),
          @('JTabbedPane', 'page tab list', 'Fixture tabs'), @('JTabbedPane tab', 'page tab', 'Data'),
          @('JMenuBar', 'menu bar', ''), @('JMenu', 'menu', 'Fixture menu'), @('JMenuItem', 'menu item', 'Fixture menu item'),
          @('JScrollPane', 'scroll pane', 'Items'), @('JLabel', 'label', 'Editable text'),
          @('Custom component with AccessibleAction', 'push button', 'Accessible custom swatch'))
    } else {
        @(@('Button', 'push button', 'Increment fixture counter'), @('TextField', 'text', 'Fixture edit'),
          @('TextField with echo character', 'text', 'Fixture password'),
          @('Checkbox', 'check box', 'Fixture check box'), @('Choice', 'combo box', 'Fixture combo box'),
          @('List', 'list', 'Fixture list'), @('Panel', 'panel', ''), @('Label', 'label', 'Editable text'))
    }
    $rows = foreach ($item in $expected) {
        $found = @($snapshot.elements | Where-Object { $_.nativeRole -ceq $item[1] -and (!$item[2] -or $_.name -ceq $item[2]) })
        $row = [ordered]@{ control = $item[0]; nativeRole = $item[1]; name = $item[2]; found = $found.Count }
        if ($found.Count) {
            $row.role = $found[0].role
            $row.actions = @($found[0].actions)
            $row.enabled = $found[0].enabled
            $row.offscreen = $found[0].offscreen
            $row.children = @($snapshot.elements | Where-Object parentRef -CEQ $found[0].ref).Count
        }
        $row
    }
    return @($rows)
}

function Invoke-JabFunction($row, $spec, $launch) {
    $row.checks = New-Object 'Collections.Generic.List[object]'
    $state = @{}
    $run = $null
    $swing = $row.framework -eq 'Swing'
    try {
        $run = Start-FrameworkAgent $row.backend
        $row.requests = $run.requests
        Invoke-FrameworkCase $row 'capabilities' $true {
            $cap = Framework-Result $run @{ op = 'getCapabilities' }
            Require-Framework ($cap.available -and $cap.backend -ceq 'JAB' -and !$cap.physicalInput -and !$cap.screenshot -and
                (@($cap.operations | Sort-Object) -join ',') -ceq 'findElement,getCapabilities,getElementInfo,invoke,listWindows,setValue,snapshot' -and
                $cap.bridge.connectedWindows -ge 1 -and $cap.bridge.javaWindows -ge $cap.bridge.connectedWindows) 'Invalid Java Access Bridge capabilities.'
            $row.bridge = $cap.bridge
            @{ bridge = $cap.bridge; firstRequestMs = $run.requests[0].ms }
        }
        Invoke-FrameworkCase $row 'window' (!$run.closedProtocol) {
            $rows = @(Framework-Result $run @{ op = 'listWindows' } | Where-Object { $_.processId -eq $fixture.Id -and $_.name -ceq $title })
            Require-Framework ($rows.Count -eq 1 -and $rows[0].windowId -and $null -eq $rows[0].PSObject.Properties['ownerWindowId']) 'Expected one unowned window with the fixture PID and title.'
            $state.window = $rows[0].windowId
            $row.windowId = $state.window
            $fixture.Refresh()
            Require-Framework ([long]$state.window -eq $fixture.MainWindowHandle.ToInt64()) 'The window ID is not the HWND of the fixture frame.'
        }
        Invoke-FrameworkCase $row 'tree' ([bool]$state.window) {
            $state.snapshot = (Get-FrameworkSnapshot $run $state.window).data
            $row.tree = Get-FrameworkTree $state.snapshot
            Require-Framework (!$row.tree.truncated -and $row.tree.partialElements -eq 0 -and $row.tree.foreign -eq 0) 'The whole-window snapshot is incomplete or contains another process.'
            Require-Framework (!@($state.snapshot.elements | Where-Object { $_.backend -cne 'JAB' -or $_.automationId -or $_.className -or !$_.nativeRole }).Count) 'A row is not a Java Access Bridge element or carries an invented identifier.'
            $roles = [ordered]@{}
            foreach ($group in $state.snapshot.elements | Group-Object nativeRole | Sort-Object Name) { $roles[$group.Name] = $group.Count }
            @{ elements = $row.tree.elements; nativeRoles = $roles; customRoleElements = @($state.snapshot.elements | Where-Object role -CEQ 'Custom').Count }
        }
        Invoke-FrameworkCase $row 'controlInventory' ([bool]$state.snapshot) {
            $inventory = Get-JabInventory $state.snapshot $row.framework
            $row.controls = $inventory
            $absent = @($inventory | Where-Object { !$_.found } | ForEach-Object control)
            Require-Framework (!$absent.Count) "Controls absent from the bridge tree: $($absent -join ', ')."
            # A painted component without an Accessible implementation has no node at all.
            Require-Framework (!@($state.snapshot.elements | Where-Object name -CMatch 'Visual-only').Count) 'A component without accessibility appeared in the tree.'
            @{ controls = $inventory; componentWithoutAccessibility = 'absent' }
        }
        Invoke-FrameworkCase $row 'buttonLocatorAndLiveMetadata' ([bool]$state.snapshot -and !$run.closedProtocol) {
            $locator = @{ role = 'Button'; name = 'Increment fixture counter' }
            $button = Find-FrameworkElement $run $state.snapshot $locator
            $info = Framework-Result $run @{ op = 'getElementInfo'; ref = $button.ref }
            Require-Framework ($info.ref -ceq $button.ref -and $info.processId -eq $fixture.Id -and $info.parentRef -ceq $button.parentRef -and
                $info.name -ceq $locator.name -and $info.role -ceq 'Button' -and $info.nativeRole -ceq 'push button' -and $info.enabled -and
                !$info.offscreen -and $info.bounds.width -gt 0 -and $info.bounds.height -gt 0 -and (@($info.actions) -join ',') -ceq 'invoke' -and
                $null -eq $info.PSObject.Properties['value']) 'Unexpected live button metadata.'
            [void](Find-FrameworkElement $run $state.snapshot @{ name = $locator.name; role = 'button' } '' 'ELEMENT_NOT_FOUND')
            $state.button = $button
            @{ role = $info.role; nativeRole = $info.nativeRole; actions = $info.actions; bounds = $info.bounds }
        }
        Invoke-FrameworkCase $row 'editLocatorAndLiveMetadata' ([bool]$state.snapshot -and !$run.closedProtocol) {
            $edit = Find-FrameworkElement $run $state.snapshot (Get-FixtureLocator $spec 'edit' 'Edit')
            $info = Framework-Result $run @{ op = 'getElementInfo'; ref = $edit.ref }
            # The name is the label that the application gave the field. Its text is never read.
            Require-Framework ($info.ref -ceq $edit.ref -and $info.role -ceq 'Edit' -and $info.nativeRole -ceq 'text' -and
                $info.name -ceq 'Fixture edit' -and @($info.actions) -ccontains 'setValue' -and $null -eq $info.PSObject.Properties['value'] -and
                !@($state.snapshot.elements | Where-Object { $_.name -cmatch 'initial fixture value|fixed fixture value' }).Count) 'Edit metadata was invalid or exposed text content.'
            $state.edit = $edit
            @{ actions = $info.actions }
        }
        Invoke-FrameworkCase $row 'ambiguousDuplicate' ([bool]$state.snapshot -and !$run.closedProtocol) {
            [void](Find-FrameworkElement $run $state.snapshot @{ role = 'Button'; name = 'Duplicate label' } '' 'AMBIGUOUS_ELEMENT')
        }
        Invoke-FrameworkCase $row 'unnamedElementByScope' ([bool]$state.snapshot -and !$run.closedProtocol) {
            $parents = @{}
            foreach ($node in $state.snapshot.elements) { if ($node.parentRef) { $parents[$node.parentRef] = $true } }
            $leaf = @($state.snapshot.elements | Where-Object { !$_.name -and $_.parentRef -and !$parents[$_.ref] } | Select-Object -First 1)
            Require-Framework ($leaf.Count -eq 1) 'The fixture exposed no unnamed leaf element.'
            $unscoped = if (@($state.snapshot.elements | Where-Object { !$_.name -and $_.role -ceq $leaf[0].role }).Count -gt 1) { 'AMBIGUOUS_ELEMENT' } else { 'OK' }
            [void](Find-FrameworkElement $run $state.snapshot @{ role = $leaf[0].role; name = '' } '' $unscoped)
            $found = Find-FrameworkElement $run $state.snapshot @{ role = $leaf[0].role; name = '' } $leaf[0].ref
            Require-Framework ($found.ref -ceq $leaf[0].ref) 'A scoped lookup of an unnamed element returned another element.'
            @{ role = $leaf[0].role; nativeRole = $leaf[0].nativeRole; unscopedLookup = $unscoped }
        }
        Invoke-FrameworkCase $row 'passwordMetadata' ([bool]$state.snapshot -and !$run.closedProtocol) {
            Require-Framework (!@($state.snapshot.elements | Where-Object { $_.name -cmatch 'synthetic' }).Count) 'The masked text appeared in the tree.'
            if ($swing) {
                $password = Find-FrameworkElement $run $state.snapshot @{ role = 'Edit'; name = '' }
                $info = Framework-Result $run @{ op = 'getElementInfo'; ref = $password.ref }
                Require-Framework ($info.nativeRole -ceq 'password text' -and $info.name -ceq '' -and $null -eq $info.PSObject.Properties['value'] -and
                    !@($state.snapshot.elements | Where-Object parentRef -CEQ $password.ref).Count) 'Password metadata was not redacted.'
                $state.password = $password
                return @{ nativeRole = $info.nativeRole; nameRedacted = $true }
            }
            # java.awt.TextField has no password role. Its accessible name is the label, never the text.
            $password = Find-FrameworkElement $run $state.snapshot @{ role = 'Edit'; name = 'Fixture password' }
            $state.password = $password
            @{ nativeRole = $password.nativeRole; nameRedacted = $false; note = 'AWT reports an echo-character field as plain text. No text content is exposed.' }
        }
        Invoke-FrameworkCase $row 'invokeAndDuplicateRequest' ([bool]$state.button -and !$run.closedProtocol) {
            $before = [int](Read-State 'count.txt')
            $id = [guid]::NewGuid().ToString()
            $reply = (Invoke-FrameworkRequest $run @{ op = 'invoke'; ref = $state.button.ref } 'OK' $id).reply.result
            Require-Framework ($reply.performed -eq $true -and $reply.effectVerified -eq $false) 'An invoke reply must report dispatch without a verified effect.'
            Wait-FrameworkEffect $run 'count.txt' ([string]($before + 1))
            [void](Invoke-FrameworkRequest $run @{ op = 'invoke'; ref = $state.button.ref } 'DUPLICATE_COMMAND' $id)
            Require-Framework (Test-JabStateUnchanged 'count.txt' ([string]($before + 1)) 600) 'A repeated command ID reached the application.'
            $state.invokeWorks = $true
            @{ countBefore = $before; countAfter = $before + 1 }
        }
        Invoke-FrameworkCase $row 'disabledControl' ([bool]$state.snapshot -and !$run.closedProtocol) {
            $disabled = Find-FrameworkElement $run $state.snapshot @{ role = 'Button'; name = 'Disabled action' }
            Require-Framework (!$disabled.enabled) 'The disabled button was reported as enabled.'
            [void](Framework-Result $run @{ op = 'invoke'; ref = $disabled.ref } 'PRECONDITION_FAILED')
            Require-Framework (Test-JabStateUnchanged 'disabled-click.txt' '0' 600) 'The disabled button handler ran.'
        }
        Invoke-FrameworkCase $row 'setValueAndEmpty' ([bool]$state.edit -and !$run.closedProtocol) {
            $value = 'jab-value-' + [guid]::NewGuid()
            Set-JabValue $run $state.edit $value
            Set-JabValue $run $state.edit ''
            $state.setValueWorks = $true
        }
        Invoke-FrameworkCase $row 'setValueUnicodeAndLimits' ([bool]$state.setValueWorks -and !$run.closedProtocol) {
            $korean = "한글 설비 값 " + [char]::ConvertFromUtf32(0x1F600) + [char]::ConvertFromUtf32(0x20000)
            Set-JabValue $run $state.edit $korean
            $longest = 'x' * 1023
            Set-JabValue $run $state.edit $longest
            # The bridge transports 1,023 UTF-16 code units. A longer value is refused before dispatch.
            [void](Framework-Result $run @{ op = 'setValue'; ref = $state.edit.ref; value = ('y' * 1024) } 'PRECONDITION_FAILED')
            Require-Framework (Test-JabStateUnchanged 'value.txt' $longest 600) 'A refused value changed the field.'
            Set-JabValue $run $state.edit 'after limits'
            @{ supplementaryPlane = $true; maxCodeUnits = 1023; overLimit = 'PRECONDITION_FAILED' }
        }
        Invoke-FrameworkCase $row 'readOnlyControl' ([bool]$state.snapshot -and !$run.closedProtocol) {
            $readOnly = Find-FrameworkElement $run $state.snapshot (Get-FixtureLocator $spec 'readOnly' 'Edit')
            Require-Framework (@($readOnly.actions) -cnotcontains 'setValue') 'A read-only field offered setValue.'
            [void](Framework-Result $run @{ op = 'setValue'; ref = $readOnly.ref; value = 'must not change' } 'PATTERN_UNSUPPORTED')
            Require-Framework (Test-JabStateUnchanged 'read-only.txt' 'fixed fixture value' 600) 'The read-only field changed.'
        }
        Invoke-FrameworkCase $row 'passwordSetValue' ([bool]$state.password -and [bool]$state.setValueWorks -and !$run.closedProtocol) {
            # A synthetic value. The fixture publishes its length only, and the Agent never reads it back.
            Set-JabValue $run $state.password 'synthetic-pw-12' 'password-length.txt' '15'
            $after = (Get-FrameworkSnapshot $run $state.window).data
            Require-Framework (!@($after.elements | Where-Object { $_.name -cmatch 'synthetic' }).Count) 'The new masked text appeared in the tree.'
            $state.snapshot = $after
            $state.button = Find-FrameworkElement $run $after @{ role = 'Button'; name = 'Increment fixture counter' }
            @{ publishedLength = 15; textReadBack = $false }
        }
        if ($swing) { Invoke-FrameworkCase $row 'offscreenControl' ([bool]$state.snapshot -and !$run.closedProtocol) {
            # The custom component sits on the unselected Data tab and the menu item in a closed menu.
            $selected = Read-FixtureState 'selected.txt'
            foreach ($name in 'Accessible custom swatch', 'Fixture menu item') {
                $hidden = Find-FrameworkElement $run $state.snapshot @{ role = if ($name -match 'menu') { 'MenuItem' } else { 'Button' }; name = $name }
                Require-Framework ($hidden.offscreen -and @($hidden.actions) -ccontains 'invoke') "$name should be an offscreen element that offers invoke."
                [void](Framework-Result $run @{ op = 'invoke'; ref = $hidden.ref } 'PRECONDITION_FAILED')
            }
            Start-Sleep -Milliseconds 400
            Require-Framework ((Read-FixtureState 'selected.txt') -ceq $selected) 'An element that is not showing was activated.'
            @{ note = 'A menu item is reachable only while its menu is open. Expanding a menu is not part of the API.' }
        } }
        if ($swing) { Invoke-FrameworkCase $row 'customAccessibleAction' ([bool]$state.window -and !$run.closedProtocol) {
            # Reset the marker: another row of this fixture may have activated the same component.
            [IO.File]::WriteAllText((Join-Path $stateDir 'select-tab-0'), '')
            Wait-State 'tab.txt' 'Controls' 5000
            $check = Find-FrameworkElement $run (Get-FrameworkSnapshot $run $state.window).data @{ role = 'CheckBox'; name = 'Fixture check box' }
            Require-Framework (!@($check.actions).Count) 'A check box must not offer invoke. Toggling is outside the API.'
            [IO.File]::WriteAllText((Join-Path $stateDir 'select-tab-1'), '')
            Wait-State 'tab.txt' 'Data' 5000
            try {
                $shown = (Get-FrameworkSnapshot $run $state.window).data
                $swatch = Find-FrameworkElement $run $shown @{ role = 'Button'; name = 'Accessible custom swatch' }
                Require-Framework (!$swatch.offscreen) 'The custom component is still reported as not showing.'
                $duplicate = @($shown.elements | Where-Object name -CEQ 'Duplicate label')[0]
                Invoke-JabButton $run $duplicate 'selected.txt' 'Duplicate one'
                Invoke-JabButton $run $swatch 'selected.txt' 'Accessible custom swatch'
                $data = [ordered]@{}
                foreach ($pair in @('table', 'Fixture table'), @('tree', 'Fixture tree')) {
                    $node = (Get-JabRow $shown $pair[0] $pair[1])[0]
                    $data[$pair[0]] = @{ offscreen = $node.offscreen; children = @($shown.elements | Where-Object parentRef -CEQ $node.ref | ForEach-Object { "$($_.nativeRole):$($_.name)" }) }
                }
                @{ action = 'click'; dataTab = $data }
            } finally {
                [IO.File]::WriteAllText((Join-Path $stateDir 'select-tab-0'), '')
                Wait-State 'tab.txt' 'Controls' 5000
            }
        } }
        Invoke-FrameworkCase $row 'replacement' ([bool]$state.invokeWorks -and !$run.closedProtocol) {
            $snapshot = (Get-FrameworkSnapshot $run $state.window).data
            $old = Find-FrameworkElement $run $snapshot @{ role = 'Button'; name = 'Increment fixture counter' }
            $before = Read-State 'count.txt'
            # An earlier row of this fixture leaves the marker behind.
            Remove-Item -LiteralPath (Join-Path $stateDir 'replaced') -Force -ErrorAction SilentlyContinue
            [IO.File]::WriteAllText((Join-Path $stateDir 'replace-control'), '')
            Wait-State 'replaced' 'ready' 5000
            # The new button has the same name, role and position. Only the object differs.
            [void](Framework-Result $run @{ op = 'invoke'; ref = $old.ref } 'STALE_REFERENCE')
            [void](Framework-Result $run @{ op = 'getElementInfo'; ref = $old.ref } 'STALE_REFERENCE')
            Require-Framework (Test-JabStateUnchanged 'count.txt' $before 600) 'A reference to the replaced button reached the new one.'
            $fresh = (Get-FrameworkSnapshot $run $state.window).data
            $button = Find-FrameworkElement $run $fresh @{ role = 'Button'; name = 'Increment fixture counter' }
            Invoke-JabButton $run $button 'count.txt' ([string]([int]$before + 1))
            $state.snapshot = $fresh
            $state.button = $button
        }
        Invoke-FrameworkCase $row 'truncatedSnapshot' ([bool]$state.invokeWorks -and !$run.closedProtocol) {
            $full = (Get-FrameworkSnapshot $run $state.window).data
            $index = 0
            for ($i = 0; $i -lt $full.elements.Count; $i++) { if ($full.elements[$i].name -ceq 'Duplicate label') { $index = $i } }
            # The element budget ends just after the counter row, so that row is whole and a later branch is cut.
            $cut = (Get-FrameworkSnapshot $run $state.window '' 32 ($index + 2)).data
            $partial = @($cut.elements | Where-Object partial)
            Require-Framework ($cut.truncated -and $cut.elements.Count -eq $index + 2 -and $partial.Count -ge 1 -and
                !@($partial | Where-Object { $_.partialReason -cne 'limit' }).Count) 'An element-limited snapshot must mark its cut elements with the reason "limit".'
            $locator = @{ role = 'Button'; name = 'Increment fixture counter' }
            [void](Find-FrameworkElement $run $cut $locator '' 'INCOMPLETE_SNAPSHOT')
            $button = @($cut.elements | Where-Object { $_.name -ceq $locator.name })[0]
            $container = @($cut.elements | Where-Object ref -CEQ $button.parentRef)[0]
            Require-Framework (!$container.partial) 'The counter row should be whole in the limited snapshot.'
            $found = Find-FrameworkElement $run $cut $locator $container.ref
            $before = [int](Read-State 'count.txt')
            Invoke-JabButton $run $found 'count.txt' ([string]($before + 1))
            [void](Find-FrameworkElement $run $cut $locator @($partial)[0].ref 'INCOMPLETE_SNAPSHOT')
            $shallow = (Get-FrameworkSnapshot $run $state.window '' 1 2000).data
            Require-Framework ($shallow.truncated -and @($shallow.elements | Where-Object { $_.partial -and $_.partialReason -ceq 'limit' }).Count -ge 1) 'A depth-limited snapshot must mark its cut elements.'
            @{ elementLimit = $index + 2; partialElements = $partial.Count; depthLimitedElements = $shallow.elements.Count }
        }
        Invoke-FrameworkCase $row 'scopedSnapshot' ([bool]$state.window -and !$run.closedProtocol) {
            $full = (Get-FrameworkSnapshot $run $state.window).data
            $edit = Find-FrameworkElement $run $full (Get-FixtureLocator $spec 'edit' 'Edit')
            $scoped = (Get-FrameworkSnapshot $run $state.window $edit.parentRef).data
            Require-Framework (!$scoped.truncated -and !$scoped.elements[0].parentRef -and $scoped.elements.Count -lt $full.elements.Count) 'A scoped snapshot must start at the scope and be smaller than the window.'
            [void](Framework-Result $run @{ op = 'getElementInfo'; ref = $edit.ref } 'STALE_REFERENCE')
            $again = Find-FrameworkElement $run $scoped (Get-FixtureLocator $spec 'edit' 'Edit')
            $info = Framework-Result $run @{ op = 'getElementInfo'; ref = $again.ref }
            Require-Framework ($info.name -ceq 'Fixture edit') 'The scoped snapshot did not resolve the edit field.'
            [void](Find-FrameworkElement $run $scoped @{ role = 'Button'; name = 'Increment fixture counter' } '' 'ELEMENT_NOT_FOUND')
            $state.snapshot = $null
            @{ windowElements = $full.elements.Count; scopeElements = $scoped.elements.Count }
        }
        Invoke-FrameworkCase $row 'modalOpenedByApplication' ([bool]$state.window -and !$run.closedProtocol) {
            [IO.File]::WriteAllText((Join-Path $stateDir 'open-modal'), '')
            Wait-State 'modal.txt' 'open' 5000
            try {
                $modal = Get-JabModalWindow $run "$title modal" $state.window
                Close-JabModal $run $modal $spec.modalClose 'modal.txt'
            } finally {
                if ((Read-FixtureState 'modal.txt') -cne 'closed') { [IO.File]::WriteAllText((Join-Path $stateDir 'close-modal'), '') ; Wait-State 'modal.txt' 'closed' 5000 }
            }
        }
        if ($swing) { Invoke-FrameworkCase $row 'optionPane' ([bool]$state.window -and !$run.closedProtocol) {
            [IO.File]::WriteAllText((Join-Path $stateDir 'open-option-pane'), '')
            Wait-State 'option.txt' 'open' 5000
            $pane = Get-JabModalWindow $run "$title option" $state.window
            $snapshot = (Get-FrameworkSnapshot $run $pane).data
            # A message dialog reports the role "alert", the other option types "option pane".
            Require-Framework (@($snapshot.elements | Where-Object nativeRole -CIn 'alert', 'option pane').Count -eq 1 -and
                @($snapshot.elements | Where-Object name -CEQ 'Fixture option pane message').Count -ge 1) 'The option pane content was not exposed.'
            $buttons = @($snapshot.elements | Where-Object { $_.nativeRole -ceq 'push button' -and !$_.offscreen -and @($_.actions) -ccontains 'invoke' })
            Require-Framework ($buttons.Count -eq 1) 'The option pane should expose one visible button.'
            Invoke-JabButton $run $buttons[0] 'option.txt' 'closed'
            @{ elements = $snapshot.elements.Count; button = $buttons[0].name
                paneRole = @($snapshot.elements | Where-Object nativeRole -CIn 'alert', 'option pane')[0].nativeRole }
        } }
        Invoke-FrameworkCase $row 'modalOpenedByInvoke' ([bool]$state.invokeWorks -and !$run.closedProtocol) {
            $snapshot = (Get-FrameworkSnapshot $run $state.window).data
            $opener = Find-FrameworkElement $run $snapshot @{ role = 'Button'; name = 'Open fixture modal' }
            $response = Send-UiaRequest $run.cli @{ op = 'invoke'; ref = $opener.ref } ([guid]::NewGuid().ToString()) 20000
            $code = if ($response.reply.ok) { 'OK' } else { $response.reply.error.code }
            $run.requests.Add(@{ op = 'invoke'; code = $code; ms = $response.ms })
            try {
                if ($code -ceq 'OK') {
                    Wait-FrameworkEffect $run 'modal.txt' 'open'
                    $modal = Get-JabModalWindow $run "$title modal" $state.window
                    $closed = Close-JabModal $run $modal $spec.modalClose 'modal.txt'
                    $row.modalOpened = $true
                    $row.modalClosed = $true
                    return @{ invokeMs = $response.ms; modal = $closed }
                }
                Require-Framework ($code -ceq 'ACTION_OUTCOME_UNKNOWN') "invoke expected OK or ACTION_OUTCOME_UNKNOWN, received $code."
                # javax.swing buttons run their listeners inside the bridge request. A listener that shows
                # a modal dialog returns when the dialog closes, and the JVM answers nothing until then.
                $evidence = [ordered]@{ agentReply = $code; invokeMs = $response.ms }
                $evidence.modalOpened = [bool](Wait-JabFile $stateDir 'modal.txt' 'open' 5000)
                $evidence.whileOpen = (Send-UiaRequest $run.cli @{ op = 'listWindows' } ([guid]::NewGuid().ToString()) 20000).reply.error.code
                [IO.File]::WriteAllText((Join-Path $stateDir 'close-modal'), '')
                Wait-State 'modal.txt' 'closed' 5000
                $clock = [Diagnostics.Stopwatch]::StartNew()
                do {
                    Start-Sleep -Milliseconds 200
                    $after = Send-UiaRequest $run.cli @{ op = 'getElementInfo'; ref = $opener.ref } ([guid]::NewGuid().ToString()) 20000
                } while (!$after.reply.ok -and $clock.ElapsedMilliseconds -lt 5000)
                $evidence.sessionUsableAfterClose = [bool]$after.reply.ok
                $evidence.recoveryMs = $clock.ElapsedMilliseconds
                $evidence.cause = 'AbstractButton.doClick runs the action listener synchronously on the event thread, and the bridge waits for it without a timeout (AccessBridge.InvocationUtils.invokeAndWait).'
                if ($evidence.modalOpened -and $evidence.whileOpen -ceq 'TARGET_NOT_RESPONDING' -and $evidence.sessionUsableAfterClose) {
                    $run.uncertainAction = $false
                    Stop-FrameworkCase 'JAB_PROVIDER_LIMITATION' 'The click opened the modal dialog, and the JVM answered no bridge request until the dialog was closed.' $evidence
                }
                $run.uncertainAction = $true
                Stop-FrameworkCase 'UNCLASSIFIED' 'An unconfirmed invoke did not follow the pattern of a modal dialog opened inside the bridge request.' $evidence
            } finally {
                if ((Read-FixtureState 'modal.txt') -ceq 'open') { [IO.File]::WriteAllText((Join-Path $stateDir 'close-modal'), ''); Wait-State 'modal.txt' 'closed' 5000 }
            }
        }
        if ($IncludeExpiry) {
            Invoke-FrameworkCase $row 'expiredReference' ([bool]$state.window -and !$run.closedProtocol) {
                $snapshot = (Get-FrameworkSnapshot $run $state.window '' 2 50).data
                Start-Sleep -Seconds 121
                [void](Framework-Result $run @{ op = 'getElementInfo'; ref = $snapshot.elements[0].ref } 'STALE_REFERENCE')
                [void](Framework-Result $run @{ op = 'invoke'; ref = $snapshot.elements[0].ref } 'STALE_REFERENCE')
                @{ waitedSeconds = 121 }
            }
        }
    } finally {
        if ($run) { try { Stop-Cli $run.cli JNA } catch { $row.agentShutdownFailure = $_.Exception.Message } }
        $row.status = Get-FrameworkStatus $row.checks
    }
    Test-JabIsolation $row $spec $launch
    Test-JabEnvironment $row $spec $launch
    $row.status = Get-FrameworkStatus $row.checks
}

# Process, session and backend boundaries, each with Agent sessions of their own.
function Test-JabIsolation($row, $spec, $launch) {
    $swing = $row.framework -eq 'Swing'
    $window = $row.windowId
    $locator = @{ role = 'Button'; name = 'Increment fixture counter' }
    Invoke-FrameworkCase $row 'otherProcessDenied' ([bool]$window) {
        $run = Start-FrameworkAgent $row.backend -WithoutPid
        try {
            $snapshot = (Get-FrameworkSnapshot $run $window).data
            $button = Find-FrameworkElement $run $snapshot $locator
            $before = Read-State 'count.txt'
            [void](Framework-Result $run @{ op = 'invoke'; ref = $button.ref } 'PERMISSION_DENIED')
            $edit = Find-FrameworkElement $run $snapshot (Get-FixtureLocator $spec 'edit' 'Edit')
            [void](Framework-Result $run @{ op = 'setValue'; ref = $edit.ref; value = 'denied' } 'PERMISSION_DENIED')
            Require-Framework (Test-JabStateUnchanged 'count.txt' $before 600) 'A session without the fixture PID changed the fixture.'
        } finally { Stop-Cli $run.cli JNA }
    }
    Invoke-FrameworkCase $row 'otherSessionReference' ([bool]$window) {
        $first = Start-FrameworkAgent $row.backend
        $second = Start-FrameworkAgent $row.backend
        try {
            $button = Find-FrameworkElement $first (Get-FrameworkSnapshot $first $window).data $locator
            [void](Get-FrameworkSnapshot $second $window)
            $before = Read-State 'count.txt'
            [void](Framework-Result $second @{ op = 'getElementInfo'; ref = $button.ref } 'STALE_REFERENCE')
            [void](Framework-Result $second @{ op = 'invoke'; ref = $button.ref } 'STALE_REFERENCE')
            Require-Framework (Test-JabStateUnchanged 'count.txt' $before 600) 'A reference of another session reached the fixture.'
        } finally { Stop-Cli $first.cli JNA; Stop-Cli $second.cli JNA }
    }
    $uia = Get-JabUiaBackend $row.backend
    $uiaReady = if ($uia -eq 'JNA') { [IO.File]::Exists($Jar) } else { [IO.File]::Exists($CppAgent) }
    Invoke-FrameworkCase $row 'otherBackendReference' ([bool]$window -and $uiaReady) {
        $bridge = Start-FrameworkAgent $row.backend
        $automation = Start-FrameworkAgent $uia
        try {
            $jabButton = Find-FrameworkElement $bridge (Get-FrameworkSnapshot $bridge $window).data $locator
            $uiaRoot = (Get-FrameworkSnapshot $automation $window '' 1 50).data.elements[0]
            Require-Framework ($uiaRoot.backend -ceq 'UIA' -and $jabButton.backend -ceq 'JAB') 'Each session must answer with its own backend.'
            $before = Read-State 'count.txt'
            [void](Framework-Result $automation @{ op = 'invoke'; ref = $jabButton.ref } 'STALE_REFERENCE')
            [void](Framework-Result $automation @{ op = 'getElementInfo'; ref = $jabButton.ref } 'STALE_REFERENCE')
            [void](Framework-Result $bridge @{ op = 'getElementInfo'; ref = $uiaRoot.ref } 'STALE_REFERENCE')
            Require-Framework (Test-JabStateUnchanged 'count.txt' $before 600) 'A reference of another backend reached the fixture.'
            @{ uiaBackend = $uia; sameWindowId = $true }
        } finally { Stop-Cli $bridge.cli JNA; Stop-Cli $automation.cli JNA }
    }
    if ($swing) { Invoke-FrameworkCase $row 'exitWhileTargetSilent' ([bool]$window) {
        $run = Start-FrameworkAgent $row.backend
        $exited = $false
        try {
            $opener = Find-FrameworkElement $run (Get-FrameworkSnapshot $run $window).data @{ role = 'Button'; name = 'Open fixture modal' }
            $response = Send-UiaRequest $run.cli @{ op = 'invoke'; ref = $opener.ref } ([guid]::NewGuid().ToString()) 20000
            Require-Framework (!$response.reply.ok -and $response.reply.error.code -ceq 'ACTION_OUTCOME_UNKNOWN') 'The modal-opening click should end as ACTION_OUTCOME_UNKNOWN.'
            Require-Framework (Wait-JabFile $stateDir 'modal.txt' 'open' 5000) 'The modal dialog did not open.'
            # The dialog stays open. The Agent must still end, without waiting on the silent JVM.
            $clock = [Diagnostics.Stopwatch]::StartNew()
            $run.cli.StandardInput.Close()
            $exited = $run.cli.WaitForExit(15000)
            Require-Framework ($exited -and $run.cli.ExitCode -eq 0) 'The Agent did not exit while the target JVM was silent.'
            @{ exitMs = $clock.ElapsedMilliseconds; exitCode = $run.cli.ExitCode }
        } finally {
            if (!$exited) { try { $run.cli.Kill() } catch {} }
            $run.cli.Dispose()
            [IO.File]::WriteAllText((Join-Path $stateDir 'close-modal'), '')
            Wait-State 'modal.txt' 'closed' 8000
            Start-Sleep -Milliseconds 300
        }
    } }
}

# Bridge availability and several JVMs.
function Test-JabEnvironment($row, $spec, $launch) {
    $window = $row.windowId
    $mode = $row.framework.ToLowerInvariant()
    $java = $launch.executable
    Invoke-FrameworkCase $row 'bridgeNotConnected' ([bool]$window) {
        $plain = Start-JabSecondFixture $launch $mode $java $false
        $run = Start-FrameworkAgent $row.backend
        try {
            $cap = Framework-Result $run @{ op = 'getCapabilities' }
            Require-Framework ($cap.available -and $cap.bridge.javaWindows -gt $cap.bridge.connectedWindows) 'A Java window without the bridge was not counted.'
            $listed = @(Framework-Result $run @{ op = 'listWindows' } | Where-Object processId -EQ $plain.process.Id)
            Require-Framework (!$listed.Count) 'A JVM without the bridge was listed as operable.'
            [void](Framework-Result $run @{ op = 'snapshot'; windowId = [string]$plain.window } 'BRIDGE_NOT_CONNECTED')
            [void](Get-FrameworkSnapshot $run $window '' 1 20)
            @{ javaWindows = $cap.bridge.javaWindows; connectedWindows = $cap.bridge.connectedWindows; secondRuntime = $plain.runtime }
        } finally { Stop-Cli $run.cli JNA; Stop-JabSecondFixture $plain }
    }
    Invoke-FrameworkCase $row 'multipleJvms' ([bool]$window) {
        $otherJava = if ($SecondFixtureJava) { $SecondFixtureJava } else { $java }
        $otherMode = if ($mode -eq 'swing') { 'awt' } else { 'swing' }
        $other = Start-JabSecondFixture $launch $otherMode $otherJava $true
        $run = Start-FrameworkAgent $row.backend
        try {
            $rows = @(Framework-Result $run @{ op = 'listWindows' })
            $mine = @($rows | Where-Object { $_.processId -eq $fixture.Id -and $_.name -ceq $title })
            $theirs = @($rows | Where-Object { $_.processId -eq $other.process.Id -and $_.name -ceq $other.title })
            Require-Framework ($mine.Count -eq 1 -and $theirs.Count -eq 1 -and $mine[0].windowId -cne $theirs[0].windowId) 'Two JVMs were not listed as two windows with their own PIDs.'
            $foreign = (Framework-Result $run @{ op = 'snapshot'; windowId = $theirs[0].windowId; maxDepth = 32; maxElements = 2000 })
            Require-Framework (!@($foreign.elements | Where-Object processId -NE $other.process.Id).Count) 'A snapshot mixed elements of two JVMs.'
            $theirButton = Framework-Result $run @{ op = 'findElement'; snapshotId = $foreign.snapshotId; locator = @{ role = 'Button'; name = 'Increment fixture counter' } }
            [void](Framework-Result $run @{ op = 'invoke'; ref = $theirButton.ref } 'PERMISSION_DENIED')
            Start-Sleep -Milliseconds 400
            Require-Framework ((Read-JabFile $other.stateDir 'count.txt') -ceq '0') 'The JVM that was not allowed received the click.'
            $snapshot = (Get-FrameworkSnapshot $run $window).data
            $button = Find-FrameworkElement $run $snapshot @{ role = 'Button'; name = 'Increment fixture counter' }
            [void](Framework-Result $run @{ op = 'invoke'; ref = $theirButton.ref } 'STALE_REFERENCE')
            $before = [int](Read-State 'count.txt')
            Invoke-JabButton $run $button 'count.txt' ([string]($before + 1))
            Require-Framework ((Read-JabFile $other.stateDir 'count.txt') -ceq '0') 'A click on the fixture reached the other JVM.'
            # The other JVM leaves. The references into the fixture stay valid.
            [IO.File]::WriteAllText((Join-Path $other.stateDir 'close-fixture'), '')
            Require-Framework ($other.process.WaitForExit(5000)) 'The second fixture did not exit.'
            $info = Framework-Result $run @{ op = 'getElementInfo'; ref = $button.ref }
            Require-Framework ($info.name -ceq 'Increment fixture counter') 'A reference into the fixture died with the other JVM.'
            [void](Framework-Result $run @{ op = 'snapshot'; windowId = $theirs[0].windowId } 'WINDOW_NOT_FOUND')
            @{ firstRuntime = (Read-State 'framework.txt'); secondRuntime = $other.runtime; secondFramework = $otherMode }
        } finally { Stop-Cli $run.cli JNA; Stop-JabSecondFixture $other }
    }
    Invoke-FrameworkCase $row 'bridgeLibraryMissing' $true {
        $missing = Join-Path $stateDir 'absent\WindowsAccessBridge-64.dll'
        $run = Start-FrameworkAgent $row.backend -ExtraArguments "--jab-dll ""$missing"""
        try {
            $cap = Framework-Result $run @{ op = 'getCapabilities' }
            Require-Framework (!$cap.available -and $cap.backend -ceq 'JAB' -and !@($cap.operations).Count -and
                $cap.reason -cmatch 'does not exist') 'A missing bridge library must be an unavailable JAB capability with its reason.'
            # The session stays on its backend. It never answers through UI Automation.
            [void](Framework-Result $run @{ op = 'listWindows' } 'BACKEND_UNAVAILABLE')
            if ($row.windowId) { [void](Framework-Result $run @{ op = 'snapshot'; windowId = $row.windowId } 'BACKEND_UNAVAILABLE') }
            @{ reason = $cap.reason }
        } finally { Stop-Cli $run.cli JNA }
    }
    Invoke-FrameworkCase $row 'bridgeLibraryInvalid' $true {
        $reasons = [ordered]@{}
        $notImage = Join-Path $stateDir 'WindowsAccessBridge-64.dll'
        [IO.File]::WriteAllText($notImage, 'not a library')
        # A real library of the right architecture that is not Java Access Bridge.
        $foreign = Join-Path $env:SystemRoot 'System32\version.dll'
        foreach ($case in @(@('notAnImage', $notImage, 'does not match'), @('withoutBridgeExports', $foreign, 'lacks '))) {
            $run = Start-FrameworkAgent $row.backend -ExtraArguments "--jab-dll ""$($case[1])"""
            try {
                $cap = Framework-Result $run @{ op = 'getCapabilities' }
                Require-Framework (!$cap.available -and $cap.backend -ceq 'JAB' -and $cap.reason -cmatch $case[2]) "Initialization with $($case[0]) must fail with its reason."
                [void](Framework-Result $run @{ op = 'listWindows' } 'BACKEND_UNAVAILABLE')
                $reasons[$case[0]] = $cap.reason
            } finally { Stop-Cli $run.cli JNA }
        }
        Remove-Item -LiteralPath $notImage -Force
        $reasons
    }
}

# The fixture JVM exits and a new one starts with the same window title.
function Test-JabLifetime($rows, $launch) {
    $agents = @{}
    try {
        foreach ($row in $rows) {
            Invoke-FrameworkCase $row 'captureBeforeExit' ([bool]$row.windowId) {
                $run = Start-FrameworkAgent $row.backend
                $agents[$row.backend] = $run
                $run.capture = (Get-FrameworkSnapshot $run $row.windowId).data
                $run.button = Find-FrameworkElement $run $run.capture @{ role = 'Button'; name = 'Increment fixture counter' }
            }
        }
        if (!$agents.Count) { return }
        $oldPid = $fixture.Id
        [IO.File]::WriteAllText((Join-Path $stateDir 'close-fixture'), '')
        Require-Framework ($fixture.WaitForExit(5000) -and $fixture.ExitCode -eq 0) 'Fixture failed to exit normally.'
        foreach ($row in $rows) {
            $run = $agents[$row.backend]
            Invoke-FrameworkCase $row 'processExitInvalidatesReference' ([bool]$run.capture) {
                [void](Framework-Result $run @{ op = 'getElementInfo'; ref = $run.capture.elements[0].ref } 'STALE_REFERENCE')
                # The allowed process no longer exists, so the action is refused before any reference is used.
                [void](Framework-Result $run @{ op = 'invoke'; ref = $run.button.ref } 'PERMISSION_DENIED')
                $windows = @(Framework-Result $run @{ op = 'listWindows' } | Where-Object { $_.processId -eq $oldPid })
                Require-Framework (!$windows.Count) 'The exited fixture still appeared in listWindows.'
                [void](Framework-Result $run @{ op = 'snapshot'; windowId = $row.windowId } 'WINDOW_NOT_FOUND')
            }
        }
        $fixture.Dispose()
        Remove-Item -LiteralPath (Join-Path $stateDir 'ready') -Force -ErrorAction SilentlyContinue
        Start-FrameworkFixture $launch
        foreach ($row in $rows) {
            $run = $agents[$row.backend]
            Invoke-FrameworkCase $row 'jvmRestart' ([bool]$run.capture) {
                Require-Framework ($fixture.Id -ne $oldPid) 'The restarted fixture reused the process ID.'
                # The session connected before this JVM existed. It learns of the JVM from its announcement.
                $windows = @()
                $clock = [Diagnostics.Stopwatch]::StartNew()
                do {
                    $windows = @(Framework-Result $run @{ op = 'listWindows' } | Where-Object { $_.processId -eq $fixture.Id -and $_.name -ceq $title })
                    if (!$windows.Count) { Start-Sleep -Milliseconds 200 }
                } while (!$windows.Count -and $clock.ElapsedMilliseconds -lt 8000)
                Require-Framework ($windows.Count -eq 1) 'The restarted JVM was not discovered by the running session.'
                [void](Framework-Result $run @{ op = 'getElementInfo'; ref = $run.button.ref } 'STALE_REFERENCE')
                $snapshot = Framework-Result $run @{ op = 'snapshot'; windowId = $windows[0].windowId; maxDepth = 32; maxElements = 2000 }
                Require-Framework (!@($snapshot.elements | Where-Object processId -NE $fixture.Id).Count) 'The new snapshot does not belong to the restarted JVM.'
                $button = Framework-Result $run @{ op = 'findElement'; snapshotId = $snapshot.snapshotId; locator = @{ role = 'Button'; name = 'Increment fixture counter' } }
                # This session was allowed the first process only. Same title and same control are not enough.
                $count = Read-State 'count.txt'
                [void](Framework-Result $run @{ op = 'invoke'; ref = $button.ref } 'PERMISSION_DENIED')
                Require-Framework (Test-JabStateUnchanged 'count.txt' $count 600) 'The restarted JVM received a click from a session bound to the old process.'
                $fresh = Start-FrameworkAgent $row.backend
                try {
                    $again = Find-FrameworkElement $fresh (Get-FrameworkSnapshot $fresh $windows[0].windowId).data @{ role = 'Button'; name = 'Increment fixture counter' }
                    Invoke-JabButton $fresh $again 'count.txt' ([string]([int]$count + 1))
                } finally { Stop-Cli $fresh.cli JNA }
                @{ oldPid = $oldPid; newPid = $fixture.Id; discoveryMs = $clock.ElapsedMilliseconds }
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

# Versions and bitness of the bridge parts that took part in a run.
function Get-JabEnvironment($launch) {
    $info = [ordered]@{ fixtureProperty = 'javax.accessibility.assistive_technologies=com.sun.java.accessibility.AccessBridge'
        registryOrUserSettingsChanged = $false }
    $name = if ([IntPtr]::Size -eq 8) { 'WindowsAccessBridge-64.dll' } else { 'WindowsAccessBridge-32.dll' }
    $libraries = [ordered]@{}
    if ($JabDll) { $libraries.explicit = $JabDll }
    if ($javaExe) { $libraries.javaAgentRuntime = Join-Path (Split-Path $javaExe) $name }
    $libraries.systemDirectory = Join-Path ([Environment]::SystemDirectory) $name
    $info.windowsSideLibraries = [ordered]@{}
    foreach ($entry in $libraries.GetEnumerator()) {
        if ([IO.File]::Exists($entry.Value)) {
            $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($entry.Value)
            $info.windowsSideLibraries[$entry.Key] = [ordered]@{ path = $entry.Value; fileVersion = $version.FileVersion
                architecture = Get-PeArchitecture $entry.Value; sha256 = (Get-FileHash -LiteralPath $entry.Value).Hash }
        } else { $info.windowsSideLibraries[$entry.Key] = @{ path = $entry.Value; present = $false } }
    }
    $info.selection = @{ Jab = if ($JabDll) { 'explicit' } else { 'javaAgentRuntime, then systemDirectory' }
        CppJab = if ($JabDll) { 'explicit' } else { 'systemDirectory, then the Java installation registered under HKLM' } }
    if ($launch -and $launch.executable) {
        $jvmSide = Join-Path (Split-Path $launch.executable) 'javaaccessbridge.dll'
        $info.fixtureJvm = [ordered]@{ launcher = $launch.executable; launcherArchitecture = Get-PeArchitecture $launch.executable
            version = $launch.version }
        if ([IO.File]::Exists($jvmSide)) {
            $info.fixtureJvm.javaSideLibrary = @{ path = $jvmSide; fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($jvmSide).FileVersion
                architecture = Get-PeArchitecture $jvmSide }
        }
    }
    return $info
}
