#include "windows/msaa_adapter.hpp"
#include "windows/uia_adapter.hpp"

#include <Windows.h>
#include <oleacc.h>
#include <wrl/client.h>

#include <algorithm>
#include <array>
#include <charconv>
#include <deque>
#include <type_traits>
#include <utility>
#include <variant>

namespace desktop::windows {
namespace {
using Microsoft::WRL::ComPtr;
using Accessible = ComPtr<IAccessible>;
constexpr int pageSize = 32;
constexpr UINT textLimit = 1024;
constexpr std::size_t maxIdentityWindows = 256;

Error unavailable() { return {"BACKEND_UNAVAILABLE", "Microsoft Active Accessibility cannot access the input desktop."}; }
Error missing() { return {"WINDOW_NOT_FOUND", "The requested top-level window is unavailable."}; }
Error stale() { return {"STALE_REFERENCE", "Capture a new snapshot and resolve the element again."}; }
Error unsupported() { return {"PATTERN_UNSUPPORTED", "The live MSAA element does not safely support this action."}; }
Error unknown(bool retire = false) {
    return {"ACTION_OUTCOME_UNKNOWN", "The native action was not confirmed. Inspect the target before retrying.", retire};
}

bool timedOut(HRESULT status) {
    return status == static_cast<HRESULT>(0x8001011fUL) || status == HRESULT_FROM_WIN32(ERROR_TIMEOUT);
}

bool ok(HRESULT status) {
    if (timedOut(status)) throw Error("TIMEOUT", "The native Microsoft Active Accessibility call timed out.", true);
    return status == S_OK;
}

class Apartment {
public:
    Apartment() {
        if (FAILED(CoInitializeEx(nullptr, COINIT_MULTITHREADED))) throw unavailable();
    }
    ~Apartment() { CoUninitialize(); }
    Apartment(const Apartment&) = delete;
    Apartment& operator=(const Apartment&) = delete;
};

std::wstring desktopName(HDESK desktop) {
    std::array<wchar_t, 256> buffer{};
    DWORD needed = 0;
    if (!desktop || !GetUserObjectInformationW(desktop, UOI_NAME, buffer.data(), sizeof(buffer), &needed)
        || needed < sizeof(wchar_t) || needed > sizeof(buffer) || needed % sizeof(wchar_t)
        || buffer[needed / sizeof(wchar_t) - 1] != L'\0') throw unavailable();
    return {buffer.data(), needed / sizeof(wchar_t) - 1};
}

void checkDesktop() {
    DWORD session = 0, needed = 0;
    USEROBJECTFLAGS flags{};
    if (!ProcessIdToSessionId(GetCurrentProcessId(), &session) || session == 0
        || !GetUserObjectInformationW(GetProcessWindowStation(), UOI_FLAGS, &flags, sizeof(flags), &needed)
        || !(flags.dwFlags & WSF_VISIBLE)) throw unavailable();
    const auto input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS | DESKTOP_ENUMERATE);
    if (!input) throw unavailable();
    const auto close = [](HDESK handle) { CloseDesktop(handle); };
    const std::unique_ptr<std::remove_pointer_t<HDESK>, decltype(close)> scoped(input, close);
    if (desktopName(input) != desktopName(GetThreadDesktop(GetCurrentThreadId()))) throw unavailable();
}

std::string utf8(const wchar_t* text, int length) {
    if (!length) return {};
    // Replace unpaired UTF-16 surrogates the same way as the Java wire projection.
    std::wstring normalized(text, static_cast<std::size_t>(length));
    for (std::size_t i = 0; i < normalized.size(); ++i) {
        auto& unit = normalized[i];
        if (unit >= 0xd800 && unit <= 0xdbff) {
            if (i + 1 < normalized.size() && normalized[i + 1] >= 0xdc00 && normalized[i + 1] <= 0xdfff) ++i;
            else unit = 0xfffd;
        } else if (unit >= 0xdc00 && unit <= 0xdfff) unit = 0xfffd;
    }
    const int size = WideCharToMultiByte(CP_UTF8, 0, normalized.data(), length, nullptr, 0, nullptr, nullptr);
    std::string result(static_cast<std::size_t>(size), '\0');
    if (size) WideCharToMultiByte(CP_UTF8, 0, normalized.data(), length, result.data(), size, nullptr, nullptr);
    return result;
}

std::wstring wide(const std::string& text) {
    if (text.empty()) return {};
    const int bytes = static_cast<int>(text.size());
    // NDJSON has already validated UTF-8.
    const int length = MultiByteToWideChar(CP_UTF8, 0, text.data(), bytes, nullptr, 0);
    if (!length) throw Error("INVALID_REQUEST", "Invalid value.");
    std::wstring result(static_cast<std::size_t>(length), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), bytes, result.data(), length);
    return result;
}

