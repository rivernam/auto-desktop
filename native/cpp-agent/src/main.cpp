#include "core/multi_session.hpp"
#include "windows/jab_adapter.hpp"
#include "windows/uia_adapter.hpp"

#include <Windows.h>

#include <charconv>
#include <fcntl.h>
#include <io.h>
#include <iostream>

namespace {
using namespace desktop;

struct Policy {
    std::unordered_map<int, std::uint64_t> started;
    std::set<Action> actions;
    // An explicit choice. A Java Access Bridge failure is reported, never answered through UI Automation.
    bool jab = false;
    // UI Automation and Java Access Bridge side by side, each named by the request that uses it.
    bool multi = false;
    bool backendGiven = false;
    std::wstring jabLibrary;
};

std::wstring widePath(std::string_view text) {
    const int units = MultiByteToWideChar(CP_ACP, MB_ERR_INVALID_CHARS, text.data(), static_cast<int>(text.size()),
                                          nullptr, 0);
    std::wstring result(static_cast<std::size_t>(units > 0 ? units : 0), L'\0');
    if (units > 0) MultiByteToWideChar(CP_ACP, 0, text.data(), static_cast<int>(text.size()), result.data(), units);
    return result;
}

std::optional<Policy> parsePolicy(int argc, char** argv) {
    if (argc % 2 == 0) return {};
    Policy policy;
    for (int index = 1; index < argc; index += 2) {
        const std::string_view flag = argv[index];
        const std::string_view value = argv[index + 1];
        if (flag == "--allow-pid") {
            int pid = 0;
            const auto end = value.data() + value.size();
            const auto parsed = std::from_chars(value.data(), end, pid);
            if (parsed.ec != std::errc{} || parsed.ptr != end || pid <= 0) return {};
            const auto started = windows::processStart(pid);
            if (!started) return {};
            policy.started[pid] = *started;
        } else if (flag == "--allow-action" && isMutation(value)) {
            policy.actions.insert(value == "invoke" ? Action::invoke : Action::setValue);
        } else if (flag == "--backend" && !policy.backendGiven
                   && (value == "uia" || value == "jab" || value == "multi")) {
            policy.backendGiven = true;
            policy.jab = value == "jab";
            policy.multi = value == "multi";
        } else if (flag == "--jab-dll" && policy.jabLibrary.empty() && !value.empty()) {
            policy.jabLibrary = widePath(value);
            // A relative path would be resolved against the working directory.
            if (policy.jabLibrary.size() < 3 || policy.jabLibrary[1] != L':'
                || (policy.jabLibrary[2] != L'\\' && policy.jabLibrary[2] != L'/')) return {};
        } else {
            return {};
        }
    }
    if (!policy.jabLibrary.empty() && !policy.jab && !policy.multi) return {};
    return policy;
}
} // namespace

int main(int argc, char** argv) {
    try {
        auto policy = parsePolicy(argc, argv);
        if (!policy) {
            std::cerr << "Usage: cpp-agent.exe [--allow-pid PID] [--allow-action invoke] [--allow-action setValue] "
                         "[--backend uia|jab|multi] [--jab-dll ABSOLUTE_DLL_PATH]\n"
                         "Each allowed PID must identify a running process with a readable start time.\n";
            return 2;
        }
        if (_setmode(_fileno(stdin), _O_BINARY) == -1 || _setmode(_fileno(stdout), _O_BINARY) == -1)
            return 1;
        std::ios::sync_with_stdio(false);
        std::cin.tie(nullptr);
        const bool jab = policy->jab;
        int status = 0;
        {
            const SessionWorker::AdapterFactory bridge = [library = policy->jabLibrary] {
                return windows::makeJabAdapter(library);
            };
            AllowedProcess allowed = [started = std::move(policy->started)](int pid) {
                const auto known = started.find(pid);
                return known != started.end() && windows::processStart(pid) == known->second;
            };
            // Unloading Java Access Bridge sends untimed messages to every JVM, so library detach is skipped.
            const auto endWithoutDetach = [] { TerminateProcess(GetCurrentProcess(), 1); };
            std::optional<SessionWorker> single;
            std::optional<MultiSession> several;
            std::function<Json(Json)> handle;
            if (policy->multi) {
                // The bridge is not restarted in place: a retired bridge session may have left its
                // library loaded for a silent JVM.
                several.emplace(std::vector<MultiSession::Backend>{{"UIA", windows::makeAdapter, true},
                                                                   {"JAB", bridge, false}},
                                windows::sessionToken(), std::move(allowed), std::move(policy->actions));
                several->onAbandon(endWithoutDetach);
                handle = [&several](Json request) { return several->handle(std::move(request)); };
            } else {
                single.emplace(jab ? bridge : SessionWorker::AdapterFactory(windows::makeAdapter),
                               windows::sessionToken(), std::move(allowed), std::move(policy->actions),
                               requestBudget, jab ? "JAB" : "UIA");
                if (jab) single->onAbandon(endWithoutDetach);
                handle = [&single](Json request) { return single->handle(std::move(request)); };
            }
            std::string frame;
            std::uint64_t sequence = 0;
            while (status == 0 && readFrame(std::cin, frame)) {
                const auto start = Clock::now();
                auto request = parseFrame(frame);
                const auto* op = operation(request);
                const auto reply = handle(std::move(request));
                const auto code = reply.at("ok").get<bool>() ? "OK" : reply.at("error").at("code").get<std::string>();
                std::cerr << "seq=" << ++sequence << " op=" << op << " status=" << code << " elapsedMs="
                          << std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count() << '\n';
                std::cout << reply.dump() << '\n' << std::flush;
                if (!std::cout) status = 1;
            }
            if (status == 0 && std::cin.bad()) status = 1;
        }
        if (windows::jabDetachWouldBlock()) {
            std::cout.flush();
            std::cerr.flush();
            TerminateProcess(GetCurrentProcess(), static_cast<UINT>(status));
        }
        return status;
    } catch (const std::exception&) {
        std::cerr << "The native agent could not run the session.\n";
        return 1;
    }
}
