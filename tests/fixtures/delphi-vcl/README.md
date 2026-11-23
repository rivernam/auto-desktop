# Delphi VCL fixture

Use an Embarcadero Delphi installation with the Win32 compiler, VCL and DataSnap/MIDAS libraries. Run these commands from the repository root in PowerShell with Delphi's `bin` directory on `PATH`. The project's `MidasLib` unit links the local in-memory dataset engine into the executable.

```powershell
$fixtureOutput = (New-Item -ItemType Directory -Force 'target/framework-fixtures').FullName
& dcc32 -B "-E$fixtureOutput" "-N0$fixtureOutput" tests/fixtures/delphi-vcl/DelphiVclFixture.dpr
if ($LASTEXITCODE -ne 0) { throw 'Delphi VCL fixture compilation failed' }
Move-Item -Force -LiteralPath (Join-Path $fixtureOutput 'DelphiVclFixture.exe') `
    -Destination (Join-Path $fixtureOutput 'delphi-vcl.exe')
```

Open `DelphiVclFixture.dpr` directly in the Delphi IDE and build the Windows 32-bit target if your license permits IDE builds only.

```powershell
& target/framework-fixtures/delphi-vcl.exe 'target/delphi-state' 'Delphi VCL fixture session'
```

The **Controls** page contains editable, read-only, and masked `TEdit` controls, a `TComboBox`, a `TCheckBox`, an owner-drawn `TListBox`, and a painted `TCustomControl`. The **Data** page contains a `TStringGrid`, a `TDBGrid` bound to sample inventory data, a `TTreeView`, and a report-style `TListView`. A `TPanel` holds the increment button, a disabled button, and two distinct buttons with the same caption. **Open fixture modal** opens an application-modal window titled `<unique-window-title> modal`.

The fixture assigns native control IDs `4101`, `4102`, and `4103` to the editable, read-only, and masked `TEdit` controls. `edit-id.txt`, `read-only-id.txt`, and `password-id.txt` record the IDs returned by `GetDlgCtrlID` before `ready`. Use these to check the corresponding UI Automation `AutomationId` when the Windows provider exposes one, or to identify the HWND in a native diagnostic. `Fixture…` component names are Delphi metadata. The Windows provider determines the exposed role, class, and properties. [Microsoft documentation on AutomationId and Win32 control IDs](https://learn.microsoft.com/en-us/dotnet/framework/ui-automation/use-the-automationid-property)

The fixture writes atomic UTF-8 state files for its PID (`ready`), compiler (`framework.txt`), click count (`count.txt`), edit changes (`value.txt`), read-only changes (`read-only.txt`), disabled action (`disabled-click.txt`), last selection (`selected.txt`), and dialog status (`modal.txt`). The password field uses a synthetic value that stays out of state files. Create the empty command file `replace-control` to replace the increment control, `close-modal` to close the modal dialog, or `close-fixture` to close the fixture. Replacement completes when `replaced` contains `ready`.
