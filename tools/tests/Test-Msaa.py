"""Exercise the MSAA NDJSON contract and measure bounded Windows fixture requests."""
import argparse
from collections import Counter
from contextlib import contextmanager
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import itertools
import json
from pathlib import Path
import platform
import queue
import subprocess
import tempfile
import threading
import time


class Client:
    def __init__(self, process, evidence):
        self.process = process
        self.evidence = evidence
        self.sequence = itertools.count(1)
        self.replies = queue.Queue()
        threading.Thread(target=self.read, daemon=True).start()

    def read(self):
        for line in self.process.stdout:
            self.replies.put(line)
        self.replies.put(None)

    def ask(self, op, expected="OK", request_id=None, **fields):
        request_id = request_id or str(next(self.sequence))
        started = time.perf_counter()
        self.process.stdin.write(json.dumps(dict(id=request_id, op=op, **fields)) + "\n")
        self.process.stdin.flush()
        line = self.replies.get(timeout=25)
        elapsed = (time.perf_counter() - started) * 1000
        assert line is not None, f"No reply for {op}"
        reply = json.loads(line)
        code = "OK" if reply.get("ok") else reply["error"]["code"]
        self.evidence.append({"id": request_id, "op": op, "code": code, "ms": round(elapsed, 3)})
        assert reply["id"] == request_id and code == expected, (op, expected, code)
        return reply.get("result")


@contextmanager
def agent(command, mode, evidence, pid=None, allowed_actions=(), trusted=False):
    flags = ["--backend", mode]
    if pid is not None:
        flags += ["--allow-pid", str(pid)]
    if trusted:
        flags += ["--trust-msaa-identity", str(pid)]
    for action in allowed_actions:
        flags += ["--allow-action", action]
    with subprocess.Popen([*command, *flags], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                          stderr=subprocess.DEVNULL, text=True, encoding="utf-8") as process:
        try:
            yield Client(process, evidence)
        finally:
            process.stdin.close()
            try:
                code = process.wait(timeout=20)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
                raise
            assert code == 0, f"Agent exit {code}"


def read_state(state, name):
    try:
        return (state / name).read_text(encoding="utf-8")
    except (FileNotFoundError, PermissionError):
        return None


def wait_state(state, name, expected):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if read_state(state, name) == expected:
            return
        time.sleep(0.025)
    raise AssertionError(f"Fixture did not publish {name}={expected}")


