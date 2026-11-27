#pragma once

#include <Windows.h>
#include <array>
#include <chrono>
#include <exception>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace desktop::windows {

// A Windows clipboard transaction on the same thread that sends input and pumps the owner window.
class ClipboardPaste {
public:
    using Clock = std::chrono::steady_clock;
    static constexpr std::chrono::milliseconds restoreBudget{750};

    ClipboardPaste(DWORD pid, std::function<void()> check, Clock::time_point deadline);
    ~ClipboardPaste();
    ClipboardPaste(const ClipboardPaste&) = delete;
    ClipboardPaste& operator=(const ClipboardPaste&) = delete;

    void stage(std::u16string_view text);
    void arm(std::chrono::milliseconds timeout);
    void awaitRead();
    // Call on both success and failure. The destructor only releases local resources.
    void restore();

private:
    struct Block {
        UINT format;
        HGLOBAL memory;
        bool transferred = false;

        Block(UINT format, SIZE_T size);
        Block(Block&& other) noexcept;
        ~Block();
        bool publish();
    };

    static LRESULT CALLBACK windowProc(HWND, UINT, WPARAM, LPARAM);
    void render(UINT format);
    void openForPaste();
    void pump() const;
    void checkOwner() const;
    bool isCurrent() const;
    void requireRenderBudget() const;
    std::vector<UINT> formats() const;
    void snapshot();

    DWORD pid_;
    std::function<void()> check_;
    Clock::time_point deadline_;
    std::wstring className_;
    HINSTANCE instance_;
    HWND owner_ = nullptr;
    std::array<UINT, 3> privacyFormats_{};
    std::vector<Block> privacy_;
    std::vector<Block> original_;
    std::optional<Block> payload_;
    std::exception_ptr renderFailure_;
    DWORD sequence_ = 0;
    Clock::time_point renderUntil_;
    bool staged_ = false;
    bool armed_ = false;
    bool rendered_ = false;
    bool lost_ = false;
};
} // namespace desktop::windows
