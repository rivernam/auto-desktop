#include "windows/uia_adapter.hpp"

#include <Windows.h>
#include <ole2.h>
#include <UIAutomation.h>
#include <wrl/client.h>

#include <array>
#include <charconv>

namespace desktop::windows {
namespace {
using Microsoft::WRL::ComPtr;
using UiaElement = IUIAutomationElement;
using ElementPtr = ComPtr<UiaElement>;
using ValuePtr = ComPtr<IUIAutomationValuePattern>;

constexpr HRESULT uiaTimeout = static_cast<HRESULT>(0x80131505UL);
constexpr HRESULT rpcTimeout = static_cast<HRESULT>(0x8001011fUL);

struct ComFailure {
    HRESULT status;
};

bool timedOut(HRESULT status) {
    return status == uiaTimeout || status == rpcTimeout || status == HRESULT_FROM_WIN32(ERROR_TIMEOUT);
}

void check(HRESULT status) {
    if (timedOut(status)) throw Error("TIMEOUT", "The UI Automation provider timed out.", true);
    if (FAILED(status)) throw ComFailure{status};
}

Error stale() { return {"STALE_REFERENCE", "The captured element or window is no longer current."}; }
Error missing() { return {"WINDOW_NOT_FOUND", "The requested top-level window is unavailable."}; }
Error unavailable() { return {"BACKEND_UNAVAILABLE", "UI Automation could not access the interactive desktop."}; }
Error precondition() { return {"PRECONDITION_FAILED", "The current element state does not permit the action."}; }
Error unsupported() { return {"PATTERN_UNSUPPORTED", "The live element does not provide the required pattern."}; }

class Apartment {
public:
    Apartment() { check(CoInitializeEx(nullptr, COINIT_MULTITHREADED)); }
    ~Apartment() { CoUninitialize(); }
    Apartment(const Apartment&) = delete;
    Apartment& operator=(const Apartment&) = delete;
};

class Bstr {
public:
    Bstr() = default;
    explicit Bstr(const std::wstring& text)
        : value(SysAllocStringLen(text.data(), static_cast<UINT>(text.size()))) {
        if (!value) throw std::bad_alloc();
    }
    ~Bstr() { SysFreeString(value); }
    Bstr(const Bstr&) = delete;
    Bstr& operator=(const Bstr&) = delete;
    BSTR value = nullptr;
};

struct RuntimeArray {
    SAFEARRAY* value = nullptr;
    ~RuntimeArray() { if (value) SafeArrayDestroy(value); }
    RuntimeArray() = default;
    RuntimeArray(const RuntimeArray&) = delete;
    RuntimeArray& operator=(const RuntimeArray&) = delete;
};

class ArrayData {
public:
    explicit ArrayData(SAFEARRAY* array) : array_(array) { check(SafeArrayAccessData(array_, &data)); }
    ~ArrayData() { SafeArrayUnaccessData(array_); }
    ArrayData(const ArrayData&) = delete;
    ArrayData& operator=(const ArrayData&) = delete;
    void* data = nullptr;

private:
    SAFEARRAY* array_;
};

struct HandleCloser {
    void operator()(HANDLE value) const { CloseHandle(value); }
};

template<class T, class Interface>
T property(Interface* object, HRESULT (STDMETHODCALLTYPE Interface::*getter)(T*)) {
    T result{};
    check((object->*getter)(&result));
    return result;
}

std::string utf8(const wchar_t* text, int length) {
    if (length == 0) return {};
    const int bytes = WideCharToMultiByte(CP_UTF8, 0, text, length, nullptr, 0, nullptr, nullptr);
    if (!bytes) throw ComFailure{E_FAIL};
    std::string result(static_cast<std::size_t>(bytes), '\0');
    if (!WideCharToMultiByte(CP_UTF8, 0, text, length, result.data(), bytes, nullptr, nullptr))
        throw ComFailure{E_FAIL};
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

std::string label(UiaElement* node, HRESULT (STDMETHODCALLTYPE UiaElement::*getter)(BSTR*), bool& clipped) {
    Bstr text;
    check((node->*getter)(&text.value));
    auto length = SysStringLen(text.value);
    if (length > 256) {
        clipped = true;
        const auto edge = text.value[255];
        length = edge >= 0xd800 && edge <= 0xdbff ? 255 : 256;
    }
    return utf8(text.value, static_cast<int>(length));
}

const char* role(int type) {
    static constexpr std::array<const char*, 41> roles{
        "Button", "Calendar", "CheckBox", "ComboBox", "Edit", "Hyperlink", "Image", "ListItem", "List",
        "Menu", "MenuBar", "MenuItem", "ProgressBar", "RadioButton", "ScrollBar", "Slider", "Spinner",
        "StatusBar", "Tab", "TabItem", "Text", "ToolBar", "ToolTip", "Tree", "TreeItem", "Custom",
        "Group", "Thumb", "DataGrid", "DataItem", "Document", "SplitButton", "Window", "Pane",
        "Header", "HeaderItem", "Table", "TitleBar", "Separator", "SemanticZoom", "AppBar"};
    return type >= 50000 && type <= 50040 ? roles[static_cast<std::size_t>(type - 50000)] : "Custom";
}

std::vector<int> runtimeId(UiaElement* node) {
    RuntimeArray array;
    check(node->GetRuntimeId(&array.value));
    if (!array.value || SafeArrayGetDim(array.value) != 1 || SafeArrayGetElemsize(array.value) != sizeof(int))
        throw ComFailure{E_FAIL};
    VARTYPE type{};
    long lower{}, upper{};
    check(SafeArrayGetVartype(array.value, &type));
    check(SafeArrayGetLBound(array.value, 1, &lower));
    check(SafeArrayGetUBound(array.value, 1, &upper));
    const auto size = static_cast<long long>(upper) - lower + 1;
    if (type != VT_I4 || size < 0 || size > 4096) throw ComFailure{E_FAIL};
    if (size == 0) return {};
    ArrayData data(array.value);
    const auto* values = static_cast<const int*>(data.data);
    if (!values) throw ComFailure{E_FAIL};
    return {values, values + size};
}

template<class Pattern>
ComPtr<Pattern> pattern(UiaElement* node, PATTERNID id) {
    ComPtr<Pattern> result;
    const auto status = node->GetCurrentPatternAs(id, IID_PPV_ARGS(result.GetAddressOf()));
    if (status == UIA_E_NOTSUPPORTED || status == E_NOINTERFACE) return {};
    check(status);
    return result;
}

bool protectsChildren(UiaElement* node) {
    return property(node, &UiaElement::get_CurrentIsPassword)
        || property(node, &UiaElement::get_CurrentControlType) == UIA_EditControlTypeId
        || pattern<IUIAutomationValuePattern>(node, UIA_ValuePatternId);
}

struct Inspection {
    Element row;
    bool protectedContent;
};

Inspection inspect(UiaElement* node) {
    const auto invoke = pattern<IUIAutomationInvokePattern>(node, UIA_InvokePatternId);
    const auto value = pattern<IUIAutomationValuePattern>(node, UIA_ValuePatternId);
    const auto type = property(node, &UiaElement::get_CurrentControlType);
    const bool protect = property(node, &UiaElement::get_CurrentIsPassword) || type == UIA_EditControlTypeId || value;
    Element row;
    row.identity.role = role(type);
    if (!protect) row.identity.name = label(node, &UiaElement::get_CurrentName, row.identity.clipped);
    row.identity.automationId = label(node, &UiaElement::get_CurrentAutomationId, row.identity.clipped);
    row.identity.className = label(node, &UiaElement::get_CurrentClassName, row.identity.clipped);
    row.enabled = property(node, &UiaElement::get_CurrentIsEnabled) != FALSE;
    row.offscreen = property(node, &UiaElement::get_CurrentIsOffscreen) != FALSE;
    row.invoke = static_cast<bool>(invoke);
    row.writable = value && !property(value.Get(), &IUIAutomationValuePattern::get_CurrentIsReadOnly);
    const auto rect = property(node, &UiaElement::get_CurrentBoundingRectangle);
    if (rect.right > rect.left && rect.bottom > rect.top) {
        row.bounds = Bounds{rect.left, rect.top, static_cast<long long>(rect.right) - rect.left,
                            static_cast<long long>(rect.bottom) - rect.top};
    }
    row.pid = property(node, &UiaElement::get_CurrentProcessId);
    return {std::move(row), protect};
}

bool interactive() {
    DWORD session = 0;
    DWORD needed = 0;
    USEROBJECTFLAGS flags{};
    return ProcessIdToSessionId(GetCurrentProcessId(), &session) && session != 0
        && GetUserObjectInformationW(GetProcessWindowStation(), UOI_FLAGS, &flags, sizeof(flags), &needed)
        && (flags.dwFlags & WSF_VISIBLE);
}

std::uint32_t windowNumber(UIA_HWND handle) {
    return static_cast<std::uint32_t>(reinterpret_cast<std::uintptr_t>(handle));
}

HWND parseWindow(const std::string& id) {
    std::uint32_t value = 0;
    const auto end = id.data() + id.size();
    const auto result = std::from_chars(id.data(), end, value);
    if (id.empty() || id.front() == '0' || result.ec != std::errc{} || result.ptr != end) throw missing();
    return reinterpret_cast<HWND>(static_cast<std::uintptr_t>(value));
}

bool windowProcess(HWND handle, int pid) {
    DWORD live = 0;
    return pid > 0 && GetWindowThreadProcessId(handle, &live) && live == static_cast<DWORD>(pid);
}

class UiaAdapter final : public DesktopAdapter {
public:
    bool available() override;
    std::vector<Window> windows() override;
    Capture capture(const std::string& windowId, std::optional<std::size_t> scope, int depth, int limit) override;
    Element info(std::size_t index) override;
    void perform(Action action, std::size_t index, const std::string& value, const BeforeMutation& before) override;
    void clear() noexcept override { active_.reset(); }

private:
    struct Client {
        Apartment apartment;
        ComPtr<IUIAutomation> automation;
        ComPtr<IUIAutomationTreeWalker> walker;

        Client() {
            check(CoCreateInstance(__uuidof(CUIAutomation), nullptr, CLSCTX_INPROC_SERVER,
                                   IID_PPV_ARGS(automation.GetAddressOf())));
            check(automation->get_ControlViewWalker(walker.GetAddressOf()));
            if (!walker) throw ComFailure{E_FAIL};
        }
    };

    struct Entry {
        ElementPtr node;
        std::shared_ptr<const Entry> parent;
        int pid;
        std::vector<int> runtime;
        Identity identity;
    };

    struct NativeCapture {
        HWND handle = nullptr;
        std::uint64_t started = 0;
        std::shared_ptr<const Entry> window;
        std::vector<std::shared_ptr<const Entry>> entries;
        std::size_t visited = 0;
    };

    // Destruction order releases the snapshot before the walker and the MTA.
    std::optional<Client> client_;
    std::optional<NativeCapture> active_;

    ElementPtr desktop();
    ElementPtr window(HWND handle, UiaElement* root);
    ElementPtr walk(UiaElement* element, HRESULT (STDMETHODCALLTYPE IUIAutomationTreeWalker::*step)
                    (UiaElement*, UiaElement**));
    bool same(UiaElement* a, UiaElement* b);
    static bool identityMatches(const Entry& entry, UiaElement* live);
    bool parentsMatch(const NativeCapture& capture, const Entry& selected);
    const Entry& resolve(const NativeCapture& capture, std::size_t index, UiaElement* root, bool scope = false);
    void visit(NativeCapture& native, Capture& rows, ElementPtr node, std::shared_ptr<const Entry> parent,
               std::optional<std::size_t> parentIndex, int depth, int maxDepth, std::size_t limit);
};

ElementPtr UiaAdapter::desktop() {
    if (!interactive()) throw unavailable();
    try {
        if (!client_) client_.emplace();
        ElementPtr root;
        check(client_->automation->GetRootElement(root.GetAddressOf()));
        if (root) return root;
    } catch (const ComFailure&) {}
    throw unavailable();
}

ElementPtr UiaAdapter::walk(UiaElement* element, HRESULT (STDMETHODCALLTYPE IUIAutomationTreeWalker::*step)
                            (UiaElement*, UiaElement**)) {
    ElementPtr result;
    check((client_->walker.Get()->*step)(element, result.GetAddressOf()));
    return result;
}

bool UiaAdapter::same(UiaElement* a, UiaElement* b) {
    BOOL result = FALSE;
    check(client_->automation->CompareElements(a, b, &result));
    return result != FALSE;
}

ElementPtr UiaAdapter::window(HWND handle, UiaElement* root) {
    try {
        ElementPtr result;
        check(client_->automation->ElementFromHandle(handle, result.GetAddressOf()));
        if (!result || windowNumber(property(result.Get(), &UiaElement::get_CurrentNativeWindowHandle))
                       != windowNumber(handle)) throw missing();
        auto parent = walk(result.Get(), &IUIAutomationTreeWalker::GetParentElement);
        if (parent && same(parent.Get(), root)) return result;
    } catch (const ComFailure&) {}
    throw missing();
}

bool UiaAdapter::available() {
    try {
        const auto root = desktop();
        const auto child = walk(root.Get(), &IUIAutomationTreeWalker::GetFirstChildElement);
        return !runtimeId(root.Get()).empty();
    } catch (const ComFailure&) {
        return false;
    } catch (const Error& error) {
        if (error.retire) throw;
        return false;
    }
}

std::vector<Window> UiaAdapter::windows() {
    for (int attempt = 0; attempt < 2; ++attempt) {
        try {
            const auto root = desktop();
            std::vector<Window> result;
            int visited = 0;
            auto node = walk(root.Get(), &IUIAutomationTreeWalker::GetFirstChildElement);
            while (node) {
                if (++visited > 4096) throw precondition();
                const auto handle = windowNumber(property(node.Get(), &UiaElement::get_CurrentNativeWindowHandle));
                const int pid = property(node.Get(), &UiaElement::get_CurrentProcessId);
                if (handle && pid > 0) {
                    bool clipped = false;
                    result.push_back({std::to_string(handle), pid, protectsChildren(node.Get())
                        ? "" : label(node.Get(), &UiaElement::get_CurrentName, clipped)});
                }
                node = walk(node.Get(), &IUIAutomationTreeWalker::GetNextSiblingElement);
            }
            return result;
        } catch (const ComFailure& failure) {
            if (failure.status != UIA_E_ELEMENTNOTAVAILABLE) throw unavailable();
        }
    }
    throw stale();
}

bool UiaAdapter::identityMatches(const Entry& entry, UiaElement* live) {
    return property(live, &UiaElement::get_CurrentProcessId) == entry.pid && runtimeId(live) == entry.runtime;
}

bool UiaAdapter::parentsMatch(const NativeCapture& capture, const Entry& selected) {
    const auto* expected = &selected;
    ElementPtr child = selected.node;
    while (expected->parent) {
        auto parent = walk(child.Get(), &IUIAutomationTreeWalker::GetParentElement);
        expected = expected->parent.get();
        if (!parent || !same(expected->node.Get(), parent.Get()) || !identityMatches(*expected, parent.Get())
            || protectsChildren(parent.Get())) return false;
        child = std::move(parent);
    }
    return expected == capture.window.get();
}

const UiaAdapter::Entry& UiaAdapter::resolve(const NativeCapture& capture, std::size_t index, UiaElement* root,
                                            bool scope) {
    if (index >= capture.entries.size()) throw stale();
    const auto& entry = *capture.entries[index];
    try {
        const auto live = window(capture.handle, root);
        const auto& anchor = *capture.window;
        if (!windowProcess(capture.handle, anchor.pid) || processStart(anchor.pid) != capture.started
            || !same(live.Get(), anchor.node.Get()) || !identityMatches(anchor, live.Get())
            || !identityMatches(entry, entry.node.Get()) || !parentsMatch(capture, entry)) throw stale();
        if (scope && !(entry.identity == inspect(entry.node.Get()).row.identity)) throw stale();
        return entry;
    } catch (const ComFailure&) {
        throw stale();
    } catch (const Error& error) {
        if (error.retire) throw;
        throw stale();
    }
}

void UiaAdapter::visit(NativeCapture& native, Capture& rows, ElementPtr node, std::shared_ptr<const Entry> parent,
                       std::optional<std::size_t> parentIndex, int depth, int maxDepth, std::size_t limit) {
    ++native.visited;
    auto current = inspect(node.Get());
    if (current.row.pid <= 0) throw stale();
    auto runtime = runtimeId(node.Get());
    // A valid but empty ID cannot be revalidated, so omit this branch and report truncation.
    if (runtime.empty()) {
        if (depth == 0) throw stale();
        rows.truncated = true;
        return;
    }
    auto entry = std::make_shared<Entry>(Entry{std::move(node), std::move(parent), current.row.pid,
                                                std::move(runtime), current.row.identity});
    if (!entry->parent) native.window = entry;
    const auto index = native.entries.size();
    native.entries.push_back(entry);
    current.row.parent = parentIndex;
    rows.truncated = rows.truncated || current.row.identity.clipped;
    rows.elements.push_back(std::move(current.row));
    if (current.protectedContent) return;
    auto child = walk(entry->node.Get(), &IUIAutomationTreeWalker::GetFirstChildElement);
    while (child) {
        if (depth >= maxDepth || native.visited >= limit) {
            rows.truncated = true;
            return;
        }
        visit(native, rows, child, entry, index, depth + 1, maxDepth, limit);
        child = walk(child.Get(), &IUIAutomationTreeWalker::GetNextSiblingElement);
    }
}

Capture UiaAdapter::capture(const std::string& windowId, std::optional<std::size_t> scope, int depth, int limit) {
    auto previous = std::move(active_);
    active_.reset();
    NativeCapture next;
    next.handle = parseWindow(windowId);
    const auto root = desktop();
    ElementPtr selected;
    std::shared_ptr<const Entry> parent;
    if (scope) {
        if (!previous || previous->handle != next.handle) throw stale();
        const auto& entry = resolve(*previous, *scope, root.Get(), true);
        selected = entry.node;
        parent = entry.parent;
        next.window = previous->window;
        next.started = previous->started;
    } else {
        selected = window(next.handle, root.Get());
        int pid;
        try {
            pid = property(selected.Get(), &UiaElement::get_CurrentProcessId);
        } catch (const ComFailure&) {
            throw missing();
        }
        if (!windowProcess(next.handle, pid)) throw missing();
        const auto started = processStart(pid);
        if (!started) throw missing();
        next.started = *started;
    }
    previous.reset();
    Capture rows;
    try {
        visit(next, rows, std::move(selected), std::move(parent), {}, 0, depth, static_cast<std::size_t>(limit));
        if (!windowProcess(next.handle, next.window->pid) || processStart(next.window->pid) != next.started)
            throw stale();
    } catch (const ComFailure&) {
        throw stale();
    }
    active_ = std::move(next);
    return rows;
}

Element UiaAdapter::info(std::size_t index) {
    if (!active_) throw stale();
    try {
        const auto root = desktop();
        const auto& entry = resolve(*active_, index, root.Get());
        return inspect(entry.node.Get()).row;
    } catch (const ComFailure&) {
        throw stale();
    }
}

void UiaAdapter::perform(Action action, std::size_t index, const std::string& value, const BeforeMutation& before) {
    if (!active_) throw stale();
    try {
        const auto root = desktop();
        const auto& entry = resolve(*active_, index, root.Get());
        auto* node = entry.node.Get();
        const auto live = inspect(node).row;
        if (entry.identity.clipped || !(entry.identity == live.identity) || entry.pid != live.pid) throw stale();
        if (!live.enabled || live.offscreen) throw precondition();
        const auto validateAtDispatch = [&] {
            if (!identityMatches(entry, node) || !parentsMatch(*active_, entry)
                || !windowProcess(active_->handle, active_->window->pid)
                || processStart(active_->window->pid) != active_->started) throw stale();
            before();
        };
        HRESULT status;
        if (action == Action::invoke) {
            const auto invoke = pattern<IUIAutomationInvokePattern>(node, UIA_InvokePatternId);
            if (!invoke) throw unsupported();
            validateAtDispatch();
            status = invoke->Invoke();
        } else {
            const auto writable = pattern<IUIAutomationValuePattern>(node, UIA_ValuePatternId);
            if (!writable) throw unsupported();
            if (property(writable.Get(), &IUIAutomationValuePattern::get_CurrentIsReadOnly)) throw precondition();
            const Bstr text(wide(value));
            validateAtDispatch();
            status = writable->SetValue(text.value);
        }
        if (FAILED(status))
            throw Error("ACTION_OUTCOME_UNKNOWN", "The provider did not confirm the action.", timedOut(status));
    } catch (const ComFailure&) {
        throw stale();
    }
}
} // namespace

std::optional<std::uint64_t> processStart(int pid) {
    if (pid <= 0) return {};
    const std::unique_ptr<void, HandleCloser> process(
        OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, FALSE, static_cast<DWORD>(pid)));
    if (!process || WaitForSingleObject(process.get(), 0) != WAIT_TIMEOUT) return {};
    FILETIME start{}, exit{}, kernel{}, user{};
    if (!GetProcessTimes(process.get(), &start, &exit, &kernel, &user)) return {};
    return (static_cast<std::uint64_t>(start.dwHighDateTime) << 32) | start.dwLowDateTime;
}

std::string sessionToken() {
    GUID guid{};
    if (FAILED(CoCreateGuid(&guid))) throw std::runtime_error("Could not allocate a session token.");
    wchar_t text[39]{};
    if (StringFromGUID2(guid, text, 39) != 39) throw std::runtime_error("Could not format a session token.");
    return utf8(text + 1, 36);
}

std::unique_ptr<DesktopAdapter> makeAdapter() { return std::make_unique<UiaAdapter>(); }
} // namespace desktop::windows