@contextmanager
def fixture(binary, name, *arguments):
    with tempfile.TemporaryDirectory(prefix="msaa-fixture-") as directory:
        state = Path(directory)
        with subprocess.Popen([binary, str(state), name, *arguments],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as process:
            try:
                wait_state(state, "ready", str(process.pid))
                yield process, state
            finally:
                (state / "close-fixture").touch()
                try:
                    code = process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
                    raise
                assert code == 0, f"Fixture exit {code}"


def window_for(client, pid):
    windows = [row for row in client.ask("listWindows") if row["processId"] == pid]
    assert len(windows) == 1, len(windows)
    return windows[0]


def snapshot(client, window, **fields):
    return client.ask("snapshot", windowId=window, **fields)


def element(capture, role, name=None):
    match = next((row for row in capture["elements"] if row["role"] == role
                  and (name is None or row["name"] == name)), None)
    assert match is not None, f"Fixture element missing: {role}/{name}"
    return match


def weak(row):
    assert row["referenceStrength"] == "weak" and row["actions"] == [], row["role"]


def capabilities(client, mode):
    result = client.ask("getCapabilities")
    assert result["backend"] == ("MSAA" if mode == "msaa" else "multi") and result["available"], result
    assert not result["physicalInput"] and not result["screenshot"]
    operations = {"getCapabilities", "listWindows", "snapshot", "findElement",
                  "getElementInfo", "defaultAction", "setValue", "select"}
    if mode == "multi":
        assert result["defaultBackend"] == "UIA", result
        assert [row["backend"] for row in result["backends"]] == ["UIA", "JAB", "MSAA"], result
        assert result["backends"][-1]["available"]
        operations.add("invoke")
    assert set(result["operations"]) == operations, result


def winforms(command, binary, report):
    evidence = report["frames"]
    allowed = ("select", "defaultAction", "invoke", "setValue")
    with fixture(binary, "MSAA WinForms fixture") as (target, state):
        with agent(command, "multi", evidence, target.pid, allowed, trusted=True) as client:
            capabilities(client, "multi")
            top = window_for(client, target.pid)
            assert top["backends"] == ["UIA", "MSAA"], top
            hwnd = top["windowId"]
            uia = snapshot(client, hwnd, maxDepth=12, maxElements=500)
            assert uia["backend"] == "UIA"
            report["uiaObserved"] = dict(Counter(row["role"] for row in uia["elements"]))
            uia_root = uia["elements"][0]["ref"]
            common = snapshot(client, hwnd, backend="MSAA", maxDepth=16, maxElements=500)
            assert common["backend"] == "MSAA"
            assert "fixture password" not in json.dumps(common)
            assert all("value" not in row and "description" not in row for row in common["elements"])
            report["commonRoles"] = dict(Counter(row["role"] for row in common["elements"]))
            tab = element(common, "TabItem", "Common controls")
            assert tab["selected"] is True
            weak(tab)
            client.ask("snapshot", windowId=hwnd, scopeRef=tab["ref"], backend="UIA", expected="STALE_REFERENCE")
            client.ask("defaultAction", ref=tab["ref"], expected="PATTERN_UNSUPPORTED")
            client.ask("invoke", ref=tab["ref"], expected="PATTERN_UNSUPPORTED")
            list_row = element(common, "List", "Fixture list")
            scoped = snapshot(client, hwnd, scopeRef=list_row["ref"], maxElements=16)
            item = client.ask("findElement", snapshotId=scoped["snapshotId"],
                              locator={"role": "ListItem", "name": "Item two"})
            weak(item)
            assert client.ask("getElementInfo", ref=item["ref"])["name"] == "Item two"
            assert client.ask("getElementInfo", ref=uia_root)["backend"] == "UIA"
            for scenario, position_name in (("replace", "Item two"), ("reorder", "Replacement item"),
                                             ("delete", "Item one")):
                before = snapshot(client, hwnd, backend="MSAA", maxDepth=16, maxElements=500)
                container = element(before, "List", "Fixture list")
                before_list = snapshot(client, hwnd, scopeRef=container["ref"], maxElements=16)
                held = element(before_list, "ListItem", position_name)
                weak(held)
                (state / f"msaa-list-{scenario}").touch()
                wait_state(state, "msaa-list-state.txt", {"replace": "replaced", "reorder": "reordered",
                                                         "delete": "deleted"}[scenario])
                selection = read_state(state, "selected.txt")
                client.ask("getElementInfo", ref=held["ref"], expected="STALE_REFERENCE")
                client.ask("select", ref=held["ref"], expected="PATTERN_UNSUPPORTED")
                assert read_state(state, "selected.txt") == selection
                report.setdefault("listChanges", []).append(scenario)
            (state / "select-page").write_text("1", encoding="utf-8")
            wait_state(state, "page.txt", "1")
            grid = snapshot(client, hwnd, backend="MSAA", maxDepth=24, maxElements=1100)
            report["gridRoles"] = dict(Counter(row["role"] for row in grid["elements"]))
            assert grid["truncated"] and any(row.get("partial") for row in grid["elements"])
            table = element(grid, "Table", "Fixture data grid")
            scoped_grid = snapshot(client, hwnd, scopeRef=table["ref"], maxElements=320)
            report["scopedGridRoles"] = dict(Counter(row["role"] for row in scoped_grid["elements"]))
            rows = [row for row in scoped_grid["elements"] if row["role"] == "Row"]
            assert len(rows) >= 2, "Expected the grid header row and at least one data row"
            row = rows[1]
            weak(row)
            assert client.ask("getElementInfo", ref=row["ref"])["role"] == "Row"
            scoped_row = snapshot(client, hwnd, scopeRef=row["ref"], maxElements=32)
            cell = element(scoped_row, "Cell")
            weak(cell)
            same_cell = client.ask("findElement", snapshotId=scoped_row["snapshotId"],
                                   locator={"name": cell["name"], "role": "Cell"})
            assert same_cell["ref"] == cell["ref"]
            assert client.ask("getElementInfo", ref=cell["ref"])["role"] == "Cell"
            client.ask("setValue", ref=cell["ref"], value="synthetic-grid-value", expected="PATTERN_UNSUPPORTED")
            assert read_state(state, "grid-edit.txt") is None
            assert client.ask("getElementInfo", ref=uia_root)["backend"] == "UIA"
        with agent(command, "msaa", evidence) as client:
            capabilities(client, "msaa")
            assert window_for(client, target.pid)["windowId"] == hwnd
            assert element(snapshot(client, hwnd, maxElements=1100, maxDepth=24), "Table", "Fixture data grid")["backend"] == "MSAA"


def win32(command, binary, report):
    with fixture(binary, "MSAA Win32 fixture") as (target, state):
        with agent(command, "msaa", report["frames"], target.pid, ("defaultAction", "select"), trusted=True) as client:
            hwnd = window_for(client, target.pid)["windowId"]
            shot = snapshot(client, hwnd, maxElements=900, maxDepth=16)
            report["roles"] = dict(Counter(row["role"] for row in shot["elements"]))
            for role, name, action, file in (("ListItem", "Item two", "select", "list.txt"),
                                             ("TabItem", "Tab two", "defaultAction", "tab.txt")):
                before = read_state(state, file)
                row = element(shot, role, name)
                weak(row)
                assert client.ask("getElementInfo", ref=row["ref"])["name"] == name
                client.ask(action, ref=row["ref"], expected="PATTERN_UNSUPPORTED")
                assert before is not None and read_state(state, file) == before


def strong_provider(command, binary, action, report):
    evidence = report["frames"]
    success = {"performed": True, "effectVerified": False}
    is_child = action == "defaultAction"
    arguments = (action, "child") if is_child else (action,)
    with fixture(binary, "MSAA COM fixture", *arguments) as (target, state):
        invalid = subprocess.run([*command, "--backend", "msaa", "--trust-msaa-identity", str(target.pid)],
                                 input=b"", capture_output=True, timeout=8)
        assert invalid.returncode == 2 and not invalid.stdout
        with agent(command, "msaa", evidence, target.pid, (action,)) as untrusted:
            hwnd = window_for(untrusted, target.pid)["windowId"]
            candidate = snapshot(untrusted, hwnd)["elements"][int(is_child)]
            weak(candidate)
            value = {"value": "blocked"} if action == "setValue" else {}
            untrusted.ask(action, ref=candidate["ref"], expected="PATTERN_UNSUPPORTED", **value)
            assert read_state(state, "calls.txt") is None
        with agent(command, "msaa", evidence, target.pid, trusted=True) as denied:
            captured = snapshot(denied, hwnd)["elements"][int(is_child)]
            assert captured["referenceStrength"] == "strong" and action in captured["actions"], captured
            denied.ask(action, ref=captured["ref"], expected="PERMISSION_DENIED")
            assert read_state(state, "calls.txt") is None
        with agent(command, "multi", evidence, target.pid, (action, "invoke"), trusted=True) as client:
            uia = snapshot(client, hwnd, backend="UIA")["elements"][0]["ref"]
            full = snapshot(client, hwnd, backend="MSAA")
            original = full["elements"][int(is_child)]
            if is_child:
                assert full["elements"][0]["referenceStrength"] == "strong"
                original = snapshot(client, hwnd, scopeRef=original["ref"])["elements"][0]
            assert original["referenceStrength"] == "strong" and original["actions"] == [action]
            assert original["name"] == ("" if action == "setValue" else "MSAA identity target")
            observed = {"defaultAction": "invoked", "select": "selected", "setValue": "값 Δ"}.get(action)
            args = {"value": observed} if action == "setValue" else {}
            client.ask("invoke", ref=original["ref"], expected="PATTERN_UNSUPPORTED")
            assert client.ask(action, ref=original["ref"], request_id="applied", **args) == success
            wait_state(state, "effect.txt", observed)
            wait_state(state, "calls.txt", "1")
            if action == "select":
                assert client.ask("getElementInfo", ref=original["ref"])["selected"] is True
            client.ask(action, ref=original["ref"], request_id="applied", expected="DUPLICATE_COMMAND", **args)
            client.ask("invoke", ref=uia, request_id="applied", expected="DUPLICATE_COMMAND")
            assert read_state(state, "calls.txt") == "1"
            (state / "disable-after-default-query").touch()
            client.ask(action, ref=original["ref"], expected="PRECONDITION_FAILED", **args)
            assert read_state(state, "calls.txt") == "1"
            (state / "swap-provider").touch()
            wait_state(state, "swapped", "ready")
            client.ask("getElementInfo", ref=original["ref"], expected="STALE_REFERENCE")
            client.ask(action, ref=original["ref"], expected="STALE_REFERENCE", **args)
            assert read_state(state, "calls.txt") == "1" and read_state(state, "retired-call.txt") is None
            replacement = snapshot(client, hwnd, backend="MSAA")["elements"][int(is_child)]
            (state / "reply-failure").touch()
            client.ask(action, ref=replacement["ref"], request_id="ambiguous", expected="ACTION_OUTCOME_UNKNOWN", **args)
            wait_state(state, "calls.txt", "2")
            client.ask(action, ref=replacement["ref"], request_id="ambiguous", expected="DUPLICATE_COMMAND", **args)
            assert read_state(state, "calls.txt") == "2"
            report["providerCalls"] = 2
            report["applicationEffectObserved"] = True
            if action != "setValue":
                (state / "protect-during-name").touch()
                protected = snapshot(client, hwnd, backend="MSAA")["elements"][int(is_child)]
                assert protected["name"] == "" and protected["actions"] == []
                assert not (state / "protect-during-name").exists()
                report["metadataMaskVerified"] = True


def timeout_recovery(command, identity, forms, report):
    with fixture(identity, "MSAA timeout fixture", "defaultAction") as (silenced, state):
        with fixture(forms, "Independent UIA fixture") as (normal, _):
            with agent(command, "multi", report["frames"], silenced.pid, ("defaultAction",), trusted=True) as client:
                normal_window = window_for(client, normal.pid)["windowId"]
                normal_ref = snapshot(client, normal_window, backend="UIA")["elements"][0]["ref"]
                delayed_window = window_for(client, silenced.pid)["windowId"]
                delayed_ref = snapshot(client, delayed_window, backend="MSAA")["elements"][0]["ref"]
                (state / "delay-role").touch()
                client.ask("getElementInfo", ref=delayed_ref, expected="TIMEOUT")
                assert read_state(state, "role-delayed") == "started"
                assert client.ask("getElementInfo", ref=normal_ref)["backend"] == "UIA"
                wait_state(state, "role-delayed", "finished")
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    rows = client.ask("getCapabilities")["backends"]
                    if rows[-1]["available"]:
                        break
                    time.sleep(0.05)
                else:
                    raise AssertionError("MSAA did not recover")
                client.ask("getElementInfo", ref=delayed_ref, expected="STALE_REFERENCE")
                current = snapshot(client, delayed_window, backend="MSAA")["elements"][0]
                assert current["referenceStrength"] == "strong"
                assert client.ask("defaultAction", ref=current["ref"])["effectVerified"] is False
                wait_state(state, "calls.txt", "1")


class ProcessMemory(ctypes.Structure):
    _fields_ = [("cb", wintypes.DWORD), ("pageFaultCount", wintypes.DWORD)] + [
        (field, ctypes.c_size_t) for field in ("peakWorkingSet", "workingSet", "quotaPeakPaged", "quotaPaged",
                                             "quotaPeakNonPaged", "quotaNonPaged", "pagefile", "peakPagefile",
                                             "privateBytes")]


def resources(process):
    kernel = ctypes.windll.kernel32
    memory = ProcessMemory()
    memory.cb = ctypes.sizeof(memory)
    handle = wintypes.HANDLE(int(process._handle))
    times = [wintypes.FILETIME() for _ in range(4)]
    assert kernel.GetProcessTimes(handle, *(ctypes.byref(field) for field in times))
    assert ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(memory), memory.cb)
    handles = wintypes.DWORD()
    assert kernel.GetProcessHandleCount(handle, ctypes.byref(handles))
    units = sum((field.dwHighDateTime << 32) + field.dwLowDateTime for field in times[2:])
    return {"cpuSeconds": round(units / 10_000_000, 6), "privateBytes": memory.privateBytes,
            "workingSet": memory.workingSet, "handles": handles.value}


