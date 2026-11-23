using System;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

internal sealed class WinFormsFixture : Form
{
    private readonly string stateDirectory;
    private readonly FlowLayoutPanel actions = new FlowLayoutPanel();
    private readonly Timer timer = new Timer { Interval = 25 };
    private readonly TabControl tabs;
    private readonly TextBox edit = new TextBox { Text = "initial fixture value" };
    private readonly TextBox readOnly = new TextBox { Text = "fixed fixture value", ReadOnly = true };
    private readonly Button disabled = ButtonFor("fixtureDisabled", "Disabled action");
    private Button increment;
    private Form modal;
    private int count;

    [STAThread]
    private static int Main(string[] args)
    {
        if (args.Length != 2)
        {
            Console.Error.WriteLine("Usage: WinFormsFixture <state-directory> <window-title>");
            return 2;
        }

        Directory.CreateDirectory(args[0]);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.SetUnhandledExceptionMode(UnhandledExceptionMode.ThrowException);
        using (var form = new WinFormsFixture(args[0], args[1]))
        {
            Application.Run(form);
        }
        return 0;
    }

    private WinFormsFixture(string directory, string title)
    {
        stateDirectory = directory;
        Text = title;
        ClientSize = new Size(740, 620);
        StartPosition = FormStartPosition.CenterScreen;

        var root = new TableLayoutPanel { ColumnCount = 1, RowCount = 2, Dock = DockStyle.Fill };
        root.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        Controls.Add(root);
        root.Controls.Add(BuildActions(), 0, 0);
        tabs = BuildTabs();
        root.Controls.Add(tabs, 0, 1);

        WriteState("count.txt", "0");
        WriteState("value.txt", edit.Text);
        WriteState("read-only.txt", readOnly.Text);
        WriteState("disabled-click.txt", "0");
        WriteState("modal.txt", "closed");
        WriteState("selected.txt", "Choice one");
#if NET9_0_OR_GREATER
        string runtime = RuntimeInformation.FrameworkDescription;
#else
        string runtime = ".NET Framework CLR " + Environment.Version;
#endif
        WriteState("runtime.txt", runtime + " / " + (IntPtr.Size * 8) + "-bit");
        timer.Tick += PollCommands;
        Shown += delegate
        {
            WriteState("page.txt", tabs.SelectedIndex.ToString(CultureInfo.InvariantCulture));
            using (var process = Process.GetCurrentProcess())
            {
                WriteState("ready", process.Id.ToString(CultureInfo.InvariantCulture));
            }
            timer.Start();
        };
        FormClosed += delegate { timer.Dispose(); };
    }

    private Control BuildActions()
    {
        actions.AutoSize = true;
        actions.Dock = DockStyle.Fill;
        actions.Padding = new Padding(5);
        increment = NewIncrementButton();
        disabled.Enabled = false;
        disabled.Click += delegate { WriteState("disabled-click.txt", "1"); };
        var toggle = ButtonFor("fixtureToggle", "Toggle fixture state");
        toggle.Click += delegate
        {
            disabled.Enabled = !disabled.Enabled;
            readOnly.ReadOnly = !readOnly.ReadOnly;
            WriteState("dynamic-state.txt", disabled.Enabled ? "enabled-writable" : "disabled-read-only");
        };
        var openModal = ButtonFor("fixtureModal", "Open fixture modal");
        openModal.Click += delegate { BeginInvoke((MethodInvoker)ShowFixtureModal); };
        actions.Controls.AddRange(new Control[] {
            increment, disabled, ButtonFor("fixtureDuplicateOne", "Duplicate label"),
            ButtonFor("fixtureDuplicateTwo", "Duplicate label"), toggle, openModal
        });
        return actions;
    }

    private TabControl BuildTabs()
    {
        var tabs = Identify(new TabControl { Dock = DockStyle.Fill }, "fixtureTab", "Fixture tabs");
        tabs.TabPages.Add(new TabPage("Common controls") { Controls = { BuildCommonControls() } });
        tabs.TabPages.Add(new TabPage("Grid and tree") { Controls = { BuildGridAndTree() } });
        tabs.TabPages.Add(new TabPage("Virtual lists") { Controls = { BuildVirtualLists() } });
        return tabs;
    }

