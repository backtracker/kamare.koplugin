#!/bin/sh
# Run the Kamare offline-cache unit tests against the KOReader emulator runtime.
# No network, no Kavita credentials required.
set -e
KOREADER_DIR=${KOREADER_DIR:-/home/nick/koreader-emulator/lib/koreader}
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd)
cd "$KOREADER_DIR"
exec ./luajit "$REPO_DIR/spec/run.lua" "$@"
