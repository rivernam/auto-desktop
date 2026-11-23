using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public sealed partial class ReadOnlyJavaAccessBridge
{
    // Windows ABI from OpenJDK AccessBridgePackages.h. Java handles are 64-bit;
    // the VM identifier, jints and BOOLs are 32-bit under this ABI.
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ContextInfo
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 1024)] public string Name;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 1024)] public string Description;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string Role;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string EnglishRole;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string States;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string EnglishStates;
        public int IndexInParent;
        public int ChildCount;
        public int X;
        public int Y;
        public int Width;
        public int Height;
        public int AccessibleComponent;
        public int AccessibleAction;
        public int AccessibleSelection;
        public int AccessibleText;
        public int AccessibleInterfaces;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Message
    {
        public IntPtr Hwnd;
        public uint Id;
        public UIntPtr WParam;
        public IntPtr LParam;
        public uint Time;
        public int X;
        public int Y;
        public uint Reserved;
    }

    public sealed class Node
    {
        public string Path { get; set; }
        public string Name { get; set; }
        public string Role { get; set; }
        public string States { get; set; }
        public int ChildCount { get; set; }
        public bool HasAction { get; set; }
        public bool HasText { get; set; }
    }

    public sealed class Result
    {
        public readonly List<Node> Nodes = new List<Node>();
        public bool Truncated { get; internal set; }
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void Run();

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int GetRoot(IntPtr hwnd, out int vmId, out long context);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int GetInfo(int vmId, long context, out ContextInfo info);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate long GetChild(int vmId, long context, int index);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void Release(int vmId, long context);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr LoadLibraryExW(string fileName, IntPtr reserved, uint flags);

    [DllImport("kernel32.dll", CharSet = CharSet.Ansi, ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr GetProcAddress(IntPtr module, string name);

    [DllImport("kernel32.dll")]
    private static extern bool FreeLibrary(IntPtr module);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out int processId);

    [DllImport("user32.dll")]
    private static extern bool PeekMessageW(out Message message, IntPtr hwnd, uint min, uint max, uint flags);

    [DllImport("user32.dll")]
    private static extern IntPtr DispatchMessageW(ref Message message);

    private readonly GetInfo getInfo;
    private readonly GetChild getChild;
    private readonly Release release;

    private ReadOnlyJavaAccessBridge(IntPtr module)
    {
        getInfo = Load<GetInfo>(module, "getAccessibleContextInfo");
        getChild = Load<GetChild>(module, "getAccessibleChildFromContext");
        release = Load<Release>(module, "releaseJavaObject");
    }

    public static Result Read(string dllPath, IntPtr hwnd, int expectedPid)
    {
        return WithRoot(dllPath, hwnd, expectedPid, (module, bridge, vmId, root) => bridge.ReadTree(vmId, root));
    }

    private Result ReadTree(int vmId, long root)
    {
        var result = new Result();
        Visit(vmId, root, "0", 0, result, false);
        if (result.Nodes.Count == 0)
            throw new InvalidOperationException("Java Access Bridge returned a root without context metadata.");
        return result;
    }

    private static T WithRoot<T>(string dllPath, IntPtr hwnd, int expectedPid,
        Func<IntPtr, ReadOnlyJavaAccessBridge, int, long, T> operation)
    {
        AssertOwner(hwnd, expectedPid);
        const uint searchDllLoadDirectory = 0x100;
        const uint searchDefaultDirectories = 0x1000;
        IntPtr module = LoadLibraryExW(dllPath, IntPtr.Zero, searchDllLoadDirectory | searchDefaultDirectories);
        if (module == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Loading Java Access Bridge");

        try
        {
            var bridge = new ReadOnlyJavaAccessBridge(module);
            var getRoot = Load<GetRoot>(module, "getAccessibleContextFromHWND");
            Load<Run>(module, "Windows_run")();

            var timer = Stopwatch.StartNew();
            while (timer.ElapsedMilliseconds < 5000)
            {
                // The DLL's discovery handshake uses a message window on this thread.
                Message message;
                while (PeekMessageW(out message, IntPtr.Zero, 0, 0, 1))
                    DispatchMessageW(ref message);

                AssertOwner(hwnd, expectedPid);
                int vmId;
                long root;
                if (getRoot(hwnd, out vmId, out root) != 0 && root != 0)
                {
                    try { return operation(module, bridge, vmId, root); }
                    finally { bridge.release(vmId, root); }
                }
                Thread.Sleep(25);
            }
            throw new InvalidOperationException("No Java Access Bridge context for the fixture window within five seconds.");
        }
        finally
        {
            FreeLibrary(module);
        }
    }

    private static void AssertOwner(IntPtr hwnd, int expectedPid)
    {
        int owner;
        if (GetWindowThreadProcessId(hwnd, out owner) == 0 || owner != expectedPid)
            throw new InvalidOperationException("The fixture HWND no longer belongs to its expected PID.");
    }

    private void Visit(int vmId, long context, string path, int depth, Result result, bool releaseContext = true)
    {
        const int maxDepth = 16;
        const int maxNodes = 150;
        try
        {
            ContextInfo info;
            if (getInfo(vmId, context, out info) == 0)
                return;

            result.Nodes.Add(new Node
            {
                Path = path,
                Name = RequiresNameRedaction(info) ? "" : info.Name,
                Role = info.EnglishRole,
                States = info.EnglishStates,
                ChildCount = info.ChildCount,
                HasAction = info.AccessibleAction != 0,
                HasText = info.AccessibleText != 0
            });
            if (depth == maxDepth)
            {
                if (info.ChildCount > 0)
                    result.Truncated = true;
                return;
            }

            for (int index = 0; index < info.ChildCount; index++)
            {
                if (result.Nodes.Count == maxNodes)
                {
                    result.Truncated = true;
                    break;
                }
                long child = getChild(vmId, context, index);
                if (child != 0)
                    Visit(vmId, child, path + "/" + index, depth + 1, result);
            }
        }
        finally
        {
            if (releaseContext)
                release(vmId, context);
        }
    }

    private static bool RequiresNameRedaction(ContextInfo info)
    {
        return info.AccessibleText != 0
            || string.Equals(info.EnglishRole, "text", StringComparison.OrdinalIgnoreCase)
            || string.Equals(info.EnglishRole, "password text", StringComparison.OrdinalIgnoreCase)
            || (info.EnglishStates != null && info.EnglishStates.IndexOf("editable", StringComparison.OrdinalIgnoreCase) >= 0);
    }

    private static T Load<T>(IntPtr module, string name) where T : class
    {
        IntPtr address = GetProcAddress(module, name);
        if (address == IntPtr.Zero)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Resolving Java Access Bridge export " + name);
        return (T)(object)Marshal.GetDelegateForFunctionPointer(address, typeof(T));
    }
}