    private Control BuildCommonControls()
    {
        var table = new TableLayoutPanel {
            ColumnCount = 2, Dock = DockStyle.Fill, AutoScroll = true, Padding = new Padding(10)
        };
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 180));
        table.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        Identify(edit, "fixtureEdit", "Fixture edit");
        edit.TextChanged += delegate { WriteState("value.txt", edit.Text); };
        AddField(table, "Editable text", edit);
        Identify(readOnly, "fixtureReadOnly", "Fixture read-only");
        readOnly.TextChanged += delegate { WriteState("read-only.txt", readOnly.Text); };
        AddField(table, "Read-only text", readOnly);
        var password = Identify(new TextBox { UseSystemPasswordChar = true, Text = "fixture password" },
            "fixturePassword", "Fixture password");
        AddField(table, "Password", password);

        var check = Identify(new CheckBox { AutoSize = true, Text = "Fixture check box" },
            "fixtureCheck", "Fixture check box");
        check.CheckedChanged += delegate { WriteState("checked.txt", check.Checked ? "checked" : "unchecked"); };
        AddField(table, "Check box", check);
        var combo = Identify(new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList }, "fixtureCombo", "Fixture combo box");
        combo.Items.AddRange(new object[] { "Choice one", "Choice two", "Choice three" });
        combo.SelectedIndex = 0;
        combo.SelectedIndexChanged += delegate { WriteState("selected.txt", (string)combo.SelectedItem); };
        AddField(table, "Combo box", combo);
        var list = Identify(new ListBox { Height = 65 }, "fixtureList", "Fixture list");
        list.Items.AddRange(new object[] { "Item one", "Item two", "Item three" });
        list.SelectedIndex = 0;
        list.SelectedIndexChanged += delegate { WriteState("selected.txt", (string)list.SelectedItem); };
        AddField(table, "List box", list);

        var radioGroup = new FlowLayoutPanel { AutoSize = true };
        radioGroup.Controls.Add(new RadioButton { AutoSize = true, Text = "Radio one", Checked = true });
        radioGroup.Controls.Add(new RadioButton { AutoSize = true, Text = "Radio two" });
        AddField(table, "Radio buttons", radioGroup);
        AddField(table, "Number", Identify(new NumericUpDown { Value = 17 }, "fixtureNumber", "Fixture number"));
        AddField(table, "Date", Identify(new DateTimePicker { Format = DateTimePickerFormat.Short, Value = new DateTime(2026, 1, 15) },
            "fixtureDate", "Fixture date"));
        AddField(table, "Slider", Identify(new TrackBar { AutoSize = false, Height = 27, Value = 3 }, "fixtureSlider", "Fixture slider"));
        AddField(table, "Progress", Identify(new ProgressBar { Value = 35 }, "fixtureProgress", "Fixture progress"));

        var contextButton = ButtonFor("fixtureContext", "Open fixture context menu");
        var menu = new ContextMenuStrip();
        menu.Items.Add("Fixture context action", null, delegate { WriteState("context.txt", "clicked"); });
        contextButton.ContextMenuStrip = menu;
        contextButton.Click += delegate { menu.Show(contextButton, new Point(0, contextButton.Height)); };
        AddField(table, "Context menu", contextButton);
        return table;
    }

    private Control BuildGridAndTree()
    {
        var split = new SplitContainer { Dock = DockStyle.Fill, Size = ClientSize, SplitterDistance = 420 };
        var grid = Identify(new DataGridView {
            Dock = DockStyle.Fill, VirtualMode = true, AllowUserToAddRows = false, AllowUserToDeleteRows = false,
            RowHeadersVisible = true, AutoSizeColumnsMode = DataGridViewAutoSizeColumnsMode.Fill
        }, "fixtureDataGrid", "Fixture data grid");
        grid.Columns.Add("fixtureRow", "Row");
        grid.Columns.Add("fixtureCell", "Value");
        grid.Columns[0].ReadOnly = true;
        var editedCells = new System.Collections.Generic.Dictionary<int, string>();
        grid.CellValueNeeded += delegate(object sender, DataGridViewCellValueEventArgs e)
        {
            string value;
            e.Value = e.ColumnIndex == 0 ? "Row " + (e.RowIndex + 1) :
                editedCells.TryGetValue(e.RowIndex, out value) ? value : "Cell " + (e.RowIndex + 1);
        };
        grid.CellValuePushed += delegate(object sender, DataGridViewCellValueEventArgs e)
        {
            editedCells[e.RowIndex] = Convert.ToString(e.Value, CultureInfo.InvariantCulture);
            WriteState("grid-edit.txt", editedCells[e.RowIndex]);
        };
        grid.RowCount = 2000;
        split.Panel1.Controls.Add(grid);

        var tree = Identify(new TreeView { Dock = DockStyle.Fill, CheckBoxes = true }, "fixtureTree", "Fixture tree");
        for (int i = 1; i <= 50; i++)
        {
            TreeNode branch = tree.Nodes.Add("Branch " + i);
            for (int j = 1; j <= 12; j++)
            {
                branch.Nodes.Add("Leaf " + i + "." + j);
            }
        }
        tree.Nodes[0].Expand();
        split.Panel2.Controls.Add(tree);
        return split;
    }

    private Control BuildVirtualLists()
    {
        var split = new SplitContainer { Dock = DockStyle.Fill, Size = ClientSize, SplitterDistance = 420 };
        var list = Identify(new ListView { Dock = DockStyle.Fill, View = View.Details, VirtualMode = true,
            FullRowSelect = true }, "fixtureListView", "Fixture list view");
        list.Columns.Add("Entry", 150);
        list.Columns.Add("Detail", 200);
        list.RetrieveVirtualItem += delegate(object sender, RetrieveVirtualItemEventArgs e)
        {
            e.Item = new ListViewItem(new[] { "Entry " + (e.ItemIndex + 1), "Detail " + (e.ItemIndex + 1) });
        };
        list.VirtualListSize = 3000;
        split.Panel1.Controls.Add(list);

        var ownerDrawn = Identify(new ListBox { Dock = DockStyle.Fill, DrawMode = DrawMode.OwnerDrawFixed },
            "fixtureOwnerDrawn", "Owner-drawn fixture list");
        for (int i = 1; i <= 150; i++)
        {
            ownerDrawn.Items.Add("Painted item " + i);
        }
        ownerDrawn.DrawItem += delegate(object sender, DrawItemEventArgs e)
        {
            if (e.Index >= 0)
            {
                e.DrawBackground();
                TextRenderer.DrawText(e.Graphics, (string)ownerDrawn.Items[e.Index], e.Font, e.Bounds, e.ForeColor,
                    TextFormatFlags.Left | TextFormatFlags.VerticalCenter);
                e.DrawFocusRectangle();
            }
        };
        split.Panel2.Controls.Add(ownerDrawn);
        return split;
    }

    private static void AddField(TableLayoutPanel table, string label, Control field)
    {
        var caption = new Label { AutoSize = true, Text = label, Anchor = AnchorStyles.Left };
        int row = table.RowCount++;
        table.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        table.Controls.Add(caption, 0, row);
        field.Anchor = AnchorStyles.Left | AnchorStyles.Right;
        table.Controls.Add(field, 1, row);
    }

    private static T Identify<T>(T control, string name, string accessibleName) where T : Control
    {
        control.Name = name;
        control.AccessibleName = accessibleName;
        return control;
    }

    private static Button ButtonFor(string name, string text)
    {
        return Identify(new Button { Text = text, AutoSize = true }, name, text);
    }

    private Button NewIncrementButton()
    {
        var button = ButtonFor("fixtureIncrement", "Increment fixture counter");
        button.Click += delegate { WriteState("count.txt", (++count).ToString(CultureInfo.InvariantCulture)); };
        return button;
    }

    private void ShowFixtureModal()
    {
        if (modal != null) return;

        using (var dialog = new Form { Text = Text + " modal", StartPosition = FormStartPosition.CenterParent,
            ClientSize = new Size(280, 100), FormBorderStyle = FormBorderStyle.FixedDialog, ShowInTaskbar = false })
        {
            var close = ButtonFor("fixtureCloseModal", "Close fixture modal");
            close.DialogResult = DialogResult.OK;
            close.Location = new Point(12, 12);
            dialog.Controls.Add(close);
            dialog.AcceptButton = close;
            dialog.CancelButton = close;
            dialog.Shown += delegate { WriteState("modal.txt", "open"); };
            modal = dialog;
            try { dialog.ShowDialog(this); }
            finally { modal = null; }
        }
        WriteState("modal.txt", "closed");
    }

    private void PollCommands(object sender, EventArgs e)
    {
        if (File.Exists(Path.Combine(stateDirectory, "close-fixture")))
        {
            if (modal != null) modal.Close();
            else Close();
            return;
        }
        if (modal != null && Consume("close-modal")) modal.Close();

        SelectRequestedPage();

        if (Consume("replace-control"))
        {
            actions.Controls.Remove(increment);
            increment.Dispose();
            increment = NewIncrementButton();
            actions.Controls.Add(increment);
            actions.Controls.SetChildIndex(increment, 0);
            PerformLayout();
            WriteState("replaced", "ready");
        }
    }

    private void SelectRequestedPage()
    {
        string command = Path.Combine(stateDirectory, "select-page");
        if (!File.Exists(command)) return;

        string request;
        try { request = File.ReadAllText(command, Encoding.UTF8); }
        catch (IOException) { return; }
        File.Delete(command);

        int index;
        if (!Int32.TryParse(request, NumberStyles.Integer, CultureInfo.InvariantCulture, out index) ||
            index < 0 || index >= tabs.TabPages.Count) return;

        tabs.SelectedIndex = index;
        tabs.Update();
        if (tabs.SelectedIndex == index) WriteState("page.txt", tabs.SelectedIndex.ToString(CultureInfo.InvariantCulture));
    }

    private bool Consume(string fileName)
    {
        string path = Path.Combine(stateDirectory, fileName);
        if (!File.Exists(path)) return false;
        File.Delete(path);
        return true;
    }

    private void WriteState(string fileName, string value)
    {
        string path = Path.Combine(stateDirectory, fileName);
        string pending = path + ".pending";
        File.WriteAllText(pending, value, new UTF8Encoding(false));
        if (File.Exists(path)) File.Replace(pending, path, null);
        else File.Move(pending, path);
    }
}
