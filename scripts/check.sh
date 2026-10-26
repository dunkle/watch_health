#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
SWIFT_BIN="${SWIFT_BIN:-swift}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-/tmp/watchmind-clang-cache}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-/tmp/watchmind-cache}"
mkdir -p "$CLANG_MODULE_CACHE_PATH" "$XDG_CACHE_HOME" /tmp/watchmind-config /tmp/watchmind-security
python3 scripts/check-localizations.py
"$SWIFT_BIN" test --cache-path "$XDG_CACHE_HOME" --config-path /tmp/watchmind-config --security-path /tmp/watchmind-security -j 4
"${SWIFT_BIN%swift}swiftc" -frontend -parse iOS/*.swift Watch/*.swift
git diff --check
