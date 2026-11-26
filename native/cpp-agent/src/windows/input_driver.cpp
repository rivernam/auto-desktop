#include "windows/input_driver.hpp"

#include <Windows.h>

#include <algorithm>
#include <atomic>
#include <climits>
#include <future>
#include <mutex>
#include <random>
#include <thread>

namespace desktop::windows {
namespace {
using Clock = std::chrono::steady_clock;
using namespace std::chrono_literals;

// DPI_AWARENESS_CONTEXT values. The functions that take them are resolved at run time for Windows 7.
using Context = HANDLE;
const Context perMonitorV2Context = reinterpret_cast<Context>(static_cast<INT_PTR>(-4));
const Context perMonitorContext = reinterpret_cast<Context>(static_cast<INT_PTR>(-3));

// The driver ends this long before the request deadline, so the worker never has to answer for it.
constexpr auto margin = 250ms;
constexpr auto observeLimit = 500ms;
constexpr auto reachLimit = 200ms;
constexpr auto foregroundLimit = 500ms;
constexpr std::size_t heldLimit = 8;
constexpr std::size_t chunkUnits = 16;

Error refusal(const char* code, const char* message) {
    Error error(code, message);
    error.inputSent = false;
    return error;
}

struct DpiApi {
    using SetThreadContext = Context(WINAPI*)(Context);
    using GetThreadContext = Context(WINAPI*)();
    using AwarenessOf = int(WINAPI*)(Context);
    using ContextsEqual = BOOL(WINAPI*)(Context, Context);
    using ProcessAwareness = HRESULT(WINAPI*)(HANDLE, int*);
    SetThreadContext set = nullptr;
    GetThreadContext get = nullptr;
    AwarenessOf awareness = nullptr;
    ContextsEqual equal = nullptr;
    ProcessAwareness process = nullptr;

