# Read-only diagnostic, independent of both Agents. Walks one window's Control View through the
# UI Automation COM client (the API both Agents use) and reports elements whose GetRuntimeId result is
# empty or shared with another element. It reads no Value, calls no pattern, and reports control
# types, class names and framework IDs only.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][long]$WindowHandle,
    [Parameter(Mandatory)][int]$ProcessId,
    [ValidateRange(0, 32)][int]$MaxDepth = 12,
    [ValidateRange(1, 5000)][int]$MaxElements = 2000,
    [string]$EditAutomationId
)
$ErrorActionPreference = 'Stop'
if ([Console]::IsOutputRedirected) { [Console]::OutputEncoding = New-Object Text.UTF8Encoding($false) }
# Run this in a process that has not loaded the managed System.Windows.Automation client. That
# library registers a process-wide proxy callback, after which this COM client is served bare HWND
# panes for WinForms controls instead of the provider's own elements.
if ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -ceq 'UIAutomationClient' }) {
    throw 'Run this probe in a process that has not loaded the managed UI Automation client.'
}
if (!('UiaRuntimeIdProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

// Vtable order follows UIAutomationClient.h. Unused slots keep their position.
[ComImport, Guid("30CBE57D-D9D0-452A-AB13-7AC5AC4825EE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IProbeAutomation {
    void _3(); void _4(); void _5();
    [PreserveSig] int ElementFromHandle(IntPtr window, out IProbeElement element);
    void _7(); void _8(); void _9(); void _10(); void _11(); void _12(); void _13();
    [PreserveSig] int get_ControlViewWalker(out IProbeWalker walker);
}
[ComImport, Guid("4042C624-389C-4AFC-A630-9DF854A541FC"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IProbeWalker {
    void _3();
    [PreserveSig] int GetFirstChildElement(IProbeElement element, out IProbeElement child);
    void _5();
    [PreserveSig] int GetNextSiblingElement(IProbeElement element, out IProbeElement next);
}
[ComImport, Guid("D22108AA-8AC5-49A5-837B-37BBB3D7591E"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IProbeElement {
    void _3();
    [PreserveSig] int GetRuntimeId(out IntPtr array);
    void _5(); void _6(); void _7(); void _8(); void _9(); void _10(); void _11(); void _12(); void _13();
    void _14(); void _15(); void _16(); void _17(); void _18(); void _19();
    [PreserveSig] int get_CurrentProcessId(out int value);
    [PreserveSig] int get_CurrentControlType(out int value);
    void _22(); void _23(); void _24(); void _25(); void _26(); void _27(); void _28();
    [PreserveSig] int get_CurrentAutomationId([MarshalAs(UnmanagedType.BStr)] out string value);
    [PreserveSig] int get_CurrentClassName([MarshalAs(UnmanagedType.BStr)] out string value);
    void _31(); void _32(); void _33(); void _34(); void _35();
    [PreserveSig] int get_CurrentNativeWindowHandle(out IntPtr value);
    void _37(); void _38(); void _39();
    [PreserveSig] int get_CurrentFrameworkId([MarshalAs(UnmanagedType.BStr)] out string value);
}

public static class UiaRuntimeIdProbe {
    [DllImport("oleaut32.dll")] static extern uint SafeArrayGetDim(IntPtr array);
    [DllImport("oleaut32.dll")] static extern int SafeArrayGetVartype(IntPtr array, out ushort type);
    [DllImport("oleaut32.dll")] static extern int SafeArrayGetLBound(IntPtr array, uint dim, out int bound);
    [DllImport("oleaut32.dll")] static extern int SafeArrayGetUBound(IntPtr array, uint dim, out int bound);
    [DllImport("oleaut32.dll")] static extern int SafeArrayAccessData(IntPtr array, out IntPtr data);
    [DllImport("oleaut32.dll")] static extern int SafeArrayUnaccessData(IntPtr array);
    [DllImport("oleaut32.dll")] static extern int SafeArrayDestroy(IntPtr array);

    public sealed class Row {
        public int Depth, ControlType, ProcessId, RuntimeIdLength = -1, DuplicateOf = -1;
        public long Handle;
        public string Path, ClassName, FrameworkId, RuntimeIdResult, Error, AutomationId;
        public bool Duplicated;
    }

    static string Hex(int status) { return "0x" + status.ToString("X8"); }

    static void ReadId(IProbeElement element, Row row, Dictionary<string, int> seen, List<Row> rows) {
        IntPtr array;
        int status = element.GetRuntimeId(out array);
        if (status < 0) { row.RuntimeIdResult = Hex(status); return; }
        if (array == IntPtr.Zero) { row.RuntimeIdResult = "S_OK null array"; return; }
        try {
            ushort type; int lower, upper;
            if (SafeArrayGetDim(array) != 1 || SafeArrayGetVartype(array, out type) < 0 || type != 3
                    || SafeArrayGetLBound(array, 1, out lower) < 0 || SafeArrayGetUBound(array, 1, out upper) < 0) {
                row.RuntimeIdResult = "S_OK unexpected array shape"; return;
            }
            long length = (long)upper - lower + 1;
            row.RuntimeIdResult = "S_OK VT_I4 [" + lower + ".." + upper + "]";
            if (length < 0 || length > 4096) return;
            row.RuntimeIdLength = (int)length;
            if (length == 0) return;
            IntPtr data;
            if (SafeArrayAccessData(array, out data) < 0) return;
            var values = new int[length];
            try { Marshal.Copy(data, values, 0, (int)length); } finally { SafeArrayUnaccessData(array); }
            string key = String.Join(".", values);
            int first;
            if (seen.TryGetValue(key, out first)) { row.DuplicateOf = first; rows[first].Duplicated = true; }
            else seen.Add(key, rows.Count);
        } finally { SafeArrayDestroy(array); }
    }

    public static List<Row> Walk(long window, int maxDepth, int maxElements, bool checkEdit, out bool limited) {
        var automation = (IProbeAutomation)Activator.CreateInstance(
            Type.GetTypeFromCLSID(new Guid("FF48DBA4-60EF-4201-AA87-54103EEF594E")));
        IProbeWalker walker; IProbeElement root;
        Marshal.ThrowExceptionForHR(automation.get_ControlViewWalker(out walker));
        Marshal.ThrowExceptionForHR(automation.ElementFromHandle(new IntPtr(window), out root));
        var rows = new List<Row>();
        var seen = new Dictionary<string, int>(StringComparer.Ordinal);
        limited = false;
        var stack = new Stack<Tuple<IProbeElement, int, string>>();
        stack.Push(Tuple.Create(root, 0, ""));
        while (stack.Count > 0) {
            var item = stack.Pop();
            if (rows.Count >= maxElements) { limited = true; break; }
            var row = new Row { Depth = item.Item2 };
            IntPtr handle;
            int status = item.Item1.get_CurrentControlType(out row.ControlType);
            if (status >= 0 && checkEdit && row.ControlType == 50004)
                status = item.Item1.get_CurrentAutomationId(out row.AutomationId);
            if (status >= 0) status = item.Item1.get_CurrentProcessId(out row.ProcessId);
            if (status >= 0) status = item.Item1.get_CurrentClassName(out row.ClassName);
            if (status >= 0) status = item.Item1.get_CurrentFrameworkId(out row.FrameworkId);
            if (status >= 0) { status = item.Item1.get_CurrentNativeWindowHandle(out handle); row.Handle = handle.ToInt64(); }
            if (status < 0) row.Error = Hex(status);
            row.Path = (item.Item3 + "/" + row.ControlType).TrimStart('/');
            ReadId(item.Item1, row, seen, rows);
            rows.Add(row);
            if (row.Error != null || item.Item2 >= maxDepth) continue;
            var children = new List<IProbeElement>();
            IProbeElement child;
            if (walker.GetFirstChildElement(item.Item1, out child) < 0) { row.Error = "children"; continue; }
            while (child != null && children.Count < maxElements) {
                children.Add(child);
                IProbeElement next;
                if (walker.GetNextSiblingElement(child, out next) < 0) { row.Error = "siblings"; break; }
                child = next;
            }
            for (int i = children.Count - 1; i >= 0; i--) stack.Push(Tuple.Create(children[i], item.Item2 + 1, row.Path));
        }
        return rows;
    }
}
'@
}

$types = 'Button', 'Calendar', 'CheckBox', 'ComboBox', 'Edit', 'Hyperlink', 'Image', 'ListItem', 'List', 'Menu', 'MenuBar',
    'MenuItem', 'ProgressBar', 'RadioButton', 'ScrollBar', 'Slider', 'Spinner', 'StatusBar', 'Tab', 'TabItem', 'Text', 'ToolBar',
    'ToolTip', 'Tree', 'TreeItem', 'Custom', 'Group', 'Thumb', 'DataGrid', 'DataItem', 'Document', 'SplitButton', 'Window', 'Pane',
    'Header', 'HeaderItem', 'Table', 'TitleBar', 'Separator', 'SemanticZoom', 'AppBar'
function Get-TypeName([int]$id) { if ($id -ge 50000 -and $id -le 50040) { $types[$id - 50000] } else { "Type$id" } }
function Get-PathName([string]$path) { (($path -split '/') | ForEach-Object { Get-TypeName ([int]$_) }) -join '/' }
function Group-Rows($selected) {
    $selected | Group-Object { "$($_.Path)|$($_.FrameworkId)|$($_.RuntimeIdResult)" } | Sort-Object Name | ForEach-Object {
        $first = $_.Group[0]
        [ordered]@{ path = Get-PathName $first.Path; frameworkId = $first.FrameworkId; className = $first.ClassName
            getRuntimeId = $first.RuntimeIdResult; count = $_.Count; hwndBacked = @($_.Group | Where-Object { $_.Handle -ne 0 }).Count }
    }
}

$limited = $false
$rows = [UiaRuntimeIdProbe]::Walk($WindowHandle, $MaxDepth, $MaxElements, [bool]$EditAutomationId, [ref]$limited)
if (!$rows.Count -or $rows[0].ProcessId -ne $ProcessId) { throw 'The window does not belong to the requested process.' }
$empty = @($rows | Where-Object { $_.RuntimeIdLength -le 0 })
$duplicates = @($rows | Where-Object { $_.DuplicateOf -ge 0 -or $_.Duplicated })
ConvertTo-Json -Depth 6 -InputObject ([ordered]@{
    windowHandle = $WindowHandle; processId = $ProcessId; capturedUtc = [DateTime]::UtcNow.ToString('o')
    client = 'IUIAutomation COM client (CUIAutomation), Control View'
    maxDepth = $MaxDepth; maxElements = $MaxElements; elementLimitReached = $limited
    elements = $rows.Count
    propertyErrors = @($rows | Where-Object Error).Count
    matchingEdits = if ($EditAutomationId) {
        @($rows | Where-Object { $_.ProcessId -eq $ProcessId -and $_.ControlType -eq 50004 -and $_.AutomationId -ceq $EditAutomationId }).Count
    } else { $null }
    unusableRuntimeIds = $empty.Count
    unusableRuntimeIdGroups = [object[]]@(Group-Rows $empty)
    duplicateRuntimeIds = $duplicates.Count
    duplicateRuntimeIdGroups = [object[]]@(Group-Rows $duplicates)
    controlTypes = [object[]]@($rows | Group-Object ControlType | Sort-Object Count -Descending |
        ForEach-Object { [ordered]@{ controlType = Get-TypeName ([int]$_.Name); count = $_.Count } })
})