def performance(command, binary, duration, report):
    evidence = report["frames"]
    with fixture(binary, "MSAA measurement fixture") as (target, state):
        with agent(command, "msaa", evidence) as client:
            capabilities(client, "msaa")
            hwnd = window_for(client, target.pid)["windowId"]
            for _ in range(3):
                snapshot(client, hwnd, maxDepth=16, maxElements=500)
            start = time.monotonic()
            next_sample = 0
            samples = report["resources"] = []
            measured = len(evidence)
            rounds = 0
            while time.monotonic() - start < duration:
                elapsed = time.monotonic() - start
                if elapsed >= next_sample:
                    samples.append({"elapsedSeconds": round(elapsed, 3), **resources(client.process)})
                    next_sample += 10
                shot = snapshot(client, hwnd, maxDepth=16, maxElements=500)
                item = element(shot, "List", "Fixture list")
                client.ask("getElementInfo", ref=item["ref"])
                rounds += 1
            elapsed = time.monotonic() - start
            samples.append({"elapsedSeconds": round(elapsed, 3), **resources(client.process)})
            cpu = samples[-1]["cpuSeconds"] - samples[0]["cpuSeconds"]
            report.update({"seconds": round(elapsed, 3), "rounds": rounds,
                           "meanAgentCpuPercentOfOneCore": round(100 * cpu / elapsed, 2),
                           "privateBytesDelta": samples[-1]["privateBytes"] - samples[0]["privateBytes"]})
            for op in ("snapshot", "getElementInfo"):
                values = sorted(row["ms"] for row in evidence[measured:] if row["op"] == op)
                report[op] = {"p50Ms": values[(len(values) - 1) // 2], "p95Ms": values[int((len(values) - 1) * .95)]}


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main(options):
    path = Path(options.output)
    report = {"startUtc": datetime.now(timezone.utc).isoformat(), "windows": platform.version(),
              "javaVersion": subprocess.run(["java.exe", "-version"], capture_output=True,
                                            text=True, check=True).stderr.splitlines()[0],
              "fixtureSha256": sha256(options.fixture), "identityFixtureSha256": sha256(options.identity),
              "agent": {}}
    if not options.duration:
        report["win32FixtureSha256"] = sha256(options.win32)
    started = time.monotonic()
    commands = {"Java": ["java.exe", "-XX:+UseSerialGC", "-Xms16m", "-jar", options.jar],
                "Cpp": [options.cpp]}
    if options.cpp_x86:
        commands["CppX86"] = [options.cpp_x86]
    failed = []
    for name, command in commands.items():
        rows = report["agent"][name] = {"sha256": sha256(command[-1]), "checks": {}}
        if options.duration:
            if name == "CppX86":
                continue
            checks = {"performance": lambda row: performance(command, options.fixture, options.duration, row)}
        elif options.only_win32:
            checks = {"win32": lambda row: win32(command, options.win32, row)}
        else:
            checks = {"winforms": lambda row: winforms(command, options.fixture, row)}
            checks["win32"] = lambda row: win32(command, options.win32, row)
            checks.update({action: lambda row, action=action: strong_provider(command, options.identity, action, row)
                           for action in ("defaultAction", "setValue", "select")})
            checks["timeoutRecovery"] = lambda row: timeout_recovery(command, options.identity, options.fixture, row)
        for check, run in checks.items():
            row = rows["checks"][check] = {"frames": []}
            begin = time.monotonic()
            try:
                run(row)
                row["status"] = "PASS"
            except Exception as failure:
                row["status"] = "FAIL"
                row["error"] = repr(failure)
                failed.append(f"{name}/{check}: {failure!r}")
            finally:
                row["wallSeconds"] = round(time.monotonic() - begin, 3)
                report["totalSeconds"] = round(time.monotonic() - started, 3)
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            print(f"{name}/{check}: {row['status']}", flush=True)
    if failed:
        raise SystemExit("\n".join(failed))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jar", default="target/desktop-agent.jar")
    parser.add_argument("--cpp", default="target/cpp-agent/Release/cpp-agent.exe")
    parser.add_argument("--cpp-x86")
    parser.add_argument("--fixture", default="target/framework-fixtures/winforms-framework.exe")
    parser.add_argument("--identity", default="target/cpp-agent/Release/msaa-identity-fixture.exe")
    parser.add_argument("--win32", default="target/framework-fixtures/win32.exe")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--duration", type=int, choices=range(60, 301), metavar="SECONDS")
    group.add_argument("--only-win32", action="store_true")
    parser.add_argument("--output", default="target/msaa-verification.json")
    main(parser.parse_args())
