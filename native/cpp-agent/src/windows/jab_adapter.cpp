#include "windows/jab_adapter.hpp"
#include "windows/uia_adapter.hpp"

#include <Windows.h>

#include <algorithm>
#include <atomic>
#include <charconv>
#include <cstdio>
#include <cstdint>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <string_view>
#include <unordered_map>
#include <utility>
#include <vector>

namespace desktop::windows {
namespace {
// Windows ABI of OpenJDK AccessBridgePackages.h where Java object handles are 64-bit
// (WindowsAccessBridge-64.dll and WindowsAccessBridge-32.dll). The legacy ABI is not supported.
using JObject = std::int64_t;
using JInt = std::int32_t;
constexpr int nameChars = 1024;
constexpr int shortChars = 256;
constexpr int maxActions = 256;
constexpr int maxActionsToDo = 32;
// setTextContents copies into a buffer of nameChars code units. One is the terminator.
constexpr std::size_t maxText = nameChars - 1;

struct ContextInfo {
    wchar_t name[nameChars];
    wchar_t description[nameChars];
    wchar_t role[shortChars];
    wchar_t roleEnglish[shortChars];
    wchar_t states[shortChars];
    wchar_t statesEnglish[shortChars];
    JInt indexInParent, childrenCount, x, y, width, height;
    BOOL accessibleComponent, accessibleAction, accessibleSelection, accessibleText, accessibleInterfaces;
};
struct ActionInfo {
    wchar_t name[shortChars];
};
struct Actions {
    JInt count;
    ActionInfo info[maxActions];
};
struct ActionsToDo {
    JInt count;
    ActionInfo actions[maxActionsToDo];
};
static_assert(sizeof(ContextInfo) == 6188, "AccessibleContextInfo layout");
static_assert(sizeof(Actions) == 131076, "AccessibleActions layout");
static_assert(sizeof(ActionsToDo) == 16388, "AccessibleActionsToDo layout");

// A JVM did not answer. The library waits at least four seconds for each reply and then returns
// whatever its buffer held, so the result of such a call carries no information.
struct Silent {};

std::atomic<bool> detachWouldBlock{false};

Error stale() { return {"STALE_REFERENCE", "The captured element or window is no longer current."}; }
Error missing() { return {"WINDOW_NOT_FOUND", "The requested top-level window is unavailable."}; }
Error precondition() { return {"PRECONDITION_FAILED", "The current element state does not permit the action."}; }
Error unsupported() {
    return {"PATTERN_UNSUPPORTED", "The element does not provide this action through Java Access Bridge."};
}
Error silent() {
    return {"TARGET_NOT_RESPONDING",
            "A JVM is not answering Java Access Bridge. Retry when the application is responsive again."};
}
Error notConnected() {
    return {"BRIDGE_NOT_CONNECTED",
            "The Java window has no Java Access Bridge connection. Enable the bridge in its JVM."};
}

std::string utf8(const std::wstring& text) {
    if (text.empty()) return {};
    const int units = static_cast<int>(text.size());
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, text.data(), units, nullptr, 0, nullptr, nullptr);
    std::string result(static_cast<std::size_t>(bytes > 0 ? bytes : 0), '\0');
    if (bytes <= 0 || !WideCharToMultiByte(CP_UTF8, 0, text.data(), units, result.data(), bytes, nullptr, nullptr))
        throw stale();
    return result;
}

std::wstring wide(const std::string& text) {
    if (text.empty()) return {};
    const auto bytes = static_cast<int>(text.size());
    const int units = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), bytes, nullptr, 0);
    if (!units) throw Error("INVALID_REQUEST", "Invalid UTF-8 value.");
    std::wstring result(static_cast<std::size_t>(units), L'\0');
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(), bytes, result.data(), units))
        throw Error("INVALID_REQUEST", "Invalid UTF-8 value.");
    return result;
}

template<std::size_t Size>
std::wstring field(const wchar_t (&buffer)[Size]) {
    return {buffer, static_cast<std::size_t>(std::find(buffer, buffer + Size, L'\0') - buffer)};
}

// The first 256 UTF-16 code units, without splitting a surrogate pair.
std::string clip(std::wstring text, bool& clipped) {
    if (text.size() > 256) {
        clipped = true;
        text.resize(text[255] >= 0xD800 && text[255] <= 0xDBFF ? 255 : 256);
    }
    return utf8(text);
}

std::uint32_t windowNumber(HWND handle) {
    return static_cast<std::uint32_t>(reinterpret_cast<std::uintptr_t>(handle));
}

HWND windowHandle(std::uint32_t number) { return reinterpret_cast<HWND>(static_cast<std::uintptr_t>(number)); }

HWND parseWindow(const std::string& id) {
    std::uint32_t value = 0;
    const auto end = id.data() + id.size();
    const auto result = std::from_chars(id.data(), end, value);
    if (id.empty() || id.front() == '0' || result.ec != std::errc{} || result.ptr != end) throw missing();
    return windowHandle(value);
}

