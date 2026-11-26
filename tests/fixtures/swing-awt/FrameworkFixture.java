import java.awt.BorderLayout;
import java.awt.Button;
import java.awt.Checkbox;
import java.awt.Choice;
import java.awt.Color;
import java.awt.Component;
import java.awt.Container;
import java.awt.Dialog;
import java.awt.Dimension;
import java.awt.EventQueue;
import java.awt.FlowLayout;
import java.awt.Frame;
import java.awt.Graphics;
import java.awt.GridLayout;
import java.awt.Label;
import java.awt.Panel;
import java.awt.Point;
import java.awt.TextArea;
import java.awt.TextField;
import java.awt.Window;
import java.awt.event.ActionListener;
import java.awt.event.MouseAdapter;
import java.awt.event.MouseEvent;
import java.awt.event.WindowAdapter;
import java.awt.event.WindowEvent;
import java.io.IOException;
import java.io.UncheckedIOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import javax.accessibility.Accessible;
import javax.accessibility.AccessibleAction;
import javax.accessibility.AccessibleContext;
import javax.accessibility.AccessibleRole;
import javax.swing.BorderFactory;
import javax.swing.ButtonGroup;
import javax.swing.JButton;
import javax.swing.JCheckBox;
import javax.swing.JComboBox;
import javax.swing.JComponent;
import javax.swing.JDialog;
import javax.swing.JFrame;
import javax.swing.JLabel;
import javax.swing.JList;
import javax.swing.JMenu;
import javax.swing.JMenuBar;
import javax.swing.JMenuItem;
import javax.swing.JOptionPane;
import javax.swing.JPanel;
import javax.swing.JPasswordField;
import javax.swing.JRadioButton;
import javax.swing.JScrollPane;
import javax.swing.JTabbedPane;
import javax.swing.JTable;
import javax.swing.JTextArea;
import javax.swing.JTextField;
import javax.swing.JTree;
import javax.swing.Timer;
import javax.swing.event.DocumentEvent;
import javax.swing.event.DocumentListener;
import javax.swing.tree.DefaultMutableTreeNode;

public final class FrameworkFixture {
    private static final String INITIAL_VALUE = "initial fixture value";
    private static final String FIXED_VALUE = "fixed fixture value";
    private static final String PASSWORD = "synthetic";
    private static final String INCREMENT_LABEL = "Increment fixture counter";
    private static final String OPEN_MODAL_LABEL = "Open fixture modal";
    private static final String CLOSE_MODAL_LABEL = "Close fixture modal";
    private static final String[] CHOICES = {"Choice one", "Choice two"};
    private static final String[] ITEMS = {"Item one", "Item two"};

    private final Path stateDirectory;
    private final String title;
    private final boolean swing;
    private final boolean interactive;
    private Window window;
    private Dialog modal;
    private Container counterRow;
    private Component incrementButton;
    private Timer commands;
    private TextField awtEdit;
    private TextField awtReadOnly;
    private TextField awtPassword;
    private JTextField swingEdit;
    private JTabbedPane swingTabs;
    private int publishedAwtPasswordLength = PASSWORD.length();
    private String publishedAwtValue = INITIAL_VALUE;
    private String publishedAwtReadOnly = FIXED_VALUE;
    private int count;
    private long eventSequence;
    private static final boolean TRACE = Boolean.getBoolean("desktop.fixture.events");

    private FrameworkFixture(String mode, boolean interactive, Path stateDirectory, String title) {
        this.swing = mode.equals("swing");
        this.interactive = interactive;
        this.stateDirectory = stateDirectory;
        this.title = title;
    }

    public static void main(String[] args) throws Exception {
        // Unset or "background": never focusable and kept behind the user's windows (accessibility tests).
        // "interactive" (physical-input tests only): focusable and shown in front like a normal application.
        String fixtureMode = System.getenv().getOrDefault("DESKTOP_FIXTURE_MODE", "");
        if (!fixtureMode.isEmpty() && !fixtureMode.equals("background") && !fixtureMode.equals("interactive")) {
            System.err.println("DESKTOP_FIXTURE_MODE must be background or interactive.");
            System.exit(2);
        }
        if (args.length != 3 || !(args[0].equals("swing") || args[0].equals("awt"))) {
            throw new IllegalArgumentException("Usage: FrameworkFixture swing|awt <state-directory> <window-title>");
        }
        Path stateDirectory = Path.of(args[1]);
        Files.createDirectories(stateDirectory);
        var fixture = new FrameworkFixture(args[0], fixtureMode.equals("interactive"), stateDirectory, args[2]);
        EventQueue.invokeAndWait(fixture::show);
    }