struct Bstr {
    BSTR value = nullptr;
    ~Bstr() { SysFreeString(value); }
};

struct Variants {
    std::array<VARIANT, pageSize> values{};
    ~Variants() { for (auto& value : values) VariantClear(&value); }
};

VARIANT childArg(LONG child) {
    VARIANT value{};
    value.vt = VT_I4;
    value.lVal = child;
    return value;
}

struct Node {
    Accessible object;
    LONG child = CHILDID_SELF;
    LONG enumeratedId = CHILDID_SELF;
    explicit operator bool() const { return static_cast<bool>(object); }
};

Node fromWindow(HWND window) {
    Node node;
    if (!ok(AccessibleObjectFromWindow(window, static_cast<DWORD>(OBJID_CLIENT),
                                       IID_PPV_ARGS(node.object.GetAddressOf())))) return {};
    return node;
}

HWND sourceWindow(const Node& node) {
    HWND window = nullptr;
    return ok(WindowFromAccessibleObject(node.object.Get(), &window)) ? window : nullptr;
}

int pidOf(HWND window) {
    DWORD pid = 0;
    return GetWindowThreadProcessId(window, &pid) && pid <= INT_MAX ? static_cast<int>(pid) : 0;
}

bool topLevel(HWND window) {
    return IsWindowVisible(window) && GetAncestor(window, GA_PARENT) == GetDesktopWindow();
}

std::string windowId(HWND window) {
    return std::to_string(static_cast<std::uint32_t>(reinterpret_cast<std::uintptr_t>(window)));
}

HWND parseWindow(const std::string& id) {
    std::uint32_t number = 0;
    const auto end = id.data() + id.size();
    const auto parsed = std::from_chars(id.data(), end, number);
    if (id.empty() || id.front() == '0' || parsed.ec != std::errc{} || parsed.ptr != end) throw missing();
    return reinterpret_cast<HWND>(static_cast<std::uintptr_t>(number));
}

std::string className(HWND window) {
    std::array<wchar_t, 256> buffer{};
    return utf8(buffer.data(), GetClassNameW(window, buffer.data(), static_cast<int>(buffer.size())));
}

BOOL CALLBACK collectWindows(HWND window, LPARAM state) {
    auto& handles = *reinterpret_cast<std::vector<HWND>*>(state);
    if (topLevel(window)) handles.push_back(window); // Capacity is reserved before entering User32.
    return handles.size() < 4096;
}

BOOL CALLBACK collectIdentityWindows(HWND window, LPARAM state) {
    auto& handles = *reinterpret_cast<std::vector<HWND>*>(state);
    handles.push_back(window); // Capacity is reserved before entering User32.
    return handles.size() <= maxIdentityWindows;
}

int childCount(const Node& node) {
    if (node.child != CHILDID_SELF) return 0;
    LONG count = 0;
    return ok(node.object->get_accChildCount(&count)) && count >= 0 ? count : -1;
}

struct Children {
    std::vector<Node> nodes;
    bool incomplete = false;
    int obtained = 0;
};

