#include "fixture_common.h"
#include "resource.h"

namespace {

using namespace fixture;

constexpr wchar_t kWindowClass[] = L"AutoDesktopWin32Fixture";

int QuietShow(int show) {
    switch (show) {
    case SW_HIDE: return SW_HIDE;
    case SW_MINIMIZE:
    case SW_SHOWMINIMIZED:
    case SW_SHOWMINNOACTIVE:
    case SW_FORCEMINIMIZE: return SW_SHOWMINNOACTIVE;
    default: return SW_SHOWNOACTIVATE;
    }
}

const wchar_t* ClassName(Kind kind) {
    switch (kind) {
    case Kind::Label: return WC_STATICW;
    case Kind::Button: return WC_BUTTONW;
    case Kind::Edit: return WC_EDITW;
    case Kind::Combo: return WC_COMBOBOXW;
    case Kind::List: return WC_LISTBOXW;
    case Kind::Tree: return WC_TREEVIEWW;
    case Kind::Tab: return WC_TABCONTROLW;
    case Kind::Grid: return WC_LISTVIEWW;
    }
    return nullptr;
}

class FixtureWindow {
public:
    FixtureWindow(HINSTANCE instance, const Arguments& args, Mode mode)
        : instance_(instance), title_(args.title), controls_(args.directory), mode_(mode) {}