    private void show() {
        write("fixture-mode.txt", interactive ? "interactive" : "background");
        write("framework.txt", (swing ? "Swing" : "AWT") + " / "
                + System.getProperty("java.vendor") + " Java " + Runtime.version());
        write("count.txt", "0");
        write("value.txt", INITIAL_VALUE);
        write("read-only.txt", FIXED_VALUE);
        write("disabled-click.txt", "0");
        // The length only. The masked text itself never reaches a state file.
        write("password-length.txt", Integer.toString(PASSWORD.length()));

        window = swing ? swingWindow() : awtWindow();
        window.addWindowListener(onClose(this::close));
        window.pack();
        // Background: never focusable, so neither showing the window nor an automation action may take the focus
        // of whoever is using the PC. The fixture is driven through accessibility APIs, which do not need it.
        window.setAutoRequestFocus(interactive);
        window.setFocusableWindowState(interactive);
        window.setLocationByPlatform(true);
        window.setVisible(true);
        if (!interactive) window.toBack();
        commands = new Timer(50, event -> pollCommands());
        commands.start();
        write("ready", Long.toString(ProcessHandle.current().pid()));
    }

    private JFrame swingWindow() {
        var frame = named(new JFrame(title), "fixtureWindow", title);
        var content = new JPanel(new BorderLayout(6, 6));
        content.setBorder(BorderFactory.createEmptyBorder(8, 8, 8, 8));
        content.add(counterRow(), BorderLayout.NORTH);

        var tabs = named(new JTabbedPane(), "fixtureTabs", "Fixture tabs");
        tabs.addTab("Controls", swingControls());
        tabs.addTab("Data", swingData());
        swingTabs = tabs;
        content.add(tabs, BorderLayout.CENTER);
        frame.setContentPane(content);

        var menu = named(new JMenu("Fixture menu"), "fixtureMenu", "Fixture menu");
        var item = named(new JMenuItem("Fixture menu item"), "fixtureMenuItem", "Fixture menu item");
        item.addActionListener(event -> write("selected.txt", "Fixture menu item"));
        menu.add(item);
        var menuBar = new JMenuBar();
        menuBar.add(menu);
        frame.setJMenuBar(menuBar);
        return frame;
    }

    private JPanel swingControls() {
        var fields = new JPanel(new GridLayout(0, 2, 5, 5));
        var edit = named(new JTextField(INITIAL_VALUE, 22), "fixtureEdit", "Fixture edit");
        swingEdit = edit;
        if (TRACE) edit.getAccessibleContext().setAccessibleDescription("fixture-description-sentinel");
        onTextChange(edit, "value.txt");
        addField(fields, "Editable text", edit);
        var readOnly = named(new JTextField(FIXED_VALUE, 22), "fixtureReadOnly", "Fixture read-only edit");
        readOnly.setEditable(false);
        onTextChange(readOnly, "read-only.txt");
        addField(fields, "Read-only text", readOnly);
        var password = named(new JPasswordField(PASSWORD, 22), "fixturePassword", "Fixture password");
        password.getDocument().addDocumentListener(new DocumentListener() {
            @Override public void insertUpdate(DocumentEvent event) { update(); }
            @Override public void removeUpdate(DocumentEvent event) { update(); }
            @Override public void changedUpdate(DocumentEvent event) { update(); }

            private void update() {
                write("password-length.txt", Integer.toString(password.getPassword().length));
            }
        });
        addField(fields, "Password", password);

        var combo = named(new JComboBox<>(CHOICES), "fixtureCombo", "Fixture combo box");
        combo.addActionListener(event -> write("selected.txt", String.valueOf(combo.getSelectedItem())));
        addField(fields, "Choices", combo);
        var list = named(new JList<>(ITEMS), "fixtureList", "Fixture list");
        list.setVisibleRowCount(2);
        list.setSelectedIndex(0);
        list.addListSelectionListener(event -> {
            if (!event.getValueIsAdjusting() && list.getSelectedValue() != null) {
                write("selected.txt", list.getSelectedValue());
            }
        });
        addField(fields, "Items", new JScrollPane(list));

        var check = named(new JCheckBox("Fixture check box"), "fixtureCheck", "Fixture check box");
        check.addItemListener(event -> write("selected.txt", Boolean.toString(check.isSelected())));
        fields.add(check);
        fields.add(button("fixtureModal", OPEN_MODAL_LABEL, event -> showModal()));

        var area = named(new JTextArea("fixture notes", 2, 22), "fixtureTextArea", "Fixture text area");
        addField(fields, "Notes", new JScrollPane(area));
        var radios = new JPanel(new FlowLayout(FlowLayout.LEFT));
        var group = new ButtonGroup();
        for (String label : new String[] {"Fixture radio one", "Fixture radio two"}) {
            var radio = named(new JRadioButton(label), "fixtureRadio", label);
            radio.addActionListener(event -> write("selected.txt", label));
            group.add(radio);
            radios.add(radio);
        }
        addField(fields, "Mode", radios);

        var panel = new JPanel(new BorderLayout(6, 6));
        panel.setBorder(BorderFactory.createEmptyBorder(8, 8, 8, 8));
        panel.add(fields, BorderLayout.NORTH);
        return panel;
    }