Children children(const Node& parent, int start, int count, int selected = -1) {
    Variants results;
    LONG obtained = 0;
    const auto hr = AccessibleChildren(parent.object.Get(), start, count, results.values.data(), &obtained);
    const bool complete = ok(hr);
    if (FAILED(hr) || obtained < 0 || obtained > count) return {{}, true};
    Children page;
    page.incomplete = !complete || obtained != count;
    page.obtained = obtained;
    for (int i = 0; i < obtained; ++i) {
        if (selected >= 0 && i != selected) continue;
        const auto& item = results.values[static_cast<std::size_t>(i)];
        Node child;
        if (item.vt == VT_DISPATCH && item.pdispVal)
            ok(item.pdispVal->QueryInterface(IID_PPV_ARGS(child.object.GetAddressOf())));
        else if (item.vt == VT_I4 && item.lVal > 0) {
            ComPtr<IDispatch> dispatch;
            const auto found = parent.object->get_accChild(childArg(item.lVal), dispatch.GetAddressOf());
            if (ok(found) && dispatch) ok(dispatch.As(&child.object));
            if (!child) child = {parent.object, item.lVal, item.lVal};
            else child.enumeratedId = item.lVal;
        }
        page.nodes.push_back(std::move(child));
    }
    return page;
}

using Property = HRESULT (STDMETHODCALLTYPE IAccessible::*)(VARIANT, VARIANT*);

int number(const Node& node, Property getter) {
    VARIANT result{};
    const auto hr = (node.object.Get()->*getter)(childArg(node.child), &result);
    const auto value = result.vt == VT_I4 && result.lVal >= 0 ? result.lVal : -1;
    VariantClear(&result);
    return ok(hr) ? value : -1;
}

const char* wireRole(int role) {
    switch (role) {
    case ROLE_SYSTEM_WINDOW: case ROLE_SYSTEM_DIALOG: return "Window";
    case ROLE_SYSTEM_CLIENT: case ROLE_SYSTEM_PANE: case ROLE_SYSTEM_PROPERTYPAGE: return "Pane";
    case ROLE_SYSTEM_LIST: return "List";
    case ROLE_SYSTEM_LISTITEM: return "ListItem";
    case ROLE_SYSTEM_PAGETABLIST: return "Tab";
    case ROLE_SYSTEM_PAGETAB: return "TabItem";
    case ROLE_SYSTEM_TABLE: return "Table";
    case ROLE_SYSTEM_ROW: return "Row";
    case ROLE_SYSTEM_CELL: return "Cell";
    case ROLE_SYSTEM_COLUMNHEADER: case ROLE_SYSTEM_ROWHEADER: return "HeaderItem";
    case ROLE_SYSTEM_OUTLINE: return "Tree";
    case ROLE_SYSTEM_OUTLINEITEM: return "TreeItem";
    case ROLE_SYSTEM_TEXT: return "Edit";
    case ROLE_SYSTEM_STATICTEXT: return "Text";
    case ROLE_SYSTEM_PUSHBUTTON: return "Button";
    case ROLE_SYSTEM_CHECKBUTTON: return "CheckBox";
    case ROLE_SYSTEM_RADIOBUTTON: return "RadioButton";
    case ROLE_SYSTEM_COMBOBOX: return "ComboBox";
    case ROLE_SYSTEM_GROUPING: return "Group";
    case ROLE_SYSTEM_LINK: return "Hyperlink";
    case ROLE_SYSTEM_MENUBAR: return "MenuBar";
    case ROLE_SYSTEM_MENUPOPUP: return "Menu";
    case ROLE_SYSTEM_MENUITEM: return "MenuItem";
    case ROLE_SYSTEM_SLIDER: return "Slider";
    case ROLE_SYSTEM_SCROLLBAR: return "ScrollBar";
    case ROLE_SYSTEM_PROGRESSBAR: return "ProgressBar";
    case ROLE_SYSTEM_SPINBUTTON: return "Spinner";
    case ROLE_SYSTEM_SEPARATOR: return "Separator";
    case ROLE_SYSTEM_TOOLBAR: return "ToolBar";
    case ROLE_SYSTEM_TOOLTIP: return "ToolTip";
    case ROLE_SYSTEM_STATUSBAR: return "StatusBar";
    case ROLE_SYSTEM_GRAPHIC: return "Image";
    default: return "Custom";
    }
}

struct Inspection {
    Element row;
    HWND reportedWindow;
    HWND window;
    int role;
    int state;
    bool masked;
};

bool masksName(int role, int state) {
    return role == ROLE_SYSTEM_TEXT || state < 0 || role < 0 || (state & STATE_SYSTEM_PROTECTED);
}

