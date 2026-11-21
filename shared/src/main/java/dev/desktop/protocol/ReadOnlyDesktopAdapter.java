package dev.desktop.protocol;

/** Observations available to a read-only host. T is the runtime's JSON result model. */
public interface ReadOnlyDesktopAdapter<T> {
    T capabilities();
    T listWindows();
}
