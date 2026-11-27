import java.awt.Component;
import java.awt.EventQueue;
import java.awt.Frame;
import java.awt.TextArea;
import java.awt.TextComponent;
import java.awt.TextField;
import java.awt.Window;
import java.awt.event.ActionEvent;
import java.awt.event.KeyAdapter;
import java.awt.event.KeyEvent;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.util.Locale;
import javax.swing.JFrame;
import javax.swing.AbstractAction;
import javax.swing.Action;
import javax.swing.JTextField;
import javax.swing.Timer;
import javax.swing.text.JTextComponent;
import javax.swing.text.DefaultEditorKit;

/** A text-only fixture for comparing real Windows input and Java's received key events. */
public final class TextInputFixture {
    public static void main(String[] arguments) throws Exception {
        if (arguments.length != 3 || !"interactive".equals(System.getenv("DESKTOP_FIXTURE_MODE"))) {
            throw new IllegalArgumentException("TextInputFixture requires interactive mode, a kind, a state directory and a title.");
        }
        Path state = Path.of(arguments[1]);
        EventQueue.invokeAndWait(() -> show(arguments[0], state, arguments[2]));
    }

    private static void show(String kind, Path state, String title) {
        Window window;
        Component edit;
        switch (kind) {
            case "AwtField":
                window = new Frame(title);
                edit = new TextField("start", 32);
                break;
            case "AwtArea":
                window = new Frame(title);
                edit = new TextArea("start", 3, 32, TextArea.SCROLLBARS_NONE);
                break;
            case "Swing":
                window = new JFrame(title);
                edit = new JTextField("start", 32);
                break;
            default:
                throw new IllegalArgumentException("Unknown fixture kind " + kind);
        }
        window.add(edit);
        if (edit instanceof JTextField) installPasteControl((JTextField) edit, state);
        StringBuilder keys = new StringBuilder();
        edit.addKeyListener(new KeyAdapter() {
            private void record(String kind, KeyEvent event) {
                keys.append(kind).append(' ')
                        .append(event.getKeyCode()).append(' ')
                        .append(String.format(Locale.ROOT, "%04x", (int) event.getKeyChar())).append('\n');
            }

            @Override public void keyPressed(KeyEvent event) { record("pressed", event); }
            @Override public void keyReleased(KeyEvent event) { record("released", event); }
            @Override public void keyTyped(KeyEvent event) { record("typed", event); }
        });
        window.pack();
        window.setLocationRelativeTo(null);
        window.setVisible(true);
        edit.requestFocusInWindow();
        write(state, "ready", Long.toString(ProcessHandle.current().pid()));
        new Timer(30, event -> {
            if (Files.exists(state.resolve("close-fixture"))) {
                ((Timer) event.getSource()).stop();
                window.dispose();
                System.exit(0);
            }
            String value = edit instanceof TextComponent
                    ? ((TextComponent) edit).getText() : ((JTextComponent) edit).getText();
            write(state, "value.txt", value);
            write(state, "edit-focus.txt", Boolean.toString(edit.isFocusOwner()));
            write(state, "key-events.txt", keys.toString());
        }).start();
    }

    private static void installPasteControl(JTextField edit, Path state) {
        String name = DefaultEditorKit.pasteAction;
        Action paste = edit.getActionMap().get(name);
        edit.getActionMap().put(name, new AbstractAction() {
            @Override public void actionPerformed(ActionEvent event) {
                Path instruction = state.resolve("paste-mode.txt");
                if (!Files.isRegularFile(instruction)) {
                    paste.actionPerformed(event);
                    return;
                }
                try {
                    String mode = Files.readString(instruction).trim();
                    write(state, "paste-pending.txt", mode);
                    if (mode.equals("hold")) return;
                    if (mode.equals("focus")) {
                        JFrame other = new JFrame("Clipboard fixture foreground switch");
                        other.add(new JTextField("Other window", 20));
                        other.pack();
                        other.setLocationRelativeTo(edit);
                        other.setAutoRequestFocus(true);
                        other.setVisible(true);
                        other.toFront();
                        Timer close = new Timer(550, ignored -> other.dispose());
                        close.setRepeats(false);
                        close.start();
                        return;
                    }
                    Timer delayed = new Timer(Integer.parseInt(mode), ignored -> {
                        paste.actionPerformed(event);
                        write(state, "paste-finished.txt", mode);
                    });
                    delayed.setRepeats(false);
                    delayed.start();
                } catch (java.io.IOException failure) {
                    write(state, "paste-finished.txt", "instruction unreadable");
                }
            }
        });
    }

    private static void write(Path directory, String name, String value) {
        Path destination = directory.resolve(name);
        Path pending = directory.resolve(name + ".pending");
        try {
            if (Files.exists(destination) && value.equals(Files.readString(destination, StandardCharsets.UTF_8))) return;
            Files.writeString(pending, value, StandardCharsets.UTF_8);
            Files.move(pending, destination, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (java.io.IOException busy) {
            // The next tick retries if the probe was reading the file.
        }
    }
}