Inspection inspect(const Node& node, HWND inherited, HWND root, int pid) {
    auto role = number(node, &IAccessible::get_accRole);
    auto state = number(node, &IAccessible::get_accState);
    const auto reported = node.child == CHILDID_SELF ? sourceWindow(node) : nullptr;
    if (reported && (pidOf(reported) != pid || (reported != root && !IsChild(root, reported)))) throw stale();
    const auto window = reported ? reported : inherited;
    Element row;
    row.pid = pid;
    row.identity.className = className(window);
    LONG x = 0, y = 0, width = 0, height = 0;
    if (ok(node.object->accLocation(&x, &y, &width, &height, childArg(node.child))) && width > 0 && height > 0)
        row.bounds = Bounds{x, y, width, height};
    if (!masksName(role, state)) {
        Bstr name;
        if (ok(node.object->get_accName(childArg(node.child), &name.value)) && name.value) {
            const auto length = SysStringLen(name.value);
            if (length) {
                // The provider can change the field's protection state while answering the name query.
                role = number(node, &IAccessible::get_accRole);
                state = number(node, &IAccessible::get_accState);
                if (!masksName(role, state)) {
                    row.identity.clipped = length > textLimit;
                    row.identity.name = utf8(name.value, static_cast<int>(std::min(length, textLimit)));
                }
            }
        }
    }
    row.identity.role = wireRole(role);
    row.identity.nativeRole = role < 0 ? "unknown" : std::to_string(role);
    row.enabled = state >= 0 && !(state & STATE_SYSTEM_UNAVAILABLE);
    row.offscreen = state >= 0 && (state & (STATE_SYSTEM_OFFSCREEN | STATE_SYSTEM_INVISIBLE));
    if (state >= 0) row.selected = (state & STATE_SYSTEM_SELECTED) != 0;
    row.referenceStrength = "weak";
    return {std::move(row), reported, window, role, state, masksName(role, state)};
}

std::vector<BYTE> identityBytes(IAccessible* node) {
    ComPtr<IAccIdentity> identity;
    if (!ok(node->QueryInterface(IID_PPV_ARGS(identity.GetAddressOf()))) || !identity) return {};
    BYTE* bytes = nullptr;
    DWORD length = 0;
    const auto hr = identity->GetIdentityString(CHILDID_SELF, &bytes, &length);
    const std::unique_ptr<BYTE, decltype(&CoTaskMemFree)> buffer(bytes, CoTaskMemFree);
    if (!ok(hr) || !bytes || length == 0 || length > 4096) return {};
    return {bytes, bytes + length};
}

bool opaqueIdentity(IAccPropServices* services, const std::vector<BYTE>& bytes) {
    if (!services) return false;
    const auto size = static_cast<DWORD>(bytes.size());
    HWND window = nullptr;
    HMENU menu = nullptr;
    DWORD object = 0, child = 0;
    // Classify with the system APIs. Accept neither HWND-based nor HMENU-based identities.
    const auto hwnd = services->DecomposeHwndIdentityString(bytes.data(), size, &window, &object, &child);
    if (hwnd != E_INVALIDARG) { ok(hwnd); return false; }
    const auto hmenu = services->DecomposeHmenuIdentityString(bytes.data(), size, &menu, &child);
    if (hmenu != E_INVALIDARG) { ok(hmenu); return false; }
    return true;
}

struct Strong {
    Accessible original;
    std::vector<BYTE> identity;
    HWND window;
};

bool sameObject(const Strong& strong, const Node& current) {
    return current && current.child == CHILDID_SELF && identityBytes(current.object.Get()) == strong.identity;
}

bool hasDefaultAction(const Node& node) {
    Bstr label;
    return ok(node.object->get_accDefaultAction(childArg(CHILDID_SELF), &label.value))
        && label.value && SysStringLen(label.value) != 0;
}

void actions(Inspection& info, const Node& node) {
    if (info.state < 0 || !info.row.enabled || info.row.offscreen || (info.state & STATE_SYSTEM_PROTECTED)) return;
    info.row.defaultAction = hasDefaultAction(node);
    info.row.writable = info.role == ROLE_SYSTEM_TEXT && !(info.state & STATE_SYSTEM_READONLY);
    info.row.select = (info.state & STATE_SYSTEM_SELECTABLE) != 0;
}

