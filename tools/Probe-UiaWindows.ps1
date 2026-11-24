# Read-only diagnostic. Compares the Win32 top-level windows of one process with their place in the
# UI Automation tree. It sends no input and calls no pattern. Window titles are reported only for
# the process named by -ProcessId.
[CmdletBinding()]
param([Parameter(Mandatory)][int]$ProcessId)
$ErrorActionPreference = 'Stop'
if ([Console]::IsOutputRedirected) { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) }
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
if (!('UiaWindowProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
public static class UiaWindowProbe {
    private delegate bool EnumProc(IntPtr window, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint owner);
    [DllImport("user32.dll")] private static extern IntPtr GetWindow(IntPtr window, uint command);
    [DllImport("user32.dll")] private static extern IntPtr GetAncestor(IntPtr window, uint flags);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll")] private static extern bool IsWindowEnabled(IntPtr window);
    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW")] private static extern IntPtr GetLong(IntPtr window, int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetWindowTextW(IntPtr window, StringBuilder text, int count);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr window, StringBuilder text, int count);
    [DllImport("dwmapi.dll")] private static extern int DwmGetWindowAttribute(IntPtr window, int attribute, out int value, int size);
    public sealed class Row {
        public long Handle, Owner, RootOwner, Parent;
        public bool Visible, Enabled, Cloaked;
        public string Title, ClassName, Style, ExStyle;
    }
    public static List<Row> TopLevel(uint pid) {
        var rows = new List<Row>();
        EnumWindows(delegate(IntPtr window, IntPtr state) {
            uint owner;
            if (GetWindowThreadProcessId(window, out owner) == 0 || owner != pid) return true;
            var title = new StringBuilder(512);
            var name = new StringBuilder(256);
            GetWindowTextW(window, title, title.Capacity);
            GetClassNameW(window, name, name.Capacity);
            int cloaked;
            if (DwmGetWindowAttribute(window, 14, out cloaked, 4) != 0) cloaked = 0;
            rows.Add(new Row {
                Handle = window.ToInt64(), Owner = GetWindow(window, 4).ToInt64(),
                RootOwner = GetAncestor(window, 3).ToInt64(), Parent = GetAncestor(window, 1).ToInt64(),
                Visible = IsWindowVisible(window), Enabled = IsWindowEnabled(window), Cloaked = cloaked != 0,
                Title = title.ToString(), ClassName = name.ToString(),
                Style = "0x" + (GetLong(window, -16).ToInt64() & 0xffffffffL).ToString("X8"),
                ExStyle = "0x" + (GetLong(window, -20).ToInt64() & 0xffffffffL).ToString("X8")
            });
            return true;
        }, IntPtr.Zero);
        return rows;
    }
}
'@
}

$automation = [Windows.Automation.AutomationElement]
$root = $automation::RootElement
$views = [ordered]@{ control = [Windows.Automation.TreeWalker]::ControlViewWalker; raw = [Windows.Automation.TreeWalker]::RawViewWalker }

function Get-Handle($element) { [long]$element.Current.NativeWindowHandle }

# Desktop children by view. This is the set the Agent's listWindows walked before owned-window support.
$desktop = [ordered]@{}
foreach ($view in $views.GetEnumerator()) {
    $handles = New-Object 'Collections.Generic.List[long]'
    $node = $view.Value.GetFirstChild($root)
    $visited = 0
    while ($node -and ++$visited -le 4096) {
        try { if ($node.Current.ProcessId -eq $ProcessId) { $handles.Add((Get-Handle $node)) } } catch {}
        $node = $view.Value.GetNextSibling($node)
    }
    $desktop[$view.Key] = $handles.ToArray()
}

$windows = foreach ($row in [UiaWindowProbe]::TopLevel([uint32]$ProcessId)) {
    $entry = [ordered]@{
        hwnd = $row.Handle; owner = $row.Owner; rootOwner = $row.RootOwner; win32Parent = $row.Parent
        visible = $row.Visible; enabled = $row.Enabled; cloaked = $row.Cloaked
        title = $row.Title; className = $row.ClassName; style = $row.Style; exStyle = $row.ExStyle
        desktopChildControlView = $desktop.control -contains $row.Handle
        desktopChildRawView = $desktop.raw -contains $row.Handle
    }
    try {
        $element = $automation::FromHandle([IntPtr]$row.Handle)
        $entry.uia = [ordered]@{
            controlType = $element.Current.ControlType.ProgrammaticName
            isControlElement = $element.Current.IsControlElement
            isOffscreen = $element.Current.IsOffscreen
            name = $element.Current.Name
        }
        foreach ($view in $views.GetEnumerator()) {
            # Parent chain up to the desktop: each step is the HWND of the UIA parent, 0 for a non-HWND element.
            $chain = New-Object 'Collections.Generic.List[object]'
            $node = $element
            for ($depth = 0; $depth -lt 16; $depth++) {
                $node = $view.Value.GetParent($node)
                if (!$node) { break }
                if ($node -eq $root) { $chain.Add('desktop'); break }
                $chain.Add((Get-Handle $node))
            }
            $entry.uia["$($view.Key)ParentChain"] = $chain.ToArray()
        }
    } catch { $entry.uiaError = $_.Exception.Message }
    $entry
}

ConvertTo-Json -Depth 8 -InputObject ([ordered]@{
    processId = $ProcessId
    capturedUtc = [DateTime]::UtcNow.ToString('o')
    desktopChildren = $desktop
    topLevelWindows = @($windows)
})