    private JPanel swingData() {
        var table = named(new JTable(new Object[][] {{"Alpha", 10}, {"Beta", 20}},
                new Object[] {"Name", "Quantity"}), "fixtureTable", "Fixture table");
        table.setPreferredScrollableViewportSize(new Dimension(290, 95));
        table.getSelectionModel().addListSelectionListener(event -> {
            if (!event.getValueIsAdjusting() && table.getSelectedRow() >= 0) {
                write("selected.txt", String.valueOf(table.getValueAt(table.getSelectedRow(), 0)));
            }
        });
        var root = new DefaultMutableTreeNode("Inventory");
        var group = new DefaultMutableTreeNode("Warehouse");
        root.add(group);
        group.add(new DefaultMutableTreeNode("Crate"));
        var tree = named(new JTree(root), "fixtureTree", "Fixture tree");
        tree.addTreeSelectionListener(event -> {
            if (tree.getLastSelectedPathComponent() != null) {
                write("selected.txt", tree.getLastSelectedPathComponent().toString());
            }
        });

        var custom = new JPanel(new FlowLayout(FlowLayout.LEFT));
        custom.add(named(new AccessibleSwatch(), "fixtureAccessibleCustom", "Accessible custom swatch"));
        custom.add(visualOnlySwatch());
        var panel = new JPanel(new BorderLayout(6, 6));
        panel.add(new JScrollPane(table), BorderLayout.WEST);
        panel.add(new JScrollPane(tree), BorderLayout.CENTER);
        panel.add(custom, BorderLayout.SOUTH);
        return panel;
    }

    private Frame awtWindow() {
        var frame = named(new Frame(title), "fixtureWindow", title);
        frame.setLayout(new BorderLayout(6, 6));
        frame.add(counterRow(), BorderLayout.NORTH);
        var fields = new Panel(new GridLayout(0, 2, 5, 5));
        awtEdit = named(new TextField(INITIAL_VALUE, 22), "fixtureEdit", "Fixture edit");
        awtReadOnly = named(new TextField(FIXED_VALUE, 22), "fixtureReadOnly", "Fixture read-only edit");
        awtReadOnly.setEditable(false);
        awtEdit.addTextListener(event -> syncAwtTextFiles());
        awtReadOnly.addTextListener(event -> syncAwtTextFiles());
        addField(fields, "Editable text", awtEdit);
        addField(fields, "Read-only text", awtReadOnly);
        awtPassword = named(new TextField(PASSWORD, 22), "fixturePassword", "Fixture password");
        awtPassword.setEchoChar('*');
        addField(fields, "Password", awtPassword);

        var choice = named(new Choice(), "fixtureCombo", "Fixture combo box");
        for (String value : CHOICES) {
            choice.add(value);
        }
        choice.addItemListener(event -> write("selected.txt", choice.getSelectedItem()));
        addField(fields, "Choices", choice);
        var list = named(new java.awt.List(2), "fixtureList", "Fixture list");
        for (String item : ITEMS) {
            list.add(item);
        }
        list.select(0);
        list.addItemListener(event -> {
            if (list.getSelectedItem() != null) {
                write("selected.txt", list.getSelectedItem());
            }
        });
        addField(fields, "Items", list);

        var check = named(new Checkbox("Fixture check box"), "fixtureCheck", "Fixture check box");
        check.addItemListener(event -> write("selected.txt", Boolean.toString(check.getState())));
        fields.add(check);
        fields.add(button("fixtureModal", OPEN_MODAL_LABEL, event -> showModal()));
        frame.add(fields, BorderLayout.CENTER);
        var custom = new Panel(new FlowLayout(FlowLayout.LEFT));
        custom.add(visualOnlySwatch());
        frame.add(custom, BorderLayout.SOUTH);
        return frame;
    }