int windowProcess(HWND handle) {
    DWORD pid = 0;
    return GetWindowThreadProcessId(handle, &pid) ? static_cast<int>(pid) : 0;
}

bool topLevel(HWND handle) {
    return IsWindow(handle) && IsWindowVisible(handle) && GetAncestor(handle, GA_PARENT) == GetDesktopWindow();
}

// The class of every AWT and Swing top-level window. A diagnostic hint, never a way to select a target.
bool javaWindowClass(HWND handle) {
    wchar_t name[64]{};
    const int length = GetClassNameW(handle, name, 64);
    return length >= 6 && std::wstring_view(name, 6) == L"SunAwt";
}

BOOL CALLBACK collectTopLevel(HWND handle, LPARAM state) {
    auto& found = *reinterpret_cast<std::vector<HWND>*>(state);
    try {
        if (topLevel(handle)) found.push_back(handle);
    } catch (const std::bad_alloc&) {
        return FALSE;
    }
    return found.size() < 4096;
}

std::vector<HWND> topLevelWindows() {
    std::vector<HWND> found;
    EnumWindows(collectTopLevel, reinterpret_cast<LPARAM>(&found));
    return found;
}

// Bridge roles (en_US) with one clear counterpart in the shared role vocabulary. Others stay Custom.
const char* sharedRole(const std::wstring& role) {
    static const std::unordered_map<std::wstring, const char*> roles{
        {L"push button", "Button"}, {L"toggle button", "Button"}, {L"check box", "CheckBox"},
        {L"radio button", "RadioButton"}, {L"combo box", "ComboBox"}, {L"text", "Edit"},
        {L"password text", "Edit"}, {L"label", "Text"}, {L"list", "List"}, {L"list item", "ListItem"},
        {L"table", "Table"}, {L"tree", "Tree"}, {L"page tab list", "Tab"}, {L"page tab", "TabItem"},
        {L"menu bar", "MenuBar"}, {L"popup menu", "Menu"}, {L"menu", "MenuItem"}, {L"menu item", "MenuItem"},
        {L"check box menu item", "MenuItem"}, {L"radio button menu item", "MenuItem"},
        {L"scroll bar", "ScrollBar"}, {L"slider", "Slider"}, {L"progress bar", "ProgressBar"},
        {L"tool bar", "ToolBar"}, {L"tool tip", "ToolTip"}, {L"separator", "Separator"},
        {L"hyperlink", "Hyperlink"}, {L"spinbox", "Spinner"}, {L"status bar", "StatusBar"},
        {L"icon", "Image"}, {L"group box", "Group"}, {L"header", "Header"}, {L"column header", "HeaderItem"},
        {L"row header", "HeaderItem"}, {L"frame", "Window"}, {L"dialog", "Window"}, {L"window", "Window"},
        {L"internal frame", "Window"}, {L"panel", "Pane"}, {L"root pane", "Pane"}, {L"layered pane", "Pane"},
        {L"glass pane", "Pane"}, {L"viewport", "Pane"}, {L"scroll pane", "Pane"}, {L"split pane", "Pane"},
        {L"desktop pane", "Pane"}, {L"option pane", "Pane"}};
    const auto found = roles.find(role);
    return found == roles.end() ? "Custom" : found->second;
}

bool hasState(const std::wstring& states, std::wstring_view wanted) {
    std::size_t start = 0;
    while (start <= states.size()) {
        auto end = states.find(L',', start);
        if (end == std::wstring::npos) end = states.size();
        auto first = start;
        auto last = end;
        while (first < last && states[first] == L' ') ++first;
        while (last > first && states[last - 1] == L' ') --last;
        if (std::wstring_view(states).substr(first, last - first) == wanted) return true;
        start = end + 1;
    }
    return false;
}

// The action that Invoke dispatches. A push button or menu item with one action is activated by it,
// whatever its localized name. With several actions only an unambiguous "click" qualifies.
std::wstring invokeAction(const std::vector<std::wstring>& actions) {
    if (actions.size() == 1) return actions.front();
    std::wstring found;
    for (const auto& action : actions) {
        if (CompareStringOrdinal(action.data(), static_cast<int>(action.size()), L"click", 5, TRUE) != CSTR_EQUAL)
            continue;
        if (!found.empty()) return {};
        found = action;
    }
    return found;
}

std::uint16_t machineOf(const std::filesystem::path& file) {
    std::ifstream image(file, std::ios::binary);
    unsigned char header[0x40]{};
    if (!image.read(reinterpret_cast<char*>(header), sizeof(header)) || header[0] != 'M' || header[1] != 'Z') return 0;
    const std::uint32_t offset = header[0x3c] | (header[0x3d] << 8) | (header[0x3e] << 16)
        | (static_cast<std::uint32_t>(header[0x3f]) << 24);
    unsigned char pe[6]{};
    if (!image.seekg(offset) || !image.read(reinterpret_cast<char*>(pe), sizeof(pe))
        || pe[0] != 'P' || pe[1] != 'E' || pe[2] != 0 || pe[3] != 0) return 0;
    return static_cast<std::uint16_t>(pe[4] | (pe[5] << 8));
}

