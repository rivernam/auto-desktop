param(
    [Parameter(Mandatory)][string]$StateDirectory,
    [Parameter(Mandatory)][string]$WindowTitle,
    [switch]$Borderless,
    [switch]$Extended
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
    [DllImport("user32.dll", EntryPoint = "GetWindowLongW")]
    private static extern int GetWindowLong(IntPtr window, int index);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongW")]
    private static extern int SetWindowLong(IntPtr window, int index, int value);
    // WS_EX_NOACTIVATE for the whole life of the window: neither the first show nor an automation action
    // (SetValue, Invoke) may take the focus from whoever is using the PC.
    public static void NeverActivate(IntPtr window) { SetWindowLong(window, -20, GetWindowLong(window, -20) | 0x08000000); }
    // The fixture inherits the right to take the foreground from the process chain that started it, and
    // ShowDialog activates a window even with ShowActivated = false. A thread-local CBT hook refuses every
    // activation that is not a mouse click on the fixture.
    private delegate IntPtr HookProc(int code, IntPtr wParam, IntPtr lParam);
    private static readonly HookProc refuse = RefuseActivation;
    [DllImport("user32.dll")]
    private static extern IntPtr SetWindowsHookEx(int hook, HookProc procedure, IntPtr module, uint thread);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hook, int code, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();
    public static void RefuseActivationInThisThread() {
        if (SetWindowsHookEx(5, refuse, IntPtr.Zero, GetCurrentThreadId()) == IntPtr.Zero) throw new Win32Exception();
    }
    private static IntPtr RefuseActivation(int code, IntPtr wParam, IntPtr lParam) {
        // WH_CBT HCBT_ACTIVATE; CBTACTIVATESTRUCT.fMouse is its first field.
        if (code == 5 && Marshal.ReadInt32(lParam) == 0) return new IntPtr(1);
        return CallNextHookEx(IntPtr.Zero, code, wParam, lParam);
    }
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW")]
    private static extern IntPtr SetWindowLongPtr(IntPtr window, int index, IntPtr value);
    // GWLP_HWNDPARENT of a top-level window is its owner. WPF would take the thread's active window as the
    // popup's owner, and the fixture window is never active, so the owner is set here instead.
    public static void SetOwner(IntPtr window, IntPtr owner) { SetWindowLongPtr(window, -8, owner); }
    // Showing without activation still draws a window on top of the others. Every z-order change of a fixture
    // window goes to the bottom instead, unless the user is working in the fixture itself.
    [StructLayout(LayoutKind.Sequential)]
    private struct WindowPos { public IntPtr Window, InsertAfter; public int X, Y, Width, Height; public uint Flags; }
    private delegate IntPtr SubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data);
    private static readonly SubclassProc keepBehind = KeepBehindProc;
    [DllImport("comctl32.dll")]
    private static extern bool SetWindowSubclass(IntPtr window, SubclassProc procedure, UIntPtr id, UIntPtr data);
    [DllImport("comctl32.dll")]
    private static extern IntPtr DefSubclassProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam);
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);
    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentProcessId();
    public static void KeepBehind(IntPtr window) {
        if (!SetWindowSubclass(window, keepBehind, new UIntPtr(1), UIntPtr.Zero)) throw new Win32Exception();
    }
    private static IntPtr KeepBehindProc(IntPtr window, uint message, IntPtr wParam, IntPtr lParam, UIntPtr id, UIntPtr data) {
        if (message == 0x0046) { // WM_WINDOWPOSCHANGING
            var position = (WindowPos)Marshal.PtrToStructure(lParam, typeof(WindowPos));
            uint owner;
            GetWindowThreadProcessId(GetForegroundWindow(), out owner);
            // A new window is created at the top and its first show keeps that place (SWP_NOZORDER), so a show
            // (SWP_SHOWWINDOW) moves the window to the bottom too.
            var reorders = (position.Flags & 0x0004) == 0 || (position.Flags & 0x0040) != 0;
            if (reorders && owner != GetCurrentProcessId()) {
                position.InsertAfter = new IntPtr(1); // HWND_BOTTOM
                position.Flags &= ~0x0004u;
                Marshal.StructureToPtr(position, lParam, false);
            }
        }
        return DefSubclassProc(window, message, wParam, lParam);
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct PowerThrottling { public uint Version, ControlMask, StateMask; }
    [DllImport("kernel32.dll")]
    private static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32.dll")]
    private static extern bool SetProcessInformation(IntPtr process, int informationClass, ref PowerThrottling state, int size);
    // Windows 11 throttles a process whose windows are all covered (EcoQoS, coarse timers): keep full speed.
    public static void KeepFullSpeedWhenCovered() {
        var state = new PowerThrottling { Version = 1, ControlMask = 0x1 | 0x4, StateMask = 0 };
        SetProcessInformation(GetCurrentProcess(), 4, ref state, Marshal.SizeOf(typeof(PowerThrottling)));
    }
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

function Initialize-ExtendedFixture {
    Add-Type -AssemblyName WindowsFormsIntegration, System.Windows.Forms, UIAutomationProvider, UIAutomationTypes, System.Xaml
    $references = @(
        [Windows.Window].Assembly.Location
        [Windows.UIElement].Assembly.Location
        [Windows.Point].Assembly.Location
        [Windows.Automation.Provider.IInvokeProvider].Assembly.Location
        [Windows.Automation.AutomationElementIdentifiers].Assembly.Location
        [System.Xaml.XamlReader].Assembly.Location
    ) | Select-Object -Unique
    Add-Type -ReferencedAssemblies $references -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace DesktopFixture {
    public sealed class Row {
        public Row(int index) {
            Label = "Row " + index;
            Value = "Cell " + index;
        }
        public string Label { get; private set; }
        public string Value { get; set; }
    }

    public sealed class Node {
        public Node(string label, Node[] children) {
            Label = label;
            Children = children;
        }
        public string Label { get; private set; }
        public Node[] Children { get; private set; }
    }

    public class SurfaceWithoutPeer : FrameworkElement {
        private readonly string label;

        public SurfaceWithoutPeer(string label) {
            this.label = label;
            Height = 28;
        }

        protected override void OnRender(DrawingContext drawing) {
            drawing.DrawRectangle(Brushes.WhiteSmoke, new Pen(Brushes.Gray, 1), new Rect(RenderSize));
            var text = new FormattedText(label, CultureInfo.CurrentUICulture, FlowDirection.LeftToRight,
                new Typeface("Segoe UI"), 13, Brushes.Black, VisualTreeHelper.GetDpi(this).PixelsPerDip);
            drawing.DrawText(text, new Point(8, 4));
        }
    }

    public sealed class SurfaceWithPeer : SurfaceWithoutPeer {
        public SurfaceWithPeer() : base("Custom fixture surface") { Focusable = true; }

        public event EventHandler Activated;

        protected override AutomationPeer OnCreateAutomationPeer() { return new Peer(this); }

        protected override void OnMouseLeftButtonUp(MouseButtonEventArgs e) {
            base.OnMouseLeftButtonUp(e);
            Focus();
            Activate();
            e.Handled = true;
        }

        protected override void OnKeyDown(KeyEventArgs e) {
            base.OnKeyDown(e);
            if (e.Key == Key.Enter || e.Key == Key.Space) {
                Activate();
                e.Handled = true;
            }
        }

        private void Activate() {
            if (Activated != null) Activated(this, EventArgs.Empty);
        }

        private sealed class Peer : FrameworkElementAutomationPeer, IInvokeProvider {
            internal Peer(SurfaceWithPeer owner) : base(owner) {}

            protected override string GetClassNameCore() { return "SurfaceWithPeer"; }
            protected override AutomationControlType GetAutomationControlTypeCore() { return AutomationControlType.Button; }
            public override object GetPattern(PatternInterface pattern) {
                return pattern == PatternInterface.Invoke ? this : base.GetPattern(pattern);
            }
            void IInvokeProvider.Invoke() {
                if (!IsEnabled()) throw new System.Windows.Automation.ElementNotEnabledException();
                var surface = (SurfaceWithPeer)Owner;
                surface.Dispatcher.BeginInvoke(new Action(surface.Activate));
            }
        }
    }

    public sealed class NativeEditHost : HwndHost {
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateWindowEx(int extendedStyle, string className, string windowName,
            int style, int x, int y, int width, int height, IntPtr parent, IntPtr id,
            IntPtr instance, IntPtr parameter);

        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DestroyWindow(IntPtr window);

        protected override HandleRef BuildWindowCore(HandleRef parent) {
            const int child = 0x40000000;
            const int visible = 0x10000000;
            const int border = 0x00800000;
            const int tabStop = 0x00010000;
            const int autoHorizontalScroll = 0x80;
            IntPtr edit = CreateWindowEx(0, "EDIT", "Fixture native HWND edit",
                child | visible | border | tabStop | autoHorizontalScroll,
                0, 0, 200, 26, parent.Handle, new IntPtr(4420), IntPtr.Zero, IntPtr.Zero);
            if (edit == IntPtr.Zero) throw new Win32Exception();
            return new HandleRef(this, edit);
        }

        protected override void DestroyWindowCore(HandleRef window) { DestroyWindow(window.Handle); }
    }
}
'@

    $window.Width = 800
    $window.Height = 685
    $window.SizeToContent = [Windows.SizeToContent]::Manual
    $window.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen
    [Windows.Automation.AutomationProperties]::SetName($edit, 'Fixture edit')
    [Windows.Automation.AutomationProperties]::SetName($readOnlyEdit, 'Fixture read-only')
    [Windows.Automation.AutomationProperties]::SetName($combo, 'Fixture combo box')
    [Windows.Automation.AutomationProperties]::SetName($list, 'Fixture list')
    $check.Add_Checked({ Write-State 'checked.txt' 'checked' })
    $check.Add_Unchecked({ Write-State 'checked.txt' 'unchecked' })
    $combo.Add_SelectionChanged({ param($sender, $eventArgs) Write-State 'selected.txt' ([string]$sender.SelectedItem) })
    $list.Add_SelectionChanged({ param($sender, $eventArgs) Write-State 'selected.txt' ([string]$sender.SelectedItem) })
    Write-State 'selected.txt' 'Choice one'
    Write-State 'modal.txt' 'closed'
    Write-State 'popup.txt' 'closed'
    Write-State 'runtime.txt' ('.NET Framework CLR ' + [Environment]::Version + ' / ' + ([IntPtr]::Size * 8) + '-bit')

    [xml]$markup = @'
<StackPanel xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
            xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Margin="4">
  <StackPanel Orientation="Horizontal">
    <Button Name="Toggle" AutomationProperties.AutomationId="fixtureToggle" Content="Toggle fixture state" Margin="0,0,4,0" />
    <Button Name="Modal" AutomationProperties.AutomationId="fixtureModal" Content="Open fixture modal" Margin="0,0,4,0" />
    <Button Name="PopupButton" AutomationProperties.AutomationId="fixturePopup" Content="Open fixture popup" Margin="0,0,4,0" />
    <Popup Name="FixturePopup" Placement="Bottom" StaysOpen="True" PlacementTarget="{Binding ElementName=PopupButton}">
      <Border Background="White" BorderBrush="Gray" BorderThickness="1" Padding="8">
        <Button Name="PopupAction" AutomationProperties.AutomationId="fixturePopupAction" Content="Fixture popup action" />
      </Border>
    </Popup>
    <PasswordBox Width="130" Password="fixture password" AutomationProperties.AutomationId="fixturePassword"
                 AutomationProperties.Name="Fixture password" />
  </StackPanel>
  <TabControl Name="FixtureTabs" AutomationProperties.AutomationId="fixtureTab" AutomationProperties.Name="Fixture tabs" Height="430" Margin="0,4,0,0">
    <TabItem Header="Grid and tree">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="3*"/><ColumnDefinition Width="2*"/></Grid.ColumnDefinitions>
        <DataGrid Name="Grid" AutomationProperties.AutomationId="fixtureDataGrid" AutomationProperties.Name="Fixture data grid"
                  AutoGenerateColumns="False" CanUserAddRows="False" EnableRowVirtualization="True" EnableColumnVirtualization="True"
                  VirtualizingPanel.VirtualizationMode="Recycling">
          <DataGrid.Columns>
            <DataGridTextColumn Header="Row" Binding="{Binding Label}" IsReadOnly="True" Width="*" />
            <DataGridTextColumn Header="Value" Binding="{Binding Value}" Width="*" />
          </DataGrid.Columns>
        </DataGrid>
        <TreeView Name="Tree" Grid.Column="1" AutomationProperties.AutomationId="fixtureTree" AutomationProperties.Name="Fixture tree"
                  VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling">
          <TreeView.ItemTemplate>
            <HierarchicalDataTemplate ItemsSource="{Binding Children}">
              <TextBlock Text="{Binding Label}" />
            </HierarchicalDataTemplate>
          </TreeView.ItemTemplate>
        </TreeView>
      </Grid>
    </TabItem>
    <TabItem Header="Lists and templates">
      <Grid>
        <Grid.ColumnDefinitions><ColumnDefinition Width="3*"/><ColumnDefinition Width="2*"/></Grid.ColumnDefinitions>
        <ListView Name="TemplatedList" AutomationProperties.AutomationId="fixtureListView" AutomationProperties.Name="Fixture list view"
                  VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling" ScrollViewer.CanContentScroll="True">
          <ListView.ItemContainerStyle>
            <Style TargetType="ListViewItem"><Setter Property="AutomationProperties.Name" Value="{Binding Label}" /></Style>
          </ListView.ItemContainerStyle>
          <ListView.View>
            <GridView>
              <GridViewColumn Header="Row" DisplayMemberBinding="{Binding Label}" Width="110" />
              <GridViewColumn Header="Details" Width="180">
                <GridViewColumn.CellTemplate>
                  <DataTemplate><Button Content="{Binding Value}" /></DataTemplate>
                </GridViewColumn.CellTemplate>
              </GridViewColumn>
            </GridView>
          </ListView.View>
        </ListView>
        <ListBox Name="VirtualList" Grid.Column="1" AutomationProperties.AutomationId="fixtureVirtualList" AutomationProperties.Name="Fixture virtual list"
                 VirtualizingPanel.IsVirtualizing="True" VirtualizingPanel.VirtualizationMode="Recycling" ScrollViewer.CanContentScroll="True" />
      </Grid>
    </TabItem>
    <TabItem Header="Custom and hosted">
      <StackPanel Name="HostedControls" Margin="8" />
    </TabItem>
  </TabControl>
</StackPanel>
'@
    $reader = New-Object Xml.XmlNodeReader $markup
    try { $extendedPanel = [Windows.Markup.XamlReader]::Load($reader) } finally { $reader.Close() }
    [void]$panel.Children.Add($extendedPanel)
    $script:fixtureTabs = $extendedPanel.FindName('FixtureTabs')
    $script:fixtureTabs.SelectedIndex = 0

    $grid = $extendedPanel.FindName('Grid')
    $rows = [DesktopFixture.Row[]]::new(2000)
    for ($i = 0; $i -lt $rows.Length; $i++) { $rows[$i] = [DesktopFixture.Row]::new($i + 1) }
    $grid.ItemsSource = $rows
    $grid.Add_CellEditEnding({
        param($sender, $eventArgs)
        if ($eventArgs.EditAction -eq [Windows.Controls.DataGridEditAction]::Commit) {
            Write-State 'grid-edit.txt' $eventArgs.EditingElement.Text
        }
    })
    $extendedPanel.FindName('TemplatedList').ItemsSource = $rows
    $extendedPanel.FindName('VirtualList').ItemsSource = [string[]](1..3000 | ForEach-Object { "Virtual item $_" })

    $branches = [DesktopFixture.Node[]]::new(60)
    for ($i = 0; $i -lt $branches.Length; $i++) {
        $branchNumber = $i + 1
        $leaves = [DesktopFixture.Node[]](1..12 | ForEach-Object { [DesktopFixture.Node]::new("Leaf $branchNumber.$_", $null) })
        $branches[$i] = [DesktopFixture.Node]::new("Branch $branchNumber", $leaves)
    }
    $extendedPanel.FindName('Tree').ItemsSource = $branches

    $hosted = $extendedPanel.FindName('HostedControls')
    $surface = [DesktopFixture.SurfaceWithPeer]::new()
    [Windows.Automation.AutomationProperties]::SetAutomationId($surface, 'fixturePeer')
    [Windows.Automation.AutomationProperties]::SetName($surface, 'Custom fixture surface')
    $surface.Add_Activated({ Write-State 'custom.txt' 'activated' })
    [void]$hosted.Children.Add($surface)
    $opaqueSurface = [DesktopFixture.SurfaceWithoutPeer]::new('Fixture surface without an automation peer')
    [Windows.Automation.AutomationProperties]::SetAutomationId($opaqueSurface, 'fixtureWithoutPeer')
    [void]$hosted.Children.Add($opaqueSurface)

    $formsHost = New-Object Windows.Forms.Integration.WindowsFormsHost
    $formsHost.Height = 26
    [Windows.Automation.AutomationProperties]::SetAutomationId($formsHost, 'fixtureFormsHost')
    $formsEdit = New-Object Windows.Forms.TextBox
    $formsEdit.Name = 'fixtureHostEdit'
    $formsEdit.AccessibleName = 'Fixture hosted WinForms edit'
    $formsEdit.Text = 'Hosted WinForms value'
    $formsHost.Child = $formsEdit
    [void]$hosted.Children.Add($formsHost)
    $hwndHost = [DesktopFixture.NativeEditHost]::new()
    $hwndHost.Height = 26
    [Windows.Automation.AutomationProperties]::SetAutomationId($hwndHost, 'fixtureHwndHost')
    [void]$hosted.Children.Add($hwndHost)

    $extendedPanel.FindName('Toggle').Add_Click({
        $disabled.IsEnabled = !$disabled.IsEnabled
        $readOnlyEdit.IsReadOnly = !$readOnlyEdit.IsReadOnly
        if ($disabled.IsEnabled) { Write-State 'dynamic-state.txt' 'enabled-writable' }
        else { Write-State 'dynamic-state.txt' 'disabled-read-only' }
    })
    $extendedPanel.FindName('Modal').Add_Click({ Show-FixtureModal })
    $popup = $extendedPanel.FindName('FixturePopup')
    $script:fixturePopup = $popup
    $popupButton = $extendedPanel.FindName('PopupButton')
    $popupButton.Tag = $popup
    # WPF gives a popup the thread's active window as its owner. The fixture window is never active, so the
    # popup gets its owner explicitly once its HWND exists.
    $popupButton.Add_Click({ param($sender, $eventArgs) $sender.Tag.IsOpen = $true })
    $popup.Add_Opened({ param($sender, $eventArgs)
        $source = [Windows.PresentationSource]::FromVisual($sender.Child)
        [FixtureCursor]::SetOwner($source.Handle, (New-Object Windows.Interop.WindowInteropHelper $window).Handle)
        Write-State 'popup.txt' 'open'
    })
    $popup.Add_Closed({ Write-State 'popup.txt' 'closed' })
    $popupAction = $extendedPanel.FindName('PopupAction')
    $popupAction.Tag = $popup
    $popupAction.Add_Click({
        param($sender, $eventArgs)
        Write-State 'popup-click.txt' 'clicked'
        $sender.Tag.IsOpen = $false
    })
    $window.Add_Closed({ $formsHost.Dispose(); $hwndHost.Dispose() }.GetNewClosure())
}

function Update-ExtendedFixtureCommands {
    $closePopup = Join-Path $StateDirectory 'close-popup'
    if ([IO.File]::Exists($closePopup)) {
        [IO.File]::Delete($closePopup)
        $script:fixturePopup.IsOpen = $false
    }

    $selectPage = Join-Path $StateDirectory 'select-page'
    if (![IO.File]::Exists($selectPage)) { return }
    try { $request = [IO.File]::ReadAllText($selectPage, [Text.Encoding]::UTF8) }
    catch [IO.IOException] { return }
    [IO.File]::Delete($selectPage)

    $index = 0
    $valid = [int]::TryParse($request, [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$index)
    if (!$valid -or $index -lt 0 -or $index -ge $script:fixtureTabs.Items.Count) { return }

    $script:fixtureTabs.SelectedIndex = $index
    $window.UpdateLayout()
    if ($script:fixtureTabs.SelectedIndex -eq $index) { Write-State 'page.txt' ([string]$script:fixtureTabs.SelectedIndex) }
}

function Show-FixtureModal {
    $script:modalWindow = New-Object Windows.Window
    $script:modalWindow.Title = "$WindowTitle modal"
    $script:modalWindow.Width = 280
    $script:modalWindow.Height = 100
    $script:modalWindow.Owner = $window
    $script:modalWindow.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterOwner
    $script:modalWindow.ShowInTaskbar = $false
    $script:modalWindow.ShowActivated = $false
    $script:modalWindow.Add_SourceInitialized({ param($sender, $eventArgs)
        [FixtureCursor]::KeepBehind((New-Object Windows.Interop.WindowInteropHelper $sender).Handle)
    })
    $close = New-Object Windows.Controls.Button
    $close.Content = 'Close fixture modal'
    $close.IsCancel = $true
    [Windows.Automation.AutomationProperties]::SetAutomationId($close, 'fixtureCloseModal')
    $close.Add_Click({ $script:modalWindow.Close() })
    $script:modalWindow.Content = $close
    $script:modalWindow.Add_ContentRendered({ Write-State 'modal.txt' 'open' })
    try { [void]$script:modalWindow.ShowDialog() }
    finally { $script:modalWindow = $null; Write-State 'modal.txt' 'closed' }
}

[FixtureCursor]::RefuseActivationInThisThread()
[FixtureCursor]::KeepFullSpeedWhenCovered()
$window = New-Object Windows.Window
$window.Title = $WindowTitle
# A test run must not take the focus from whoever is using the PC.
$window.ShowActivated = $false
$window.Add_SourceInitialized({
    $handle = (New-Object Windows.Interop.WindowInteropHelper $window).Handle
    [FixtureCursor]::NeverActivate($handle)
    [FixtureCursor]::KeepBehind($handle)
})
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

if ($Extended) { Initialize-ExtendedFixture }

# A unique filename per sample prevents a delayed response from satisfying the next read.
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(25)
$timer.Add_Tick({
    if ([IO.File]::Exists((Join-Path $StateDirectory 'close-fixture'))) {
        if ($script:modalWindow) { $script:modalWindow.Close(); return }
        $timer.Stop()
        $window.Close()
        return
    }

    $closeModal = Join-Path $StateDirectory 'close-modal'
    if ($script:modalWindow -and [IO.File]::Exists($closeModal)) {
        [IO.File]::Delete($closeModal)
        $script:modalWindow.Close()
    }
    if ($Extended) { Update-ExtendedFixtureCommands }

    $replace = Join-Path $StateDirectory 'replace-control'
    if ([IO.File]::Exists($replace)) {
        [IO.File]::Delete($replace)
        $previousIndex = $panel.Children.IndexOf($script:incrementButton)
        [Windows.Automation.AutomationProperties]::SetAutomationId($script:incrementButton, 'retired')
        $panel.Children.Remove($script:incrementButton)
        $script:incrementButton = New-IncrementButton
        if ($Extended) { $panel.Children.Insert($previousIndex, $script:incrementButton) }
        else { [void]$panel.Children.Add($script:incrementButton) }
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
    if ($Extended) { Write-State 'page.txt' ([string]$script:fixtureTabs.SelectedIndex) }
    Write-State 'ready' ([string]$PID)
    $timer.Start()
})
[void]$window.ShowDialog()
$timer.Stop()