    DpiApi() {
        if (const HMODULE user = GetModuleHandleW(L"user32.dll")) {
            set = reinterpret_cast<SetThreadContext>(GetProcAddress(user, "SetThreadDpiAwarenessContext"));
            get = reinterpret_cast<GetThreadContext>(GetProcAddress(user, "GetThreadDpiAwarenessContext"));
            awareness = reinterpret_cast<AwarenessOf>(GetProcAddress(user, "GetAwarenessFromDpiAwarenessContext"));
            equal = reinterpret_cast<ContextsEqual>(GetProcAddress(user, "AreDpiAwarenessContextsEqual"));
        }
        // Windows 8.1. The module stays loaded for the life of the process.
        if (const HMODULE shcore = LoadLibraryExW(L"shcore.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32))
            process = reinterpret_cast<ProcessAwareness>(GetProcAddress(shcore, "GetProcessDpiAwareness"));
    }
};

// Per-monitor v2 for the calling thread while the driver works on it, so every coordinate is physical.
class ScopedDpi {
public:
    explicit ScopedDpi(const DpiApi& api) : api_(api) {
        if (!api_.set) return;
        previous_ = api_.set(perMonitorV2Context);
        if (!previous_) previous_ = api_.set(perMonitorContext);
    }
    ~ScopedDpi() {
        if (previous_) api_.set(previous_);
    }
    ScopedDpi(const ScopedDpi&) = delete;
    ScopedDpi& operator=(const ScopedDpi&) = delete;

private:
    const DpiApi& api_;
    Context previous_ = nullptr;
};

// The awareness the calling thread has now. Call inside a ScopedDpi.
const char* awareness(const DpiApi& api) {
    if (api.get && api.awareness) {
        const auto context = api.get();
        if (api.equal && api.equal(context, perMonitorV2Context)) return "perMonitorV2";
        switch (api.awareness(context)) {
        case 2: return "perMonitor";
        case 1: return "system";
        default: return "unaware";
        }
    }
    int value = 0;
    if (api.process && SUCCEEDED(api.process(nullptr, &value)))
        return value == 2 ? "perMonitor" : value == 1 ? "system" : "unaware";
    return IsProcessDPIAware() ? "system" : "unaware";
}

// An unaware thread sees scaled coordinates when the primary display is scaled.
bool scaledDisplay() {
    DEVMODEW mode{};
    mode.dmSize = sizeof(mode);
    if (!EnumDisplaySettingsW(nullptr, ENUM_CURRENT_SETTINGS, &mode)) return true;
    return static_cast<int>(mode.dmPelsWidth) != GetSystemMetrics(SM_CXSCREEN)
        || static_cast<int>(mode.dmPelsHeight) != GetSystemMetrics(SM_CYSCREEN);
}

std::optional<DWORD> integrity(HANDLE process) {
    HANDLE token = nullptr;
    if (!OpenProcessToken(process, TOKEN_QUERY, &token)) return {};
    std::optional<DWORD> result;
    DWORD size = 0;
    GetTokenInformation(token, TokenIntegrityLevel, nullptr, 0, &size);
    if (size >= sizeof(TOKEN_MANDATORY_LABEL) && size <= 1024) {
        std::vector<unsigned char> buffer(size);
        if (GetTokenInformation(token, TokenIntegrityLevel, buffer.data(), size, &size)) {
            const auto* label = reinterpret_cast<const TOKEN_MANDATORY_LABEL*>(buffer.data());
            const auto count = *GetSidSubAuthorityCount(label->Label.Sid);
            if (count > 0) result = *GetSidSubAuthority(label->Label.Sid, count - 1u);
        }
    }
    CloseHandle(token);
    return result;
}

const char* integrityName(DWORD rid) {
    if (rid < SECURITY_MANDATORY_LOW_RID) return "untrusted";
    if (rid < SECURITY_MANDATORY_MEDIUM_RID) return "low";
    if (rid < SECURITY_MANDATORY_MEDIUM_PLUS_RID) return "medium";
    if (rid < SECURITY_MANDATORY_HIGH_RID) return "mediumPlus";
    if (rid < SECURITY_MANDATORY_SYSTEM_RID) return "high";
    return "system";
}

std::wstring desktopName(HDESK desktop) {
    wchar_t name[256]{};
    DWORD needed = 0;
    if (!desktop || !GetUserObjectInformationW(desktop, UOI_NAME, name, sizeof(name) - sizeof(wchar_t), &needed))
        return {};
    return name;
}

// False on the lock screen, the secure UAC desktop and a disconnected session.
bool onInputDesktop() {
    const HDESK input = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    if (!input) return false;
    const auto name = desktopName(input);
    CloseDesktop(input);
    const auto own = desktopName(GetThreadDesktop(GetCurrentThreadId()));
    return !name.empty() && _wcsicmp(name.c_str(), own.c_str()) == 0;
}

DWORD processOf(HWND window) {
    DWORD pid = 0;
    if (window) GetWindowThreadProcessId(window, &pid);
    return pid;
}

Bounds virtualScreen() {
    return {GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN),
            GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN)};
}

// Shared with the hook callbacks, which have no context argument. One driver exists per process.
struct HookCounters {
    ULONG_PTR tag = 0;
    std::atomic<std::uint64_t> observed{0};
    std::atomic<std::uint64_t> foreign{0};
    std::atomic<ULONGLONG> lastForeign{0};
};
std::atomic<HookCounters*> activeCounters{nullptr};

// Kept trivial: Windows drops a low-level hook that is slow to return.
void see(bool injected, ULONG_PTR extra) {
    auto* counters = activeCounters.load(std::memory_order_acquire);
    if (!counters) return;
    if (injected && extra == counters->tag) {
        counters->observed.fetch_add(1, std::memory_order_release);
    } else {
        counters->lastForeign.store(GetTickCount64(), std::memory_order_release);
        counters->foreign.fetch_add(1, std::memory_order_release);
    }
}

LRESULT CALLBACK mouseHook(int code, WPARAM message, LPARAM data) {
    if (code == HC_ACTION) {
        const auto* event = reinterpret_cast<const MSLLHOOKSTRUCT*>(data);
        see((event->flags & LLMHF_INJECTED) != 0, event->dwExtraInfo);
    }
    return CallNextHookEx(nullptr, code, message, data);
}

LRESULT CALLBACK keyboardHook(int code, WPARAM message, LPARAM data) {
    if (code == HC_ACTION) {
        const auto* event = reinterpret_cast<const KBDLLHOOKSTRUCT*>(data);
        see((event->flags & LLKHF_INJECTED) != 0, event->dwExtraInfo);
    }
    return CallNextHookEx(nullptr, code, message, data);
}

// WH_MOUSE_LL and WH_KEYBOARD_LL on a thread that does nothing but pump messages for them.
class HookMonitor {
public:
    explicit HookMonitor(HookCounters& counters) : counters_(counters) {}
    ~HookMonitor() { stop(); }
    HookMonitor(const HookMonitor&) = delete;
    HookMonitor& operator=(const HookMonitor&) = delete;