const wchar_t* libraryName() {
    return sizeof(void*) == 8 ? L"WindowsAccessBridge-64.dll" : L"WindowsAccessBridge-32.dll";
}

std::wstring registryText(const std::wstring& key, const wchar_t* value) {
    wchar_t text[MAX_PATH]{};
    DWORD bytes = sizeof(text);
    if (RegGetValueW(HKEY_LOCAL_MACHINE, key.c_str(), value, RRF_RT_REG_SZ, nullptr, text, &bytes) != ERROR_SUCCESS)
        return {};
    return text;
}

// Installation directories only. The working directory and PATH are never searched.
std::vector<std::filesystem::path> defaultLibraries() {
    std::vector<std::filesystem::path> result;
    wchar_t system[MAX_PATH]{};
    const UINT length = GetSystemDirectoryW(system, MAX_PATH);
    if (length > 0 && length < MAX_PATH) result.push_back(std::filesystem::path(system) / libraryName());
    for (const wchar_t* product : {L"JDK", L"JRE", L"Java Development Kit", L"Java Runtime Environment"}) {
        const std::wstring key = std::wstring(L"SOFTWARE\\JavaSoft\\") + product;
        const auto version = registryText(key, L"CurrentVersion");
        if (version.empty()) continue;
        const auto home = registryText(key + L"\\" + version, L"JavaHome");
        if (!home.empty()) result.push_back(std::filesystem::path(home) / L"bin" / libraryName());
    }
    return result;
}

struct Root {
    long vm = 0;
    JObject context = 0;
};

struct BridgeInfo {
    std::wstring name, role, states;
    int children = 0;
    long x = 0, y = 0, width = 0, height = 0;
    bool action = false, text = false;
};

// The loaded library and its message window. One thread constructs, uses and destroys it.
class Bridge {
public:
    explicit Bridge(const std::wstring& explicitLibrary) { load(explicitLibrary); }

    ~Bridge() {
        if (!module_) return;
        // Unloading tells every connected JVM that this client left, with untimed messages.
        if (anySilent()) detachWouldBlock = true;
        else FreeLibrary(module_);
    }

    Bridge(const Bridge&) = delete;
    Bridge& operator=(const Bridge&) = delete;

    bool loaded() const { return module_ != nullptr; }
    const std::string& reason() const { return reason_; }

    // Deliver queued window messages, including the announcements of JVMs that started later.
    int pump() {
        MSG message;
        int delivered = 0;
        while (delivered < 4096 && PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
            ++delivered;
        }
        return delivered;
    }

    // Whether the bridge thread of the JVM handles messages right now. It does not while the event
    // thread of the application is inside a bridge request, for example a click that opened a modal dialog.
    static bool answering(long vm) {
        const HWND target = windowHandle(static_cast<std::uint32_t>(vm));
        DWORD_PTR reply = 0;
        return IsWindow(target) && SendMessageTimeoutW(target, WM_NULL, 0, 0, SMTO_ABORTIFHUNG, 500, &reply) != 0;
    }

    // The process that hosts the JVM, or 0 when the JVM is gone. The identifier is its bridge window.
    static int vmProcess(long vm) { return windowProcess(windowHandle(static_cast<std::uint32_t>(vm))); }

    // A known JVM that still exists and does not answer. Lookups by window would wait on it.
    bool anySilent() {
        for (auto vm = vms_.begin(); vm != vms_.end();) {
            if (!IsWindow(windowHandle(static_cast<std::uint32_t>(*vm)))) vm = vms_.erase(vm);
            else if (!answering(*vm)) return true;
            else ++vm;
        }
        return false;
    }

    bool javaWindow(HWND handle) { return timed([&] { return isJavaWindow_(handle); }) != FALSE; }

    // The caller releases the context.
    std::optional<Root> root(HWND handle) {
        long vm = 0;
        JObject context = 0;
        if (!timed([&] { return contextFromWindow_(handle, &vm, &context); }) || !context) return {};
        vms_.insert(vm);
        return Root{vm, context};
    }

    HWND windowOf(long vm, JObject context) { return timed([&] { return windowFromContext_(vm, context); }); }

    // Every handle returned by the bridge is a reference in the JVM until released. The release is an
    // untimed SendMessage. Call it only for a JVM that has just answered.
    void release(long vm, JObject context) noexcept {
        if (context) release_(vm, context);
    }

    // Releases a prefix of the handles while the JVM answers and returns its length.
    std::size_t release(long vm, const std::vector<JObject>& contexts) noexcept {
        std::size_t released = 0;
        for (const JObject context : contexts) {
            if (released % 32 == 0 && !answering(vm)) break;
            release(vm, context);
            ++released;
        }
        return released;
    }

    bool same(long vm, JObject first, JObject second) {
        return timed([&] { return isSameObject_(vm, first, second); }) != FALSE;
    }

