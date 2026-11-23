#include "core/session_worker.hpp"
#include "windows/uia_adapter.hpp"

#include <charconv>
#include <fcntl.h>
#include <io.h>
#include <iostream>

namespace {
using namespace desktop;

struct Policy {
    std::unordered_map<int, std::uint64_t> started;
    std::set<Action> actions;
};

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
        } else {
            return {};
        }
    }
    return policy;
}
} // namespace

int main(int argc, char** argv) {
    try {
        auto policy = parsePolicy(argc, argv);
        if (!policy) {
            std::cerr << "Usage: cpp-agent.exe [--allow-pid PID] [--allow-action invoke] [--allow-action setValue]\n"
                         "Each allowed PID must identify a running process with a readable start time.\n";
            return 2;
        }
        if (_setmode(_fileno(stdin), _O_BINARY) == -1 || _setmode(_fileno(stdout), _O_BINARY) == -1)
            return 1;
        std::ios::sync_with_stdio(false);
        std::cin.tie(nullptr);
        SessionWorker session(windows::makeAdapter, windows::sessionToken(),
            [started = std::move(policy->started)](int pid) {
                const auto allowed = started.find(pid);
                return allowed != started.end() && windows::processStart(pid) == allowed->second;
            }, std::move(policy->actions));
        std::string frame;
        std::uint64_t sequence = 0;
        while (readFrame(std::cin, frame)) {
            const auto start = Clock::now();
            auto request = parseFrame(frame);
            const auto* op = operation(request);
            const auto reply = session.handle(std::move(request));
            const auto status = reply.at("ok").get<bool>() ? "OK" : reply.at("error").at("code").get<std::string>();
            std::cerr << "seq=" << ++sequence << " op=" << op << " status=" << status << " elapsedMs="
                      << std::chrono::duration_cast<std::chrono::milliseconds>(Clock::now() - start).count() << '\n';
            std::cout << reply.dump() << '\n' << std::flush;
            if (!std::cout) return 1;
        }
        return std::cin.bad() ? 1 : 0;
    } catch (const std::exception&) {
        std::cerr << "The native agent could not run the session.\n";
        return 1;
    }
}
