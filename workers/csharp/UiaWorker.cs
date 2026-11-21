using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text;
using System.Web.Script.Serialization;
using System.Windows.Automation;

internal static partial class UiaWorker
{
    const int MaxRequestChars = 131072;
    const string Unavailable = "BACKEND_UNAVAILABLE";
    const string Stale = "STALE_REFERENCE";
    const string MissingWindow = "WINDOW_NOT_FOUND";
    const string Precondition = "PRECONDITION_FAILED";
    const string Unsupported = "PATTERN_UNSUPPORTED";
    const string UnknownOutcome = "ACTION_OUTCOME_UNKNOWN";

    static readonly Dictionary<string, string> Messages = new Dictionary<string, string> {
        { Unavailable, "UI Automation could not access the interactive desktop." },
        { MissingWindow, "The requested top-level window is unavailable." },
        { Stale, "The captured element or its window is no longer current." },
        { Unsupported, "The element does not support the requested pattern." },
        { Precondition, "The request or current element state does not permit this operation." },
        { UnknownOutcome, "The provider call did not complete successfully. Its effect is unknown." }
    };
    static readonly string[] Operations = { "getCapabilities", "listWindows", "snapshot",
        "findElement", "getElementInfo", "invoke", "setValue" };

    sealed class Fault : Exception
    {
        public readonly string Code;
        public Fault(string code) : base(Messages[code]) { Code = code; }
    }

    // These objects stay private to the worker. Only projected response objects are serialized.
    sealed class Entry
    {
        public AutomationElement Node;
        public int[] RuntimeId;
        public int ProcessId;
        public string Key, ParentKey;
        public string[] Locator;
        public bool Clipped, ProtectChildren;
    }

    sealed class Capture
    {
        public string WindowId;
        public Entry Root;
        public int MaxDepth, MaxElements;
        public bool Truncated;
        public readonly Dictionary<string, Entry> Entries = new Dictionary<string, Entry>();
    }

    static Capture active;
    static TreeWalker Walker { get { return TreeWalker.ControlViewWalker; } }

    static string Text(Dictionary<string, object> request, string key)
    {
        object value;
        return request.TryGetValue(key, out value) ? value as string : null;
    }

    static int Number(Dictionary<string, object> request, string key)
    {
        object value;
        return request.TryGetValue(key, out value) && value is int ? (int)value : -1;
    }

    static AutomationElement Desktop()
    {
        try {
            using (var process = Process.GetCurrentProcess()) {
                if (!Environment.UserInteractive || process.SessionId == 0) throw new Fault(Unavailable);
            }
            var desktop = AutomationElement.RootElement;
            desktop.GetRuntimeId();
            Walker.GetFirstChild(desktop);
            return desktop;
        } catch (Exception) { throw new Fault(Unavailable); }
    }

    // Isolate UIA assembly binding so missing desktop components still yield a capability report.
    [MethodImpl(MethodImplOptions.NoInlining)]
    static void ProbeDesktop() { Desktop(); }

    static object Capabilities()
    {
        try {
            if (Environment.OSVersion.Platform != PlatformID.Win32NT) throw new Fault(Unavailable);
            ProbeDesktop();
            return new { available = true, backend = "UIA", physicalInput = false,
                screenshot = false, operations = Operations };
        } catch (Exception) {
            return new { available = false, backend = "UIA", physicalInput = false,
                screenshot = false, operations = new string[0], reason = Messages[Unavailable] };
        }
    }

    static string WindowId(AutomationElement window)
    {
        return unchecked((uint)window.Current.NativeWindowHandle).ToString(CultureInfo.InvariantCulture);
    }

    static AutomationElement WindowById(string id, AutomationElement desktop)
    {
        try {
            uint number;
            if (!uint.TryParse(id, NumberStyles.None, CultureInfo.InvariantCulture, out number) || number == 0)
                throw new Fault(MissingWindow);
            var handle = IntPtr.Size == 4 ? new IntPtr(unchecked((int)number)) : new IntPtr((long)number);
            var window = AutomationElement.FromHandle(handle);
            if (window == null || WindowId(window) != id) throw new Fault(MissingWindow);
            var parent = Walker.GetParent(window);
            if (parent == null || !Automation.Compare(desktop, parent)) throw new Fault(MissingWindow);
            return window;
        } catch (Exception) { throw new Fault(MissingWindow); }
    }

    static T Pattern<T>(AutomationElement node, AutomationPattern id) where T : class
    {
        object pattern;
        return node.TryGetCurrentPattern(id, out pattern) ? pattern as T : null;
    }

    static string ShortText(string text)
    {
        if (text.Length <= 256) return text;
        return text.Substring(0, char.IsHighSurrogate(text[255]) ? 255 : 256);
    }

    static string Name(AutomationElement node, bool protectedControl)
    {
        return protectedControl ? "" : node.Current.Name ?? "";
    }