    // Empty when the bridge could not read the context. Text content is never requested.
    std::optional<BridgeInfo> info(long vm, JObject context) {
        *info_ = {};
        if (!timed([&] { return contextInfo_(vm, context, info_.get()); })) return {};
        BridgeInfo result;
        result.name = field(info_->name);
        result.role = field(info_->roleEnglish);
        result.states = field(info_->statesEnglish);
        result.children = std::max<JInt>(info_->childrenCount, 0);
        result.x = info_->x;
        result.y = info_->y;
        result.width = info_->width;
        result.height = info_->height;
        result.action = info_->accessibleAction != FALSE;
        result.text = info_->accessibleText != FALSE;
        return result;
    }

    JObject child(long vm, JObject context, int index) { return timed([&] { return child_(vm, context, index); }); }
    JObject parent(long vm, JObject context) { return timed([&] { return parent_(vm, context); }); }

    // The action names in provider order, or empty when the bridge could not read them.
    std::optional<std::vector<std::wstring>> actions(long vm, JObject context) {
        actions_->count = 0;
        if (!timed([&] { return actionsOf_(vm, context, actions_.get()); })) return {};
        if (actions_->count < 0 || actions_->count > maxActions) return {};
        std::vector<std::wstring> names;
        for (JInt index = 0; index < actions_->count; ++index) names.push_back(field(actions_->info[index].name));
        return names;
    }

    // One named action. False means the bridge did not confirm it.
    bool act(long vm, JObject context, const std::wstring& action, const BeforeMutation& before) {
        if (action.empty() || action.size() >= shortChars) return false;
        *todo_ = {};
        todo_->count = 1;
        std::copy(action.begin(), action.end(), todo_->actions[0].name);
        JInt failure = 0;
        before();
        const BOOL result = mutation("invoke", [&] { return doActions_(vm, context, todo_.get(), &failure); }, &failure);
        // A one-action success writes -1. An untouched out parameter cannot confirm dispatch.
        return result == TRUE && failure == -1;
    }

    bool setText(long vm, JObject context, const std::wstring& value, const BeforeMutation& before) {
        if (value.size() > maxText || value.find(L'\0') != std::wstring::npos) return false;
        before();
        return mutation("setValue", [&] { return setText_(vm, context, value.c_str()); }) == TRUE;
    }

private:
    template<class Call>
    BOOL mutation(const char* op, Call&& call, const JInt* failure = nullptr) {
        static const bool trace = [] {
            wchar_t value[2]{};
            return GetEnvironmentVariableW(L"AUTO_DESKTOP_NATIVE_TRACE", value, 2) == 1 && value[0] == L'1';
        }();
        if (!trace) return timed(std::forward<Call>(call));
        const auto epochMs = [] {
            return std::chrono::duration_cast<std::chrono::milliseconds>(
                std::chrono::system_clock::now().time_since_epoch()).count();
        };
        const auto started = epochMs();
        const auto ticks = GetTickCount64();
        const BOOL result = call();
        const auto elapsed = GetTickCount64() - ticks;
        if (failure)
            std::fprintf(stderr, "jabNative op=%s startedEpochMs=%lld finishedEpochMs=%lld raw=%d failureIndex=%d\n",
                         op, started, epochMs(), result, *failure);
        else
            std::fprintf(stderr, "jabNative op=%s startedEpochMs=%lld finishedEpochMs=%lld raw=%d\n",
                         op, started, epochMs(), result);
        checkAnswered(elapsed);
        return result;
    }

    template<class Call>
    auto timed(Call&& call) {
        const auto started = GetTickCount64();
        auto result = call();
        checkAnswered(GetTickCount64() - started);
        return result;
    }

    static void checkAnswered(ULONGLONG elapsed) {
        // Conservative latency guard. Timing alone cannot establish that a reply arrived.
        if (elapsed >= 3500) throw Silent{};
    }

    template<class Function>
    bool resolve(Function& target, const char* name) {
        target = reinterpret_cast<Function>(GetProcAddress(module_, name));
        if (!target) reason_ = std::string("The Java Access Bridge library lacks ") + name + ".";
        return target != nullptr;
    }

