using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;

public sealed partial class ReadOnlyJavaAccessBridge
{
    private const string CounterName = "Increment fixture counter";
    private const int ActionNameChars = 256;
    private const int ActionNameBytes = ActionNameChars * 2;
    private const int MaxActions = 256;
    private const int MaxActionsToDo = 32;

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int GetActions(int vmId, long context, IntPtr actions);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate int DoActions(int vmId, long context, IntPtr actionsToDo, out int failure);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, ExactSpelling = true, SetLastError = true)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int count);

    [DllImport("kernel32.dll")]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static void InvokeFixtureCounter(string dllPath, IntPtr hwnd, int expectedPid,
        string commandLine, string stateDirectory, string windowTitle)
    {
        AssertFixtureCommand(commandLine, stateDirectory, windowTitle);
        WithRoot(dllPath, hwnd, expectedPid, (module, bridge, vmId, root) =>
        {
            var tree = bridge.ReadTree(vmId, root);
            long expectedEdges = 0;
            foreach (var node in tree.Nodes)
                expectedEdges += node.ChildCount;
            if (tree.Truncated || expectedEdges != tree.Nodes.Count - 1
                || tree.Nodes[0].Role != "frame" || tree.Nodes[0].Name != windowTitle)
                throw new InvalidOperationException("The complete Swing fixture frame could not be identified.");

            var counter = tree.Nodes.FindAll(node => node.Name == CounterName);
            if (counter.Count != 1 || counter[0].Role != "push button" || !counter[0].HasAction)
                throw new InvalidOperationException("The Swing fixture must expose exactly one actionable counter button.");

            bridge.InvokeCounterNode(module, vmId, root, counter[0].Path, hwnd, expectedPid);
            return true;
        });
    }

    private void InvokeCounterNode(IntPtr module, int vmId, long root, string path, IntPtr hwnd, int expectedPid)
    {
        var acquired = new List<long>();
        long context = root;
        try
        {
            string[] indexes = path.Split('/');
            for (int index = 1; index < indexes.Length; index++)
            {
                context = getChild(vmId, context, int.Parse(indexes[index]));
                if (context == 0)
                    throw new InvalidOperationException("The Swing fixture counter disappeared before invocation.");
                acquired.Add(context);
            }

            ContextInfo info;
            if (getInfo(vmId, context, out info) == 0 || info.Name != CounterName || info.EnglishRole != "push button"
                || info.AccessibleAction == 0 || RequiresNameRedaction(info) || info.EnglishStates == null
                || !Array.Exists(info.EnglishStates.Split(','), state => state.Trim() == "enabled"))
                throw new InvalidOperationException("The Swing fixture counter is no longer an enabled push button.");

            var getActions = Load<GetActions>(module, "getAccessibleActions");
            var doActions = Load<DoActions>(module, "doAccessibleActions");
            string click = ReadCounterClick(getActions, vmId, context);
            AssertOwner(hwnd, expectedPid);
            DispatchClickOnce(doActions, vmId, context, click);
        }
        finally
        {
            for (int index = acquired.Count - 1; index >= 0; index--)
                release(vmId, acquired[index]);
        }
    }

    private static string ReadCounterClick(GetActions getActions, int vmId, long context)
    {
        // OpenJDK AccessibleActions: jint count followed by 256 UTF-16 names of 256 code units.
        IntPtr actions = Marshal.AllocHGlobal(sizeof(int) + MaxActions * ActionNameBytes);
        try
        {
            if (getActions(vmId, context, actions) == 0)
                throw new InvalidOperationException("Java Access Bridge could not read the Swing counter actions.");
            if (Marshal.ReadInt32(actions) != 1)
                throw new InvalidOperationException("The Swing counter must advertise exactly one Java Access Bridge action.");
            // JButton's sole accessible action calls doClick. Swing localizes its description.
            string name = Marshal.PtrToStringUni(IntPtr.Add(actions, sizeof(int)), ActionNameChars);
            int terminator = name.IndexOf('\0');
            if (terminator <= 0)
                throw new InvalidOperationException("Java Access Bridge returned a malformed Swing counter action name.");
            return name.Substring(0, terminator);
        }
        finally { Marshal.FreeHGlobal(actions); }
    }

    private static void DispatchClickOnce(DoActions doActions, int vmId, long context, string actionName)
    {
        // OpenJDK AccessibleActionsToDo uses 32 action slots with the same UTF-16 name size.
        var bytes = new byte[sizeof(int) + MaxActionsToDo * ActionNameBytes];
        IntPtr actions = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            Marshal.Copy(bytes, 0, actions, bytes.Length);
            Marshal.WriteInt32(actions, 1);
            char[] click = actionName.ToCharArray();
            Marshal.Copy(click, 0, IntPtr.Add(actions, sizeof(int)), click.Length);
            int failure;
            if (doActions(vmId, context, actions, out failure) == 0)
                throw new InvalidOperationException("Java Access Bridge rejected the single Swing counter click.");
        }
        finally { Marshal.FreeHGlobal(actions); }
    }

    private static void AssertFixtureCommand(string commandLine, string stateDirectory, string windowTitle)
    {
        if (string.IsNullOrEmpty(commandLine))
            throw new InvalidOperationException("The Swing fixture command line is unavailable.");
        int count;
        IntPtr arguments = CommandLineToArgvW(commandLine, out count);
        if (arguments == IntPtr.Zero)
            throw new InvalidOperationException("The Swing fixture command line could not be parsed.");
        try
        {
            if (count < 5 || ReadArgument(arguments, count - 4) != "FrameworkFixture"
                || ReadArgument(arguments, count - 3) != "swing" || ReadArgument(arguments, count - 1) != windowTitle
                || !string.Equals(Path.GetFullPath(ReadArgument(arguments, count - 2)),
                    Path.GetFullPath(stateDirectory), StringComparison.OrdinalIgnoreCase))
                throw new InvalidOperationException("The process does not have the expected Swing fixture arguments.");
        }
        finally { LocalFree(arguments); }
    }

    private static string ReadArgument(IntPtr arguments, int index)
    {
        return Marshal.PtrToStringUni(Marshal.ReadIntPtr(arguments, index * IntPtr.Size));
    }
}
