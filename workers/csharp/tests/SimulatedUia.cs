using System;
using System.Collections.Generic;

// Only the UIA members exercised by UiaWorker. This file is compiled into the
// optional test executable. The production project explicitly lists its sources.
namespace System.Windows.Automation
{
    class ElementNotAvailableException : Exception { }
    class AutomationPattern { }
    class InvokePattern
    {
        public static readonly AutomationPattern Pattern = new AutomationPattern();
        public int Calls;
        public void Invoke() { Calls++; }
    }
    class ValuePattern
    {
        public static readonly AutomationPattern Pattern = new AutomationPattern();
        public ValuePattern Current { get { return this; } }
        public bool IsReadOnly { get; set; }
        public string Value { get; private set; }
        public void SetValue(string text) { Value = text; }
    }
    class ControlType
    {
        public static readonly ControlType Edit = new ControlType("Edit");
        public readonly string ProgrammaticName;
        public ControlType(string role) { ProgrammaticName = "ControlType." + role; }
    }
    static class Automation
    {
        public static bool Compare(AutomationElement x, AutomationElement y) { return x == y; }
    }
    class AutomationElement
    {
        public static readonly AutomationElement RootElement = new AutomationElement();
        public AutomationElement Current { get { return this; } }
        public int NativeWindowHandle, ProcessId = 17;
        public string Name = "", ClassName = "", AutomationId = "";
        public bool IsEnabled = true;
        public bool IsOffscreen { get; set; }
        public bool IsPassword { get; set; }
        public System.Windows.Rect BoundingRectangle { get { return System.Windows.Rect.Empty; } }
        public ControlType ControlType = new ControlType("Button");
        public InvokePattern Invoke;
        public ValuePattern Value;
        public AutomationElement Parent;
        public readonly List<AutomationElement> Children = new List<AutomationElement>();
        static int nextId;
        readonly int id = ++nextId;
        public int[] GetRuntimeId() { return new int[] { 7, id }; }
        public static AutomationElement FromHandle(IntPtr handle)
        {
            return RootElement.Children.Find(c => c.NativeWindowHandle == handle.ToInt64());
        }
        public AutomationElement Add(AutomationElement child)
        {
            child.Parent = this;
            Children.Add(child);
            return child;
        }
        public bool TryGetCurrentPattern(AutomationPattern pattern, out object instance)
        {
            instance = pattern == InvokePattern.Pattern ? (object)Invoke : Value;
            return instance != null;
        }
    }
    class TreeWalker
    {
        public static readonly TreeWalker ControlViewWalker = new TreeWalker();
        public AutomationElement GetParent(AutomationElement n) { return n.Parent; }
        public AutomationElement GetFirstChild(AutomationElement n)
        {
            return n.Children.Count == 0 ? null : n.Children[0];
        }
        public AutomationElement GetNextSibling(AutomationElement n)
        {
            var siblings = n.Parent.Children;
            int next = siblings.IndexOf(n) + 1;
            return next < siblings.Count ? siblings[next] : null;
        }
    }
}
