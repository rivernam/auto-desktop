"""Replay the common no-provider NDJSON cases against packaged agents."""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile


def check(command):
    cases = [
        (b'{"id":"probe","op":"getCapabilities"}', "probe", None),
        (b'{"id":"list","op":"listWindows"}', "list", "BACKEND_UNAVAILABLE"),
        (b'{"id":"first","id":"second","op":"listWindows"}', None, "INVALID_REQUEST"),
        (b'{"id":"bad-utf8-\xff","op":"listWindows"}', None, "INVALID_REQUEST"),
        (b"x" * 65537, None, "INVALID_REQUEST"),
        ('{"id":"검사","op":"unknown"}'.encode(), "검사", "UNKNOWN_OPERATION"),
        (b'{"id":"again","op":"getCapabilities"}', "again", None),
    ]
    process = subprocess.run(command, input=b"\n".join(row[0] for row in cases),
                             capture_output=True, check=True, timeout=20)
    replies = [json.loads(line) for line in process.stdout.decode("utf-8").splitlines()]
    if len(replies) != len(cases):
        raise ValueError("expected exactly one response per frame")
    for reply, (_, expected_id, error) in zip(replies, cases):
        if reply["id"] != expected_id or reply["ok"] != (error is None):
            raise ValueError(reply)
        if error:
            if reply["error"]["code"] != error:
                raise ValueError(reply)
        else:
            caps = reply["result"]
            if any(caps[k] is not False for k in ("available", "physicalInput", "screenshot")) or caps["operations"] != []:
                raise ValueError(caps)
    invalid = subprocess.run([*command, "--invalid-option", "example"], capture_output=True, timeout=20)
    if invalid.returncode != 2 or invalid.stdout:
        raise ValueError("invalid startup options must exit with status 2 and no protocol output")
    clean = subprocess.run(command, input=b"", capture_output=True, check=True, timeout=20)
    if clean.stdout:
        raise ValueError("EOF without requests must have no protocol output")
    return len(cases) + 2


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java", default="java")
    parser.add_argument("--cpp", help="On Windows, also check the C++ agent with an unavailable JAB library.")
    parser.add_argument("jar")
    args = parser.parse_args()
    java = [args.java, "-jar", args.jar]
    if args.cpp:
        with tempfile.TemporaryDirectory(prefix="desktop-agent-contract-") as directory:
            unavailable = ["--backend", "jab", "--jab-dll", str(Path(directory, "missing.dll").resolve())]
            java_count = check(java + unavailable)
            cpp_count = check([args.cpp, *unavailable])
        print(f"PASS: Java {java_count}, C++ {cpp_count} no-provider protocol checks")
    else:
        print(f"PASS: Java {check(java)} no-provider protocol checks")
