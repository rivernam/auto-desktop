package dev.desktop;

import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.util.Locale;

/** Runs the real CLI with an explicitly selected one-shot native hook fault in the test build. */
public final class InputFaultCli {
    public static void main(String[] args) throws IOException {
        String selected = System.getenv("AUTO_DESKTOP_TEST_INPUT_FAULT");
        if (selected == null) throw new IllegalArgumentException("Specify a hook fault for the test launcher.");
        WindowsInputDriver.HookFault fault = WindowsInputDriver.HookFault.valueOf(
                selected.replace('-', '_').toUpperCase(Locale.ROOT));
        int status = Cli.run(args, System.in, new FileOutputStream(FileDescriptor.out),
                () -> new WindowsInputDriver(fault));
        System.exit(status);
    }

    private InputFaultCli() {}
}
