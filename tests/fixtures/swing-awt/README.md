# Swing and AWT fixtures

From the repository root in PowerShell, build both modes with JDK 11 or later.

```powershell
$classes = 'target/framework-fixtures/swing-awt'
New-Item -ItemType Directory -Force $classes | Out-Null
javac -Xlint:all -d $classes tests/fixtures/swing-awt/FrameworkFixture.java
```

Launch each mode in its own process with a fresh state directory and a unique window title.

```powershell
java -cp $classes FrameworkFixture swing 'target/swing-state' 'Swing fixture session'
java -cp $classes FrameworkFixture awt 'target/awt-state' 'AWT fixture session'
```

Both modes provide editable, read-only and masked text fields, a check box, a choice control, a list, a disabled button, and two buttons named **Duplicate label**. AWT uses heavyweight controls. Swing adds a **Data** tab with a `JTable`, a `JTree`, and two painted components. **Accessible custom swatch** implements `AccessibleAction` with the Java accessibility role `push button`. **Visual-only custom swatch** is painted by an AWT `Component` that does not implement `Accessible`. The AWT fixture also contains this visual-only component. Java component names such as `fixtureEdit` are application metadata. Use observed provider fields for Windows selectors.

The fixture writes atomic UTF-8 state files for its PID (`ready`), toolkit and runtime (`framework.txt`), increment-button clicks (`count.txt`), editable text (`value.txt`), read-only text (`read-only.txt`), disabled-button handler (`disabled-click.txt`), and the last wired selection or custom-control action (`selected.txt`). AWT also checks its two non-password fields on the fixture timer so edits that bypass AWT text events still reach the state files. The password uses a synthetic value that stays out of state files. **Open fixture modal** opens a dialog titled `<unique-window-title> modal` and updates `modal.txt` to `open`. It becomes `closed` on dismissal.

Create the empty command file `replace-control` to replace the increment button, `close-modal` to dismiss the dialog, or `close-fixture` to exit. Replacement completes when `replaced` contains `ready`.

## Java Access Bridge probe

With a Windows x64 OpenJDK distribution that includes `windowsaccessbridge-64.dll`, enable Java Access Bridge for the fixture JVM with its provider property. The following commands use separate PowerShell processes because the fixture runs until closed. Substitute `awt` to inspect the AWT fixture.

```powershell
java '-Djavax.accessibility.assistive_technologies=com.sun.java.accessibility.AccessBridge' `
    -cp 'target/framework-fixtures/swing-awt' FrameworkFixture swing `
    'target/swing-bridge-state' 'Swing bridge fixture session'
```

```powershell
& tests/fixtures/swing-awt/Probe-JavaAccessBridge.ps1 `
    -StateDirectory 'target/swing-bridge-state' -WindowTitle 'Swing bridge fixture session'
```

The probe uses the fixture's `ready` PID and exact main window title to read Java Access Bridge metadata for that HWND. Its JSON includes accessible names, roles, states and interface flags. Names are blank for password, editable, and text-capable nodes. The `truncated` flag reports whether the traversal reached its node or depth limit with more children to visit. It makes no action or text-content calls and requires no changes to the Windows accessibility settings. Microsoft UI Automation and Java Access Bridge expose separate trees. [OpenJDK Java Access Bridge API declarations](https://github.com/openjdk/jdk21u/tree/master/src/jdk.accessibility/windows/native/include/bridge)

After building the fixture, run the optional counter proof in its own PowerShell process. It launches a fresh bridge-enabled Swing fixture with a unique title and temporary state directory and closes it afterward.

```powershell
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File tests/fixtures/swing-awt/Invoke-SwingFixtureCounter.ps1
```

The proof checks its own Swing process, HWND, exact title and launch arguments. It finds the unique enabled **Increment fixture counter** button, calls its advertised Java Access Bridge `click` action once, and requires `count.txt` to increase by one. Use `-FixtureJava` or `-Classes` to override the Java launcher or class directory.