std::optional<Strong> prove(const Node& node, Inspection& info, HWND inherited, bool root,
                           HWND top, int pid, IAccPropServices* services) {
    if (node.child != CHILDID_SELF || info.role < 0 || info.state < 0 || info.row.identity.clipped) return {};
    auto bytes = identityBytes(node.object.Get());
    if (bytes.empty() || !opaqueIdentity(services, bytes)) return {};
    HWND dedicated = info.reportedWindow;
    if (root && dedicated != top) return {};
    if (!root && (!dedicated || dedicated == inherited || dedicated == top)) {
        // Some providers report the enclosing HWND even though the full element has its own client object.
        std::vector<HWND> candidates;
        candidates.reserve(maxIdentityWindows + 1);
        EnumChildWindows(top, collectIdentityWindows, reinterpret_cast<LPARAM>(&candidates));
        if (candidates.size() > maxIdentityWindows) return {};
        dedicated = nullptr;
        for (auto candidate : candidates) {
            if (candidate == inherited || pidOf(candidate) != pid || !IsChild(top, candidate)) continue;
            const auto direct = fromWindow(candidate);
            if (!direct || identityBytes(direct.object.Get()) != bytes) continue;
            if (dedicated) return {}; // The identity must select exactly one window.
            dedicated = candidate;
        }
    }
    if (!dedicated) return {};
    Strong strong{node.object, std::move(bytes), dedicated};
    if (!sameObject(strong, fromWindow(strong.window))) return {};
    info.row.referenceStrength = "strong";
    actions(info, node);
    return strong;
}

struct Page {
    int start = 0, count = 0, obtained = 0;
};

struct Path {
    std::shared_ptr<const Path> parent;
    int ordinal, siblings;
    Page page;
    LONG child, enumeratedId;
    HWND window;
    Identity identity;
    std::optional<Strong> strong;
};

struct Cache {
    HWND window;
    int pid;
    std::uint64_t started;
    std::vector<std::shared_ptr<const Path>> paths;
};

struct Live {
    Node node;
    Inspection info;
};

bool sameWindow(const Cache& cache) {
    return topLevel(cache.window) && pidOf(cache.window) == cache.pid && processStart(cache.pid) == cache.started;
}

Live resolve(const Cache& cache, const Path& path) {
    if (!sameWindow(cache)) throw stale();
    auto node = fromWindow(cache.window);
    HWND inherited = cache.window;
    std::vector<const Path*> segments;
    for (auto* part = &path; part; part = part->parent.get()) segments.push_back(part);
    for (auto part = segments.rbegin(); part != segments.rend(); ++part) {
        const auto& captured = **part;
        if (!node) throw stale();
        if (captured.parent) {
            if (childCount(node) != captured.siblings) throw stale();
            // Some Win32 proxies cannot skip to an ordinal they returned in a page.
            const auto& page = captured.page;
            auto found = children(node, page.start, page.count, captured.ordinal - page.start);
            if (found.obtained != page.obtained || found.nodes.size() != 1 || !found.nodes[0]) throw stale();
            node = std::move(found.nodes[0]);
        }
        auto info = inspect(node, inherited, cache.window, cache.pid);
        if (node.child != captured.child || node.enumeratedId != captured.enumeratedId
            || info.window != captured.window || info.role < 0 || info.state < 0
            || info.row.identity.clipped || !(captured.identity == info.row.identity)) throw stale();
        if (captured.strong && (!sameObject(*captured.strong, node)
            || !sameObject(*captured.strong, fromWindow(captured.strong->window))
            || !sameObject(*captured.strong, Node{captured.strong->original}))) throw stale();
        if (part + 1 == segments.rend()) {
            if (captured.strong) {
                info.row.referenceStrength = "strong";
                actions(info, node);
            }
            return {std::move(node), std::move(info)};
        }
        if (info.masked) throw stale();
        inherited = info.window;
    }
    throw stale();
}

void partial(Capture& result, Element& row, const char* reason) {
    result.truncated = true;
    if (row.partial && row.partialReason != reason) row.partialReason = "limit,provider";
    else row.partialReason = reason;
    row.partial = true;
}

class MsaaAdapter final : public DesktopAdapter {
public:
    explicit MsaaAdapter(AllowedProcess trustedProvider) : trustedProvider_(std::move(trustedProvider)) {}

