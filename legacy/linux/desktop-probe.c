/* Read-only diagnostic. Xlib and AT-SPI 1 ABI types are opaque here.
 * Resolve the runtime itself so header/.pc availability is a separate result. */
#include <dlfcn.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

typedef struct _XDisplay Display;
typedef unsigned long Window;
typedef struct AccessibleHandle Accessible;

static void deadline(int sig)
{
    static const char message[] = "TIMEOUT: desktop probe exceeded 10 seconds\n";
    (void)sig;
    (void)write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

static void *load_library(const char *name)
{
    void *library = dlopen(name, RTLD_NOW | RTLD_LOCAL);
    if (library == NULL)
        fprintf(stderr, "MISSING_LIBRARY %s: %s\n", name, dlerror());
    return library;
}

static void *load_symbol(void *library, const char *name)
{
    void *result = dlsym(library, name);
    if (result == NULL)
        fprintf(stderr, "MISSING_SYMBOL %s: %s\n", name, dlerror());
    return result;
}

static int probe_x11(void)
{
    void *lib = load_library("libX11.so.6");
    Display *(*open_display)(const char *);
    Window (*root_window)(Display *);
    int (*query_tree)(Display *, Window, Window *, Window *, Window **, unsigned int *);
    int (*free_data)(void *);
    int (*close_display)(Display *);
    Window root, parent, *children = NULL;
    unsigned int count = 0;
    Display *display;
    int ok;

    if (lib == NULL) return 2;
    open_display = (Display *(*)(const char *))load_symbol(lib, "XOpenDisplay");
    root_window = (Window (*)(Display *))load_symbol(lib, "XDefaultRootWindow");
    query_tree = (int (*)(Display *, Window, Window *, Window *, Window **, unsigned int *))
        load_symbol(lib, "XQueryTree");
    free_data = (int (*)(void *))load_symbol(lib, "XFree");
    close_display = (int (*)(Display *))load_symbol(lib, "XCloseDisplay");
    if (!open_display || !root_window || !query_tree || !free_data || !close_display) return 2;
    display = open_display(NULL);
    if (display == NULL) {
        fprintf(stderr, "NO_DISPLAY: XOpenDisplay failed for current session\n");
        return 3;
    }
    ok = query_tree(display, root_window(display), &root, &parent, &children, &count);
    if (children != NULL) free_data(children);
    close_display(display);
    if (!ok) {
        fprintf(stderr, "QUERY_FAILED: XQueryTree failed\n");
        return 3;
    }
    printf("READ_OK X11 root_children=%u\n", count);
    return 0;
}

static int probe_cspi(void)
{
    void *lib = load_library("libcspi.so.0");
    int (*spi_init)(void), (*spi_exit)(void), (*desktop_count)(void);
    Accessible *(*desktop_at)(int);
    long (*child_count)(Accessible *);
    void (*unref)(Accessible *);
    Accessible *desktop;
    int desktops;
    long children = -1;

    if (lib == NULL) return 2;
    spi_init = (int (*)(void))load_symbol(lib, "SPI_init");
    spi_exit = (int (*)(void))load_symbol(lib, "SPI_exit");
    desktop_count = (int (*)(void))load_symbol(lib, "SPI_getDesktopCount");
    desktop_at = (Accessible *(*)(int))load_symbol(lib, "SPI_getDesktop");
    child_count = (long (*)(Accessible *))load_symbol(lib, "Accessible_getChildCount");
    unref = (void (*)(Accessible *))load_symbol(lib, "Accessible_unref");
    if (!spi_init || !spi_exit || !desktop_count || !desktop_at || !child_count || !unref) return 2;
    if (spi_init() != 0) {
        fprintf(stderr, "NO_REGISTRY: SPI_init failed\n");
        return 3;
    }
    desktops = desktop_count();
    desktop = desktops > 0 ? desktop_at(0) : NULL;
    if (desktop != NULL) {
        children = child_count(desktop);
        unref(desktop);
    }
    spi_exit();
    if (children < 0) {
        fprintf(stderr, "QUERY_FAILED: AT-SPI 1 desktop unavailable\n");
        return 3;
    }
    printf("READ_OK AT-SPI1 desktops=%d first_desktop_children=%ld\n", desktops, children);
    return 0;
}

int main(int argc, char **argv)
{
    if (argc != 2 || (strcmp(argv[1], "x11") && strcmp(argv[1], "atspi1"))) {
        fprintf(stderr, "usage: desktop-probe x11|atspi1\n");
        return 1;
    }
    signal(SIGALRM, deadline);
    alarm(10);
    return strcmp(argv[1], "x11") == 0 ? probe_x11() : probe_cspi();
}
