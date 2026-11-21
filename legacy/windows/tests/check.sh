#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
pe=${1:-build/xp-window-worker.exe}
temp=$(mktemp -d)
trap 'rm -rf "$temp"' EXIT
"${CC:-cc}" -std=c99 -Wall -Wextra -Werror tests/test_json.c -o "$temp/json-test"
"$temp/json-test"
"${OBJDUMP:-objdump}" -p "$pe" > "$temp/pe"
python3 - "$temp/pe" <<'PY'
import pathlib, re, sys
report = pathlib.Path(sys.argv[1]).read_text()
for signature in [
    r'file format pei-i386', r'Magic\s+010b\s+\(PE32\)',
    r'MajorOSystemVersion\s+5\b', r'MinorOSystemVersion\s+1\b',
    r'MajorSubsystemVersion\s+5\b', r'MinorSubsystemVersion\s+1\b',
    r'Subsystem\s+00000003\b',
]:
    assert re.search(signature, report), signature
imports = re.split(r'DLL Name: (\S+)', report)[1:]
expected = {
    'KERNEL32.dll': {'GetCurrentThreadId', 'GetStdHandle', 'ReadFile', 'WriteFile', 'ExitProcess'},
    'USER32.dll': {'CloseDesktop', 'EnumWindows', 'GetProcessWindowStation', 'GetThreadDesktop',
                   'GetUserObjectInformationW', 'GetWindowTextW', 'GetWindowThreadProcessId',
                   'IsWindowVisible', 'OpenInputDesktop'},
}
assert set(imports[::2]) == set(expected), imports[::2]
for dll, body in zip(imports[::2], imports[1::2]):
    # GNU objdump versions differ on whether an Ordinal column is printed.
    rows = re.findall(r'^\s*[0-9a-f]+\s+(?:<none>\s+)?[0-9a-f]+\s+(\w+)\s*$', body, re.M)
    assert set(rows) == expected[dll], (dll, rows)
print('PASS: escaping, integer encoding, bounded writes, i386 PE32 console 5.1 and XP import allowlist')
PY