    const char* backend() const override { return "MSAA"; }
    Availability availability() override {
        Availability result;
        try { checkDesktop(); }
        catch (const Error& error) { result.available = false; result.reason = error.what(); }
        return result;
    }

    std::vector<Window> windows() override {
        checkDesktop();
        std::vector<HWND> handles;
        handles.reserve(4096);
        EnumWindows(collectWindows, reinterpret_cast<LPARAM>(&handles));
        std::vector<Window> result;
        for (auto hwnd : handles) {
            const int pid = pidOf(hwnd);
            if (pid <= 0 || !topLevel(hwnd)) continue;
            std::array<wchar_t, textLimit + 1> text{};
            const auto length = GetWindowTextW(hwnd, text.data(), static_cast<int>(text.size()));
            const HWND owner = GetWindow(hwnd, GW_OWNER);
            if (pidOf(hwnd) == pid)
                result.push_back({windowId(hwnd), pid, utf8(text.data(), length), owner ? windowId(owner) : ""});
        }
        return result;
    }

    Capture capture(const std::string& id, std::optional<std::size_t> scope, int depthLimit, int limit) override {
        checkDesktop();
        const auto window = parseWindow(id);
        const int pid = pidOf(window);
        const auto started = processStart(pid);
        if (!topLevel(window) || pid <= 0 || !started) throw scope ? stale() : missing();
        Cache next{window, pid, *started, {}};
        const auto trusted = trustedProvider_(pid);
        if (trusted && !propertyServices_)
            ok(CoCreateInstance(__uuidof(CAccPropServices), nullptr, CLSCTX_INPROC_SERVER,
                                IID_PPV_ARGS(propertyServices_.GetAddressOf())));
        Capture result;
        std::deque<Work> queue;
        int scheduled = 1, examined = 0;
        if (scope) {
            const auto path = entry(*scope);
            if (active_->window != window) throw stale();
            auto live = resolve(*active_, *path);
            next.started = active_->started;
            queue.emplace_back(Pending{std::move(live.node), path->parent, {},
                path->ordinal, path->siblings, path->page, 0});
        } else {
            auto node = fromWindow(window);
            if (!node) throw missing();
            queue.emplace_back(Pending{std::move(node), {}, {}, 0, 0, {}, 0});
        }
        while (!queue.empty()) {
            auto work = std::move(queue.front());
            queue.pop_front();
            if (auto* branch = std::get_if<Expand>(&work)) {
                const int requested = std::min({pageSize, limit - scheduled, 2 * limit - examined,
                                                branch->count - branch->start});
                auto& row = result.elements[branch->index];
                if (!requested) { partial(result, row, "limit"); continue; }
                examined += requested;
                auto page = children(branch->node, branch->start, requested);
                if (page.incomplete) partial(result, row, "provider");
                const Page address{branch->start, requested, page.obtained};
                for (auto& child : page.nodes) {
                    if (child) {
                        queue.emplace_back(Pending{std::move(child), branch->path, branch->index,
                            branch->start, branch->count, address, branch->depth});
                        ++scheduled;
                    } else partial(result, row, "provider");
                    ++branch->start;
                }
                if (!page.incomplete && branch->start < branch->count) queue.emplace_back(std::move(*branch));
                continue;
            }
            auto pending = std::get<Pending>(std::move(work));
            const auto inherited = pending.path ? pending.path->window : window;
            Inspection live = [&] {
                try { return inspect(pending.node, inherited, window, pid); }
                catch (const Error& error) {
                    if (std::string_view(error.code) != "STALE_REFERENCE" || !pending.parent) throw;
                    return Inspection{{}, nullptr, nullptr, -1, -1, true};
                }
            }();
            if (!live.window) {
                partial(result, result.elements[*pending.parent], "provider");
                continue;
            }
            auto strong = trusted && propertyServices_
                ? prove(pending.node, live, inherited, !pending.path, window, pid, propertyServices_.Get()) : std::nullopt;
            auto path = std::make_shared<Path>(Path{std::move(pending.path), pending.ordinal, pending.siblings, pending.page,
                pending.node.child, pending.node.enumeratedId, live.window, live.row.identity, std::move(strong)});
            next.paths.push_back(path);
            live.row.parent = pending.parent;
            const auto index = result.elements.size();
            result.elements.push_back(std::move(live.row));
            auto& row = result.elements[index];
            if (row.identity.clipped) partial(result, row, "provider");
            if (live.masked) {
                if (live.role < 0 || live.state < 0) partial(result, row, "provider");
                continue;
            }
            const auto count = childCount(pending.node);
            if (count < 0) partial(result, row, "provider");
            else if (count > 0 && pending.depth == depthLimit) partial(result, row, "limit");
            else if (count > 0) queue.emplace_back(Expand{std::move(pending.node), path, index, 0, count, pending.depth + 1});
        }
        if (!sameWindow(next)) throw stale();
        active_ = std::move(next);
        return result;
    }

