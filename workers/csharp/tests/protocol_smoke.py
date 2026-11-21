"""Exercise the compiled .NET worker over its production stdin/stdout pipes."""

import argparse
import json
import subprocess


def check(condition, message):
    if not condition:
        raise AssertionError(message)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--expect-unavailable", action="store_true",
                        help="also verify the unavailable desktop response")
    parser.add_argument("command", nargs="+", help="worker executable, optionally preceded by mono")
    args = parser.parse_args()

    capabilities = b'{"op":"getCapabilities"}'
    marker = b"diagnostic-privacy-canary"
    malformed = b'{"op":] ' + marker
    oversized = b" " * (1024 * 1024) + capabilities
    frames = [capabilities, malformed, oversized, capabilities]
    if args.expect_unavailable:
        frames.append(b'{"op":"listWindows"}')
    run = subprocess.run(args.command, input=b"\n".join(frames) + b"\n",
                         capture_output=True, timeout=30, check=True)
    check(marker not in run.stdout + run.stderr, "worker echoed private input into diagnostics")
    replies = [json.loads(line) for line in run.stdout.decode("utf-8").splitlines()]
    check(len(replies) == len(frames), "expected exactly one response per frame")
    for index in (0, 3):
        reply = replies[index]
        check(reply.get("ok") is True, "worker did not answer getCapabilities")
        caps = reply["result"]
        check(type(caps.get("available")) is bool, "invalid availability flag")
        check(caps.get("physicalInput") is False, "unexpected physical-input capability")
        if args.expect_unavailable:
            check(caps["available"] is False, "an interactive provider is unexpectedly available")
    for reply in replies[1:3]:
        check(reply.get("ok") is False and reply.get("error", {}).get("code") == "PRECONDITION_FAILED",
              "rejected frame lacks a structured error")
    if args.expect_unavailable:
        reply = replies[4]
        check(reply.get("ok") is False and reply["error"]["code"] == "BACKEND_UNAVAILABLE",
              "desktop access should fail when no provider is available")
    print("Passed worker framing, malformed and oversized request recovery, and capability checks.")
    if args.expect_unavailable:
        print("Passed unavailable desktop check.")


if __name__ == "__main__":
    main()