    private Container counterRow() {
        var layout = new FlowLayout(FlowLayout.LEFT, 5, 5);
        counterRow = swing ? new JPanel(layout) : new Panel(layout);
        incrementButton = newIncrementButton();
        counterRow.add(incrementButton);
        var disabled = button("fixtureDisabled", "Disabled action", event -> write("disabled-click.txt", "1"));
        disabled.setEnabled(false);
        counterRow.add(disabled);
        counterRow.add(button("fixtureDuplicateOne", "Duplicate label", event -> write("selected.txt", "Duplicate one")));
        counterRow.add(button("fixtureDuplicateTwo", "Duplicate label", event -> write("selected.txt", "Duplicate two")));
        return counterRow;
    }

    private Component newIncrementButton() {
        return button("fixtureIncrement", INCREMENT_LABEL, event -> {
            trace("counterIncrement", ++count);
            write("count.txt", Integer.toString(count));
        });
    }

    private Component button(String id, String label, ActionListener handler) {
        if (swing) {
            var button = named(new JButton(label), id, label);
            button.addActionListener(handler);
            return button;
        }
        var button = named(new Button(label), id, label);
        button.addActionListener(handler);
        return button;
    }

    private void addField(Container fields, String label, Component field) {
        if (swing) {
            var caption = new JLabel(label);
            caption.setLabelFor(field);
            fields.add(caption);
        } else {
            fields.add(new Label(label));
        }
        fields.add(field);
    }

    private void onTextChange(JTextField field, String stateFile) {
        field.getDocument().addDocumentListener(new DocumentListener() {
            @Override public void insertUpdate(DocumentEvent event) { update(); }
            @Override public void removeUpdate(DocumentEvent event) { update(); }
            @Override public void changedUpdate(DocumentEvent event) { update(); }

            private void update() {
                write(stateFile, field.getText());
            }
        });
    }

    private Point windowPlace;
    private Point dialogPlace;

    private void showModal() {
        if (modal != null) {
            return;
        }
        String modalTitle = title + " modal";
        var dialog = swing ? new JDialog((Frame) window, modalTitle, true)
                : new Dialog((Frame) window, modalTitle, true);
        modal = named(dialog, "fixtureModalWindow", modalTitle);
        trace("modalCreated", 0);
        dialog.setLayout(new FlowLayout());
        dialog.add(swing ? new JLabel("Fixture modal dialog") : new Label("Fixture modal dialog"));
        dialog.add(button("fixtureCloseModal", CLOSE_MODAL_LABEL, event -> closeModal()));
        if (!swing) {
            // In the dialog, because a second native text control in the frame would share the control
            // identifier that the UI Automation checks use for the editable field.
            dialog.add(named(new TextArea("fixture notes", 2, 22, TextArea.SCROLLBARS_NONE), "fixtureTextArea",
                    "Fixture text area"));
        }
        dialog.addWindowListener(new WindowAdapter() {
            @Override public void windowOpened(WindowEvent event) {
                if (!interactive) {
                    window.toBack();
                    window.setLocation(windowPlace);
                    dialog.setLocation(dialogPlace);
                }
                trace("modalOpened", 0);
                write("modal.txt", "open");
            }
            @Override public void windowClosing(WindowEvent event) { closeModal(); }
        });
        dialog.pack();
        dialog.setLocationRelativeTo(window);
        if (interactive) {
            // Shown in front and focused like any modal dialog; setVisible blocks until it closes.
            dialog.setVisible(true);
            trace("modalShowReturned", 0);
            return;
        }
        dialog.setAutoRequestFocus(false);
        dialog.setFocusableWindowState(false);
        // Showing a modal dialog puts it and its owner on top of the other windows. Both wait off screen until
        // the dialog is open and the owner, with the dialog, is sent behind the other windows.
        dialogPlace = dialog.getLocation();
        windowPlace = window.getLocation();
        window.setLocation(-32000, -32000);
        dialog.setLocation(-32000, -32000);
        dialog.setVisible(true);
        trace("modalShowReturned", 0);
    }

