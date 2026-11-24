# Read-only by default: what MSAA (IAccessible) exposes below the list, tab and table containers of one
# process, and whether a child can be told apart from another by anything but its position.
# -SelectListItem and -ActivateTab change the target and are meant for a test fixture only.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][int]$ProcessId,
    [ValidateRange(1, 64)][int]$MaxChildren = 8,
    [ValidateRange(0, 64)][int]$SelectListItem = 0,
    [ValidateRange(0, 64)][int]$ActivateTab = 0
)
$ErrorActionPreference = 'Stop'
Add-Type -ReferencedAssemblies Accessibility -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
using Accessibility;

public static class MsaaChildren {
    private delegate bool EnumProc(IntPtr window, IntPtr state);
    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumProc callback, IntPtr state);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr window, out uint owner);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr window);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int GetClassNameW(IntPtr window, StringBuilder text, int count);
    [DllImport("oleacc.dll")] private static extern int AccessibleObjectFromWindow(IntPtr window, uint id, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object accessible);
    [DllImport("oleacc.dll")] private static extern int AccessibleChildren(IAccessible container, int start, int count, [Out] object[] children, out int obtained);
    [DllImport("oleacc.dll")] private static extern int WindowFromAccessibleObject(IAccessible accessible, out IntPtr window);
    private static readonly Guid IAccIdentity = new Guid("7852B78D-1CFD-41C1-A615-9C0C85960B5F");
    private static readonly HashSet<int> Containers = new HashSet<int> { 33, 60, 24, 35 }; // list, page tab list, table, outline

    public sealed class Child {
        public int Index; public string Kind; public int Role; public bool Named; public int State; public string DefaultAction;
        public bool HasIdentityInterface; public string SameObjectOnRefetch; public int ChildCount;
    }
    public sealed class Container {
        public string Path; public int Role; public string WindowClass; public int ChildCount; public string Action;
        public List<Child> Children = new List<Child>();
    }

    private static object Get(Func<object> read) { try { return read(); } catch (Exception) { return null; } }
    private static int Role(IAccessible node, object id) { object role = Get(() => node.get_accRole(id)); return role is int ? (int)role : -1; }
    private static int State(IAccessible node, object id) { object state = Get(() => node.get_accState(id)); return state is int ? (int)state : -1; }

    private static object[] ChildrenOf(IAccessible node, int limit) {
        int count = 0;
        try { count = node.accChildCount; } catch (Exception) { return new object[0]; }
        var children = new object[Math.Min(count, limit)];
        int obtained;
        if (children.Length == 0 || AccessibleChildren(node, 0, children.Length, children, out obtained) < 0) return new object[0];
        Array.Resize(ref children, obtained);
        return children;
    }

    public static List<Container> Read(uint pid, int maxChildren, int selectListItem, int activateTab) {
        var result = new List<Container>();
        var roots = new List<IntPtr>();
        EnumWindows((window, state) => {
            uint owner;
            if (IsWindowVisible(window) && GetWindowThreadProcessId(window, out owner) != 0 && owner == pid) roots.Add(window);
            return true;
        }, IntPtr.Zero);
        Guid iid = typeof(IAccessible).GUID;
        int budget = 4000;
        foreach (IntPtr root in roots) {
            object client;
            if (AccessibleObjectFromWindow(root, 0xFFFFFFFC, ref iid, out client) < 0 || !(client is IAccessible)) continue;
            Walk((IAccessible)client, "0", 0, result, maxChildren, selectListItem, activateTab, ref budget);
        }
        return result;
    }

    private static void Walk(IAccessible node, string path, int depth, List<Container> result, int maxChildren,
                             int selectListItem, int activateTab, ref int budget) {
        if (--budget < 0 || depth > 14) return;
        int role = Role(node, 0);
        bool container = Containers.Contains(role);
        if (container) result.Add(Describe(node, path, role, maxChildren, selectListItem, activateTab));
        // Containers nest: a tab control holds the pages with the lists and grids. A grid can have thousands of rows.
        object[] children = ChildrenOf(node, container ? 16 : 256);
        for (int index = 0; index < children.Length; index++) {
            var child = children[index] as IAccessible;
            if (child != null) Walk(child, path + "/" + index, depth + 1, result, maxChildren, selectListItem, activateTab, ref budget);
        }
    }

    private static Container Describe(IAccessible node, string path, int role, int maxChildren, int selectListItem, int activateTab) {
        var container = new Container { Path = path, Role = role };
        try { container.ChildCount = node.accChildCount; } catch (Exception) { container.ChildCount = -1; }
        IntPtr window;
        if (WindowFromAccessibleObject(node, out window) >= 0) {
            var name = new StringBuilder(256);
            GetClassNameW(window, name, name.Capacity);
            container.WindowClass = name.ToString();
        }
        object[] children = ChildrenOf(node, maxChildren);
        for (int index = 0; index < children.Length; index++) {
            var item = new Child { Index = index };
            var element = children[index] as IAccessible;
            if (element != null) {
                // A full object. Two fetches of one child give two COM objects unless the server keeps one.
                item.Kind = "object";
                item.Role = Role(element, 0);
                item.State = State(element, 0);
                item.Named = !string.IsNullOrEmpty(Get(() => element.get_accName(0)) as string);
                item.DefaultAction = Get(() => element.get_accDefaultAction(0)) as string;
                try { item.ChildCount = element.accChildCount; } catch (Exception) { item.ChildCount = -1; }
                IntPtr unknown = Marshal.GetIUnknownForObject(element);
                try {
                    IntPtr identity;
                    Guid identityIid = IAccIdentity;
                    item.HasIdentityInterface = Marshal.QueryInterface(unknown, ref identityIid, out identity) >= 0 && identity != IntPtr.Zero;
                    if (identity != IntPtr.Zero) Marshal.Release(identity);
                    object[] again = ChildrenOf(node, index + 1);
                    if (again.Length > index && again[index] is IAccessible) {
                        IntPtr second = Marshal.GetIUnknownForObject(again[index]);
                        item.SameObjectOnRefetch = second == unknown ? "same" : "different";
                        Marshal.Release(second);
                    }
                } finally { Marshal.Release(unknown); }
            } else if (children[index] is int) {
                // A simple element: only the pair (parent, child number) names it, and the number is its position.
                object id = children[index];
                item.Kind = "childId " + id;
                item.Role = Role(node, id);
                item.State = State(node, id);
                item.Named = !string.IsNullOrEmpty(Get(() => node.get_accName(id)) as string);
                item.DefaultAction = Get(() => node.get_accDefaultAction(id)) as string;
            } else { item.Kind = "other"; }
            container.Children.Add(item);
        }
        try {
            if (role == 33 && selectListItem > 0) { node.accSelect(2, selectListItem); container.Action = "accSelect(TAKESELECTION, " + selectListItem + ") returned"; }
            if (role == 60 && activateTab > 0) { node.accDoDefaultAction(activateTab); container.Action = "accDoDefaultAction(" + activateTab + ") returned"; }
        } catch (Exception failure) { container.Action = "failed: " + failure.GetType().Name; }
        return container;
    }
}
'@
$rows = [MsaaChildren]::Read([uint32]$ProcessId, $MaxChildren, $SelectListItem, $ActivateTab)
$roleNames = @{ 24 = 'table'; 33 = 'list'; 35 = 'outline'; 60 = 'page tab list'; 34 = 'list item'; 37 = 'page tab'; 28 = 'row'; 29 = 'cell'; 25 = 'column header'; 26 = 'row header'; 36 = 'outline item' }
[ordered]@{
    client = 'MSAA IAccessible through oleacc.dll, no UI Automation and no Agent'
    processId = $ProcessId
    containers = @($rows | ForEach-Object {
        [ordered]@{ path = $_.Path; role = $roleNames[$_.Role]; roleId = $_.Role; windowClass = $_.WindowClass; childCount = $_.ChildCount; action = $_.Action
            children = @($_.Children | ForEach-Object {
                [ordered]@{ index = $_.Index; kind = $_.Kind; role = $roleNames[$_.Role]; roleId = $_.Role; named = $_.Named; state = $_.State
                    defaultAction = $_.DefaultAction; hasIdentityInterface = $_.HasIdentityInterface; sameObjectOnRefetch = $_.SameObjectOnRefetch
                    childCount = $_.ChildCount } }) } })
} | ConvertTo-Json -Depth 6
