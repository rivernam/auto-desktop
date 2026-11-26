#include <afxwin.h>
#include <afxcmn.h>
#include <afxdlgs.h>

#include "../win32/fixture_common.h"
#include "resource.h"

#include <memory>
#include <type_traits>
#include <vector>

namespace {

using namespace fixture;

constexpr Control kMfcControls[]{
    {Kind::Button, kOpenSdi, L"Open SDI frame", kInput, 16, 472, 203, 28},
    {Kind::Button, kOpenMdi, L"Open MDI frame", kInput, 229, 472, 203, 28},
    {Kind::Button, kOpenProperties, L"Open property sheet", kInput, 442, 472, 224, 28},
};

// Read once in InitInstance (DESKTOP_FIXTURE_MODE).
Mode mode = Mode::Background;

bool Interactive() { return mode == Mode::Interactive; }

// Extended style for every fixture window: background windows never take the focus of whoever is using the PC.
DWORD QuietExStyle() { return Interactive() ? 0 : WS_EX_NOACTIVATE; }

// ActivateFrame and the dialog manager (SW_SHOWNORMAL for a hidden dialog) activate the window. In background
// mode the fixture windows are shown here without activation and never focus a control, so a test run does not
// take the focus of whoever is using the PC. Interactive windows are shown and activated normally.
void ShowQuietly(CWnd& window) {
    if (Interactive()) {
        window.ShowWindow(SW_SHOW);
        return;
    }
    window.ShowWindow(SW_SHOWNOACTIVATE);
    window.SetWindowPos(&CWnd::wndBottom, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

template <typename Frame>
class OwnedFrame : public Frame {
private:
    void PostNcDestroy() override { CWnd::PostNcDestroy(); }
};

class SdiFrame final : public OwnedFrame<CFrameWnd> {
public:
    bool Open(const std::wstring& title) {
        if (!GetSafeHwnd()) {
            if (!Create(nullptr, title.c_str(), WS_OVERLAPPEDWINDOW, CRect(120, 120, 580, 370), nullptr, nullptr, QuietExStyle())) return false;
            if (!edit_.Create(kInput | WS_BORDER | ES_AUTOHSCROLL, CRect(16, 16, 405, 46), this, 2100)) {
                DestroyWindow();
                return false;
            }
            edit_.SetWindowText(L"Fixture SDI document");
            SetControlFont(edit_.GetSafeHwnd());
        }
        ShowQuietly(*this);
        return true;
    }

private:
    CEdit edit_;
};

class MdiChild final : public OwnedFrame<CMDIChildWnd> {
public:
    bool Open(CMDIFrameWnd* parent, const wchar_t* title, const RECT& bounds) {
        if (!Create(nullptr, title, WS_CHILD | WS_VISIBLE | WS_OVERLAPPEDWINDOW, bounds, parent)) return false;
        if (!edit_.Create(kInput | WS_BORDER | ES_AUTOHSCROLL, CRect(12, 12, 218, 45), this, 2101)) {
            DestroyWindow();
            return false;
        }
        edit_.SetWindowText(title);
        SetControlFont(edit_.GetSafeHwnd());
        return true;
    }

private:
    CEdit edit_;
};

class MdiFrame final : public OwnedFrame<CMDIFrameWnd> {
public:
    bool Open(const std::wstring& title) {
        if (!GetSafeHwnd()) {
            if (!Create(nullptr, title.c_str(), WS_OVERLAPPEDWINDOW, CRect(140, 140, 770, 510), nullptr, nullptr, QuietExStyle())) return false;
            if (!first_.Open(this, L"Fixture document one", CRect(10, 15, 285, 162)) ||
                !second_.Open(this, L"Fixture document two", CRect(292, 25, 567, 172))) {
                DestroyWindow();
                return false;
            }
        }
        ShowQuietly(*this);
        return true;
    }

private:
    BOOL OnCreateClient(LPCREATESTRUCT create, CCreateContext*) override {
        return CreateClient(create, nullptr);
    }

    MdiChild first_;
    MdiChild second_;
};

class FixtureModal final : public CDialog {
public:
    FixtureModal(CWnd* parent, const std::wstring& title)
        : CDialog(IDD_FIXTURE_MODAL, parent), title_(title) {}

private:
    BOOL OnInitDialog() override {
        CDialog::OnInitDialog();
        SetWindowText(title_.c_str());
        if (Interactive()) return TRUE;  // shown, activated and focused by the dialog manager
        ModifyStyleEx(0, WS_EX_NOACTIVATE);  // never takes the focus of whoever is using the PC
        ShowWindow(SW_SHOWNOACTIVATE);
        return FALSE;
    }

    std::wstring title_;
};

class FixturePage final : public CPropertyPage {
public:
    FixturePage(UINT resource, State& state, const wchar_t* label)
        : CPropertyPage(resource), state_(state), label_(label) {}

private:
    BOOL OnSetActive() override {
        if (!CPropertyPage::OnSetActive()) return FALSE;
        state_.Write(L"property-tab.txt", label_);
        return TRUE;
    }

    State& state_;
    const wchar_t* label_;
};

class QuietSheet final : public CPropertySheet {
public:
    QuietSheet(const wchar_t* title, CWnd* parent) : CPropertySheet(title, parent) {}

private:
    BOOL OnInitDialog() override {
        const auto result = CPropertySheet::OnInitDialog();
        if (Interactive()) return result;
        ModifyStyleEx(0, WS_EX_NOACTIVATE);  // never takes the focus of whoever is using the PC
        ShowWindow(SW_SHOWNOACTIVATE);
        return result;
    }
};

class FixtureDialog final : public CDialog {
public:
    explicit FixtureDialog(const Arguments& arguments)
        : CDialog(IDD_FIXTURE_MAIN), title_(arguments.title), controls_(arguments.directory) {}

    bool Healthy() const { return controls_.state.Healthy() && ready_; }

private:
    BOOL OnInitDialog() override {
        CDialog::OnInitDialog();
        ModifyStyleEx(0, QuietExStyle());  // background: never takes the focus of whoever is using the PC
        SetWindowText(title_.c_str());
        RECT bounds{0, 0, kClientWidth, kClientHeight};
        ::AdjustWindowRectEx(&bounds, GetStyle(), FALSE, GetExStyle());
        SetWindowPos(nullptr, 0, 0, bounds.right - bounds.left, bounds.bottom - bounds.top,
            SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
        CenterWindow();

        for (const auto& control : kControls) {
            if (!CreateControl(control)) {
                EndDialog(IDCANCEL);
                return TRUE;
            }
        }
        for (const auto& control : kMfcControls) {
            if (!CreateControl(control)) {
                EndDialog(IDCANCEL);
                return TRUE;
            }
        }

        CString version;
        version.Format(L"MFC 0x%04X", static_cast<unsigned>(_MFC_VER));
        controls_.Initialize(GetSafeHwnd(), static_cast<const wchar_t*>(version), mode);
        if (!controls_.state.Healthy() || !SetTimer(kStateTimer, 25, nullptr)) EndDialog(IDCANCEL);
        ShowQuietly(*this);
        return Interactive();  // interactive: the dialog manager focuses the first control
    }

    template <typename ControlType>
    std::unique_ptr<CWnd> CreateTypedControl(const Control& control) {
        auto child = std::make_unique<ControlType>();
        const CRect rect(control.x, control.y, control.x + control.width, control.y + control.height);
        const auto id = static_cast<UINT>(control.id);
        if constexpr (std::is_same_v<ControlType, CStatic> || std::is_same_v<ControlType, CButton>) {
            if (!child->Create(control.text, control.style, rect, this, id)) return nullptr;
        } else {
            if (!child->Create(control.style, rect, this, id)) return nullptr;
            if (control.kind == Kind::Edit) child->SetWindowText(control.text);
        }
        SetControlFont(child->GetSafeHwnd());
        return child;
    }

    bool CreateControl(const Control& control) {
        std::unique_ptr<CWnd> child;
        switch (control.kind) {
        case Kind::Label: child = CreateTypedControl<CStatic>(control); break;
        case Kind::Button: child = CreateTypedControl<CButton>(control); break;
        case Kind::Edit: child = CreateTypedControl<CEdit>(control); break;
        case Kind::Combo: child = CreateTypedControl<CComboBox>(control); break;
        case Kind::List: child = CreateTypedControl<CListBox>(control); break;
        case Kind::Tree: child = CreateTypedControl<CTreeCtrl>(control); break;
        case Kind::Tab: child = CreateTypedControl<CTabCtrl>(control); break;
        case Kind::Grid: child = CreateTypedControl<CListCtrl>(control); break;
        }
        if (!child) return false;
        if (control.id == kIncrement) increment_ = std::move(child);
        else children_.push_back(std::move(child));
        return true;
    }

    BOOL OnCommand(WPARAM wParam, LPARAM lParam) override {
        const UINT id = LOWORD(wParam);
        const UINT code = HIWORD(wParam);
        if (controls_.OnCommand(reinterpret_cast<HWND>(lParam), id, code)) return TRUE;
        if (code == BN_CLICKED && lParam) {
            switch (id) {
            case kOpenModal: OpenModal(); return TRUE;
            case kReplace: ReplaceCounter(); return TRUE;
            case kOpenSdi:
                controls_.state.Write(L"sdi.txt", sdi_.Open(title_ + L" SDI") ? L"open" : L"failed");
                return TRUE;
            case kOpenMdi:
                controls_.state.Write(L"mdi.txt", mdi_.Open(title_ + L" MDI") ? L"open" : L"failed");
                return TRUE;
            case kOpenProperties: OpenProperties(); return TRUE;
            }
        }
        return CDialog::OnCommand(wParam, lParam);
    }

    BOOL OnNotify(WPARAM wParam, LPARAM lParam, LRESULT* result) override {
        if (controls_.OnNotify(reinterpret_cast<NMHDR*>(lParam))) {
            *result = 0;
            return TRUE;
        }
        return CDialog::OnNotify(wParam, lParam, result);
    }

    afx_msg void OnDrawItem(int id, LPDRAWITEMSTRUCT draw) {
        if (id == kOwnerDraw) DrawOwnerButton(*draw);
        else CDialog::OnDrawItem(id, draw);
    }

    afx_msg void OnClose() {
        if (popup_) {
            closePending_ = true;
            popup_->SendMessage(WM_CLOSE);
        } else {
            EndDialog(IDCANCEL);
        }
    }

    afx_msg void OnDestroy() {
        if (sdi_.GetSafeHwnd()) sdi_.DestroyWindow();
        if (mdi_.GetSafeHwnd()) mdi_.DestroyWindow();
        CDialog::OnDestroy();
    }

    afx_msg void OnTimer(UINT_PTR timer) {
        if (timer != kStateTimer) return;
        auto& state = controls_.state;
        if (state.Consume(L"close-fixture") || !state.Healthy()) {
            OnClose();
            return;
        }
        if (state.Consume(L"close-modal") && popup_) popup_->SendMessage(WM_CLOSE);
        if (state.Consume(L"replace-control")) ReplaceCounter();
        controls_.PollGridCommands(GetSafeHwnd());
        if (!ready_ && IsWindowVisible()) {
            ready_ = true;
            state.Write(L"ready", std::to_wstring(GetCurrentProcessId()));
        }
        if (popup_ && popup_->GetSafeHwnd() && popup_->IsWindowVisible() && !popupReady_) {
            popupReady_ = true;
            state.Write(popupStateFile_, L"open");
        }
        state.ReplyToCursorRequests();
    }

    void ReplaceCounter() {
        auto replacement = CreateTypedControl<CButton>(kIncrementControl);
        if (!replacement || !PrepareReplacement(replacement->GetSafeHwnd(), increment_->GetSafeHwnd())) return;
        increment_ = std::move(replacement);
        controls_.state.Write(L"replaced", L"ready");
    }

    void OpenModal() {
        FixtureModal dialog(this, title_ + L" modal");
        RunPopup(dialog, L"modal.txt");
    }

    void OpenProperties() {
        const auto title = title_ + L" properties";
        FixturePage general(IDD_FIXTURE_GENERAL, controls_.state, L"General");
        FixturePage advanced(IDD_FIXTURE_ADVANCED, controls_.state, L"Advanced");
        QuietSheet sheet(title.c_str(), this);
        sheet.AddPage(&general);
        sheet.AddPage(&advanced);
        RunPopup(sheet, L"properties.txt");
    }

    template <typename Popup>
    void RunPopup(Popup& dialog, const wchar_t* file) {
        popup_ = &dialog;
        popupReady_ = false;
        popupStateFile_ = file;
        const auto result = dialog.DoModal();
        popup_ = nullptr;
        // Same contract as the Win32 fixture: the result in its own file, then the popup state.
        std::wstring resultFile(file);
        resultFile.insert(resultFile.rfind(L'.'), L"-result");
        controls_.state.Write(resultFile.c_str(), result == IDOK ? L"accepted" : result == IDCANCEL ? L"canceled" : L"failed");
        controls_.state.Write(file, L"closed");
        if (closePending_) PostMessage(WM_CLOSE);
    }

    DECLARE_MESSAGE_MAP()

    std::wstring title_;
    ControlState controls_;
    std::vector<std::unique_ptr<CWnd>> children_;
    std::unique_ptr<CWnd> increment_;
    SdiFrame sdi_;
    MdiFrame mdi_;
    CWnd* popup_ = nullptr;
    const wchar_t* popupStateFile_ = nullptr;
    bool closePending_ = false;
    bool ready_ = false;
    bool popupReady_ = false;
};

BEGIN_MESSAGE_MAP(FixtureDialog, CDialog)
    ON_WM_DRAWITEM()
    ON_WM_CLOSE()
    ON_WM_DESTROY()
    ON_WM_TIMER()
END_MESSAGE_MAP()

class FixtureApp final : public CWinApp {
private:
    BOOL InitInstance() override {
        const auto selected = ReadMode();
        if (!selected) {
            exitCode_ = 2;
            return FALSE;
        }
        mode = *selected;
        const auto arguments = ReadArguments();
        if (!arguments || !InitializeCommonControls() || !CWinApp::InitInstance()) return FALSE;
        if (!Interactive() && !RefuseActivationInThisThread()) return FALSE;
        KeepFullSpeedWhenCovered();
        FixtureDialog dialog(*arguments);
        m_pMainWnd = &dialog;
        dialog.DoModal();
        m_pMainWnd = nullptr;
        exitCode_ = dialog.Healthy() ? 0 : 2;
        return FALSE;
    }

    int ExitInstance() override {
        CWinApp::ExitInstance();
        return exitCode_;
    }

    int exitCode_ = 1;
};

FixtureApp app;

}  // namespace
