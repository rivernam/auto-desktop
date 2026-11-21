#!/bin/sh
set -eu
cd "$(dirname "$0")"
out=${OUT_DIR:-build}
cc=${XP_CC:-i686-w64-mingw32-gcc}
mkdir -p "$out"
"$cc" -std=c99 -Os -march=i686 -Wall -Wextra -Werror -ffreestanding -fno-builtin \
    -fno-stack-protector -fno-asynchronous-unwind-tables -nostdlib -s \
    -Wl,--entry,_worker_entry@0,--subsystem,console:5.01,--major-os-version,5,--minor-os-version,1 \
    -Wl,--no-insert-timestamp -o "$out/xp-window-worker.exe" xp_window_worker.c -luser32 -lkernel32