    bool running() const { return thread_.joinable(); }

    bool start() {
        if (running()) return true;
        std::promise<DWORD> ready;
        auto started = ready.get_future();
        activeCounters.store(&counters_, std::memory_order_release);
        thread_ = std::thread([&ready] {
            MSG message;
            // Creates the queue before the thread ID is published for WM_QUIT.
            PeekMessageW(&message, nullptr, WM_USER, WM_USER, PM_NOREMOVE);
            const HINSTANCE module = GetModuleHandleW(nullptr);
            const HHOOK mouse = SetWindowsHookExW(WH_MOUSE_LL, mouseHook, module, 0);
            const HHOOK keyboard = SetWindowsHookExW(WH_KEYBOARD_LL, keyboardHook, module, 0);
            const bool installed = mouse && keyboard;
            ready.set_value(installed ? GetCurrentThreadId() : 0);
            if (installed) {
                while (GetMessageW(&message, nullptr, 0, 0) > 0) {}
            }
            if (mouse) UnhookWindowsHookEx(mouse);
            if (keyboard) UnhookWindowsHookEx(keyboard);
        });
        threadId_ = started.get();
        if (!threadId_) {
            thread_.join();
            activeCounters.store(nullptr, std::memory_order_release);
            return false;
        }
        return true;
    }

    void stop() {
        if (!running()) return;
        PostThreadMessageW(threadId_, WM_QUIT, 0, 0);
        thread_.join();
        threadId_ = 0;
        activeCounters.store(nullptr, std::memory_order_release);
    }

private:
    HookCounters& counters_;
    std::thread thread_;
    DWORD threadId_ = 0;
};

// One INPUT record and what it does to the set of pressed keys and buttons.
struct Event {
    INPUT input{};
    enum class Kind { none, press, release } kind = Kind::none;
    int id = 0;
};

class Driver;

// The state of one request: what it pressed, how much it sent, and the checks between batches.
class Run {
public:
    Run(Driver& driver, const InputCommand& command, const InputGate& gate);
    InputOutcome execute();
    Error fail(Error error);

private:
    HWND target() const { return reinterpret_cast<HWND>(static_cast<std::uintptr_t>(command_.window)); }
    void checkWindow() const;
    void checkReady(bool foreground, bool user) const;
    void checkForeground() const;
    void checkUser() const;
    ScreenPoint resolve(const InputPoint& point) const;
    void checkPoint(const ScreenPoint& point) const;
    void hitTest(const ScreenPoint& point) const;
    bool belongs(HWND window) const;
    void begin();
    void checkTime() const;
    void pause(int milliseconds) const;
    void send(std::vector<Event> batch);
    void reach(const ScreenPoint& point) const;
    bool settle();
    Event move(const ScreenPoint& point) const;
    Event button(bool down) const;
    Event key(const Key& key, bool up) const;
    Event unicode(char16_t unit, bool up) const;
    InputOutcome pointer();
    InputOutcome drag();
    InputOutcome keyboard();
    InputOutcome text();
    InputOutcome activate();

    Driver& driver_;
    const InputCommand& command_;
    const InputGate& gate_;
    const Clock::time_point stopAt_;
    std::vector<std::pair<int, INPUT>> pressed_;
    bool begun_ = false;
    bool sent_ = false;
    int events_ = 0;
    std::uint64_t observedAtStart_ = 0, foreignAtStart_ = 0;
    Bounds screen_{};
};

class Driver final : public InputDriver {
public:
    Driver() : hooks_(counters_) {
        std::random_device random;
        while (!tag_) tag_ = static_cast<ULONG_PTR>((static_cast<std::uint64_t>(random()) << 32) | random());
        counters_.tag = tag_;
    }

    ~Driver() override {
        const std::lock_guard<std::timed_mutex> lock(busy_);
        release({});
        hooks_.stop();
    }

    InputStatus status() override {
        const ScopedDpi dpi(api_);
        InputStatus status;
        status.dpiAwareness = awareness(api_);
        if (const auto problem = dpiProblem(status.dpiAwareness)) {
            status.reason = problem;
        } else {
            status.available = true;
            status.reason.clear();
        }
        const auto own = integrity(GetCurrentProcess());
        status.integrity = own ? integrityName(*own) : "untrusted";
        status.inputDesktop = onInputDesktop();
        status.virtualScreen = virtualScreen();
        status.monitors = GetSystemMetrics(SM_CMONITORS);
        status.buttonsSwapped = GetSystemMetrics(SM_SWAPBUTTON) != 0;
        return status;
    }

