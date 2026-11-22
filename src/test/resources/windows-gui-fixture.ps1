param(
    [Parameter(Mandatory)][string]$StateDirectory,
    [Parameter(Mandatory)][string]$WindowTitle,
    [switch]$Borderless
)
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class FixtureCursor {
    [StructLayout(LayoutKind.Sequential)]
    private struct Point { public int X, Y; }
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetPhysicalCursorPos(out Point point);
    public static string Position() {
        Point point;
        if (!GetPhysicalCursorPos(out point)) throw new Win32Exception();
        return point.X + "," + point.Y;
    }
}
'@

function Write-State([string]$FileName, [string]$Value) {
    $path = Join-Path $StateDirectory $FileName
    $pending = "$path.pending"
    [IO.File]::WriteAllText($pending, $Value)
    if ([IO.File]::Exists($path)) {
        # Replace the directory entry so an existing reader sees the previous complete value.
        [IO.File]::Replace($pending, $path, [NullString]::Value)
    } else {
        [IO.File]::Move($pending, $path)
    }
}

$window = New-Object Windows.Window
$window.Title = $WindowTitle
if ($Borderless) { $window.WindowStyle = [Windows.WindowStyle]::None }
$window.Width = 350
$window.SizeToContent = [Windows.SizeToContent]::Height
$panel = New-Object Windows.Controls.StackPanel
$window.Content = $panel

$edit = New-Object Windows.Controls.TextBox
[Windows.Automation.AutomationProperties]::SetAutomationId($edit, 'fixtureEdit')
$edit.Add_TextChanged({ Write-State 'value.txt' $edit.Text })
$edit.Text = 'initial fixture value'
[void]$panel.Children.Add($edit)

$script:clickCount = 0
Write-State 'count.txt' '0'
function New-IncrementButton {
    $button = New-Object Windows.Controls.Button
    $button.Content = 'Increment fixture counter'
    [Windows.Automation.AutomationProperties]::SetName($button, 'Increment fixture counter')
    [Windows.Automation.AutomationProperties]::SetAutomationId($button, 'fixtureIncrement')
    $button.Add_Click({
        $script:clickCount++
        Write-State 'count.txt' ([string]$script:clickCount)
    })
    return $button
}
$script:incrementButton = New-IncrementButton
[void]$panel.Children.Add($script:incrementButton)
foreach ($index in 1..2) {
    $button = New-Object Windows.Controls.Button
    $button.Content = 'Duplicate label'
    [Windows.Automation.AutomationProperties]::SetName($button, 'Duplicate label')
    [void]$panel.Children.Add($button)
}

$check = New-Object Windows.Controls.CheckBox
$check.Content = 'Fixture check box'
[Windows.Automation.AutomationProperties]::SetAutomationId($check, 'fixtureCheck')
[void]$panel.Children.Add($check)

$combo = New-Object Windows.Controls.ComboBox
[Windows.Automation.AutomationProperties]::SetAutomationId($combo, 'fixtureCombo')
[void]$combo.Items.Add('Choice one')
[void]$combo.Items.Add('Choice two')
$combo.SelectedIndex = 0
[void]$panel.Children.Add($combo)

$list = New-Object Windows.Controls.ListBox
[Windows.Automation.AutomationProperties]::SetAutomationId($list, 'fixtureList')
[void]$list.Items.Add('Item one')
[void]$list.Items.Add('Item two')
$list.SelectedIndex = 0
[void]$panel.Children.Add($list)

$disabled = New-Object Windows.Controls.Button
$disabled.Content = 'Disabled action'
$disabled.IsEnabled = $false
[Windows.Automation.AutomationProperties]::SetAutomationId($disabled, 'fixtureDisabled')
Write-State 'disabled-click.txt' '0'
$disabled.Add_Click({ Write-State 'disabled-click.txt' '1' })
[void]$panel.Children.Add($disabled)

$readOnlyEdit = New-Object Windows.Controls.TextBox
$readOnlyEdit.IsReadOnly = $true
[Windows.Automation.AutomationProperties]::SetAutomationId($readOnlyEdit, 'fixtureReadOnly')
$readOnlyEdit.Add_TextChanged({ Write-State 'read-only.txt' $readOnlyEdit.Text })
$readOnlyEdit.Text = 'fixed fixture value'
[void]$panel.Children.Add($readOnlyEdit)

# A unique filename per sample prevents a delayed response from satisfying the next read.
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(25)
$timer.Add_Tick({
    if ([IO.File]::Exists((Join-Path $StateDirectory 'close-fixture'))) {
        $timer.Stop()
        $window.Close()
        return
    }

    $replace = Join-Path $StateDirectory 'replace-control'
    if ([IO.File]::Exists($replace)) {
        [IO.File]::Delete($replace)
        [Windows.Automation.AutomationProperties]::SetAutomationId($script:incrementButton, 'retired')
        $panel.Children.Remove($script:incrementButton)
        $script:incrementButton = New-IncrementButton
        [void]$panel.Children.Add($script:incrementButton)
        $window.UpdateLayout()
        Write-State 'replaced' 'ready'
    }
    foreach ($request in [IO.Directory]::GetFiles($StateDirectory, '*.request')) {
        $position = [FixtureCursor]::Position()
        $reply = [IO.Path]::ChangeExtension($request, 'reply')
        [IO.File]::WriteAllText("$reply.tmp", $position)
        [IO.File]::Move("$reply.tmp", $reply)
        [IO.File]::Delete($request)
    }
})
$window.Add_ContentRendered({
    Write-State 'ready' ([string]$PID)
    $timer.Start()
})
[void]$window.ShowDialog()
$timer.Stop()