    void load(const std::wstring& explicitLibrary) {
        std::filesystem::path library;
        std::error_code ignored;
        if (!explicitLibrary.empty()) {
            library = explicitLibrary;
            if (!library.is_absolute()) {
                reason_ = "The Java Access Bridge library path must be absolute.";
                return;
            }
            if (!std::filesystem::is_regular_file(library, ignored)) {
                reason_ = "The specified Java Access Bridge library does not exist.";
                return;
            }
        } else {
            for (const auto& candidate : defaultLibraries()) {
                if (std::filesystem::is_regular_file(candidate, ignored)) {
                    library = candidate;
                    break;
                }
            }
            if (library.empty()) {
                reason_ = std::string("No ") + (sizeof(void*) == 8 ? "WindowsAccessBridge-64.dll" : "WindowsAccessBridge-32.dll")
                    + " was found in the Windows system directory or a registered Java installation.";
                return;
            }
        }
        auto name = library.filename().wstring();
        if (CompareStringOrdinal(name.data(), static_cast<int>(name.size()), L"WindowsAccessBridge.dll", -1, TRUE)
            == CSTR_EQUAL) {
            reason_ = "The legacy WindowsAccessBridge.dll ABI is not supported.";
            return;
        }
        if (machineOf(library) != (sizeof(void*) == 8 ? IMAGE_FILE_MACHINE_AMD64 : IMAGE_FILE_MACHINE_I386)) {
            reason_ = std::string("The Java Access Bridge library does not match this ")
                + (sizeof(void*) == 8 ? "64" : "32") + "-bit agent process.";
            return;
        }
        // The directory of the library and System32 only. Older systems lack these flags.
        module_ = LoadLibraryExW(library.c_str(), nullptr,
                                 LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
        if (!module_) module_ = LoadLibraryExW(library.c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!module_) {
            reason_ = "Windows could not load the Java Access Bridge library.";
            return;
        }
        void (*run)() = nullptr;
        if (!(resolve(run, "Windows_run") && resolve(isJavaWindow_, "isJavaWindow")
              && resolve(contextFromWindow_, "getAccessibleContextFromHWND")
              && resolve(windowFromContext_, "getHWNDFromAccessibleContext")
              && resolve(release_, "releaseJavaObject") && resolve(isSameObject_, "isSameObject")
              && resolve(contextInfo_, "getAccessibleContextInfo")
              && resolve(child_, "getAccessibleChildFromContext")
              && resolve(parent_, "getAccessibleParentFromContext")
              && resolve(actionsOf_, "getAccessibleActions") && resolve(doActions_, "doAccessibleActions")
              && resolve(setText_, "setTextContents"))) {
            FreeLibrary(module_);
            module_ = nullptr;
            return;
        }
        info_ = std::make_unique<ContextInfo>();
        actions_ = std::make_unique<Actions>();
        todo_ = std::make_unique<ActionsToDo>();
        run();
        settle();
    }

    // Each running JVM answers the announcement of Windows_run with a posted message.
    void settle() {
        const auto started = GetTickCount64();
        auto quietSince = started;
        for (;;) {
            const auto now = GetTickCount64();
            if (pump() > 0) quietSince = now;
            if (now - started >= 2000 || (now - started >= 200 && now - quietSince >= 100)) return;
            Sleep(10);
        }
    }

    HMODULE module_ = nullptr;
    std::string reason_;
    std::set<long> vms_;
    std::unique_ptr<ContextInfo> info_;
    std::unique_ptr<Actions> actions_;
    std::unique_ptr<ActionsToDo> todo_;
    BOOL (*isJavaWindow_)(HWND) = nullptr;
    BOOL (*contextFromWindow_)(HWND, long*, JObject*) = nullptr;
    HWND (*windowFromContext_)(long, JObject) = nullptr;
    void (*release_)(long, JObject) = nullptr;
    BOOL (*isSameObject_)(long, JObject, JObject) = nullptr;
    BOOL (*contextInfo_)(long, JObject, ContextInfo*) = nullptr;
    JObject (*child_)(long, JObject, JInt) = nullptr;
    JObject (*parent_)(long, JObject) = nullptr;
    BOOL (*actionsOf_)(long, JObject, Actions*) = nullptr;
    BOOL (*doActions_)(long, JObject, ActionsToDo*, JInt*) = nullptr;
    BOOL (*setText_)(long, JObject, const wchar_t*) = nullptr;
};

// One reference in the JVM, returned when the scope ends.
class Held {
public:
    Held(Bridge& bridge, long vm, JObject context) : bridge_(bridge), vm_(vm), context_(context) {}
    ~Held() { bridge_.release(vm_, context_); }
    Held(const Held&) = delete;
    Held& operator=(const Held&) = delete;
    JObject get() const { return context_; }
    explicit operator bool() const { return context_ != 0; }
    JObject detach() { return std::exchange(context_, 0); }

private:
    Bridge& bridge_;
    long vm_;
    JObject context_;
};

class JabAdapter final : public DesktopAdapter {
public:
    explicit JabAdapter(const std::wstring& library)
        : bridge_(library), wake_(CreateEventW(nullptr, FALSE, FALSE, nullptr)) {}
    ~JabAdapter() override {
        clear();
        if (wake_) CloseHandle(wake_);
    }

    const char* backend() const override { return "JAB"; }
    Availability availability() override;
    std::vector<Window> windows() override;
    Capture capture(const std::string& windowId, std::optional<std::size_t> scope, int depth, int limit) override;
    Element info(std::size_t index) override;
    void perform(Action action, std::size_t index, const std::string& value, const BeforeMutation& before) override;
    void clear() noexcept override;
    std::chrono::milliseconds idleInterval() const override { return std::chrono::milliseconds(250); }
    void idle() noexcept override;
    void serve(const std::function<bool()>& done) noexcept override;
    void wake() noexcept override { if (wake_) SetEvent(wake_); }

private:
    struct Entry {
        JObject node;
        std::shared_ptr<const Entry> parent;
        Identity identity;
    };

