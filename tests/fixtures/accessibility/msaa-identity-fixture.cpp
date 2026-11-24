#include <Windows.h>
#include <oleacc.h>
#include <oleidl.h>

#include <filesystem>
#include <fstream>
#include <string>

namespace {
std::filesystem::path stateDirectory;
int role = ROLE_SYSTEM_PUSHBUTTON;
bool swapInProgress = false;
int calls = 0;
HWND rootWindow, targetWindow;

void publish(const wchar_t* file, const std::wstring& text) {
    const auto output = stateDirectory / file;
    auto temporary = output;
    temporary += L".pending";
    std::ofstream stream(temporary, std::ios::binary);
    const int length = static_cast<int>(text.size());
    int bytes = WideCharToMultiByte(CP_UTF8, 0, text.data(), length, nullptr, 0, nullptr, nullptr);
    std::string utf8(static_cast<std::size_t>(bytes), '\0');
    if (bytes) WideCharToMultiByte(CP_UTF8, 0, text.data(), length, utf8.data(), bytes, nullptr, nullptr);
    stream.write(utf8.data(), bytes);
    stream.close();
    MoveFileExW(temporary.c_str(), output.c_str(), MOVEFILE_REPLACE_EXISTING);
}

bool self(VARIANT child) { return child.vt == VT_I4 && child.lVal == CHILDID_SELF; }

class Provider;
Provider* active;
Provider* container;

class Provider final : public IAccessible, public IAccIdentity, public IOleWindow {
public:
    explicit Provider(HWND window, bool containsTarget = false) : window_(window), containsTarget_(containsTarget) {}
    void retire() { retired_ = true; }
    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID id, void** out) override {
        if (id == IID_IUnknown || id == IID_IDispatch || id == __uuidof(IAccessible))
            *out = static_cast<IAccessible*>(this);
        else if (id == __uuidof(IAccIdentity)) *out = static_cast<IAccIdentity*>(this);
        else if (id == __uuidof(IOleWindow)) *out = static_cast<IOleWindow*>(this);
        else { *out = nullptr; return E_NOINTERFACE; }
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override {
        const auto remaining = --refs_;
        if (!remaining) delete this;
        return remaining;
    }

    HRESULT STDMETHODCALLTYPE GetIdentityString(DWORD child, BYTE** bytes, DWORD* count) override {
        if (child != CHILDID_SELF) return E_INVALIDARG;
        *count = 0;
        *bytes = nullptr;
        if (retired_) return CO_E_OBJNOTCONNECTED;
        // The replacement deliberately reports the same bytes and UI metadata on the same HWND.
        *count = 4;
        *bytes = static_cast<BYTE*>(CoTaskMemAlloc(*count));
        if (!*bytes) return E_OUTOFMEMORY;
        (*bytes)[0] = containsTarget_ ? 19 : 11;
        (*bytes)[1] = 29; (*bytes)[2] = 74; (*bytes)[3] = 51;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE GetWindow(HWND* window) override { *window = window_; return S_OK; }
    HRESULT STDMETHODCALLTYPE ContextSensitiveHelp(BOOL) override { return E_NOTIMPL; }

    HRESULT STDMETHODCALLTYPE get_accChildCount(LONG* count) override { *count = containsTarget_ ? 1 : 0; return S_OK; }
    HRESULT STDMETHODCALLTYPE get_accName(VARIANT child, BSTR* name) override {
        if (!self(child)) return E_INVALIDARG;
        const auto protect = stateDirectory / L"protect-during-name";
        if (!containsTarget_ && std::filesystem::exists(protect)) {
            std::filesystem::remove(protect);
            protected_ = true;
            *name = SysAllocString(L"synthetic protected name");
            return *name ? S_OK : E_OUTOFMEMORY;
        }
        *name = SysAllocString(containsTarget_ ? L"MSAA identity container"
            : role == ROLE_SYSTEM_TEXT ? L"fixture edit name" : L"MSAA identity target");
        return *name ? S_OK : E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE get_accRole(VARIANT child, VARIANT* value) override {
        if (!self(child)) return E_INVALIDARG;
        const auto pause = stateDirectory / L"delay-role";
        if (!containsTarget_ && std::filesystem::exists(pause)) {
            std::filesystem::remove(pause);
            publish(L"role-delayed", L"started");
            Sleep(11500);
            publish(L"role-delayed", L"finished");
        }
        value->vt = VT_I4;
        value->lVal = containsTarget_ ? ROLE_SYSTEM_CLIENT : role;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_accState(VARIANT child, VARIANT* state) override {
        if (!self(child)) return E_INVALIDARG;
        state->vt = VT_I4;
        state->lVal = !containsTarget_ && role == ROLE_SYSTEM_LISTITEM ? STATE_SYSTEM_SELECTABLE : 0;
        if (selected_) state->lVal |= STATE_SYSTEM_SELECTED;
        if (disabled_) state->lVal |= STATE_SYSTEM_UNAVAILABLE;
        if (protected_) state->lVal |= STATE_SYSTEM_PROTECTED;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_accDefaultAction(VARIANT child, BSTR* label) override {
        if (!self(child)) return E_INVALIDARG;
        const auto disable = stateDirectory / L"disable-after-default-query";
        if (!containsTarget_ && std::filesystem::exists(disable)) {
            std::filesystem::remove(disable);
            disabled_ = true;
        }
        if (containsTarget_ || role != ROLE_SYSTEM_PUSHBUTTON) return S_FALSE;
        *label = SysAllocString(L"Press");
        return *label ? S_OK : E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE accLocation(LONG* x, LONG* y, LONG* width, LONG* height, VARIANT child) override {
        RECT rect{};
        if (!self(child) || !GetWindowRect(window_, &rect)) return E_INVALIDARG;
        *x = rect.left; *y = rect.top;
        *width = rect.right - rect.left; *height = rect.bottom - rect.top;
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE accDoDefaultAction(VARIANT child) override {
        if (!self(child) || containsTarget_ || role != ROLE_SYSTEM_PUSHBUTTON) return E_INVALIDARG;
        return effect(L"invoked");
    }
    HRESULT STDMETHODCALLTYPE accSelect(LONG flags, VARIANT child) override {
        if (!self(child) || containsTarget_ || flags != SELFLAG_TAKESELECTION || role != ROLE_SYSTEM_LISTITEM)
            return E_INVALIDARG;
        selected_ = !retired_;
        return effect(L"selected");
    }
    HRESULT STDMETHODCALLTYPE put_accValue(VARIANT child, BSTR value) override {
        if (!self(child) || containsTarget_ || !value || role != ROLE_SYSTEM_TEXT) return E_INVALIDARG;
        return effect(std::wstring(value, SysStringLen(value)));
    }

    HRESULT STDMETHODCALLTYPE GetTypeInfoCount(UINT* count) override { *count = 0; return S_OK; }
    HRESULT STDMETHODCALLTYPE GetTypeInfo(UINT, LCID, ITypeInfo**) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE GetIDsOfNames(REFIID, LPOLESTR*, UINT, LCID, DISPID*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE Invoke(DISPID, REFIID, LCID, WORD, DISPPARAMS*, VARIANT*, EXCEPINFO*, UINT*) override {
        return E_NOTIMPL;
    }
    HRESULT STDMETHODCALLTYPE get_accParent(IDispatch**) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE get_accChild(VARIANT child, IDispatch** out) override {
        if (!containsTarget_ || child.vt != VT_I4 || child.lVal != 1) return E_INVALIDARG;
        return active->QueryInterface(IID_IDispatch, reinterpret_cast<void**>(out));
    }
    HRESULT STDMETHODCALLTYPE get_accValue(VARIANT, BSTR*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE get_accDescription(VARIANT, BSTR*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE get_accHelp(VARIANT, BSTR*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE get_accHelpTopic(BSTR*, VARIANT, LONG*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE get_accKeyboardShortcut(VARIANT, BSTR*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE get_accFocus(VARIANT*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE get_accSelection(VARIANT*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE accNavigate(LONG, VARIANT, VARIANT*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE accHitTest(LONG, LONG, VARIANT*) override { return E_NOTIMPL; }
    HRESULT STDMETHODCALLTYPE put_accName(VARIANT, BSTR) override { return E_NOTIMPL; }

private:
    HRESULT effect(const std::wstring& value) {
        if (retired_) { publish(L"retired-call.txt", L"unexpected"); return E_FAIL; }
        publish(L"effect.txt", value);
        publish(L"calls.txt", std::to_wstring(++calls));
        return std::filesystem::exists(stateDirectory / L"reply-failure") ? E_FAIL : S_OK;
    }

    HWND window_;
    bool containsTarget_;
    ULONG refs_ = 1;
    bool retired_ = false;
    bool selected_ = false;
    bool disabled_ = false;
    bool protected_ = false;
};

LRESULT CALLBACK windowProc(HWND window, UINT message, WPARAM wparam, LPARAM lparam) {
    switch (message) {
    case WM_GETOBJECT:
        if (static_cast<LONG>(lparam) == OBJID_CLIENT) {
            auto* provider = window == targetWindow ? active : window == rootWindow ? container : nullptr;
            if (provider) return LresultFromObject(__uuidof(IAccessible), wparam, static_cast<IAccessible*>(provider));
        }
        break;
    case WM_TIMER:
        if (std::filesystem::exists(stateDirectory / L"close-fixture")) DestroyWindow(window);
        else if (!swapInProgress && std::filesystem::exists(stateDirectory / L"swap-provider")) {
            swapInProgress = true;
            active->retire();
            active->Release();
            active = new Provider(targetWindow);
            publish(L"swapped", L"ready");
        }
        return 0;
    case WM_DESTROY:
        if (window == rootWindow) PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, wparam, lparam);
}
}

int wmain(int argc, wchar_t** argv) {
    if (argc != 4 && argc != 5) return 2;
    stateDirectory = argv[1];
    const std::wstring action = argv[3];
    if (action == L"setValue") role = ROLE_SYSTEM_TEXT;
    else if (action == L"select") role = ROLE_SYSTEM_LISTITEM;
    else if (action != L"defaultAction") return 2;
    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return 1;
    WNDCLASSW wc{};
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpfnWndProc = windowProc;
    wc.lpszClassName = L"MsaaIdentityFixture";
    RegisterClassW(&wc);
    rootWindow = CreateWindowW(wc.lpszClassName, argv[2], WS_OVERLAPPEDWINDOW | WS_VISIBLE,
        CW_USEDEFAULT, CW_USEDEFAULT, 320, 160, nullptr, nullptr, wc.hInstance, nullptr);
    if (!rootWindow) { CoUninitialize(); return 1; }
    targetWindow = rootWindow;
    if (argc == 5 && std::wstring(argv[4]) == L"child") {
        targetWindow = CreateWindowW(wc.lpszClassName, L"", WS_CHILD | WS_VISIBLE, 0, 0, 160, 72,
                                     rootWindow, nullptr, wc.hInstance, nullptr);
        if (!targetWindow) { DestroyWindow(rootWindow); CoUninitialize(); return 1; }
        container = new Provider(rootWindow, true);
    }
    active = new Provider(targetWindow);
    SetTimer(rootWindow, 1, 50, nullptr);
    publish(L"ready", std::to_wstring(GetCurrentProcessId()));
    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    active->retire();
    active->Release();
    if (container) container->Release();
    CoUninitialize();
    return 0;
}
