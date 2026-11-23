#include <windows.h>
#include <oleacc.h>
#include <wrl/client.h>

#include <nlohmann/json.hpp>

#include <algorithm>
#include <array>
#include <charconv>
#include <cstdint>
#include <iostream>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace {

using Microsoft::WRL::ComPtr;
using nlohmann::json;

constexpr long kMaxNodes = 256;
constexpr size_t kMaxDepth = 12;
constexpr UINT kMaxNameLength = 512;

template <typename Integer>
bool ParseDecimal(std::string_view input, Integer& number) {
    const auto end = input.data() + input.size();
    const auto result = std::from_chars(input.data(), end, number);
    return result.ec == std::errc{} && result.ptr == end && number != 0;
}

bool IsOwned(HWND window, DWORD pid) {
    DWORD observed = 0;
    return window && IsWindow(window) && GetWindowThreadProcessId(window, &observed) && observed == pid;
}

VARIANT ChildId(long id) {
    VARIANT result{};
    result.vt = VT_I4;
    result.lVal = id;
    return result;
}

struct VariantBuffer {
    std::array<VARIANT, kMaxNodes> values{};
    ~VariantBuffer() {
        for (auto& value : values) VariantClear(&value);
    }
};

std::optional<long> ReadNumber(IAccessible& object, VARIANT child, HRESULT (STDMETHODCALLTYPE IAccessible::*get)(VARIANT, VARIANT*)) {
    VARIANT value{};
    const auto result = (object.*get)(child, &value);
    const auto number = result == S_OK && value.vt == VT_I4 ? std::optional<long>{value.lVal} : std::nullopt;
    VariantClear(&value);
    return number;
}

std::optional<std::string> ReadName(IAccessible& object, VARIANT child) {
    BSTR value = nullptr;
    const auto result = object.get_accName(child, &value);
    const auto length = SysStringLen(value);
    std::optional<std::string> name;
    if (SUCCEEDED(result) && length == 0) {
        name.emplace();
    } else if (SUCCEEDED(result) && length <= kMaxNameLength) {
        const auto chars = static_cast<int>(length);
        const auto bytes = WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, chars, nullptr, 0, nullptr, nullptr);
        if (bytes > 0) {
            name.emplace(static_cast<size_t>(bytes), '\0');
            if (WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, value, chars, name->data(), bytes, nullptr, nullptr) != bytes) {
                name.reset();
            }
        }
    }
    SysFreeString(value);
    return name;
}

class Probe {
public:
    explicit Probe(DWORD pid) : pid_(pid) {}

    bool CaptureRoot(IAccessible& root, HWND window) {
        HWND boundWindow = nullptr;
        if (WindowFromAccessibleObject(&root, &boundWindow) != S_OK || boundWindow != window || !IsOwned(boundWindow, pid_)) {
            return false;
        }
        std::vector<long> path;
        Capture(root, boundWindow, ChildId(CHILDID_SELF), path);
        return !nodes_.empty();
    }

    json TakeResult() {
        return {{"status", "ok"}, {"nodes", std::move(nodes_)}, {"truncated", truncated_}, {"unreadable", unreadable_}};
    }

private:
    void Capture(IAccessible& object, HWND window, VARIANT child, std::vector<long>& path) {
        ++visited_;
        if (!IsOwned(window, pid_)) {
            ++unreadable_;
            return;
        }

        auto role = ReadNumber(object, child, &IAccessible::get_accRole);
        if (role && (*role < ROLE_SYSTEM_TITLEBAR || *role > ROLE_SYSTEM_OUTLINEBUTTON)) role.reset();
        auto state = ReadNumber(object, child, &IAccessible::get_accState);
        if (state && (*state < 0 || (*state & ~STATE_SYSTEM_VALID) != 0)) state.reset();

        std::optional<std::string> name;
        const bool nameAllowed = role && state && *role != ROLE_SYSTEM_TEXT && (*state & STATE_SYSTEM_PROTECTED) == 0;
        if (nameAllowed) name = ReadName(object, child);

        const bool simpleChild = child.lVal != CHILDID_SELF;
        long rawChildCount = 0;
        const auto childCountKnown = simpleChild || (object.get_accChildCount(&rawChildCount) == S_OK && rawChildCount >= 0);
        if (!role || !state || (nameAllowed && !name) || !childCountKnown) ++unreadable_;

        nodes_.push_back({
            {"path", path},
            {"role", role ? json(*role) : json(nullptr)},
            {"name", name ? json(*name) : json(nullptr)},
            {"state", state ? json(*state) : json(nullptr)},
            {"childCount", childCountKnown ? json(rawChildCount) : json(nullptr)},
        });
        if (childCountKnown && rawChildCount > 0) CaptureChildren(object, window, rawChildCount, path);
    }

