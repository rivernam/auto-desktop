#define WINVER 0x0501
#define _WIN32_WINNT 0x0501
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include "json_buffer.h"

#define MAX_WINDOWS 4096u
#define MAX_TITLE 256u

static char frame[4u * 1024u * 1024u];
static JsonBuffer response = { frame, 0, sizeof(frame) - 1, 0 };
static unsigned count;

static int same_bytes(const char *a, const char *b) {
    while (*a && *a == *b) { ++a; ++b; }
    return *a == *b;
}

/* The Java dispatcher sends one of two constant internal frames per process. */
static int read_operation(void) {
    char request[64], chunk[64];
    unsigned used = 0;
    DWORD received, i;
    HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
    while (ReadFile(input, chunk, sizeof(chunk), &received, NULL) && received) {
        for (i = 0; i < received; i++) {
            char ch = chunk[i];
            if (ch == '\n') {
                if (used && request[used - 1] == '\r') --used;
                request[used] = 0;
                if (same_bytes(request, "{\"op\":\"getCapabilities\"}")) return 1;
                if (same_bytes(request, "{\"op\":\"listWindows\"}")) return 2;
                return 0;
            }
            if (used == sizeof(request) - 1 || ch == 0) return 0;
            request[used++] = ch;
        }
    }
    return 0;
}

static int desktop_name(HDESK desk, WCHAR *name, DWORD bytes) {
    DWORD used;
    return GetUserObjectInformationW(desk, UOI_NAME, name, bytes, &used) &&
           used >= sizeof(WCHAR) && used <= bytes && used % sizeof(WCHAR) == 0 &&
           name[used / sizeof(WCHAR) - 1] == 0;
}

static int on_input_desktop(void) {
    USEROBJECTFLAGS flags;
    DWORD used;
    HDESK input, thread;
    WCHAR a[256], b[256];
    unsigned i = 0;
    int same;
    if (!GetUserObjectInformationW(GetProcessWindowStation(), UOI_FLAGS,
            &flags, sizeof(flags), &used) || !(flags.dwFlags & WSF_VISIBLE)) return 0;
    input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS | DESKTOP_ENUMERATE);
    if (!input) return 0;
    thread = GetThreadDesktop(GetCurrentThreadId());
    same = thread && desktop_name(thread, a, sizeof(a)) && desktop_name(input, b, sizeof(b));
    if (same) {
        while (a[i] && a[i] == b[i]) ++i;
        same = a[i] == b[i];
    }
    CloseDesktop(input);
    return same;
}

static BOOL CALLBACK collect(HWND window, LPARAM unused) {
    WCHAR title[MAX_TITLE + 1];
    DWORD pid = 0;
    int length;
    (void)unused;
    if (!IsWindowVisible(window)) return TRUE;
    if (!GetWindowThreadProcessId(window, &pid)) return TRUE; /* Closed during enumeration. */
    if (count == MAX_WINDOWS) return FALSE;
    length = GetWindowTextW(window, title, MAX_TITLE + 1);
    if (count++) append_byte(&response, ',');
    append_text(&response, "{\"windowId\":\"");
    append_number(&response, (unsigned long)(ULONG_PTR)window);
    append_text(&response, "\",\"processId\":");
    append_number(&response, pid);
    append_text(&response, ",\"name\":");
    append_title(&response, title, (unsigned)length);
    append_byte(&response, '}');
    return !response.overflow;
}

static BOOL CALLBACK probe(HWND window, LPARAM unused) {
    (void)window;
    (void)unused;
    return TRUE;
}

static void build_response(int op) {
    if (!op) {
        append_text(&response, "{\"ok\":false,\"error\":{\"code\":\"INVALID_REQUEST\","
                    "\"message\":\"Invalid internal request.\"}}");
    } else if (op == 1) {
        append_text(&response, "{\"ok\":true,\"result\":{\"backend\":\"win32-xp\","
                    "\"physicalInput\":false,\"screenshot\":false,");
        if (on_input_desktop() && EnumWindows(probe, 0)) {
            append_text(&response, "\"available\":true,\"operations\":[\"getCapabilities\",\"listWindows\"]}}");
        } else {
            append_text(&response, "\"available\":false,\"operations\":[],"
                        "\"reason\":\"Interactive desktop enumeration is unavailable.\"}}");
        }
    } else {
        append_text(&response, "{\"ok\":true,\"result\":[");
        if (on_input_desktop() && EnumWindows(collect, 0) && !response.overflow &&
            response.capacity - response.length >= 2) {
            append_text(&response, "]}");
        } else {
            response.length = 0;
            response.overflow = 0;
            append_text(&response, "{\"ok\":false,\"error\":{\"code\":\"BACKEND_UNAVAILABLE\","
                        "\"message\":\"The desktop was unavailable or the enumeration limit was reached.\"}}");
        }
    }
}

void WINAPI worker_entry(void) {
    DWORD written, offset = 0;
    HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
    build_response(read_operation());
    frame[response.length++] = '\n';
    while (offset < response.length) {
        if (!WriteFile(output, frame + offset, response.length - offset, &written, NULL) || !written)
            ExitProcess(1);
        offset += written;
    }
    ExitProcess(0);
}