    Bounds windowRect(std::uint32_t window, int pid) override {
        const ScopedDpi dpi(api_);
        const auto handle = reinterpret_cast<HWND>(static_cast<std::uintptr_t>(window));
        RECT rect{};
        if (!window || !IsWindow(handle) || processOf(handle) != static_cast<DWORD>(pid) || !GetWindowRect(handle, &rect))
            throw refusal("WINDOW_NOT_FOUND", "The window no longer exists or belongs to another process.");
        return {rect.left, rect.top, static_cast<long long>(rect.right) - rect.left,
                static_cast<long long>(rect.bottom) - rect.top};
    }

    std::vector<std::uint16_t> held() override {
        const std::lock_guard<std::mutex> lock(heldMutex_);
        std::vector<std::uint16_t> codes;
        for (const auto& key : held_) codes.push_back(key.vk);
        return codes;
    }

    InputOutcome perform(const InputCommand& command, const InputGate& gate) override {
        std::unique_lock<std::timed_mutex> lock(busy_, std::defer_lock);
        const auto stopAt = command.expires == Clock::time_point::max() ? command.expires : command.expires - margin;
        // A request that timed out on an abandoned worker can still be running.
        if (!lock.try_lock_until(stopAt)) throw refusal("TIMEOUT", "Another input request is still running.");
        const ScopedDpi dpi(api_);
        Run run(*this, command, gate);
        try {
            return run.execute();
        } catch (const Error& error) {
            throw run.fail(error);
        } catch (const std::exception&) {
            throw run.fail(Error("INTERNAL_ERROR", "The input could not be completed."));
        }
    }

private:
    friend class Run;

    const char* dpiProblem(const std::string& dpi) const {
        if (dpi == "unaware" && scaledDisplay()) return "The input thread is DPI-unaware on a scaled display.";
        return nullptr;
    }

    // Lets go of what a failed request pressed and of every key the session holds. True if anything went up.
    bool release(const std::vector<std::pair<int, INPUT>>& pressed) {
        std::vector<INPUT> ups;
        for (auto entry = pressed.rbegin(); entry != pressed.rend(); ++entry) ups.push_back(entry->second);
        std::vector<Key> keys;
        {
            const std::lock_guard<std::mutex> lock(heldMutex_);
            keys = held_;
        }
        for (auto key = keys.rbegin(); key != keys.rend(); ++key) ups.push_back(keyInput(*key, true));
        if (ups.empty()) return false;
        const auto sent = SendInput(static_cast<UINT>(ups.size()), ups.data(), sizeof(INPUT));
        if (sent != ups.size()) return false;
        const std::lock_guard<std::mutex> lock(heldMutex_);
        held_.clear();
        return true;
    }

    INPUT keyInput(const Key& key, bool up) const {
        INPUT input{};
        input.type = INPUT_KEYBOARD;
        input.ki.wVk = key.vk;
        input.ki.wScan = static_cast<WORD>(MapVirtualKeyW(key.vk, MAPVK_VK_TO_VSC));
        input.ki.dwFlags = (key.extended ? KEYEVENTF_EXTENDEDKEY : 0) | (up ? KEYEVENTF_KEYUP : 0);
        input.ki.dwExtraInfo = tag_;
        return input;
    }

    void ensureHooks() {
        if (reinstall_ && hooks_.running()) hooks_.stop();
        if (hooks_.running()) return;
        if (!hooks_.start()) throw refusal("INPUT_UNAVAILABLE", "The input monitor could not be installed.");
        installedTick_ = GetTickCount();
        reinstall_ = false;
    }