    /** A message dialog that the application opens by itself. Closed through its button. */
    private void showOptionPane() {
        write("option.txt", "open");
        JDialog dialog = new JOptionPane("Fixture option pane message", JOptionPane.INFORMATION_MESSAGE)
                .createDialog(window, title + " option");
        if (!interactive) {
            // As for the modal dialog: never focusable, opened off screen, then put back behind the user's windows.
            dialog.setAutoRequestFocus(false);
            dialog.setFocusableWindowState(false);
            var dialogAt = dialog.getLocation();
            var windowAt = window.getLocation();
            dialog.addWindowListener(new WindowAdapter() {
                @Override public void windowOpened(WindowEvent event) {
                    window.toBack();
                    window.setLocation(windowAt);
                    dialog.setLocation(dialogAt);
                }
            });
            window.setLocation(-32000, -32000);
            dialog.setLocation(-32000, -32000);
        }
        dialog.setVisible(true);
        dialog.dispose();
        write("option.txt", "closed");
    }

    private void closeModal() {
        if (modal != null) {
            modal.dispose();
            modal = null;
            trace("modalClosed", 0);
            write("modal.txt", "closed");
        }
    }

    private void close() {
        commands.stop();
        closeModal();
        window.dispose();
    }

    private void pollCommands() {
        if (!swing) {
            // Changes through the native peer can bypass AWT's text events.
            syncAwtTextFiles();
        }
        if (consume("close-fixture")) {
            close();
            return;
        }
        if (consume("close-modal")) {
            trace("fixtureRequestedModalClose", 0);
            closeModal();
        }
        // A dialog that the application opens by itself, outside any accessibility request.
        if (consume("open-modal")) {
            EventQueue.invokeLater(this::showModal);
        }
        if (swing && consume("open-option-pane")) {
            EventQueue.invokeLater(this::showOptionPane);
        }
        if (TRACE && swing && consume("expose-edit-name")) {
            swingEdit.getAccessibleContext().setAccessibleName(swingEdit.getText());
            write("metadata-name.txt", "exposed");
        }
        if (TRACE && swing && consume("restore-edit-name")) {
            swingEdit.getAccessibleContext().setAccessibleName("Fixture edit");
            write("metadata-name.txt", "restored");
        }
        for (int tab = 0; swing && tab < swingTabs.getTabCount(); tab++) {
            if (consume("select-tab-" + tab)) {
                swingTabs.setSelectedIndex(tab);
                write("tab.txt", swingTabs.getTitleAt(tab));
            }
        }
        if (consume("replace-control")) {
            incrementButton.setEnabled(false);
            incrementButton.setName("fixtureRetired");
            counterRow.remove(incrementButton);
            incrementButton = newIncrementButton();
            counterRow.add(incrementButton, 0);
            counterRow.validate();
            counterRow.repaint();
            write("replaced", "ready");
        }
    }

    private void syncAwtTextFiles() {
        publishedAwtValue = publishAwtText(awtEdit, "value.txt", publishedAwtValue);
        publishedAwtReadOnly = publishAwtText(awtReadOnly, "read-only.txt", publishedAwtReadOnly);
        int passwordLength = awtPassword.getText().length();
        if (passwordLength != publishedAwtPasswordLength) {
            publishedAwtPasswordLength = passwordLength;
            write("password-length.txt", Integer.toString(passwordLength));
        }
    }

    private String publishAwtText(TextField field, String stateFile, String previous) {
        String current = field.getText();
        if (!current.equals(previous)) {
            write(stateFile, current);
        }
        return current;
    }