    Element info(std::size_t index) override {
        checkDesktop();
        const auto path = entry(index);
        return resolve(*active_, *path).info.row;
    }

    void perform(Action action, std::size_t index, const std::string& value, const BeforeMutation& before) override {
        checkDesktop();
        const auto path = entry(index);
        if (!path->strong) throw unsupported();
        const auto& strong = *path->strong;
        auto live = resolve(*active_, *path);
        if (!live.info.row.enabled || live.info.row.offscreen)
            throw Error("PRECONDITION_FAILED", "The current element state does not permit the action.");
        const auto& row = live.info.row;
        if (!(action == Action::defaultAction && row.defaultAction) && !(action == Action::setValue && row.writable)
            && !(action == Action::select && row.select)) throw unsupported();
        Bstr text;
        if (action == Action::setValue) {
            const auto units = wide(value);
            text.value = SysAllocStringLen(units.data(), static_cast<UINT>(units.size()));
            if (!text.value) throw std::bad_alloc();
        }
        const Node retained{strong.original};
        if (action == Action::defaultAction && !hasDefaultAction(retained)) throw unsupported();
        if (!sameObject(strong, retained)
            || number(retained, &IAccessible::get_accRole) != live.info.role) throw stale();
        const int state = number(retained, &IAccessible::get_accState);
        if (state < 0 || (state & (STATE_SYSTEM_UNAVAILABLE | STATE_SYSTEM_OFFSCREEN | STATE_SYSTEM_INVISIBLE
                                  | STATE_SYSTEM_PROTECTED))
            || (action == Action::setValue && (state & STATE_SYSTEM_READONLY))
            || (action == Action::select && !(state & STATE_SYSTEM_SELECTABLE)))
            throw Error("PRECONDITION_FAILED", "The current element state does not permit the action.");
        if (!sameWindow(*active_) || pidOf(strong.window) != active_->pid
            || (strong.window != active_->window && !IsChild(active_->window, strong.window))) throw stale();
        before();
        // Never mutate through a re-resolved child number or a replacement COM object.
        auto* original = strong.original.Get();
        const auto self = childArg(CHILDID_SELF);
        HRESULT status;
        if (action == Action::defaultAction) status = original->accDoDefaultAction(self);
        else if (action == Action::select) status = original->accSelect(SELFLAG_TAKESELECTION, self);
        else status = original->put_accValue(self, text.value);
        if (status != S_OK) throw unknown(timedOut(status));
    }

    void clear() noexcept override { active_.reset(); }

private:
    struct Pending {
        Node node;
        std::shared_ptr<const Path> path;
        std::optional<std::size_t> parent;
        int ordinal, siblings;
        Page page;
        int depth;
    };
    struct Expand {
        Node node;
        std::shared_ptr<const Path> path;
        std::size_t index;
        int start, count, depth;
    };
    using Work = std::variant<Pending, Expand>;

    std::shared_ptr<const Path> entry(std::size_t index) const {
        if (!active_ || index >= active_->paths.size()) throw stale();
        return active_->paths[index];
    }

    Apartment apartment_;
    AllowedProcess trustedProvider_;
    ComPtr<IAccPropServices> propertyServices_;
    std::optional<Cache> active_;
};
} // namespace

std::unique_ptr<DesktopAdapter> makeMsaaAdapter(AllowedProcess trustedProvider) {
    return std::make_unique<MsaaAdapter>(std::move(trustedProvider));
}
} // namespace desktop::windows