    static object Windows(AutomationElement desktop)
    {
        for (int attempt = 0; attempt < 2; attempt++) {
            try {
                var windows = new List<object>();
                var node = Walker.GetFirstChild(desktop);
                for (int i = 0; node != null && i < 4096; i++, node = Walker.GetNextSibling(node)) {
                    string id = WindowId(node);
                    var current = node.Current;
                    int pid = current.ProcessId;
                    if (id == "0" || pid <= 0) continue;
                    bool masked = current.IsPassword || current.ControlType == ControlType.Edit ||
                        Pattern<ValuePattern>(node, ValuePattern.Pattern) != null;
                    windows.Add(new { windowId = id, processId = pid, name = ShortText(Name(node, masked)) });
                }
                if (node != null) throw new Fault(Precondition);
                return windows;
            } catch (ElementNotAvailableException) {
                // Transient popup closure may invalidate sibling enumeration. Retry this read once.
            }
        }
        throw new Fault(Stale);
    }

    static bool Finite(double value) { return !double.IsNaN(value) && !double.IsInfinity(value); }

    static object Inspect(Entry entry, bool capturing, bool verify, out bool actionable)
    {
        var node = entry.Node;
        var current = node.Current;
        var invoke = Pattern<InvokePattern>(node, InvokePattern.Pattern);
        var value = Pattern<ValuePattern>(node, ValuePattern.Pattern);
        var actions = new List<string>(2);
        if (invoke != null) actions.Add("invoke");
        if (value != null && !value.Current.IsReadOnly) actions.Add("setValue");

        string role = current.ControlType.ProgrammaticName.Replace("ControlType.", "");
        bool masked = current.IsPassword || role == "Edit" || value != null;
        string[] identity = { Name(node, masked), role, current.AutomationId ?? "", current.ClassName ?? "" };
        if (verify && (entry.Clipped || !identity.SequenceEqual(entry.Locator, StringComparer.Ordinal)))
            throw new Fault(Stale);
        var fields = Array.ConvertAll(identity, ShortText);
        if (capturing) {
            entry.Locator = fields;
            entry.Clipped = identity.Any(field => field.Length > 256);
            entry.ProtectChildren = masked;
        }

        var rect = current.BoundingRectangle;
        object bounds = null;
        if (!rect.IsEmpty && Finite(rect.X) && Finite(rect.Y) && Finite(rect.Width) && Finite(rect.Height))
            bounds = new { x = rect.X, y = rect.Y, width = rect.Width, height = rect.Height };
        bool enabled = current.IsEnabled;
        bool offscreen = current.IsOffscreen;
        actionable = enabled && !offscreen;
        return new { key = entry.Key, parentKey = entry.ParentKey, name = fields[0], role = fields[1],
            automationId = fields[2], className = fields[3], processId = current.ProcessId,
            bounds, enabled, offscreen, actions, backend = "UIA" };
    }

    static int[] RuntimeId(AutomationElement node)
    {
        var id = node.GetRuntimeId();
        if (id == null || id.Length == 0) throw new Fault(Stale);
        return id;
    }

    static void Visit(Capture capture, List<object> rows, AutomationElement node, string parentKey, int depth)
    {
        var entry = new Entry { Key = Guid.NewGuid().ToString("N"), ParentKey = parentKey,
            Node = node, ProcessId = node.Current.ProcessId, RuntimeId = RuntimeId(node) };
        bool actionable;
        rows.Add(Inspect(entry, true, false, out actionable));
        capture.Entries.Add(entry.Key, entry);
        if (depth == 0) capture.Root = entry;
        if (entry.Clipped) capture.Truncated = true;
        if (entry.ProtectChildren) return;
        for (var child = Walker.GetFirstChild(node); child != null; child = Walker.GetNextSibling(child)) {
            if (depth >= capture.MaxDepth || rows.Count >= capture.MaxElements) {
                capture.Truncated = true;
                break;
            }
            Visit(capture, rows, child, entry.Key, depth + 1);
        }
    }

    static object Snapshot(Dictionary<string, object> request, AutomationElement desktop)
    {
        active = null;
        var capture = new Capture { WindowId = Text(request, "windowId"),
            MaxDepth = Number(request, "maxDepth"), MaxElements = Number(request, "maxElements") };
        if (capture.MaxDepth < 0 || capture.MaxDepth > 32 || capture.MaxElements < 1 || capture.MaxElements > 2000)
            throw new Fault(Precondition);
        var window = WindowById(capture.WindowId, desktop);
        var rows = new List<object>();
        try { Visit(capture, rows, window, null, 0); }
        catch (Exception) { throw new Fault(Stale); }
        active = capture;
        return new { elements = rows, truncated = capture.Truncated };
    }