    DpiApi api_;
    ULONG_PTR tag_ = 0;
    HookCounters counters_;
    HookMonitor hooks_;
    bool reinstall_ = false;
    DWORD installedTick_ = 0;
    std::timed_mutex busy_;
    std::mutex heldMutex_;
    std::vector<Key> held_;
};

Run::Run(Driver& driver, const InputCommand& command, const InputGate& gate)
    : driver_(driver), command_(command), gate_(gate),
      stopAt_(command.expires == Clock::time_point::max() ? command.expires : command.expires - margin),
      screen_(virtualScreen()) {}

// Every error leaves here: inputSent is what this request actually sent, whatever the thrower assumed.
Error Run::fail(Error error) {
    error.inputSent = sent_;
    error.released = driver_.release(pressed_);
    pressed_.clear();
    return error;
}

void Run::checkWindow() const {
    const HWND window = target();
    if (!command_.window || !IsWindow(window) || processOf(window) != static_cast<DWORD>(command_.processId))
        throw refusal("WINDOW_NOT_FOUND", "The window no longer exists or belongs to another process.");
}

// Steps 2 to 8 of the specification, in order.
void Run::checkReady(bool foreground, bool user) const {
    checkWindow();
    const HWND window = target();
    if (GetAncestor(window, GA_ROOT) != window || !IsWindowVisible(window) || IsIconic(window))
        throw refusal("PRECONDITION_FAILED", "The window must be a visible top-level window that is not minimized.");
    if (!onInputDesktop())
        throw refusal("INPUT_DESKTOP_UNAVAILABLE", "The input desktop is not the agent's desktop.");
    const HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, static_cast<DWORD>(command_.processId));
    std::optional<DWORD> theirs;
    if (process) {
        theirs = integrity(process);
        CloseHandle(process);
    }
    const auto own = integrity(GetCurrentProcess());
    // UIPI drops input silently, so an unreadable level counts as higher.
    if (!theirs || !own || *theirs > *own)
        throw refusal("INTEGRITY_MISMATCH", "The target runs at a higher integrity level than the agent.");
    if (const auto problem = driver_.dpiProblem(awareness(driver_.api_))) throw refusal("INPUT_UNAVAILABLE", problem);
    if (foreground) checkForeground();
    if (user) checkUser();
}

bool Run::belongs(HWND window) const {
    const HWND own = target();
    if (window == own) return true;
    return window && processOf(window) == static_cast<DWORD>(command_.processId)
        && GetAncestor(window, GA_ROOTOWNER) == GetAncestor(own, GA_ROOTOWNER);
}

void Run::checkForeground() const {
    const HWND foreground = GetForegroundWindow();
    if (!belongs(foreground))
        throw refusal("FOREGROUND_MISMATCH", "The target window is not in the foreground.");
    if (!isKeyboard(command_.op)) return;
    GUITHREADINFO info{};
    info.cbSize = sizeof(info);
    if (!GetGUIThreadInfo(GetWindowThreadProcessId(foreground, nullptr), &info))
        throw refusal("FOREGROUND_MISMATCH", "The keyboard focus could not be read.");
    const HWND focus = info.hwndFocus ? info.hwndFocus : info.hwndActive;
    if (processOf(focus) != static_cast<DWORD>(command_.processId))
        throw refusal("FOREGROUND_MISMATCH", "The keyboard focus is not in the target process.");
}

void Run::checkUser() const {
    for (const int code : {VK_LBUTTON, VK_RBUTTON, VK_MBUTTON, VK_XBUTTON1, VK_XBUTTON2}) {
        if (GetAsyncKeyState(code) & 0x8000)
            throw refusal("USER_INPUT_CONFLICT", "A mouse button is held down.");
    }
    const auto held = driver_.held();
    for (const int code : {VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN}) {
        if (std::find(held.begin(), held.end(), static_cast<std::uint16_t>(code)) != held.end()) continue;
        if (GetAsyncKeyState(code) & 0x8000) throw refusal("USER_INPUT_CONFLICT", "A modifier key is held down.");
    }
    if (command_.quietMs <= 0) return;
    const auto quiet = static_cast<DWORD>(command_.quietMs);
    const auto conflict = [] { return refusal("USER_INPUT_CONFLICT", "Someone used the mouse or keyboard just now."); };
    const bool hooked = driver_.hooks_.running();
    if (hooked) {
        const auto last = driver_.counters_.lastForeign.load(std::memory_order_acquire);
        if (last && GetTickCount64() - last < quiet) throw conflict();
    }
    // Before the hook, the session's last input time is all there is. Afterwards it still covers input
    // older than the hook, but no longer tells this agent's own input apart.
    LASTINPUTINFO info{};
    info.cbSize = sizeof(info);
    if (GetLastInputInfo(&info) && GetTickCount() - info.dwTime < quiet
        && (!hooked || static_cast<LONG>(info.dwTime - driver_.installedTick_) < 0)) throw conflict();
}

ScreenPoint Run::resolve(const InputPoint& point) const {
    long long x = point.x, y = point.y;
    if (point.space == Space::window) {
        RECT rect{};
        if (!GetWindowRect(target(), &rect)) throw refusal("WINDOW_NOT_FOUND", "The window no longer exists.");
        x += rect.left;
        y += rect.top;
    } else if (point.space == Space::client) {
        POINT origin{0, 0};
        if (!ClientToScreen(target(), &origin)) throw refusal("WINDOW_NOT_FOUND", "The window no longer exists.");
        x += origin.x;
        y += origin.y;
    }
    if (x < LONG_MIN || x > LONG_MAX || y < LONG_MIN || y > LONG_MAX)
        throw refusal("PRECONDITION_FAILED", "The point is outside the target window.");
    return {static_cast<long>(x), static_cast<long>(y)};
}

// Step 9.
void Run::checkPoint(const ScreenPoint& point) const {
    RECT rect{};
    if (!GetWindowRect(target(), &rect)) throw refusal("WINDOW_NOT_FOUND", "The window no longer exists.");
    const Bounds window{rect.left, rect.top, static_cast<long long>(rect.right) - rect.left,
                        static_cast<long long>(rect.bottom) - rect.top};
    if (!contains(window, point) || !contains(screen_, point))
        throw refusal("PRECONDITION_FAILED", "The point is outside the target window or the screen.");
    hitTest(point);
}

void Run::hitTest(const ScreenPoint& point) const {
    const HWND hit = WindowFromPoint(POINT{point.x, point.y});
    if (!belongs(hit ? GetAncestor(hit, GA_ROOT) : nullptr)) {
        Error error("WINDOW_OBSCURED", "Another window covers the point.");
        error.inputSent = sent_;
        throw error;
    }
}

void Run::checkTime() const {
    if (Clock::now() < stopAt_) return;
    if (sent_) {
        Error error("ACTION_OUTCOME_UNKNOWN", "The request deadline passed while input was being sent.");
        error.inputSent = true;
        throw error;
    }
    throw refusal("TIMEOUT", "The request expired before input was sent.");
}

void Run::pause(int milliseconds) const {
    if (milliseconds <= 0) return;
    if (Clock::now() + std::chrono::milliseconds(milliseconds) >= stopAt_) {
        std::this_thread::sleep_until(stopAt_);
        checkTime();
    }
    Sleep(static_cast<DWORD>(milliseconds));
}

// Opens the gate and installs the monitor. Nothing before this sends anything.
void Run::begin() {
    checkTime();
    gate_();
    driver_.ensureHooks();
    observedAtStart_ = driver_.counters_.observed.load(std::memory_order_acquire);
    foreignAtStart_ = driver_.counters_.foreign.load(std::memory_order_acquire);
    begun_ = true;
}

void Run::send(std::vector<Event> batch) {
    if (!begun_) begin();
    if (sent_) {
        checkTime();
        if (driver_.counters_.foreign.load(std::memory_order_acquire) != foreignAtStart_) {
            Error error("USER_INPUT_CONFLICT", "Someone used the mouse or keyboard during the input.");
            error.inputSent = true;
            throw error;
        }
    }
    std::vector<INPUT> inputs;
    for (const auto& event : batch) inputs.push_back(event.input);
    const auto count = SendInput(static_cast<UINT>(inputs.size()), inputs.data(), sizeof(INPUT));
    for (UINT i = 0; i < count; ++i) {
        const auto& event = batch[i];
        if (event.kind == Event::Kind::press) {
            INPUT up = event.input;
            if (up.type == INPUT_KEYBOARD) up.ki.dwFlags |= KEYEVENTF_KEYUP;
            else up.mi.dwFlags <<= 1; // Every MOUSEEVENTF_*UP flag is its DOWN flag shifted left once.
            pressed_.emplace_back(event.id, up);
        } else if (event.kind == Event::Kind::release) {
            const auto found = std::find_if(pressed_.begin(), pressed_.end(),
                                            [&](const auto& entry) { return entry.first == event.id; });
            if (found != pressed_.end()) pressed_.erase(found);
        }
    }
    events_ += static_cast<int>(count);
    if (count == 0 && !sent_) throw refusal("INPUT_BLOCKED", "The system did not accept the input.");
    if (count > 0) sent_ = true;
    if (count != inputs.size()) {
        Error error("ACTION_OUTCOME_UNKNOWN", "The system accepted only part of the input.");
        error.inputSent = true;
        throw error;
    }
}

void Run::reach(const ScreenPoint& point) const {
    const auto until = std::min(Clock::now() + reachLimit, stopAt_);
    for (;;) {
        POINT cursor{};
        if (GetCursorPos(&cursor) && cursor.x == point.x && cursor.y == point.y) return;
        if (Clock::now() >= until) break;
        Sleep(1);
    }
    checkTime();
    Error error("PRECONDITION_FAILED", "The cursor did not reach the requested point.");
    error.inputSent = true;
    throw error;
}

// True once the hook has seen every tagged event of this request.
bool Run::settle() {
    const auto until = std::min(Clock::now() + observeLimit, stopAt_);
    const auto expected = static_cast<std::uint64_t>(events_);
    std::uint64_t seen = 0;
    for (;;) {
        seen = driver_.counters_.observed.load(std::memory_order_acquire) - observedAtStart_;
        if (seen >= expected || Clock::now() >= until) break;
        Sleep(1);
    }
    // A monitor that saw none of them is presumed gone and is installed again by the next request.
    if (seen == 0 && expected > 0) driver_.reinstall_ = true;
    return seen >= expected;
}

Event Run::move(const ScreenPoint& point) const {
    Event event;
    event.input.type = INPUT_MOUSE;
    event.input.mi.dx = normalizeAbsolute(point.x, screen_.x, screen_.width);
    event.input.mi.dy = normalizeAbsolute(point.y, screen_.y, screen_.height);
    event.input.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK;
    event.input.mi.dwExtraInfo = driver_.tag_;
    return event;
}

Event Run::button(bool down) const {
    // SendInput names physical buttons. The request names logical ones.
    const bool swapped = GetSystemMetrics(SM_SWAPBUTTON) != 0;
    DWORD flag = MOUSEEVENTF_MIDDLEDOWN;
    if (command_.button == Button::left) flag = swapped ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_LEFTDOWN;
    if (command_.button == Button::right) flag = swapped ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_RIGHTDOWN;
    Event event;
    event.input.type = INPUT_MOUSE;
    event.input.mi.dwFlags = down ? flag : flag << 1;
    event.input.mi.dwExtraInfo = driver_.tag_;
    event.kind = down ? Event::Kind::press : Event::Kind::release;
    event.id = 0x20000 + static_cast<int>(flag);
    return event;
}

Event Run::key(const Key& key, bool up) const {
    Event event;
    event.input = driver_.keyInput(key, up);
    event.kind = up ? Event::Kind::release : Event::Kind::press;
    event.id = key.vk;
    return event;
}

Event Run::unicode(char16_t unit, bool up) const {
    Event event;
    event.input.type = INPUT_KEYBOARD;
    event.input.ki.wScan = static_cast<WORD>(unit);
    event.input.ki.dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0);
    event.input.ki.dwExtraInfo = driver_.tag_;
    event.kind = up ? Event::Kind::release : Event::Kind::press;
    event.id = 0x10000 + unit;
    return event;
}

