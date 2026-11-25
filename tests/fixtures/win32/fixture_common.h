#pragma once

#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>

#include <filesystem>
#include <fstream>
#include <iterator>
#include <optional>
#include <string>

#pragma comment(linker, "/manifestdependency:\"type='win32' name='Microsoft.Windows.Common-Controls' " \
    "version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'\"")

namespace fixture {

constexpr UINT_PTR kStateTimer = 1;
constexpr UINT kReadyMessage = WM_APP + 1;
constexpr int kClientWidth = 700;
constexpr int kClientHeight = 510;

enum ControlId {
    kIncrement = 1001, kEdit, kReadOnly, kDisabled, kDuplicate, kPassword,
    kCheck = 1010, kCombo, kList, kTree, kTab, kOwnerDraw, kOpenModal, kGrid, kReplace,
    kOpenSdi, kOpenMdi, kOpenProperties,
};

struct Arguments {
    std::filesystem::path directory;
    std::wstring title;
};

inline std::optional<Arguments> ReadArguments() {
    int count = 0;
    auto args = CommandLineToArgvW(GetCommandLineW(), &count);
    if (!args) return std::nullopt;
    std::optional<Arguments> result;
    if (count == 3 && args[1][0] && args[2][0]) result = Arguments{args[1], args[2]};
    LocalFree(args);
    return result;
}

inline bool InitializeCommonControls() {
    const INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_WIN95_CLASSES};
    return InitCommonControlsEx(&controls) != FALSE;
}

// A fixture inherits the right to take the foreground from the process chain that started it (usually the
// terminal the user works in). Showing without activation is not enough: a button that an automation client
// clicks sets the focus, and the dialog manager activates dialogs. A thread-local CBT hook refuses every
// activation that is not a mouse click on the fixture, so a test run never takes the focus of the PC's user.
inline LRESULT CALLBACK RefuseActivation(int code, WPARAM wParam, LPARAM lParam) {
    if (code == HCBT_ACTIVATE && !reinterpret_cast<const CBTACTIVATESTRUCT*>(lParam)->fMouse) return 1;
    return CallNextHookEx(nullptr, code, wParam, lParam);
}

inline bool RefuseActivationInThisThread() {
    return SetWindowsHookExW(WH_CBT, RefuseActivation, nullptr, GetCurrentThreadId()) != nullptr;
}

// The fixture stays behind the user's windows. Windows 11 throttles a process whose windows are all covered
// (EcoQoS, coarse timers), which made the 25 ms state timer and large captures time out: keep full speed.
inline void KeepFullSpeedWhenCovered() {
    PROCESS_POWER_THROTTLING_STATE state{};
    state.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION;
    state.ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED | PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION;
    state.StateMask = 0;
    SetProcessInformation(GetCurrentProcess(), ProcessPowerThrottling, &state, sizeof(state));
}

inline std::wstring WindowText(HWND window) {
    std::wstring text(static_cast<size_t>(GetWindowTextLengthW(window)) + 1, L'\0');
    text.resize(GetWindowTextW(window, text.data(), static_cast<int>(text.size())));
    return text;
}

class State {
public:
    explicit State(const std::filesystem::path& directory) : directory_(directory) {
        std::error_code error;
        std::filesystem::create_directories(directory_, error);
        healthy_ = !error;
    }

    bool Healthy() const { return healthy_; }

    void Write(const std::filesystem::path& name, const std::wstring& value) {
        if (!healthy_) return;
        std::string utf8;
        if (!value.empty()) {
            const int length = static_cast<int>(value.size());
            const int bytes = WideCharToMultiByte(CP_UTF8, 0, value.data(), length, nullptr, 0, nullptr, nullptr);
            if (!bytes) {
                healthy_ = false;
                return;
            }
            utf8.resize(bytes);
            WideCharToMultiByte(CP_UTF8, 0, value.data(), length, utf8.data(), bytes, nullptr, nullptr);
        }

        const auto target = directory_ / name;
        auto pending = target;
        pending += L".pending";
        std::ofstream file(pending, std::ios::binary | std::ios::trunc);
        file.write(utf8.data(), static_cast<std::streamsize>(utf8.size()));
        file.close();
        if (!file) {
            healthy_ = false;
            return;
        }

        // A reader can briefly hold the target open without delete sharing.
        for (int attempt = 0; attempt < 12; ++attempt) {
            if (MoveFileExW(pending.c_str(), target.c_str(), MOVEFILE_REPLACE_EXISTING)) return;
            const auto error = GetLastError();
            if (error != ERROR_SHARING_VIOLATION && error != ERROR_ACCESS_DENIED) break;
            Sleep(5);
        }
        healthy_ = false;
    }