    int Run(int show) {
        if (!controls_.state.Healthy()) return 2;
        if (!Interactive() && !RefuseActivationInThisThread()) return 2;
        KeepFullSpeedWhenCovered();

        WNDCLASSW type{};
        type.lpfnWndProc = Dispatch;
        type.hInstance = instance_;
        type.hCursor = LoadCursorW(nullptr, IDC_ARROW);
        type.hbrBackground = reinterpret_cast<HBRUSH>(COLOR_BTNFACE + 1);
        type.lpszClassName = kWindowClass;
        if (!RegisterClassW(&type)) return 3;

        // In background mode the window never takes the focus of the PC's user.
        const DWORD exStyle = WS_EX_CONTROLPARENT | (Interactive() ? 0 : WS_EX_NOACTIVATE);
        constexpr auto style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX;
        RECT bounds{0, 0, kClientWidth, kClientHeight};
        AdjustWindowRectEx(&bounds, style, FALSE, exStyle);
        if (!CreateWindowExW(exStyle, kWindowClass, title_.c_str(), style, CW_USEDEFAULT, CW_USEDEFAULT,
                bounds.right - bounds.left, bounds.bottom - bounds.top, nullptr, nullptr, instance_, this)) return 4;

        // Shown without activation and sent behind other windows, so a test run never steals the focus
        // of whoever is using the PC. Automation reads the window the same way when it is covered.
        // A process started without STARTF_USESHOWWINDOW gets SW_SHOWDEFAULT, which activates: every visible
        // request is shown without activation instead.
        if (Interactive()) {
            ShowWindow(window_, show);
        } else {
            ShowWindow(window_, QuietShow(show));
            SetWindowPos(window_, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
        UpdateWindow(window_);
        controls_.state.Write(L"ready", std::to_wstring(GetCurrentProcessId()));

        MSG message{};
        BOOL status;
        while ((status = GetMessageW(&message, nullptr, 0, 0)) > 0) {
            if (!IsDialogMessageW(window_, &message)) {
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
        }
        return status == -1 ? 5 : static_cast<int>(message.wParam);
    }

private:
    bool Interactive() const { return mode_ == Mode::Interactive; }

    static LRESULT CALLBACK Dispatch(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
        auto self = reinterpret_cast<FixtureWindow*>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (message == WM_NCCREATE) {
            self = static_cast<FixtureWindow*>(reinterpret_cast<CREATESTRUCTW*>(lParam)->lpCreateParams);
            self->window_ = window;
            SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
        }
        return self ? self->OnMessage(message, wParam, lParam) : DefWindowProcW(window, message, wParam, lParam);
    }

    HWND Create(const Control& control) const {
        const auto child = CreateWindowExW(0, ClassName(control.kind), control.text, control.style,
            control.x, control.y, control.width, control.height, window_,
            reinterpret_cast<HMENU>(static_cast<INT_PTR>(control.id)), instance_, nullptr);
        if (child) SetControlFont(child);
        return child;
    }

    LRESULT OnMessage(UINT message, WPARAM wParam, LPARAM lParam) {
        switch (message) {
        case WM_CREATE:
            for (const auto& control : kControls) {
                if (!Create(control)) return -1;
            }
            controls_.Initialize(window_, L"Win32", mode_);
            return controls_.state.Healthy() && SetTimer(window_, kStateTimer, 25, nullptr) ? 0 : -1;
        case WM_COMMAND:
            if (OnCommand(LOWORD(wParam), HIWORD(wParam), reinterpret_cast<HWND>(lParam))) return 0;
            break;
        case WM_NOTIFY:
            if (controls_.OnNotify(reinterpret_cast<NMHDR*>(lParam))) return 0;
            break;
        case WM_DRAWITEM:
            if (wParam == kOwnerDraw) {
                DrawOwnerButton(*reinterpret_cast<DRAWITEMSTRUCT*>(lParam));
                return TRUE;
            }
            break;
        case WM_TIMER:
            if (wParam == kStateTimer) PollState();
            return 0;
        case WM_CLOSE:
            if (modal_) {
                closePending_ = true;
                EndDialog(modal_, IDCANCEL);
            } else {
                DestroyWindow(window_);
            }
            return 0;
        case WM_DESTROY:
            PostQuitMessage(controls_.state.Healthy() ? 0 : 6);
            return 0;
        }
        return DefWindowProcW(window_, message, wParam, lParam);
    }

    bool OnCommand(UINT id, UINT notification, HWND source) {
        if (controls_.OnCommand(source, id, notification)) return true;
        if (notification != BN_CLICKED || !source) return false;
        if (id == kOpenModal) {
            ShowModal();
            return true;
        }
        if (id == kReplace) {
            ReplaceCounter();
            return true;
        }
        return false;
    }

    void PollState() {
        auto& state = controls_.state;
        if (state.Consume(L"close-fixture") || !state.Healthy()) {
            SendMessageW(window_, WM_CLOSE, 0, 0);
            return;
        }
        if (state.Consume(L"close-modal") && modal_) EndDialog(modal_, IDCANCEL);
        if (state.Consume(L"replace-control")) ReplaceCounter();
        controls_.PollGridCommands(window_);
        state.ReplyToCursorRequests();
    }

    void ReplaceCounter() {
        const auto retired = GetDlgItem(window_, kIncrement);
        if (PrepareReplacement(Create(kIncrementControl), retired)) controls_.state.Write(L"replaced", L"ready");
    }

    void ShowModal() {
        const auto result = DialogBoxParamW(instance_, MAKEINTRESOURCEW(IDD_FIXTURE_MODAL), window_, ModalDispatch,
            reinterpret_cast<LPARAM>(this));
        modal_ = nullptr;
        controls_.state.Write(L"modal-result.txt", result == IDOK ? L"accepted" : result == IDCANCEL ? L"canceled" : L"failed");
        controls_.state.Write(L"modal.txt", L"closed");
        if (closePending_) PostMessageW(window_, WM_CLOSE, 0, 0);
    }

    static INT_PTR CALLBACK ModalDispatch(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
        if (message == WM_INITDIALOG) {
            const auto self = reinterpret_cast<FixtureWindow*>(lParam);
            self->modal_ = window;
            SetWindowTextW(window, (self->title_ + L" modal").c_str());
            PostMessageW(window, kReadyMessage, reinterpret_cast<WPARAM>(self), 0);
            // Interactive: the dialog manager shows, activates and focuses the dialog as usual.
            if (self->Interactive()) return TRUE;
            SetWindowLongPtrW(window, GWL_EXSTYLE, GetWindowLongPtrW(window, GWL_EXSTYLE) | WS_EX_NOACTIVATE);
            // The dialog manager shows a hidden dialog with SW_SHOWNORMAL, which activates it, and focusing the
            // first control would activate it too: show it here without activation and keep the focus unset.
            ShowWindow(window, SW_SHOWNOACTIVATE);
            return FALSE;
        }
        if (message == kReadyMessage) {
            const auto self = reinterpret_cast<FixtureWindow*>(wParam);
            self->controls_.state.Write(L"modal.txt", L"open");
            return TRUE;
        }
        if (message == WM_CLOSE || (message == WM_COMMAND && (LOWORD(wParam) == IDOK || LOWORD(wParam) == IDCANCEL))) {
            EndDialog(window, message == WM_CLOSE ? IDCANCEL : LOWORD(wParam));
            return TRUE;
        }
        return FALSE;
    }

    HINSTANCE instance_;
    std::wstring title_;
    ControlState controls_;
    Mode mode_;
    HWND window_ = nullptr;
    HWND modal_ = nullptr;
    bool closePending_ = false;
};

}  // namespace

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int show) {
    const auto mode = fixture::ReadMode();
    if (!mode) return 2;
    const auto arguments = fixture::ReadArguments();
    if (!arguments || !fixture::InitializeCommonControls()) return 1;
    return FixtureWindow(instance, *arguments, *mode).Run(show);
}
