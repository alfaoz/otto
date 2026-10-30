#!/bin/bash
# UI previews against a throwaway demo vault (tests/demo.py); the real vault and keychain are untouched.
#   tools/preview.sh <out dir> [surfaces]   surfaces: main,settings,editor,request,site,bypass,browser,import (default main)
# leaves the PNGs in <out dir>; quits the preview app afterwards.
# OTTO_APPEARANCE=light|dark forces the appearance, OTTO_PREVIEW_ENTRY=<name> picks the entry shown,
# OTTO_PREVIEW_IMPORT=<file> loads an export into the import window, OTTO_SNAPSHOT_DELAY=<s> waits longer for windows.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p "$1"
out=$(cd "$1" && pwd)
home="$out/d"  # short: the socket path must fit in 104 bytes
# (the app shares saved window state with the installed otto; ignoring it always opens the main window)
[ -f "$home/vault.kdbx" ] || python3 tests/demo.py core/target/release/otto "$home" >/dev/null
OTTO_HOME="$home" OTTO_DEV_KEY=demo-key-not-secret OTTO_PREVIEW="${2:-main}" OTTO_SNAPSHOT_DIR="$out" \
  build/Otto.app/Contents/MacOS/OttoApp -ApplePersistenceIgnoreState YES >"$out/preview.log" 2>&1 &
pid=$!
sleep "${PREVIEW_WAIT:-6}"
kill "$pid" 2>/dev/null || true
ls "$out"/*.png
