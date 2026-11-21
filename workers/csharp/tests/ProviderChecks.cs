using System;
using System.Collections.Generic;
using System.Web.Script.Serialization;
using System.Windows.Automation;

internal static partial class UiaWorker
{
    static void Require(bool value, string label)
    {
        if (!value) throw new Exception("Failed: " + label);
    }

    static void Fails(string code, Action operation)
    {
        try { operation(); }
        catch (Fault failure) { Require(failure.Code == code, failure.Code); return; }
        throw new Exception("Expected failure: " + code);
    }

    internal static void CheckProvider()
    {
        var desktop = AutomationElement.RootElement;
        var json = new JavaScriptSerializer();
        Require(json.Serialize(Windows(desktop)) == "[]", "empty window list");
        var window = desktop.Add(new AutomationElement {
            NativeWindowHandle = 3, Name = "Fixture", Invoke = new InvokePattern()
        });
        var edit = window.Add(new AutomationElement {
            Name = "private field contents", ControlType = ControlType.Edit, Value = new ValuePattern()
        });
        edit.Add(new AutomationElement { Name = "private descendant" });
        Require(json.Serialize(Windows(desktop)).Contains("\"windowId\":\"3\""), "window discovery");
        var query = new Dictionary<string, object> {
            { "windowId", "3" }, { "maxDepth", 3 }, { "maxElements", 20 }
        };
        string tree = json.Serialize(Snapshot(query, desktop));
        var snapshot = (Dictionary<string, object>)json.DeserializeObject(tree);
        var rows = (object[])snapshot["elements"];
        Require(!(bool)snapshot["truncated"] && rows.Length == 2, "protected subtree shape");
        Require(!tree.Contains("private"), "editable contents were exposed");
        var root = (Dictionary<string, object>)rows[0];
        var field = (Dictionary<string, object>)rows[1];
        Require((string)root["key"] == (string)field["parentKey"], "parent link");
        var command = new Dictionary<string, object> { { "key", field["key"] }, { "processId", 17 }, { "value", "updated ✓" } };
        ElementOperation(command, "setValue", desktop);
        Require(edit.Value.Value == "updated ✓", "value pattern");
        edit.Value.IsReadOnly = true;
        Fails("PRECONDITION_FAILED", () => ElementOperation(command, "setValue", desktop));
        Fails("PATTERN_UNSUPPORTED", () => ElementOperation(command, "invoke", desktop));
        var panel = window.Add(new AutomationElement());
        window.Children.Remove(edit);
        panel.Add(edit);
        Fails("STALE_REFERENCE", () => ElementOperation(command, "getElementInfo", desktop));
        command["key"] = root["key"];
        ElementOperation(command, "invoke", desktop);
        window.IsOffscreen = true;
        Fails("PRECONDITION_FAILED", () => ElementOperation(command, "invoke", desktop));
        window.IsOffscreen = false;
        window.Name = "changed";
        Fails("STALE_REFERENCE", () => ElementOperation(command, "invoke", desktop));
        Require(window.Invoke.Calls == 1, "side-effect count after rejected operations");
        query["maxDepth"] = 0;
        var bounded = (Dictionary<string, object>)json.DeserializeObject(json.Serialize(Snapshot(query, desktop)));
        Require((bool)bounded["truncated"] && ((object[])bounded["elements"]).Length == 1, "depth bound");
        Fails("STALE_REFERENCE", () => ElementOperation(command, "invoke", desktop));
        Console.WriteLine("Passed worker traversal, privacy, actions, preconditions, identity and depth checks with a simulated provider.");
    }
}

internal static class ProviderChecks
{
    public static void Main() { UiaWorker.CheckProvider(); }
}