    struct NativeCapture {
        HWND handle = nullptr;
        int pid = 0;
        std::uint64_t started = 0;
        long vm = 0;
        std::shared_ptr<const Entry> window;
        std::vector<std::shared_ptr<const Entry>> entries;
        // Every reference this capture holds in the JVM.
        std::vector<JObject> owned;
        std::size_t visited = 0;
    };

    struct Inspection {
        Element row;
        bool protectedContent = false;
        std::wstring invoke;
        int children = 0;
    };

    void ready();
    void releaseDeferred() noexcept;
    void retire(NativeCapture& capture) noexcept;
    Root window(HWND handle, int expectedPid);
    std::optional<Inspection> inspect(const NativeCapture& capture, JObject node);
    bool parentsMatch(const NativeCapture& capture, const Entry& selected);
    const Entry& resolve(const NativeCapture& capture, std::size_t index);
    bool visit(NativeCapture& native, Capture& rows, JObject node, std::shared_ptr<const Entry> parent,
               std::optional<std::size_t> parentIndex, int depth, int maxDepth, std::size_t limit);

    Bridge bridge_;
    // Ends the wait inside serve() when a request for this backend arrives.
    HANDLE wake_ = nullptr;
    std::optional<NativeCapture> active_;
    // References of closed captures whose JVM was not answering.
    std::map<long, std::vector<JObject>> deferred_;
};

void JabAdapter::releaseDeferred() noexcept {
    for (auto pending = deferred_.begin(); pending != deferred_.end();) {
        auto& handles = pending->second;
        // A JVM that exited needs no release.
        if (Bridge::vmProcess(pending->first) == 0) handles.clear();
        else handles.erase(handles.begin(), handles.begin()
                           + static_cast<std::ptrdiff_t>(bridge_.release(pending->first, handles)));
        pending = handles.empty() ? deferred_.erase(pending) : std::next(pending);
    }
}

// Hands every reference back to the JVM, now or once it answers again.
void JabAdapter::retire(NativeCapture& capture) noexcept {
    try {
        auto& pending = deferred_[capture.vm];
        pending.insert(pending.end(), capture.owned.begin(), capture.owned.end());
    } catch (const std::bad_alloc&) {
        // The references stay in the JVM until it exits.
    }
    capture.owned.clear();
    releaseDeferred();
}

void JabAdapter::clear() noexcept {
    if (!bridge_.loaded()) return;
    if (active_) retire(*active_);
    active_.reset();
}

void JabAdapter::idle() noexcept {
    if (!bridge_.loaded()) return;
    bridge_.pump();
    releaseDeferred();
}

void JabAdapter::serve(const std::function<bool()>& done) noexcept {
    // The bridge keeps a hidden window on this thread. A UI Automation client that walks the desktop
    // sends it messages and waits for the answer, so they are handled as they arrive.
    while (!done()) {
        if (bridge_.loaded()) bridge_.pump();
        if (wake_) MsgWaitForMultipleObjectsEx(1, &wake_, 250, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        else Sleep(10);
    }
}

void JabAdapter::ready() {
    if (!bridge_.loaded()) throw Error("BACKEND_UNAVAILABLE", bridge_.reason().c_str());
    bridge_.pump();
    releaseDeferred();
    // The library asks every JVM in turn about a window and waits seconds for one that is silent.
    if (bridge_.anySilent()) throw silent();
}

Availability JabAdapter::availability() {
    Availability result;
    result.available = bridge_.loaded();
    result.reason = bridge_.reason();
    if (!result.available) return result;
    try {
        ready();
        int javaWindows = 0;
        int connected = 0;
        for (const HWND handle : topLevelWindows()) {
            const bool bridged = bridge_.javaWindow(handle);
            if (bridged) ++connected;
            if (bridged || javaWindowClass(handle)) ++javaWindows;
        }
        // Java windows that no bridge-enabled JVM answers for cannot be read or operated here.
        result.javaWindows = std::make_pair(javaWindows, connected);
    } catch (const Silent&) {
        throw silent();
    }
    return result;
}

std::vector<Window> JabAdapter::windows() {
    try {
        ready();
        std::vector<Window> result;
        const int own = static_cast<int>(GetCurrentProcessId());
        for (const HWND handle : topLevelWindows()) {
            if (!bridge_.javaWindow(handle)) continue;
            const int pid = windowProcess(handle);
            if (pid <= 0 || pid == own) continue;
            const auto found = bridge_.root(handle);
            if (!found) continue;
            const Held root(bridge_, found->vm, found->context);
            if (bridge_.windowOf(found->vm, root.get()) != handle) continue;
            const auto described = bridge_.info(found->vm, root.get());
            if (!described) continue;
            bool clipped = false;
            Window row{std::to_string(windowNumber(handle)), pid, clip(described->name, clipped), {}};
            // Swing gives ownerless dialogs a hidden shared owner. Only a window that can be listed is named.
            const HWND owner = GetWindow(handle, GW_OWNER);
            if (owner && IsWindowVisible(owner)) row.owner = std::to_string(windowNumber(owner));
            result.push_back(std::move(row));
        }
        return result;
    } catch (const Silent&) {
        throw silent();
    }
}

// The bridge context of a visible top-level Java window. The caller owns the returned context.
Root JabAdapter::window(HWND handle, int expectedPid) {
    if (!topLevel(handle)) throw missing();
    const int pid = windowProcess(handle);
    if (pid <= 0 || pid == static_cast<int>(GetCurrentProcessId()) || (expectedPid && pid != expectedPid))
        throw missing();
    const auto found = bridge_.javaWindow(handle) ? bridge_.root(handle) : std::optional<Root>{};
    if (!found) {
        if (javaWindowClass(handle)) throw notConnected();
        throw missing();
    }
    Held root(bridge_, found->vm, found->context);
    // The context must lead back to the same window, and the JVM that answered must be its process.
    if (bridge_.windowOf(found->vm, root.get()) != handle) throw missing();
    const int vmProcess = Bridge::vmProcess(found->vm);
    if (vmProcess != 0 && vmProcess != pid) throw missing();
    return {found->vm, root.detach()};
}

std::optional<JabAdapter::Inspection> JabAdapter::inspect(const NativeCapture& capture, JObject node) {
    const auto raw = bridge_.info(capture.vm, node);
    if (!raw) return {};
    Inspection result;
    const bool password = raw->role == L"password text";
    result.protectedContent = password;
    auto& identity = result.row.identity;
    // The accessible name of a Java text component is its label. A password field stays unnamed.
    identity.name = clip(password ? std::wstring() : raw->name, identity.clipped);
    identity.role = sharedRole(raw->role);
    identity.nativeRole = clip(raw->role, identity.clipped);
    if (raw->name.size() >= static_cast<std::size_t>(nameChars - 1)) identity.clipped = true;
    result.row.pid = capture.pid;
    result.row.enabled = hasState(raw->states, L"enabled");
    result.row.offscreen = !hasState(raw->states, L"showing");
    result.row.writable = (password || raw->role == L"text") && hasState(raw->states, L"editable");
    if (raw->action && (raw->role == L"push button" || raw->role == L"menu item")) {
        if (const auto actions = bridge_.actions(capture.vm, node)) result.invoke = invokeAction(*actions);
    }
    result.row.invoke = !result.invoke.empty();
    if (raw->width > 0 && raw->height > 0) result.row.bounds = Bounds{raw->x, raw->y, raw->width, raw->height};
    result.children = raw->children;
    return result;
}

bool JabAdapter::parentsMatch(const NativeCapture& capture, const Entry& selected) {
    const auto* expected = &selected;
    JObject node = selected.node;
    std::vector<std::unique_ptr<Held>> fetched;
    while (expected->parent) {
        fetched.push_back(std::make_unique<Held>(bridge_, capture.vm, bridge_.parent(capture.vm, node)));
        const auto& parent = *fetched.back();
        expected = expected->parent.get();
        if (!parent || !bridge_.same(capture.vm, parent.get(), expected->node)) return false;
        node = parent.get();
    }
    return expected == capture.window.get();
}

// The captured element when its window, its JVM and every captured ancestor are still the same
// objects. An accessible object that Swing creates per request cannot be proven and is refused.
const JabAdapter::Entry& JabAdapter::resolve(const NativeCapture& capture, std::size_t index) {
    if (index >= capture.entries.size()) throw stale();
    const auto& entry = *capture.entries[index];
    Root live;
    try {
        live = window(capture.handle, capture.pid);
    } catch (const Error&) {
        throw stale();
    }
    {
        const Held root(bridge_, live.vm, live.context);
        if (live.vm != capture.vm || processStart(capture.pid) != capture.started
            || !bridge_.same(capture.vm, root.get(), capture.window->node)) throw stale();
    }
    if (!parentsMatch(capture, entry)) throw stale();
    return entry;
}

// Takes ownership of node. Returns false when the bridge could not read the node and it was omitted.
// A parent row records why its own subtree is incomplete.
bool JabAdapter::visit(NativeCapture& native, Capture& rows, JObject node, std::shared_ptr<const Entry> parent,
                       std::optional<std::size_t> parentIndex, int depth, int maxDepth, std::size_t limit) {
    // The caller already holds the root of the capture.
    if (depth > 0) native.owned.push_back(node);
    ++native.visited;
    auto current = inspect(native, node);
    if (!current) return false;
    auto entry = std::make_shared<Entry>(Entry{node, std::move(parent), current->row.identity});
    if (!entry->parent) native.window = entry;
    const auto index = native.entries.size();
    native.entries.push_back(entry);
    current->row.parent = parentIndex;
    rows.elements.push_back(std::move(current->row));
    // "limit" is the depth or element budget of the request. "provider" is a child the bridge did not deliver.
    const auto cut = [&](const char* reason) {
        auto& row = rows.elements[index];
        rows.truncated = true;
        row.partial = true;
        if (row.partialReason.empty()) row.partialReason = reason;
        else if (row.partialReason != reason) row.partialReason = "limit,provider";
    };
    if (rows.elements[index].identity.clipped) cut("provider");
    if (current->protectedContent) return true;
    for (int child = 0; child < current->children; ++child) {
        if (depth >= maxDepth || native.visited >= limit) {
            cut("limit");
            break;
        }
        const JObject next = bridge_.child(native.vm, node, child);
        if (!next || !visit(native, rows, next, entry, index, depth + 1, maxDepth, limit)) cut("provider");
    }
    return true;
}

Capture JabAdapter::capture(const std::string& windowId, std::optional<std::size_t> scope, int depth, int limit) {
    try {
        ready();
        auto previous = std::move(active_);
        active_.reset();
        NativeCapture next;
        Capture rows;
        try {
            next.handle = parseWindow(windowId);
            JObject selected = 0;
            std::shared_ptr<const Entry> parent;
            if (scope) {
                if (!previous || previous->handle != next.handle) throw stale();
                const auto& entry = resolve(*previous, *scope);
                // The path from the scope to its window stays referenced for later verification.
                for (const auto* step = &entry; step; step = step->parent.get()) {
                    next.owned.push_back(step->node);
                    previous->owned.erase(std::remove(previous->owned.begin(), previous->owned.end(), step->node),
                                          previous->owned.end());
                }
                selected = entry.node;
                parent = entry.parent;
                next.window = previous->window;
                next.pid = previous->pid;
                next.started = previous->started;
                next.vm = previous->vm;
            } else {
                const Root root = window(next.handle, 0);
                next.owned.push_back(root.context);
                next.vm = root.vm;
                next.pid = windowProcess(next.handle);
                const auto started = processStart(next.pid);
                if (!started) throw missing();
                next.started = *started;
                selected = root.context;
            }
            if (previous) retire(*previous);
            previous.reset();
            if (!visit(next, rows, selected, std::move(parent), {}, 0, depth, static_cast<std::size_t>(limit)))
                throw stale();
            if (windowProcess(next.handle) != next.pid || processStart(next.pid) != next.started) throw stale();
        } catch (...) {
            if (previous) retire(*previous);
            retire(next);
            throw;
        }
        active_ = std::move(next);
        return rows;
    } catch (const Silent&) {
        throw silent();
    }
}

Element JabAdapter::info(std::size_t index) {
    try {
        ready();
        if (!active_) throw stale();
        const auto& entry = resolve(*active_, index);
        auto live = inspect(*active_, entry.node);
        if (!live) throw stale();
        return std::move(live->row);
    } catch (const Silent&) {
        throw silent();
    }
}

void JabAdapter::perform(Action action, std::size_t index, const std::string& value, const BeforeMutation& before) {
    if (action != Action::invoke && action != Action::setValue) throw unsupported();
    bool dispatched = false;
    try {
        ready();
        if (!active_) throw stale();
        const auto& capture = *active_;
        const auto& entry = resolve(capture, index);
        const auto live = inspect(capture, entry.node);
        if (!live || entry.identity.clipped || !(entry.identity == live->row.identity)) throw stale();
        if (!live->row.enabled || live->row.offscreen) throw precondition();
        const BeforeMutation validateAtDispatch = [&] {
            if (!parentsMatch(capture, entry) || windowProcess(capture.handle) != capture.pid
                || processStart(capture.pid) != capture.started) throw stale();
            before();
            dispatched = true;
        };
        bool confirmed;
        if (action == Action::invoke) {
            if (live->invoke.empty()) throw unsupported();
            confirmed = bridge_.act(capture.vm, entry.node, live->invoke, validateAtDispatch);
        } else {
            if (live->row.identity.role != "Edit") throw unsupported();
            const auto text = wide(value);
            // The bridge transports at most maxText code units and ends the text at the first NUL.
            if (!live->row.writable || text.size() > maxText || text.find(L'\0') != std::wstring::npos)
                throw precondition();
            confirmed = bridge_.setText(capture.vm, entry.node, text, validateAtDispatch);
        }
        // The bridge answers FALSE for a refusal and for a lost reply alike.
        if (!confirmed) throw Error("ACTION_OUTCOME_UNKNOWN", "The provider did not confirm the action.");
    } catch (const Silent&) {
        // The request may have reached the application: a click that opens a modal dialog returns
        // only when the dialog closes, long after the library stopped waiting.
        if (dispatched)
            throw Error("ACTION_OUTCOME_UNKNOWN", "The JVM did not answer the action. Inspect the target before retrying.");
        throw silent();
    }
}
} // namespace

std::unique_ptr<DesktopAdapter> makeJabAdapter(const std::wstring& library) {
    return std::make_unique<JabAdapter>(library);
}

bool jabDetachWouldBlock() { return detachWouldBlock; }
} // namespace desktop::windows