    bool Consume(const std::filesystem::path& name) {
        std::error_code error;
        return std::filesystem::remove(directory_ / name, error);
    }

    void ReplyToCursorRequests() {
        std::error_code error;
        const std::filesystem::directory_iterator end;
        for (std::filesystem::directory_iterator entry(directory_, error); !error && entry != end; entry.increment(error)) {
            if (entry->path().extension() != L".request" || !entry->is_regular_file(error)) continue;
            POINT position{};
            if (!GetPhysicalCursorPos(&position)) continue;
            const auto request = entry->path().filename();
            auto reply = request;
            reply.replace_extension(L".reply");
            Write(reply, std::to_wstring(position.x) + L"," + std::to_wstring(position.y));
            Consume(request);
        }
    }

private:
    std::filesystem::path directory_;
    bool healthy_ = true;
};

enum class Kind { Label, Button, Edit, Combo, List, Tree, Tab, Grid };

struct Control {
    Kind kind;
    int id;
    const wchar_t* text;
    DWORD style;
    int x;
    int y;
    int width;
    int height;
};

inline constexpr auto kChild = WS_CHILD | WS_VISIBLE;
inline constexpr auto kInput = kChild | WS_TABSTOP;
inline constexpr Control kIncrementControl{Kind::Button, kIncrement, L"Increment fixture counter", kInput, 16, 16, 200, 28};
inline constexpr Control kControls[]{
    kIncrementControl,
    {Kind::Button, kDisabled, L"Disabled action", kInput | WS_DISABLED, 226, 16, 140, 28},
    {Kind::Button, kDuplicate, L"Duplicate label", kInput, 376, 16, 140, 28},
    {Kind::Button, 0, L"Duplicate label", kInput, 526, 16, 140, 28},
    {Kind::Label, -1, L"Editable value", kChild, 16, 54, 180, 19},
    {Kind::Edit, kEdit, L"initial fixture value", kInput | WS_BORDER | ES_AUTOHSCROLL, 16, 74, 210, 24},
    {Kind::Label, -1, L"Read-only value", kChild, 236, 54, 180, 19},
    {Kind::Edit, kReadOnly, L"fixed fixture value", kInput | WS_BORDER | ES_AUTOHSCROLL | ES_READONLY, 236, 74, 210, 24},
    {Kind::Label, -1, L"Password", kChild, 456, 54, 180, 19},
    {Kind::Edit, kPassword, L"fixture-test-password", kInput | WS_BORDER | ES_AUTOHSCROLL | ES_PASSWORD, 456, 74, 210, 24},
    {Kind::Button, kCheck, L"Fixture check box", kInput | BS_AUTOCHECKBOX, 16, 110, 180, 24},
    {Kind::Label, -1, L"Fixture choices", kChild, 16, 144, 150, 19},
    {Kind::Combo, kCombo, L"", kInput | CBS_DROPDOWNLIST | WS_VSCROLL, 16, 164, 164, 100},
    {Kind::Label, -1, L"Fixture items", kChild, 190, 144, 150, 19},
    {Kind::List, kList, L"", kInput | WS_BORDER | LBS_NOTIFY | LBS_NOINTEGRALHEIGHT, 190, 164, 142, 78},
    {Kind::Label, -1, L"Fixture tree", kChild, 342, 144, 150, 19},
    {Kind::Tree, kTree, L"", kInput | WS_BORDER | TVS_HASLINES | TVS_HASBUTTONS | TVS_LINESATROOT | TVS_SHOWSELALWAYS, 342, 164, 164, 78},
    {Kind::Label, -1, L"Fixture tabs", kChild, 516, 144, 150, 19},
    {Kind::Tab, kTab, L"", kInput, 516, 164, 150, 78},
    {Kind::Button, kOwnerDraw, L"Owner-drawn action", kInput | BS_OWNERDRAW, 16, 254, 190, 28},
    {Kind::Button, kOpenModal, L"Open fixture modal", kInput, 216, 254, 185, 28},
    {Kind::Button, kReplace, L"Replace fixture counter", kInput, 411, 254, 201, 28},
    {Kind::Label, -1, L"Virtual report (10000 rows)", kChild, 16, 291, 250, 20},
    {Kind::Grid, kGrid, L"", kInput | WS_BORDER | LVS_REPORT | LVS_OWNERDATA | LVS_SINGLESEL | LVS_SHOWSELALWAYS, 16, 312, 650, 152},
};

inline void SetControlFont(HWND control) {
    SendMessageW(control, WM_SETFONT, reinterpret_cast<WPARAM>(GetStockObject(DEFAULT_GUI_FONT)), FALSE);
}

