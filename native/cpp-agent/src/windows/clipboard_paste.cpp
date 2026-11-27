#include "clipboard_paste.hpp"
#include "core/desktop_adapter.hpp"

#include <algorithm>
#include <cstring>
#include <utility>

namespace desktop::windows {
namespace {
using namespace std::chrono_literals;
constexpr SIZE_T snapshotLimit = 1024 * 1024;
constexpr std::array privacyNames{L"ExcludeClipboardContentFromMonitorProcessing", L"CanIncludeInClipboardHistory",
                                  L"CanUploadToCloudClipboard"};

Error unsupported() { return {"CLIPBOARD_UNSUPPORTED", "Existing clipboard data cannot be safely restored."}; }
Error stagingFailed() { return {"INPUT_UNAVAILABLE", "The clipboard could not be prepared for paste."}; }
Error changed() { return {"CLIPBOARD_CHANGED", "Another application changed the clipboard."}; }
Error restoreFailed() { return {"CLIPBOARD_RESTORE_FAILED", "The clipboard could not be restored. Inspect its state before retrying."}; }

struct CloseClipboardOnExit {
    ~CloseClipboardOnExit() { CloseClipboard(); }
};

struct GlobalLockGuard {
    HGLOBAL memory;
    void* data;
    explicit GlobalLockGuard(HGLOBAL memory) : memory(memory), data(GlobalLock(memory)) {}
    ~GlobalLockGuard() { if (data) GlobalUnlock(memory); }
};
}

ClipboardPaste::Block::Block(UINT format, SIZE_T size) : format(format), memory(GlobalAlloc(GHND, size)) {
    if (!memory) throw stagingFailed();
}

ClipboardPaste::Block::Block(Block&& other) noexcept
    : format(other.format), memory(std::exchange(other.memory, nullptr)), transferred(other.transferred) {}

ClipboardPaste::Block::~Block() {
    if (!memory || transferred) return;
    {
        const GlobalLockGuard locked(memory);
        if (locked.data) SecureZeroMemory(locked.data, GlobalSize(memory));
    }
    GlobalFree(memory);
}

bool ClipboardPaste::Block::publish() {
    transferred = SetClipboardData(format, memory) != nullptr;
    return transferred;
}

ClipboardPaste::ClipboardPaste(DWORD pid, std::function<void()> check, Clock::time_point deadline)
    : pid_(pid), check_(std::move(check)), deadline_(deadline),
      className_(L"DesktopAgent.ClipboardOwner." + std::to_wstring(GetCurrentThreadId())), instance_(GetModuleHandleW(nullptr)) {
    WNDCLASSW window{};
    window.lpfnWndProc = windowProc;
    window.hInstance = instance_;
    window.lpszClassName = className_.c_str();
    if (RegisterClassW(&window)) {
        owner_ = CreateWindowExW(0, className_.c_str(), nullptr, 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, instance_, this);
        if (owner_) return;
        UnregisterClassW(className_.c_str(), instance_);
    }
    throw Error("INPUT_UNAVAILABLE", "A private clipboard owner window could not be created.");
}

ClipboardPaste::~ClipboardPaste() {
    DestroyWindow(owner_);
    UnregisterClassW(className_.c_str(), instance_);
}

LRESULT CALLBACK ClipboardPaste::windowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_NCCREATE) {
        const auto* create = reinterpret_cast<CREATESTRUCTW*>(lParam);
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    }
    auto* self = reinterpret_cast<ClipboardPaste*>(GetWindowLongPtrW(window, GWLP_USERDATA));
    if (!self) return DefWindowProcW(window, message, wParam, lParam);
    if (message == WM_DESTROYCLIPBOARD) {
        if (self->staged_) self->lost_ = true;
        return 0;
    }
    if (message == WM_RENDERFORMAT) {
        try { self->render(static_cast<UINT>(wParam)); }
        catch (...) { self->renderFailure_ = std::current_exception(); }
        return 0;
    }
    if (message == WM_RENDERALLFORMATS) return 0;
    return DefWindowProcW(window, message, wParam, lParam);
}

std::vector<UINT> ClipboardPaste::formats() const {
    std::vector<UINT> formats;
    for (UINT previous = 0;;) {
        SetLastError(0);
        const UINT format = EnumClipboardFormats(previous);
        if (!format) {
            if (GetLastError()) throw unsupported();
            return formats;
        }
        if (formats.size() == 7 || (format != CF_UNICODETEXT && format != CF_TEXT && format != CF_OEMTEXT
            && format != CF_LOCALE && std::find(privacyFormats_.begin(), privacyFormats_.end(), format) == privacyFormats_.end()))
            throw unsupported();
        formats.push_back(format);
        previous = format;
    }
}

void ClipboardPaste::snapshot() {
    const auto existing = formats();
    if (existing.empty()) return;
    if (existing.front() != CF_UNICODETEXT) throw unsupported();
    const HWND owner = GetClipboardOwner();
    // GetClipboardData can wait for a foreign WM_RENDERFORMAT. The API has no eager-data flag.
    if (owner && IsWindow(owner)) throw unsupported();
    SIZE_T remaining = snapshotLimit;
    for (const auto format : existing) {
        const DWORD before = GetClipboardSequenceNumber();
        const HGLOBAL source = GetClipboardData(format);
        if (!source || owner != GetClipboardOwner() || before != GetClipboardSequenceNumber()) throw unsupported();
        const SIZE_T size = GlobalSize(source);
        if (!size || size > remaining) throw unsupported();
        remaining -= size;
        original_.emplace_back(format, size);
        const GlobalLockGuard input(source);
        const GlobalLockGuard output(original_.back().memory);
        if (!input.data || !output.data) throw unsupported();
        std::memcpy(output.data, input.data, size);
    }
}