    static bool CurrentIdentity(Entry entry, AutomationElement node)
    {
        return node.Current.ProcessId == entry.ProcessId && RuntimeId(node).SequenceEqual(entry.RuntimeId);
    }

    static Entry Resolve(Dictionary<string, object> request, AutomationElement desktop)
    {
        try {
            Entry entry;
            var key = Text(request, "key");
            if (active == null || key == null || !active.Entries.TryGetValue(key, out entry) ||
                Number(request, "processId") != entry.ProcessId) throw new Fault(Stale);
            var window = WindowById(active.WindowId, desktop);
            if (!CurrentIdentity(active.Root, window) || !Automation.Compare(active.Root.Node, window) ||
                !CurrentIdentity(entry, entry.Node)) throw new Fault(Stale);
            // A provider may reparent a still-live control in the same window.
            var ancestor = entry.Node;
            var expected = entry;
            while (expected.ParentKey != null) {
                expected = active.Entries[expected.ParentKey];
                ancestor = Walker.GetParent(ancestor);
                if (ancestor == null || !Automation.Compare(ancestor, expected.Node) ||
                    !CurrentIdentity(expected, ancestor)) throw new Fault(Stale);
            }
            if (Automation.Compare(ancestor, window)) return entry;
        } catch (Exception) { throw new Fault(Stale); }
        throw new Fault(Stale);
    }

    static object ElementOperation(Dictionary<string, object> request, string op, AutomationElement desktop)
    {
        var entry = Resolve(request, desktop);
        bool actionable;
        object info;
        try { info = Inspect(entry, false, op != "getElementInfo", out actionable); }
        catch (Exception) { throw new Fault(Stale); }
        if (op == "getElementInfo") return info;
        if (!actionable) throw new Fault(Precondition);

        Action dispatch;
        try {
            if (op == "invoke") {
                var pattern = Pattern<InvokePattern>(entry.Node, InvokePattern.Pattern);
                if (pattern == null) throw new Fault(Unsupported);
                dispatch = pattern.Invoke;
            } else {
                string value = Text(request, "value");
                if (value == null || value.Length > 16384) throw new Fault(Precondition);
                var pattern = Pattern<ValuePattern>(entry.Node, ValuePattern.Pattern);
                if (pattern == null) throw new Fault(Unsupported);
                if (pattern.Current.IsReadOnly) throw new Fault(Precondition);
                dispatch = () => pattern.SetValue(value);
            }
        } catch (Fault) { throw; }
        catch (Exception) { throw new Fault(Stale); }
        try { dispatch(); }
        catch (Exception) { throw new Fault(UnknownOutcome); }
        return new { performed = true };
    }

    static object Dispatch(Dictionary<string, object> request)
    {
        string op = Text(request, "op");
        if (op == "getCapabilities") return Capabilities();
        if (Environment.OSVersion.Platform != PlatformID.Win32NT) throw new Fault(Unavailable);
        return DispatchDesktop(request, op);
    }

    [MethodImpl(MethodImplOptions.NoInlining)]
    static object DispatchDesktop(Dictionary<string, object> request, string op)
    {
        var desktop = Desktop();
        switch (op) {
            case "listWindows": return Windows(desktop);
            case "snapshot": return Snapshot(request, desktop);
            case "getElementInfo":
            case "invoke":
            case "setValue": return ElementOperation(request, op, desktop);
            default: throw new Fault(Precondition);
        }
    }

    // Drain an oversized line before reading the next frame, without retaining its excess.
    static string ReadFrame(TextReader input)
    {
        var buffer = new StringBuilder();
        int ch;
        while ((ch = input.Read()) >= 0 && ch != '\n') {
            if (buffer.Length <= MaxRequestChars) buffer.Append((char)ch);
        }
        return ch < 0 && buffer.Length == 0 ? null : buffer.ToString();
    }

    [MTAThread]
    static void Main()
    {
        var encoding = new UTF8Encoding(false);
        var json = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024, RecursionLimit = 16 };
        using (var input = new StreamReader(Console.OpenStandardInput(), encoding, false))
        using (var output = new StreamWriter(Console.OpenStandardOutput(), encoding) { AutoFlush = true }) {
            string line;
            while ((line = ReadFrame(input)) != null) {
                object response;
                try {
                    if (line.Length > MaxRequestChars) throw new Fault(Precondition);
                    Dictionary<string, object> request;
                    try { request = json.DeserializeObject(line) as Dictionary<string, object>; }
                    catch (Exception) { throw new Fault(Precondition); }
                    if (request == null) throw new Fault(Precondition);
                    response = new { ok = true, result = Dispatch(request) };
                } catch (Exception ex) {
                    var fault = ex as Fault;
                    string code = fault == null ? Unavailable : fault.Code;
                    response = new { ok = false, error = new { code, message = Messages[code] } };
                }
                output.WriteLine(json.Serialize(response));
            }
        }
    }
}