InputOutcome Run::execute() {
    switch (command_.op) {
    case InputOp::activateWindow: return activate();
    case InputOp::pointerDrag: return drag();
    case InputOp::typeText: return text();
    case InputOp::keyPress:
    case InputOp::keyDown:
    case InputOp::keyUp: return keyboard();
    default: return pointer();
    }
}

InputOutcome Run::pointer() {
    checkReady(true, true);
    const auto point = resolve(command_.point);
    checkPoint(point);
    send({move(point)});
    reach(point);
    std::vector<Event> batch;
    if (command_.op == InputOp::pointerClick) {
        hitTest(point);
        for (int i = 0; i < command_.clicks; ++i) {
            batch.push_back(button(true));
            batch.push_back(button(false));
        }
    } else if (command_.op == InputOp::pointerScroll) {
        hitTest(point);
        Event wheel;
        wheel.input.type = INPUT_MOUSE;
        wheel.input.mi.dwFlags = command_.horizontal ? MOUSEEVENTF_HWHEEL : MOUSEEVENTF_WHEEL;
        wheel.input.mi.mouseData = static_cast<DWORD>(command_.delta * WHEEL_DELTA);
        wheel.input.mi.dwExtraInfo = driver_.tag_;
        batch.push_back(wheel);
    }
    if (!batch.empty()) send(std::move(batch));
    InputOutcome outcome;
    outcome.point = point;
    outcome.events = events_;
    outcome.observed = settle();
    return outcome;
}