inline bool PrepareReplacement(HWND newButton, HWND retired) {
    if (!newButton) return false;
    SetControlFont(newButton);
    const bool hadFocus = GetFocus() == retired;
    SetWindowPos(newButton, retired, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    DestroyWindow(retired);
    if (hadFocus) SetFocus(newButton);
    return true;
}

class ControlState {
public:
    explicit ControlState(const std::filesystem::path& directory) : state(directory) {}

    void Initialize(HWND parent, const std::wstring& framework) {
        state.Write(L"count.txt", L"0");
        state.Write(L"value.txt", WindowText(GetDlgItem(parent, kEdit)));
        state.Write(L"read-only.txt", WindowText(GetDlgItem(parent, kReadOnly)));
        state.Write(L"disabled-click.txt", L"0");
        state.Write(L"owner-draw.txt", L"0");
        state.Write(L"check.txt", L"0");
        state.Write(L"modal.txt", L"closed");
        state.Write(L"framework.txt", framework + L" " + (sizeof(void*) == 8 ? L"x64" : L"x86"));

        const auto combo = GetDlgItem(parent, kCombo);
        const auto list = GetDlgItem(parent, kList);
        for (auto choice : kChoices) SendMessageW(combo, CB_ADDSTRING, 0, reinterpret_cast<LPARAM>(choice));
        for (auto item : kItems) SendMessageW(list, LB_ADDSTRING, 0, reinterpret_cast<LPARAM>(item));
        SendMessageW(combo, CB_SETCURSEL, 0, 0);
        SendMessageW(list, LB_SETCURSEL, 0, 0);

        const auto tree = GetDlgItem(parent, kTree);
        TVINSERTSTRUCTW node{};
        node.hInsertAfter = TVI_LAST;
        node.item.mask = TVIF_TEXT;
        node.hParent = TVI_ROOT;
        node.item.pszText = const_cast<wchar_t*>(kTreeRoot);
        const auto root = TreeView_InsertItem(tree, &node);
        node.hParent = root;
        node.item.pszText = const_cast<wchar_t*>(kTreeChild);
        TreeView_InsertItem(tree, &node);
        TreeView_Expand(tree, root, TVE_EXPAND);
        TreeView_SelectItem(tree, root);

        const auto tabs = GetDlgItem(parent, kTab);
        TCITEMW tab{};
        tab.mask = TCIF_TEXT;
        for (int index = 0; index < static_cast<int>(std::size(kTabs)); ++index) {
            tab.pszText = const_cast<wchar_t*>(kTabs[index]);
            TabCtrl_InsertItem(tabs, index, &tab);
        }
        TabCtrl_SetCurSel(tabs, 0);

        const auto grid = GetDlgItem(parent, kGrid);
        ListView_SetExtendedListViewStyle(grid, LVS_EX_FULLROWSELECT | LVS_EX_GRIDLINES);
        LVCOLUMNW column{};
        column.mask = LVCF_WIDTH | LVCF_TEXT;
        column.cx = 260;
        column.pszText = const_cast<wchar_t*>(L"Record");
        ListView_InsertColumn(grid, 0, &column);
        column.cx = 200;
        column.pszText = const_cast<wchar_t*>(L"Status");
        ListView_InsertColumn(grid, 1, &column);
        SetGridRows(parent, 12);

        state.Write(L"combo.txt", kChoices[0]);
        state.Write(L"list.txt", kItems[0]);
        state.Write(L"tree.txt", kTreeRoot);
        state.Write(L"tab.txt", kTabs[0]);
        state.Write(L"grid.txt", L"");
        state.Write(L"selected.txt", kChoices[0]);
    }

    void PollGridCommands(HWND parent) {
        if (state.Consume(L"large-grid")) SetGridRows(parent, 10000);
        if (state.Consume(L"compact-grid")) SetGridRows(parent, 12);
    }

    bool OnCommand(HWND source, UINT id, UINT code) {
        switch (id) {
        case kIncrement:
            if (code == BN_CLICKED) state.Write(L"count.txt", std::to_wstring(++clicks_));
            return true;
        case kDisabled:
            if (code == BN_CLICKED) state.Write(L"disabled-click.txt", L"1");
            return true;
        case kOwnerDraw:
            if (code == BN_CLICKED) state.Write(L"owner-draw.txt", std::to_wstring(++ownerClicks_));
            return true;
        case kEdit:
        case kReadOnly:
            if (code == EN_CHANGE) state.Write(id == kEdit ? L"value.txt" : L"read-only.txt", WindowText(source));
            return true;
        case kCheck:
            if (code == BN_CLICKED) state.Write(L"check.txt", SendMessageW(source, BM_GETCHECK, 0, 0) == BST_CHECKED ? L"1" : L"0");
            return true;
        case kCombo:
            if (code == CBN_SELCHANGE) Select(L"combo.txt", kChoices, SendMessageW(source, CB_GETCURSEL, 0, 0));
            return true;
        case kList:
            if (code == LBN_SELCHANGE) Select(L"list.txt", kItems, SendMessageW(source, LB_GETCURSEL, 0, 0));
            return true;
        default:
            return false;
        }
    }

    bool OnNotify(NMHDR* header) {
        switch (header->code) {
        case TVN_SELCHANGEDW:
            if (header->idFrom == kTree) {
                wchar_t label[128]{};
                TVITEMW item{};
                item.hItem = reinterpret_cast<NMTREEVIEWW*>(header)->itemNew.hItem;
                item.mask = TVIF_TEXT;
                item.pszText = label;
                item.cchTextMax = static_cast<int>(std::size(label));
                if (TreeView_GetItem(header->hwndFrom, &item)) Select(L"tree.txt", label);
                return true;
            }
            break;
        case TCN_SELCHANGE:
            if (header->idFrom == kTab) {
                Select(L"tab.txt", kTabs, TabCtrl_GetCurSel(header->hwndFrom));
                return true;
            }
            break;
        case LVN_ITEMCHANGED:
            if (header->idFrom == kGrid) {
                const auto change = reinterpret_cast<NMLISTVIEW*>(header);
                if ((change->uChanged & LVIF_STATE) && (change->uNewState & LVIS_SELECTED) && change->iItem >= 0) {
                    Select(L"grid.txt", RowText(change->iItem));
                }
                return true;
            }
            break;
        case LVN_GETDISPINFOW:
            if (header->idFrom == kGrid) {
                auto& item = reinterpret_cast<NMLVDISPINFOW*>(header)->item;
                if ((item.mask & LVIF_TEXT) && item.pszText && item.cchTextMax > 0) {
                    const auto text = item.iSubItem == 0 ? RowText(item.iItem) : L"Available";
                    lstrcpynW(item.pszText, text.c_str(), item.cchTextMax);
                }
                return true;
            }
            break;
        }
        return false;
    }

    State state;

private:
    void SetGridRows(HWND parent, int rows) {
        const auto grid = GetDlgItem(parent, kGrid);
        ListView_SetItemCount(grid, rows);
        state.Write(L"grid-rows.txt", std::to_wstring(ListView_GetItemCount(grid)));
    }

    void Select(const wchar_t* file, const std::wstring& value) {
        state.Write(file, value);
        state.Write(L"selected.txt", value);
    }

    template <size_t Size>
    void Select(const wchar_t* file, const wchar_t* const (&items)[Size], LRESULT index) {
        if (index >= 0 && static_cast<size_t>(index) < Size) Select(file, items[index]);
    }

    static std::wstring RowText(int index) { return L"Row " + std::to_wstring(index + 1); }

    static constexpr const wchar_t* kChoices[]{L"Choice one", L"Choice two"};
    static constexpr const wchar_t* kItems[]{L"Item one", L"Item two"};
    static constexpr const wchar_t* kTabs[]{L"Tab one", L"Tab two"};
    static constexpr auto kTreeRoot = L"Fixture root";
    static constexpr auto kTreeChild = L"Fixture child";
    unsigned clicks_ = 0;
    unsigned ownerClicks_ = 0;
};

inline void DrawOwnerButton(const DRAWITEMSTRUCT& draw) {
    RECT bounds = draw.rcItem;
    const bool pressed = (draw.itemState & ODS_SELECTED) != 0;
    const bool disabled = (draw.itemState & ODS_DISABLED) != 0;
    DrawFrameControl(draw.hDC, &bounds, DFC_BUTTON, DFCS_BUTTONPUSH | DFCS_ADJUSTRECT |
        (pressed ? DFCS_PUSHED : 0) | (disabled ? DFCS_INACTIVE : 0));
    const int saved = SaveDC(draw.hDC);
    SetBkMode(draw.hDC, TRANSPARENT);
    SetTextColor(draw.hDC, GetSysColor(disabled ? COLOR_GRAYTEXT : COLOR_BTNTEXT));
    SelectObject(draw.hDC, GetStockObject(DEFAULT_GUI_FONT));
    if (pressed) OffsetRect(&bounds, 1, 1);
    const auto label = WindowText(draw.hwndItem);
    DrawTextW(draw.hDC, label.c_str(), static_cast<int>(label.size()), &bounds, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    if (draw.itemState & ODS_FOCUS) DrawFocusRect(draw.hDC, &bounds);
    RestoreDC(draw.hDC, saved);
}

}  // namespace fixture