void ClipboardPaste::stage(std::u16string_view text) {
    for (std::size_t i = 0; i < privacyFormats_.size(); ++i) {
        const UINT format = RegisterClipboardFormatW(privacyNames[i]);
        if (!format) throw stagingFailed();
        privacyFormats_[i] = format;
        privacy_.emplace_back(format, sizeof(DWORD));
        const GlobalLockGuard locked(privacy_.back().memory);
        if (!locked.data) throw stagingFailed();
        *static_cast<DWORD*>(locked.data) = i == 0 ? 1 : 0;
    }
    payload_.emplace(CF_UNICODETEXT, (text.size() + 1) * sizeof(char16_t));
    {
        const GlobalLockGuard locked(payload_->memory);
        if (!locked.data) throw stagingFailed();
        std::memcpy(locked.data, text.data(), text.size() * sizeof(char16_t));
    }
    openForPaste();
    const CloseClipboardOnExit close;
    snapshot();
    check_();
    requireRenderBudget();
    if (!EmptyClipboard()) throw stagingFailed();
    staged_ = true;
    for (auto& block : privacy_) if (!block.publish()) throw stagingFailed();
    SetClipboardData(CF_UNICODETEXT, nullptr);
    if (!IsClipboardFormatAvailable(CF_UNICODETEXT)) throw stagingFailed();
}

void ClipboardPaste::arm(std::chrono::milliseconds timeout) {
    checkOwner();
    {
        openForPaste();
        const CloseClipboardOnExit close;
        if (!isCurrent()) throw changed();
        sequence_ = GetClipboardSequenceNumber();
    }
    check_();
    requireRenderBudget();
    renderUntil_ = std::min(deadline_ - restoreBudget, Clock::now() + timeout);
    armed_ = true;
}

void ClipboardPaste::openForPaste() {
    const auto until = Clock::now() + 80ms;
    const DWORD initialSequence = GetClipboardSequenceNumber();
    while (!OpenClipboard(owner_)) {
        check_();
        requireRenderBudget();
        if (staged_) checkOwner();
        if (Clock::now() >= until) throw Error("CLIPBOARD_BUSY", "Another application is holding the clipboard open.");
        if (staged_) pump();
        Sleep(2);
    }
    if (GetClipboardSequenceNumber() != initialSequence) {
        CloseClipboard();
        throw changed();
    }
}

void ClipboardPaste::requireRenderBudget() const {
    if (Clock::now() >= deadline_ - restoreBudget)
        throw Error("TIMEOUT", "No time remains to paste and restore the clipboard.");
}

void ClipboardPaste::render(UINT format) {
    if (!armed_ || rendered_ || format != CF_UNICODETEXT || renderFailure_ || Clock::now() >= renderUntil_) return;
    check_();
    checkOwner();
    if (GetClipboardSequenceNumber() != sequence_) throw changed();
    const HWND reader = GetOpenClipboardWindow();
    if (!reader) return;
    DWORD pid = 0;
    GetWindowThreadProcessId(reader, &pid);
    if (pid != pid_) return;
    if (!payload_->publish()) throw stagingFailed();
    rendered_ = true;
}

void ClipboardPaste::pump() const {
    // PeekMessage dispatches sent WM_RENDERFORMAT messages even when there is nothing posted.
    MSG message{};
    while (PeekMessageW(&message, owner_, 0, 0, PM_REMOVE)) DispatchMessageW(&message);
}

void ClipboardPaste::checkOwner() const {
    if (lost_ || GetClipboardOwner() != owner_) throw changed();
}

bool ClipboardPaste::isCurrent() const {
    if (lost_ || GetClipboardOwner() != owner_) return false;
    for (const auto& block : privacy_)
        if (block.transferred && GetClipboardData(block.format) != block.memory) return false;
    if (rendered_ && GetClipboardData(CF_UNICODETEXT) != payload_->memory) return false;
    try { formats(); }
    catch (const Error&) { return false; }
    return true;
}

void ClipboardPaste::awaitRead() {
    while (true) {
        pump();
        check_();
        checkOwner();
        if (renderFailure_) std::rethrow_exception(renderFailure_);
        if (rendered_) return;
        if (Clock::now() >= renderUntil_)
            throw Error("ACTION_OUTCOME_UNKNOWN", "The clipboard text was not requested in time. Inspect the target before retrying.");
        Sleep(2);
    }
}

void ClipboardPaste::restore() {
    if (!staged_) return;
    armed_ = false;
    const auto until = std::min(deadline_, Clock::now() + restoreBudget);
    while (!OpenClipboard(owner_)) {
        checkOwner();
        if (Clock::now() >= until) throw restoreFailed();
        pump();
        Sleep(2);
    }
    const CloseClipboardOnExit close;
    if (!isCurrent()) throw changed();
    if (!EmptyClipboard()) throw restoreFailed();
    bool restored = true;
    for (auto& block : original_) restored &= block.publish();
    if (!restored) throw restoreFailed();
}
} // namespace desktop::windows
