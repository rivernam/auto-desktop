"""Replay the common no-provider NDJSON cases on Linux against a packaged agent."""
import argparse
import json
import subprocess


def check(java, jar):
    cases = [
        (b'{"id":"probe","op":"getCapabilities"}', "probe", None),
        (b'{"id":"list","op":"listWindows"}', "list", "BACKEND_UNAVAILABLE"),
        (b'{"id":"first","id":"second","op":"listWindows"}', None, "INVALID_REQUEST"),
        (b'{"id":"bad-utf8-\xff","op":"listWindows"}', None, "INVALID_REQUEST"),
        (b"x" * 65537, None, "INVALID_REQUEST"),
        ('{"id":"검사","op":"unknown"}'.encode(), "검사", "UNKNOWN_OPERATION"),
        (b'{"id":"again","op":"getCapabilities"}', "again", None),
    ]
    process = subprocess.run([java, "-jar", jar], input=b"\n".join(row[0] for row in cases),
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
    print(f"PASS: {len(cases)} no-provider protocol cases ({jar})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--java", default="java")
    parser.add_argument("jar")
    args = parser.parse_args()
    check(args.java, args.jar)
