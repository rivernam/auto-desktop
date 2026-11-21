#!/bin/sh
# Each GUI check runs in a separate process. A failure never skips its peer.
set -u
LC_ALL=C
export LC_ALL
src_dir=$(CDPATH= cd "$(dirname "$0")" && pwd) || exit 1
if [ "$#" -gt 1 ]; then
    echo "usage: probe.sh [prebuilt-desktop-probe]" >&2
    exit 1
fi
printf 'kernel: '; uname -srm
printf 'userspace bits: '; getconf LONG_BIT
printf 'libc: '; getconf GNU_LIBC_VERSION
if [ -r /etc/redhat-release ]; then cat /etc/redhat-release; fi
if [ -n "${DISPLAY:-}" ]; then echo 'DISPLAY: set'; else echo 'DISPLAY: absent'; fi
if command -v rpm >/dev/null 2>&1; then
    rpm -q glibc libX11 at-spi ORBit2 libbonobo 2>&1
fi
if command -v pkg-config >/dev/null 2>&1; then
    for pkg in x11 cspi-1.0 atspi-2; do
        if pkg-config --exists "$pkg"; then
            printf '%s development package: ' "$pkg"; pkg-config --modversion "$pkg"
        else
            printf '%s development package: missing\n' "$pkg"
        fi
    done
fi
inspect_elf() {
    if command -v file >/dev/null 2>&1; then file -L "$1"; fi
    if command -v readelf >/dev/null 2>&1; then
        readelf -h "$1" | awk '/Class:|Machine:/'
        readelf -d "$1" | awk '/NEEDED/'
        readelf -V "$1" | awk '/Name: GLIBC_/{print}'
    fi
}
# These are loader-cache candidates for installed ABIs. The reads below use
# dlopen from this process, and are the authoritative runtime check.
ld_config=$(command -v ldconfig 2>/dev/null || true)
if [ -z "$ld_config" ] && [ -x /sbin/ldconfig ]; then ld_config=/sbin/ldconfig; fi
if [ -n "$ld_config" ]; then
    "$ld_config" -p 2>/dev/null | awk '$1 == "libX11.so.6" || $1 == "libcspi.so.0" {print $NF}' |
    while IFS= read -r candidate; do inspect_elf "$candidate"; done
fi
if command -v java >/dev/null 2>&1; then
    java -version
    inspect_elf "$(command -v java)"
else
    echo 'JVM: missing'
fi
if [ "$#" -eq 1 ]; then
    probe=$1
else
    build_dir=$(mktemp -d "${TMPDIR:-/tmp}/desktop-probe.XXXXXX") || exit 1
    trap 'rm -rf "$build_dir"' 0
    trap 'exit 1' HUP INT TERM
    probe=$build_dir/desktop-probe
    "${CC:-cc}" -std=gnu89 -Wall -Wextra -O2 "$src_dir/desktop-probe.c" -ldl -o "$probe" || exit 1
fi
inspect_elf "$probe"
overall=0
for surface in x11 atspi1; do
    "$probe" "$surface"
    status=$?
    printf '%s exit=%s\n' "$surface" "$status"
    if [ "$status" -ne 0 ]; then overall=1; fi
done
exit "$overall"
