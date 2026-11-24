#include "core/session_worker.hpp"
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
        } else if (flag == "--backend" && !policy.backendGiven && (value == "uia" || value == "jab")) {
            policy.backendGiven = true;
            policy.jab = value == "jab";
        } else if (flag == "--jab-dll" && policy.jabLibrary.empty() && !value.empty()) {
            policy.jabLibrary = widePath(value);
            // A relative path would be resolved against the working directory.
            if (policy.jabLibrary.size() < 3 || policy.jabLibrary[1] != L':'
                || (policy.jabLibrary[2] != L'\\' && policy.jabLibrary[2] != L'/')) return {};
        } else {
            return {};
        }
    }
    if (!policy.jabLibrary.empty() && !policy.jab) return {};
    return policy;
}
} // namespace

int main(int argc, char** argv) {
    try {
        auto policy = parsePolicy(argc, argv);
        if (!policy) {
            std::cerr << "Usage: cpp-agent.exe [--allow-pid PID] [--allow-action invoke] [--allow-action setValue] "
                         "[--backend uia|jab] [--jab-dll ABSOLUTE_DLL_PATH]\n"
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
            SessionWorker::AdapterFactory factory = windows::makeAdapter;
            if (jab) factory = [library = policy->jabLibrary] { return windows::makeJabAdapter(library); };
            SessionWorker session(std::move(factory), windows::sessionToken(),
                [started = std::move(policy->started)](int pid) {
                    const auto allowed = started.find(pid);
                    return allowed != started.end() && windows::processStart(pid) == allowed->second;
                }, std::move(policy->actions), requestBudget, jab ? "JAB" : "UIA");
            // Unloading Java Access Bridge sends untimed messages to every JVM, so library detach is skipped.
            if (jab) session.onAbandon([] { TerminateProcess(GetCurrentProcess(), 1); });
            std::string frame;
            std::uint64_t sequence = 0;
            while (status == 0 && readFrame(std::cin, frame)) {
                const auto start = Clock::now();
                auto request = parseFrame(frame);
                const auto* op = operation(request);
                const auto reply = session.handle(std::move(request));
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