InputOutcome Run::drag() {
    checkReady(true, true);
    const auto from = resolve(command_.from);
    const auto to = resolve(command_.to);
    checkPoint(from);
    checkPoint(to);
    send({move(from)});
    reach(from);
    hitTest(from);
    send({button(true)});
    for (int step = 1; step <= command_.steps; ++step) {
        pause(command_.stepDelayMs);
        const auto along = [&](long a, long b) {
            return static_cast<long>(a + roundHalfUp(static_cast<double>(b - a) * step / command_.steps));
        };
        const ScreenPoint next{along(from.x, to.x), along(from.y, to.y)};
        hitTest(next);
        send({move(next)});
        reach(next);
    }
    hitTest(to);
    send({button(false)});
    InputOutcome outcome;
    outcome.from = from;
    outcome.to = to;
    outcome.events = events_;
    outcome.observed = settle();
    return outcome;
}

InputOutcome Run::keyboard() {
    const auto held = driver_.held();
    const auto holds = [&](std::uint16_t code) { return std::find(held.begin(), held.end(), code) != held.end(); };
    const auto& chord = command_.keys;
    if (command_.op == InputOp::keyUp && !holds(chord.key.vk))
        throw refusal("PRECONDITION_FAILED", "This session does not hold the key.");
    if (command_.op != InputOp::keyUp && holds(chord.key.vk))
        throw refusal("PRECONDITION_FAILED", "This session already holds the key.");
    if (command_.op == InputOp::keyDown && held.size() >= heldLimit)
        throw refusal("PRECONDITION_FAILED", "This session already holds the most keys allowed.");
    checkReady(true, true);
    std::vector<Event> batch;
    if (command_.op == InputOp::keyPress) {
        // A modifier the session already holds stays down. Pressing it again would end the hold.
        std::vector<Key> pressed;
        for (const auto& modifier : chord.modifiers) {
            if (!holds(modifier.vk)) pressed.push_back(modifier);
        }
        for (const auto& modifier : pressed) batch.push_back(key(modifier, false));
        batch.push_back(key(chord.key, false));
        batch.push_back(key(chord.key, true));
        for (auto modifier = pressed.rbegin(); modifier != pressed.rend(); ++modifier)
            batch.push_back(key(*modifier, true));
    } else {
        batch.push_back(key(chord.key, command_.op == InputOp::keyUp));
    }
    send(std::move(batch));
    {
        const std::lock_guard<std::mutex> lock(driver_.heldMutex_);
        auto& keys = driver_.held_;
        if (command_.op == InputOp::keyDown) {
            // The session owns the key now. A later failure or the end of the session releases it.
            keys.push_back(chord.key);
            pressed_.clear();
        } else if (command_.op == InputOp::keyUp) {
            keys.erase(std::remove_if(keys.begin(), keys.end(),
                                      [&](const Key& entry) { return entry.vk == chord.key.vk; }), keys.end());
        }
    }
    InputOutcome outcome;
    outcome.events = events_;
    outcome.observed = settle();
    return outcome;
}