    private boolean consume(String name) {
        try {
            return Files.deleteIfExists(stateDirectory.resolve(name));
        } catch (IOException busy) {
            // The writer still holds the command file. The next poll consumes it.
            return false;
        }
    }

    private void write(String name, String content) {
        try {
            Path pending = stateDirectory.resolve(name + ".pending");
            Files.writeString(pending, content, StandardCharsets.UTF_8);
            // Windows refuses to replace a file that a reader holds open at that instant.
            for (int attempt = 0; ; attempt++) {
                try {
                    Files.move(pending, stateDirectory.resolve(name), StandardCopyOption.ATOMIC_MOVE,
                            StandardCopyOption.REPLACE_EXISTING);
                    if (name.equals("modal.txt") || name.equals("count.txt")) trace("published:" + name, attempt);
                    return;
                } catch (IOException busy) {
                    if (attempt == 100) throw busy;
                    Thread.sleep(5);
                }
            }
        } catch (IOException failure) {
            throw new UncheckedIOException("Writing " + name, failure);
        } catch (InterruptedException interrupted) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Writing " + name, interrupted);
        }
    }

    private void trace(String event, int number) {
        if (!TRACE) return;
        try {
            String line = System.currentTimeMillis() + "\t" + ++eventSequence + "\t" + event + "\t" + number + "\n";
            Files.writeString(stateDirectory.resolve("events.tsv"), line, StandardCharsets.UTF_8,
                    StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        } catch (IOException diagnosticFailure) {
            // A gap in the sequence shows that evidence was unavailable without changing the fixture action.
        }
    }

    private static <T extends Component & Accessible> T named(T component, String id, String name) {
        component.setName(id);
        component.getAccessibleContext().setAccessibleName(name);
        return component;
    }

    private static WindowAdapter onClose(Runnable callback) {
        return new WindowAdapter() {
            @Override public void windowClosing(WindowEvent event) { callback.run(); }
        };
    }

    private Component visualOnlySwatch() {
        // Component has no Accessible interface and this subclass adds none.
        var swatch = new Component() {
            @Override public void paint(Graphics graphics) {
                drawSwatch(graphics, getWidth(), getHeight(), "Visual-only custom swatch");
            }
        };
        swatch.setPreferredSize(new Dimension(200, 30));
        swatch.addMouseListener(new MouseAdapter() {
            @Override public void mouseClicked(MouseEvent event) { write("selected.txt", "Visual-only custom swatch"); }
        });
        return swatch;
    }

    private static void drawSwatch(Graphics graphics, int width, int height, String label) {
        graphics.setColor(new Color(228, 238, 249));
        graphics.fillRect(0, 0, width, height);
        graphics.setColor(new Color(26, 52, 79));
        graphics.drawString(label, 8, 19);
    }

    @SuppressWarnings("serial")
    private final class AccessibleSwatch extends JComponent implements Accessible {
        private AccessibleSwatch() {
            setPreferredSize(new Dimension(200, 30));
            addMouseListener(new MouseAdapter() {
                @Override public void mouseClicked(MouseEvent event) { activate(); }
            });
        }

        @Override protected void paintComponent(Graphics graphics) {
            drawSwatch(graphics, getWidth(), getHeight(), "Accessible custom swatch");
        }

        @Override public AccessibleContext getAccessibleContext() {
            if (accessibleContext == null) {
                accessibleContext = new SwatchContext();
            }
            return accessibleContext;
        }

        private void activate() {
            write("selected.txt", "Accessible custom swatch");
        }

        private final class SwatchContext extends AccessibleJComponent implements AccessibleAction {
            @Override public AccessibleRole getAccessibleRole() { return AccessibleRole.PUSH_BUTTON; }
            @Override public AccessibleAction getAccessibleAction() { return this; }
            @Override public int getAccessibleActionCount() { return 1; }
            @Override public String getAccessibleActionDescription(int index) { return index == 0 ? CLICK : null; }

            @Override public boolean doAccessibleAction(int index) {
                if (index != 0) {
                    return false;
                }
                EventQueue.invokeLater(AccessibleSwatch.this::activate);
                return true;
            }
        }
    }
}