    void CaptureChildren(IAccessible& object, HWND window, long count, std::vector<long>& path) {
        const long requested = std::min(count, kMaxNodes - visited_);
        if (path.size() >= kMaxDepth || requested == 0) {
            truncated_ = true;
            return;
        }
        if (requested < count) truncated_ = true;
        if (!IsOwned(window, pid_)) {
            ++unreadable_;
            return;
        }

        VariantBuffer children;
        long returned = 0;
        const auto result = AccessibleChildren(&object, 0, requested, children.values.data(), &returned);
        if (FAILED(result) || returned < 0 || returned > requested) {
            ++unreadable_;
            return;
        }
        if (returned < requested) ++unreadable_;

        for (long index = 0; index < returned; ++index) {
            if (visited_ == kMaxNodes) {
                truncated_ = true;
                break;
            }
            path.push_back(index);
            CaptureChild(object, window, children.values[index], path);
            path.pop_back();
        }
    }

    void CaptureChild(IAccessible& parent, HWND window, const VARIANT& child, std::vector<long>& path) {
        if (child.vt == VT_I4 && child.lVal > CHILDID_SELF) {
            Capture(parent, window, child, path);
            return;
        }
        if (child.vt == VT_DISPATCH && child.pdispVal) {
            ComPtr<IAccessible> nested;
            HWND nestedWindow = nullptr;
            if (SUCCEEDED(child.pdispVal->QueryInterface(IID_PPV_ARGS(nested.GetAddressOf()))) && nested &&
                WindowFromAccessibleObject(nested.Get(), &nestedWindow) == S_OK && IsOwned(nestedWindow, pid_)) {
                Capture(*nested.Get(), nestedWindow, ChildId(CHILDID_SELF), path);
                return;
            }
        }
        ++visited_;
        ++unreadable_;
    }

    DWORD pid_;
    long visited_ = 0;
    long unreadable_ = 0;
    bool truncated_ = false;
    json nodes_ = json::array();
};

int ReportError(const char* error, int exitCode) {
    std::cout << json{{"status", "error"}, {"error", error}}.dump() << '\n';
    return exitCode;
}

int Run(HWND window, DWORD pid) {
    if (!IsOwned(window, pid)) return ReportError("windowOwnershipMismatch", 3);

    ComPtr<IAccessible> root;
    const auto result = AccessibleObjectFromWindow(window, static_cast<DWORD>(OBJID_CLIENT), IID_PPV_ARGS(root.GetAddressOf()));
    if (FAILED(result) || !root) return ReportError("clientAccessibleUnavailable", 4);

    Probe probe(pid);
    if (!probe.CaptureRoot(*root.Get(), window)) return ReportError("clientAccessibleOwnershipUnverified", 4);
    if (!IsOwned(window, pid)) return ReportError("windowOwnershipMismatch", 3);
    std::cout << probe.TakeResult().dump() << '\n';
    return 0;
}

}  // namespace

int main(int argc, char* argv[]) {
    std::uintptr_t handle = 0;
    DWORD pid = 0;
    if (argc != 3 || !ParseDecimal(argv[1], handle) || !ParseDecimal(argv[2], pid)) {
        return ReportError("expectedDecimalHwndAndPid", 2);
    }

    const auto window = reinterpret_cast<HWND>(handle);
    if (!IsOwned(window, pid)) return ReportError("windowOwnershipMismatch", 3);
    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) return ReportError("comInitializationFailed", 4);
    const auto result = Run(window, pid);
    CoUninitialize();
    return result;
}