InputOutcome Run::text() {
    checkReady(true, true);
    const auto& units = command_.text;
    std::size_t index = 0;
    while (index < units.size()) {
        if (index > 0) {
            pause(command_.intervalMs);
            // fail() marks the refusal as following sent input.
            checkForeground();
        }
        std::vector<Event> batch;
        auto end = std::min(index + chunkUnits, units.size());
        // A surrogate pair stays in one chunk.
        if (end < units.size() && units[end - 1] >= 0xD800 && units[end - 1] <= 0xDBFF) ++end;
        for (; index < end; ++index) {
            const char16_t unit = units[index];
            if (unit == u'\r' || unit == u'\t') {
                const Key named{unit == u'\r' ? vk::enter : vk::tab, false};
                batch.push_back(key(named, false));
                batch.push_back(key(named, true));
            } else {
                batch.push_back(unicode(unit, false));
                batch.push_back(unicode(unit, true));
            }
        }
        send(std::move(batch));
    }
    InputOutcome outcome;
    outcome.events = events_;
    outcome.observed = settle();
    return outcome;
}

InputOutcome Run::activate() {
    checkReady(false, false);
    checkTime();
    gate_();
    // One attempt, without the Alt-key or thread-attach workarounds that defeat the foreground lock.
    SetForegroundWindow(target());
    const auto until = std::min(Clock::now() + foregroundLimit, stopAt_);
    while (GetForegroundWindow() != target()) {
        if (Clock::now() >= until) throw refusal("FOREGROUND_MISMATCH", "Windows did not bring the window to the foreground.");
        Sleep(5);
    }
    return {};
}
} // namespace

std::unique_ptr<InputDriver> makeInputDriver() { return std::make_unique<Driver>(); }
} // namespace desktop::windows
